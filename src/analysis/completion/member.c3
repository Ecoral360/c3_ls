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
 The completion context reduced to what type resolution needs, so
 completion and goto definition resolve through the same code.
*>
fn TypeContext type_context(Context* ctx) {
	return { .session = ctx.session, .file = ctx.file, .mod = ctx.mod, .location = ctx.location };
}

<*
 One link of a member access chain, as written in the source.

 `is_call` marks a name that was followed by a balanced '(...)', so it
 stands for the call's result rather than the name itself.
*>
struct ChainSegment {
	String name;
	TokenKind kind;
	Range range;
	bool is_call;
}

<*
 Work out whether the cursor sits after a '.' or a '::', and what the
 thing on the left of it resolves to.

 Driven off the token list rather than the AST: a file being typed into
 rarely parses, and a half written access is exactly the shape the parser
 turns into an error node.
*>
fn void detect_access_context(Context* ctx) {
	ctx.access = NONE;
	ctx.base_identifier = "";
	ctx.base_node = null;

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

	// The member being typed is a token of its own: in 'a.b' the cursor
	// sits after 'b', so the operator is one further back.
	if (op_idx >= 1 && is_name_token(ctx.tokens[op_idx].kind)) op_idx--;
	if (op_idx < 1) return;

	Token op_tok = ctx.tokens[op_idx];
	if (op_tok.kind != DOT && op_tok.kind != SCOPE) return;

	ChainSegment[] chain = extract_access_chain(ctx, op_idx);
	if (chain.len == 0) return;

	ChainSegment base = chain[chain.len - 1];

	ctx.access = (op_tok.kind == SCOPE) ? LspAccessKind.STATIC : LspAccessKind.INSTANCE;
	ctx.base_identifier = base.name;
	ctx.base_location = base.range.start;
	ctx.base_node = resolve_chain(ctx, chain);
}

fn bool is_name_token(TokenKind kind) @local {
	switch (kind) {
		case IDENT:
		case TYPE_IDENT:
		case HASH_IDENT:
		case AT_IDENT:
			return true;
		default:
			return false;
	}
}

<*
 Read the access chain that ends at the operator in `op_idx`, walking
 backwards until something that cannot be part of one.

 'a.b.c' yields [a, b, c]; 'foo().x' yields [foo (a call), x]; and
 'bar(a.b' stops at the '(' and yields [a, b], which is what the cursor
 inside those parentheses is actually working on.
*>
fn ChainSegment[] extract_access_chain(Context* ctx, sz op_idx) @private {
	List{ChainSegment} segments;
	segments.tinit();

	sz i = op_idx - 1;

	while (i >= 0) {
		bool is_call = false;

		// A trailing '(...)' or '[...]' belongs to the name in front of it.
		// Indexing needs no separate flag: raw_type_identifier already
		// unwraps a slice or array type down to its element.
		while (i >= 0 && (ctx.tokens[i].kind == RPAREN || ctx.tokens[i].kind == RBRACKET)) {
			if (ctx.tokens[i].kind == RPAREN) is_call = true;

			sz open = matching_open(ctx, i);
			if (open < 0) return segments.to_tarray();
			i = open - 1;
		}

		if (i < 0) break;

		Token tok = ctx.tokens[i];
		if (!is_name_token(tok.kind)) break;

		segments.insert_at(0, { .name = tok.value, .kind = tok.kind, .range = tok.range, .is_call = is_call });
		i--;

		if (i < 0 || (ctx.tokens[i].kind != DOT && ctx.tokens[i].kind != SCOPE)) break;
		i--;
	}

	return segments.to_tarray();
}

<*
 Index of the bracket that opens the one at `close_idx`, or -1.
*>
fn sz matching_open(Context* ctx, sz close_idx) @local {
	TokenKind close = ctx.tokens[close_idx].kind;
	TokenKind open  = close == TokenKind.RPAREN ? TokenKind.LPAREN : TokenKind.LBRACKET;

	int depth = 0;
	for (sz i = close_idx; i >= 0; i--) {
		TokenKind kind = ctx.tokens[i].kind;

		if (kind == close) {
			depth++;
			continue;
		}

		if (kind == open) {
			depth--;
			if (depth == 0) return i;
		}
	}

	return -1;
}

<*
 The declaration of the type the chain evaluates to, or null when a link
 cannot be followed.

 This is all the type resolution there is: the analyzer's sema::resolve
 is a stub and TypeInfo.resolved is never populated, so each hop goes
 name -> declaration -> written type name -> declaration by hand.
*>
fn Node* resolve_chain(Context* ctx, ChainSegment[] chain) {
	if (chain.len == 0) return null;

	Node* current = resolve_chain_root(ctx, chain[0]);

	for (usz i = 1; i < chain.len && current != null; i++) {
		current = resolve_member_type(ctx, current, chain[i]);
	}

	return current;
}

fn Node* resolve_chain_root(Context* ctx, ChainSegment seg) @local {
	// 'foo()' stands for whatever foo returns.
	if (seg.is_call) return analysis::return_type_decl(
		type_context(ctx),
		analysis::find_decl(type_context(ctx), seg.name, false)
	);

	// A variable shadows a type of the same name, so the scope chain wins.
	if (ctx.file) {
		Scope* leaf        = core::find_deepest_scope(ctx.file.root_rt_scope, ctx.location);
		VariableInfo* info = leaf ? scope::get_variable(leaf, seg.name) : null;

		if (info && info.node && info.node.kind == VAR_DECL) {
			return analysis::type_decl_of(type_context(ctx), info.node.as(VarDecl).type);
		}
	}

	// Otherwise the name is the type itself, the 'Point' of 'Point::'.
	return analysis::find_decl(type_context(ctx), seg.name, true);
}

<*
 Follow one '.member' hop from a type declaration.
*>
fn Node* resolve_member_type(Context* ctx, Node* type_decl, ChainSegment seg) @local {
	if (!type_decl) return null;

	// 'o.method().x' - the hop is through what the method returns.
	if (seg.is_call) {
		return analysis::return_type_decl(
			type_context(ctx),
			analysis::find_method(type_context(ctx), type_decl, seg.name)
		);
	}

	if (type_decl.kind != STRUCT_DECL) return null;

	foreach (Node* field_node : type_decl.as(StructDecl).fields) {
		if (!field_node || field_node.kind != VAR_DECL) continue;

		VarDecl* field = field_node.as(VarDecl);
		if (!field.name || field.name.text != seg.name) continue;

		return analysis::type_decl_of(type_context(ctx), field.type);
	}

	return null;
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

	if (ctx.base_node) {
		log::debug("Injecting reflection properties for type: %s", ctx.base_node.kind);
		analysis::inject_type_properties(ctx, items, ctx.base_node.kind);
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
	return analysis::variable_type(type_context(ctx), name);
}


fn bool provide_instance_access(Context* ctx, List{CompletionItem}* items) {
	if (!ctx.base_node) return false;

	if (ctx.base_node.kind == STRUCT_DECL) {
		collect_struct_fields(ctx, items, ctx.base_node.as(StructDecl));
	}

	// An enum or a typedef has no fields but can still carry methods.
	collect_methods_for_type(ctx, items, ctx.base_node);
	return true;
}

fn void collect_methods_for_type(Context* ctx, List{CompletionItem}* items, Node* type_decl) {
	String type_name = cursor::spelling(type_decl, tmem) ?? "";
	if (type_name.len == 0) return;

	foreach (SymbolRef ref : ctx.session.methods_for(type_name)) {
		if (!analysis::reachable_method(type_context(ctx), type_decl, ref)) continue;

		String name = cursor::spelling(ref.node, tmem) ?? "";
		if (name.len == 0) continue;
		if (!analysis::matches_prefix(ctx, name)) continue;

		add_symbol_completion(ctx, items, name, ref.node, type_name);
	}
}


fn void collect_module_symbols(Context* ctx, List{CompletionItem}* items, Module* mod) {
	foreach (Node* node : mod.nodes) {
		if (!node) continue;
		if (node.visibility != PUBLIC) continue;
		if (node.kind == MODULE_DECL || node.kind == IMPORT_DECL) continue;

		// A method reached through its module is not something that can be
		// written: 'InStream.read' lives in std::io, but 'io::read' is not
		// a call. It is offered on the instance instead.
		if (core::method_target(node).len > 0) continue;

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
