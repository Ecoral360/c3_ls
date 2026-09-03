module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::lexer;

import lsp::core;

import std::collections::list;

<*
 Where the cursor sits inside a call's argument list.

 `open` is the index of the '(' that is still open at the cursor, so
 everything from there to the cursor is what has been written of the
 arguments so far.
*>
struct CallSite @local {
	bool found;
	sz open;
}

<*
 The innermost call whose argument list the cursor is inside.

 Read off the token list, not the AST: `lst.init(initial` has no closing
 parenthesis, and the parser answers a half written call with the
 enclosing declaration rather than a CallExpr.
*>
fn CallSite call_site_at(Context* ctx) @local {
	sz cursor_idx = ctx.tokens.len();
	for (sz i = 0; i < ctx.tokens.len(); i++) {
		if (!analysis::is_before(ctx.tokens[i].range.start, ctx.location)) {
			cursor_idx = i;
			break;
		}
	}

	int depth;

	for (sz i = cursor_idx - 1; i >= 0; i--) {
		switch (ctx.tokens[i].kind) {
			case RPAREN:
			case RBRACKET:
				depth++;
			case LBRACKET:
				if (depth == 0) return { };
				depth--;
			case LPAREN:
				// The first '(' with nothing closing it is the call the
				// cursor is writing arguments for.
				if (depth == 0) return { .found = true, .open = i };
				depth--;
			case LBRACE:
			case RBRACE:
			case EOS:
				// A statement boundary: whatever came before it is a
				// different expression entirely.
				if (depth == 0) return { };
			default:
				break;
		}
	}

	return { };
}

<*
 The function or macro the callee in front of `open` names, or null.
*>
fn Node* resolve_callee(Context* ctx, sz open) @local {
	ChainSegment[] chain = extract_access_chain(ctx, open);
	if (chain.len == 0) return null;

	TypeContext types = type_context(ctx);
	ChainSegment last = chain[chain.len - 1];

	if (chain.len == 1) return callable_or_null(analysis::find_decl(types, last.name, false));

	Node* base = resolve_chain(ctx, chain[:chain.len - 1]);
	if (base) {
		Node* member = analysis::find_member(types, base, last.name);
		if (member) return callable_or_null(member);
	}

	QualifiedSymbol qualified = { .name = last.name, .path = chain[chain.len - 2].name };
	foreach (SymbolRef ref : analysis::lookup_symbol(ctx.session, ctx.mod, qualified)) {
		if (analysis::is_callable_decl(ref.node)) return ref.node;
	}

	return null;
}

fn Node* callable_or_null(Node* node) @local {
	return node && analysis::is_callable_decl(node) ? node : null;
}

fn NodeArray callee_params(Node* callee) @local {
	switch (callee.kind) {
		case FN_DECL:
			return callee.as(FnDecl).params;
		case MACRO_DECL:
			return callee.as(MacroDecl).params;
		default:
			return { };
	}
}

<*
 What the argument list already holds between the '(' and the cursor.
*>
struct ArgumentsSoFar @local {
	<*
	 Counts the finished arguments written without a name.
	 They fill the parameters in order, so that many can be matched off the front
	 of the list. C3 takes a named argument only after the positional ones,
	 so counting stops at the first name rather than carrying on past it.
	*>
	usz positional;
	<*
	 Marks the argument being typed as already carrying its own `name:`
	 The cursor is past the name and on the value, where a
	 parameter name is not what goes next.
	*>
	bool in_value;
}

<*
 True when the argument starting at `start` opens with `name:`.
*>
fn bool is_named_argument(Context* ctx, sz start) @local {
	if (start + 1 >= ctx.tokens.len()) return false;

	// Both halves have to be written already; the token after a trailing
	// comma is whatever follows the unfinished call.
	if (!analysis::is_before(ctx.tokens[start + 1].range.start, ctx.location)) return false;

	return ctx.tokens[start].kind == IDENT && ctx.tokens[start + 1].kind == COLON;
}

fn ArgumentsSoFar arguments_so_far(Context* ctx, sz open) @local {
	ArgumentsSoFar written;

	int depth;
	bool positional = true;
	sz arg_start    = open + 1;

	for (sz i = open + 1; i < ctx.tokens.len(); i++) {
		if (!analysis::is_before(ctx.tokens[i].range.start, ctx.location)) break;

		switch (ctx.tokens[i].kind) {
			case LPAREN:
			case LBRACKET:
			case LBRACE:
				depth++;
			case RPAREN:
			case RBRACKET:
			case RBRACE:
				depth--;
			case COMMA:
				if (depth > 0) break;

				if (is_named_argument(ctx, arg_start)) {
					positional = false;
				} else if (positional) {
					written.positional++;
				}

				arg_start = i + 1;
			default:
				break;
		}
	}

	written.in_value = is_named_argument(ctx, arg_start);

	return written;
}

<*
 True when `name:` has already been written in this argument list.
*>
fn bool argument_already_named(Context* ctx, sz open, String name) @local {
	for (sz i = open + 1; i < ctx.tokens.len(); i++) {
		if (!analysis::is_before(ctx.tokens[i].range.start, ctx.location)) break;
		if (ctx.tokens[i].kind != IDENT || ctx.tokens[i].value != name) continue;
		if (i + 1 < ctx.tokens.len() && ctx.tokens[i + 1].kind == COLON) return true;
	}

	return false;
}

fn void provide_named_args(Context* ctx, List{CompletionItem}* items) {
	if (ctx.access != NONE) return;

	CallSite site = call_site_at(ctx);
	if (!site.found) return;

	Node* callee = resolve_callee(ctx, site.open);
	if (!callee) return;

	ArgumentsSoFar written = arguments_so_far(ctx, site.open);
	if (written.in_value) return;

	usz position;

	foreach (Node* param_node : callee_params(callee)) {
		if (!param_node || param_node.kind != VAR_DECL) continue;

		VarDecl* param = param_node.as(VarDecl);

		// The receiver is not written at the call site, so it takes up no
		// position in it either.
		if (param.var_flags.is_self) continue;

		usz slot = position;
		position++;

		// A positional argument has already filled this one.
		if (slot < written.positional) continue;
		if (!param.name || param.name.text.len == 0) continue;

		String name = param.name.text;
		if (ctx.prefix.len > 0 && !name_matches_fuzzy(name, ctx.prefix)) continue;
		if (argument_already_named(ctx, site.open, name)) continue;

		String type_name = param.type ? (cursor::spelling(param.type, ctx.allocator) ?? "") : "";

		items.push(
			{
				.label = ctx.dstring_pool.cat(name, ":"),
				.kind = FIELD,
				.detail = param.init_expr ? ctx.dstring_pool.cat(type_name, " = ...") : type_name,
				.insert_text = ctx.dstring_pool.cat(name, ": "),
				.filter_text = name,
				.sort_text = ctx.dstring_pool.cat("0002_", name),
				.documentation = { .value = "Named argument." }
			}
		);
	}
}