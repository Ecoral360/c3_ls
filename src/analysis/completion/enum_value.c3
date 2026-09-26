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

fn Node* inferred_enum(Context* ctx) {
	Node* enum_decl = switch_case_enum(ctx);
	if (!enum_decl) enum_decl = argument_enum(ctx);
	if (!enum_decl) enum_decl = init_field_enum(ctx);
	if (!enum_decl) enum_decl = operand_enum(ctx);
	if (!enum_decl) enum_decl = return_enum(ctx);

	if (enum_decl && enum_decl.kind == ENUM_DECL) return enum_decl;

	return null;
}

<*
 The enum value a bare name stands for, with the enum it belongs to.
*>
fn MemberResolution inferred_enum_value(
	LspSession* session,
	FileEntry* file,
	Module* mod,
	Location location,
	String name
) {
	if (!file || !file.sf || name.len == 0) return { };

	Context ctx = context_at(session, file, mod, location);

	Node* enum_decl = inferred_enum(&ctx);
	if (!enum_decl) return { };

	Node* value = enum_value_named(enum_decl, name);
	if (!value) return { };

	return { .decl = value, .type_decl = enum_decl };
}

<*
 The value of `enum_decl` written `name`, or null.
*>
fn Node* enum_value_named(Node* enum_decl, String name) {
	if (!enum_decl || enum_decl.kind != ENUM_DECL) return null;

	foreach (Node* variant : enum_decl.as(EnumDecl).variants) {
		if (!variant || variant.kind != VAR_DECL) continue;

		VarDecl* value = variant.as(VarDecl);
		if (value.name && value.name.text == name) return variant;
	}

	return null;
}

<*
 Offer the values of `enum_decl` the way a case label takes them: bare,
 with no type in front.
*>
fn void provide_enum_values(Context* ctx, List{CompletionItem}* items, Node* enum_decl) {
	if (!enum_decl || enum_decl.kind != ENUM_DECL) return;

	EnumDecl* decl   = enum_decl.as(EnumDecl);
	String type_name = decl.name ? decl.name.text : "";

	foreach (Node* variant : decl.variants) {
		if (!variant || variant.kind != VAR_DECL) continue;

		VarDecl* value = variant.as(VarDecl);
		if (!value.name) continue;

		String name = value.name.text;
		if (!matches_typed(ctx, name)) continue;

		items.push(
			{
				.label = name,
				.kind = ENUM_MEMBER,
				.detail = type_name,
				.sort_text = ctx.dstring_pool.cat("0000_", name),
				.data = ctx.dstring_pool.format("%d;%s", (ulong)variant.id, name),
			}
		);
	}
}

<*
 The enum being switched over, when the cursor is writing a case label of
 that switch. Null everywhere else, the body of the switch included.
*>
fn Node* switch_case_enum(Context* ctx) @local {
	if (!writing_a_case(ctx)) return null;

	sz close = switch_condition_close(ctx);
	if (close < 0) return null;

	return resolve_chain(ctx, extract_access_chain(ctx, close));
}

<*
 The enum the argument being typed has to be, when the parameter it fills
 was declared as one.
*>
fn Node* argument_enum(Context* ctx) @local {
	CallSite site = call_site_at(ctx);
	if (!site.found) return null;

	Node* callee = resolve_callee(ctx, site.open);
	if (!callee) return null;

	VarDecl* param = parameter_for(callee, arguments_so_far(ctx, site.open));
	if (!param || !param.type) return null;

	// The parameter's type is written where the callable is declared,
	// which is rarely the file the call is in.
	return analysis::type_decl_of(type_context(ctx), param.type, ctx.session.entry_for_node(callee));
}

<*
 The enum on the left of the `==` or `=` the cursor is writing the right
 side of, as in `if (shade == ` and `shade = `.
*>
fn Node* operand_enum(Context* ctx) @local {
	sz op = operator_before_cursor(ctx);
	if (op < 0) return null;

	return resolve_chain(ctx, extract_access_chain(ctx, op));
}

<*
 The enum the field being initialized takes, as in `{ .shade = `.
*>
fn Node* init_field_enum(Context* ctx) @local {
	InitSite site = init_site_at(ctx);
	if (!site.found) return null;

	Node* type_decl = initializer_type(ctx, site.brace);

	Node* field = init_field(ctx, site.brace, type_decl);
	if (!field) return null;

	return analysis::type_decl_of(type_context(ctx), field.as(VarDecl).type, ctx.session.entry_for_node(type_decl));
}

<*
 The field the value being typed fills: the one `.name =` designates, or
 the next one in order.
*>
fn Node* init_field(Context* ctx, sz brace, Node* type_decl) @local {
	sz i = token_before_value(ctx);
	if (i < 0) return null;

	if (ctx.tokens[i].kind == EQ) {
		if (i < 2 || ctx.tokens[i - 1].kind != IDENT || ctx.tokens[i - 2].kind != DOT) return null;

		return analysis::find_field(type_decl, ctx.tokens[i - 1].value);
	}

	if (ctx.tokens[i].kind != LBRACE && ctx.tokens[i].kind != COMMA) return null;

	return nth_field(type_decl, values_written(ctx, brace));
}

<*
 Values written in this initializer so far, or -1 once one of them was
 designated: position says nothing after that.
*>
fn sz values_written(Context* ctx, sz brace) @local {
	sz written;
	int depth;

	for (sz i = brace + 1; i < ctx.tokens.len(); i++) {
		if (!analysis::is_before(ctx.tokens[i].range.start, ctx.location)) break;

		switch (ctx.tokens[i].kind) {
			case LBRACE:
			case LPAREN:
			case LBRACKET:
				depth++;
			case RBRACE:
			case RPAREN:
			case RBRACKET:
				depth--;
			case DOT:
				if (depth == 0) return -1;
			case COMMA:
				if (depth == 0) written++;
			default:
				break;
		}
	}

	return written;
}

fn Node* nth_field(Node* type_decl, sz index) @local {
	if (!type_decl || type_decl.kind != STRUCT_DECL || index < 0) return null;

	sz seen;

	foreach (Node* field : type_decl.as(StructDecl).fields) {
		if (!field || field.kind != VAR_DECL) continue;
		if (seen == index) return field;

		seen++;
	}

	return null;
}

<*
 The enum the enclosing signature returns, when the cursor is writing a
 `return` value.
*>
fn Node* return_enum(Context* ctx) @local {
	sz i = token_before_value(ctx);
	if (i < 0 || ctx.tokens[i].kind != RETURN) return null;

	return analysis::return_type_decl(type_context(ctx), core::top_level_at(ctx.sf, ctx.location));
}

<*
 Index of the operator the cursor sits to the right of, or -1.
*>
fn sz operator_before_cursor(Context* ctx) @local {
	sz i = token_before_value(ctx);

	return i >= 0 && takes_the_same_type(ctx.tokens[i].kind) ? i : -1;
}

<*
 Index of the token in front of the value being typed, or -1.
*>
fn sz token_before_value(Context* ctx) @local {
	sz i = cursor_token_index(ctx);

	// An enum value is spelled in capitals, which the lexer calls a
	// CONST_IDENT rather than an IDENT.
	if (i >= 0 && (is_name_token(ctx.tokens[i].kind) || ctx.tokens[i].kind == CONST_IDENT)) i--;

	return i;
}

<*
 True for the operators whose right side is a value of whatever the left
 side is: an enum compares for order as well as for equality.
*>
fn bool takes_the_same_type(TokenKind kind) @local {
	switch (kind) {
		case EQ:
		case EQEQ:
		case NOT_EQUAL:
		case LESS:
		case LESS_EQ:
		case GREATER:
		case GREATER_EQ:
			return true;
		default:
			return false;
	}
}

<*
 True when what is being typed is a case label: everything between a
 `case` and the `:` that closes it.
*>
fn bool writing_a_case(Context* ctx) @local {
	for (sz i = cursor_token_index(ctx); i >= 0; i--) {
		switch (ctx.tokens[i].kind) {
			case CASE:
				return true;

			case COLON:
			case EOS:
			case LBRACE:
			case RBRACE:
			case DEFAULT:
				return false;

			default:
		}
	}

	return false;
}

<*
 Index of the ')' closing the condition of the switch the cursor is in,
 or -1 when there is none in front of it.
*>
fn sz switch_condition_close(Context* ctx) @local {
	for (sz i = cursor_token_index(ctx); i >= 0; i--) {
		if (ctx.tokens[i].kind != SWITCH) continue;

		// `switch { case a > b: }` switches over nothing, so no value has a
		// type to be read off.
		if (i + 1 >= ctx.tokens.len() || ctx.tokens[i + 1].kind != LPAREN) return -1;

		int depth = 0;
		for (sz j = i + 1; j < ctx.tokens.len(); j++) {
			switch (ctx.tokens[j].kind) {
				case LPAREN:
					depth++;
				case RPAREN:
					depth--;
					if (depth == 0) return j;
				default:
			}
		}

		return -1;
	}

	return -1;
}
