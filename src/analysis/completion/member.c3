module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::lexer;
import analyzer::sema;
import analyzer::sema::scope;

import lsp::core;

import std::collections::list;
import std::collections::map;

import uri;

<*
 check for '.' or '::'
*>
fn void detect_access_context(Context* ctx) {
	ctx.access = NONE;
	ctx.base_identifier = "";

	if (ctx.tokens.len() < 2) return;

	sz op_idx = -1;
	for (sz i = 0; i < ctx.tokens.len(); i++) {
		// If this token starts at or past the cursor, the operator must be the previous one
		if (!analysis::is_before(ctx.tokens[i].range.start, ctx.location)) {
			op_idx = i - 1;
			break;
		}
	}
	// If the cursor is at the very end of the file, the operator is the last token
	if (op_idx == -1) op_idx = ctx.tokens.len() - 1;
	if (op_idx < 1) return; // Need at least an identifier + operator
	Token op_tok = ctx.tokens[op_idx];
	Token base_tok = ctx.tokens[op_idx - 1];

	if (op_tok.kind == IDENT) {
		op_tok = ctx.tokens[op_idx - 1];
		base_tok = ctx.tokens[op_idx - 2];
	} 

	if (op_tok.kind == DOT || op_tok.kind == SCOPE) {
		// Ensure the token right before it is the base identifier
		switch (base_tok.kind) {
			case IDENT:
			case TYPE_IDENT:
			case HASH_IDENT:
			case AT_IDENT:
				ctx.access = (op_tok.kind == SCOPE) ? LspAccessKind.STATIC : LspAccessKind.INSTANCE;
				ctx.base_identifier = base_tok.value;
				ctx.base_location = base_tok.range.start;
			default:
				break;
		}
	}
}

<*
 @returns "true if this consumed the completion (context locked to member access)"
*>
fn bool provide_member_access(Context* ctx, List{CompletionItem}* items) {
	if (ctx.access == NONE || ctx.base_identifier.len == 0) return false;
	switch (ctx.access) {
		// resolve '::' with a order of
		// (ident) locals & params -> module path
		// (type_ident) TypeResolution
		case STATIC:
			return provide_static_access(ctx, items);
		case INSTANCE:
			return provide_instance_access(ctx, items);

		default:
	}

	return false;
}

fn bool provide_static_access(Context* ctx, List{CompletionItem}* items) {
	provide_module_paths(ctx, items);

	Node* var_type = resolve_variable_type(ctx, ctx.base_identifier);
	if (var_type) {
		log::debug("Injecting reflection properties for instance variable type: %s", var_type.kind);
		analysis::inject_type_properties(ctx, items, var_type.kind);
		return true;
	}

	String current_module = ctx.mod ? ctx.mod.name : "";
	Module* target_mod    = analysis::find_module_by_identifier(ctx.session, current_module, ctx.base_identifier);
	if (target_mod) {
		collect_module_symbols(ctx, items, target_mod);
		return true;
	}

	List{SymbolRef} candidates = ctx.session.find_symbols(ctx.base_identifier);
	if (candidates.len() > 0 && candidates[0].node) {
		analysis::inject_type_properties(ctx, items, candidates[0].node.kind);
		return true;
	}

	return false;
}

<*
 Declaration of the type that variable `name` was declared with, or null.

 This is the only type resolution available: sema::resolve is a stub and
 TypeInfo.resolved is never populated, so the chain has to be walked by
 hand. Name to VarDecl through the scope chain, VarDecl to its written
 type name, then that name back through the symbol index.

 It follows one hop only. A chain like `a.b.c` needs the type of a field,
 which means resolving the field's own declaration, and the index is
 keyed by bare name, so that is left until the analyzer can answer it.
*>
fn Node* resolve_variable_type(Context* ctx, String name) {
	if (!ctx.file || name.len == 0) return null;

	Scope* leaf = core::find_deepest_scope(ctx.file.root_rt_scope, ctx.location);
	if (!leaf) return null;

	VariableInfo* info = scope::get_variable(leaf, name);
	if (!info || !info.node || info.node.kind != VAR_DECL) return null;

	VarDecl* decl = info.node.as(VarDecl);
	if (!decl.type) return null;

	String type_name = cursor::raw_type_identifier(decl.type) ?? "";
	if (type_name.len == 0) return null;

	// The index is keyed by bare name, and a name like 'Point' is declared
	// in more than one module often enough that taking the first match
	// picks a stdlib type and offers its fields. Prefer the current
	// module's declaration, and only then fall back to any other.
	String current = ctx.mod ? ctx.mod.name : "";
	Node* fallback;

	foreach (SymbolRef ref : ctx.session.find_symbols(type_name)) {
		if (!ref.node || !is_type_decl(ref.node)) continue;
		if (current.len > 0 && ref.module_name == current) return ref.node;
		if (!fallback) fallback = ref.node;
	}

	return fallback;
}

fn bool is_type_decl(Node* node) @local {
	switch (node.kind) {
		case STRUCT_DECL:
		case ENUM_DECL:
		case TYPEDEF_DECL:
		case INTERFACE_DECL:
			return true;
		default:
			return false;
	}
}

<*
 Members reachable through '.' on a variable.

 Only direct fields for now; there is no method registry to draw from,
 and a base whose type does not resolve deliberately produces nothing
 rather than falling back to the global list, which would offer keywords
 and unrelated symbols straight after a dot.
*>
fn bool provide_instance_access(Context* ctx, List{CompletionItem}* items) {
	Node* type_decl = resolve_variable_type(ctx, ctx.base_identifier);
	if (!type_decl) return false;

	switch (type_decl.kind) {
		case STRUCT_DECL:
			collect_struct_fields(ctx, items, type_decl.as(StructDecl));
			return true;
		default:
			return false;
	}
}

fn void collect_module_symbols(Context* ctx, List{CompletionItem}* items, Module* mod) {
	foreach (Node* node : mod.nodes) {
		if (!node) continue;
		if (node.visibility != PUBLIC) continue;
		if (node.kind == MODULE_DECL || node.kind == IMPORT_DECL) continue;

		String symbol_name = cursor::spelling(node, tmem) ?? "";
		if (symbol_name.len == 0) continue;
		if (ctx.prefix.len > 0 && !symbol_name.contains(ctx.prefix)) continue;

		add_symbol_completion(ctx, items, symbol_name, node, ctx.base_identifier);
	}
}

fn void collect_struct_fields(Context* ctx, List{CompletionItem}* items, StructDecl* str_decl) {
	foreach (field_node : str_decl.fields) {
		if (field_node.kind != VAR_DECL) continue;
		VarDecl* field = field_node.as(VarDecl);

		String name = field.name.text;
		if (ctx.prefix.len > 0 && !name.contains(ctx.prefix)) continue;

		items.push(
			{ .label = name, .kind = FIELD, .detail = field.type ? (cursor::spelling(field.type, tmem) ?? "") : "" }
		);
	}
}