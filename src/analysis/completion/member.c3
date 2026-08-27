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
	if (op_tok.kind == DOT || op_tok.kind == SCOPE) {
		// Ensure the token right before it is the base identifier
		Token base_tok = ctx.tokens[op_idx - 1];
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

			{
				return provide_static_access(ctx, items);
			}
		case INSTANCE:

			{
				return provide_instance_access(ctx, items);
			}

		default:
	}

	return false;
}

fn bool provide_static_access(Context* ctx, List{CompletionItem}* items) {
	provide_module_paths(ctx, items);

	if (ctx.file) {
		Scope* leaf        = core::find_deepest_scope(ctx.file.root_scope, ctx.location);
		VariableInfo* info = leaf ? scope::get_variable(leaf, ctx.base_identifier) : null;
		if (info && info.node) {
			return provide_type_static_completions(ctx, items, info.node);
		}
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
 TODO: member completion through an expression chain is disabled.

 It needed cursor::resolve_chained_type, which the analyzer removed along
 with the sema type resolution it was built on (sema::resolve is a stub
 and TypeInfo.resolved is never populated). Re-enable once the analyzer
 can resolve a variable's declared type back to a declaration node.
*>
fn bool provide_instance_access(Context* ctx, List{CompletionItem}* items) {
	return false;
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

fn bool provide_type_static_completions(Context* ctx, List{CompletionItem}* items, Node* var_def) {
	String type_spelling = cursor::raw_type_identifier(var_def) ?? "";
	if (type_spelling.len == 0) return false;

	List{SymbolRef} candidates = ctx.session.find_symbols(type_spelling);
	if (candidates.len() == 0) return false;
	if (!candidates[0].node) return false;

	log::debug("Injecting reflection properties for instance variable type: %s", type_spelling);
	analysis::inject_type_properties(ctx, items, candidates[0].node.kind);
	return true;
}