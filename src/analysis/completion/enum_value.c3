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
	if (enum_decl && enum_decl.kind == ENUM_DECL) return enum_decl;

	return null;
}

<*
 The enum value a bare name in a case label stands for, with the enum it
 belongs to.
*>
fn MemberResolution case_label_value(
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
				.kind = ENUMMEMBER,
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
