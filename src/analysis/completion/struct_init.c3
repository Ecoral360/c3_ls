module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::lexer;

import lsp::core;

import std::collections::list;

<*
 Where the cursor sits inside a struct initializer.

 `brace` is the index of the '{' that is still open at the cursor, and
 `designated` says a '.' has already been written, so the field name goes
 in bare rather than with its own dot.
*>
struct InitSite @local {
	bool found;
	sz brace;
	bool designated;
}

<*
 The innermost brace that is still open at the cursor.

 Token driven, like every other context here: `Point p = { .` cannot
 parse, and the AST answers a half written initializer with the
 enclosing declaration.
*>
fn InitSite init_site_at(Context* ctx) @local {
	sz cursor_idx = ctx.tokens.len();
	for (sz i = 0; i < ctx.tokens.len(); i++) {
		if (!analysis::is_before(ctx.tokens[i].range.start, ctx.location)) {
			cursor_idx = i;
			break;
		}
	}

	int depth;
	bool designated;

	for (sz i = cursor_idx - 1; i >= 0; i--) {
		switch (ctx.tokens[i].kind) {
			case RBRACE:
			case RPAREN:
			case RBRACKET:
				depth++;
			case LPAREN:
			case LBRACKET:
				if (depth == 0) return { };
				depth--;
			case LBRACE:
				if (depth == 0) return { .found = true, .brace = i, .designated = designated };
				depth--;
			case DOT:
				// Only a '.' written immediately before the cursor, with at
				// most the name being typed after it.
				if (depth == 0 && i >= cursor_idx - 2) designated = true;
			default:
				break;
		}
	}

	return { };
}

<*
 The struct an initializer at `brace` is building, or null.

 Only the shapes that say so unambiguously, because a '{' is a block far
 more often than it is an initializer: `Type name = {`, a `(Type){`
 compound literal, and a `.field = {` nested in one of those.
*>
fn Node* initializer_type(Context* ctx, sz brace) @local {
	sz i = brace - 1;
	if (i < 0) return null;

	switch (ctx.tokens[i].kind) {
		case EQ:
			return assigned_type(ctx, brace, i - 1);
		case RPAREN:
			// '(Type){ ... }' - a cast around a type and nothing else.
			// An 'if (c) {' has a condition in there instead.
			sz open = matching_open(ctx, i);
			if (open < 0) return null;

			sz start = type_start(ctx, i - 1);
			if (start != open + 1) return null;

			return type_named(ctx, ctx.tokens[start].value);
		default:
			return null;
	}
}

<*
 The type on the left of the '=' in front of an initializer.

 Either a declaration - `Point p = {` - or a designator inside an
 enclosing initializer, `.origin = {`, whose type is that field's.
*>
fn Node* assigned_type(Context* ctx, sz brace, sz i) @local {
	if (i < 0 || ctx.tokens[i].kind != IDENT) return null;

	String name = ctx.tokens[i].value;
	i--;

	if (i >= 0 && ctx.tokens[i].kind == DOT) {
		sz outer = enclosing_brace(ctx, brace);
		if (outer < 0) return null;

		Node* outer_type = initializer_type(ctx, outer);
		if (!outer_type) return null;

		Node* field = analysis::find_field(outer_type, name);
		if (!field) return null;

		return analysis::type_decl_of(type_context(ctx), field.as(VarDecl).type);
	}

	// 'Point p = {' and 'List{int} lst = {'.
	sz start = type_start(ctx, i);
	if (start < 0) return null;

	return type_named(ctx, ctx.tokens[start].value);
}

<*
 Index of the first token of the type ending at `last`, or -1.

 A written type is one token, except that generic arguments hang off the
 end of it: `List{int}` ends on the '}' that closes them, and the name
 worth resolving is the one in front of that '{'.
*>
fn sz type_start(Context* ctx, sz last) @local {
	sz i = last;

	if (i >= 0 && ctx.tokens[i].kind == RBRACE) {
		sz open = matching_open(ctx, i);
		if (open < 0) return -1;

		i = open - 1;
	}

	if (i < 0 || ctx.tokens[i].kind != TYPE_IDENT) return -1;

	return i;
}

fn Node* type_named(Context* ctx, String name) @local {
	Node* decl = analysis::find_decl(type_context(ctx), name, true);

	return decl && decl.kind == STRUCT_DECL ? decl : null;
}

<*
 Index of the brace enclosing the one at `brace`, or -1.
*>
fn sz enclosing_brace(Context* ctx, sz brace) @local {
	int depth;

	for (sz i = brace - 1; i >= 0; i--) {
		switch (ctx.tokens[i].kind) {
			case RBRACE:
				depth++;
			case LBRACE:
				if (depth == 0) return i;
				depth--;
			default:
				break;
		}
	}

	return -1;
}

<*
 True when `.name` has already been designated in this initializer.
*>
fn bool field_already_set(Context* ctx, sz brace, String name) @local {
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
			case IDENT:
				if (depth > 0 || ctx.tokens[i].value != name) break;
				if (i > 0 && ctx.tokens[i - 1].kind == DOT) return true;
			default:
				break;
		}
	}

	return false;
}

<*
 Offer the fields of the struct being built by an initializer.

 `Point p = { .x = 1, .y = 2 }` names its fields, and the names are the
 whole point of writing it that way. Nothing else can be designated
 there, so a '.' already written locks the completion to these.

 @returns "true when this consumed the completion"
*>
fn bool provide_struct_init(Context* ctx, List{CompletionItem}* items) {
	if (ctx.access != NONE) return false;

	InitSite site = init_site_at(ctx);
	if (!site.found) return false;

	Node* type_decl = initializer_type(ctx, site.brace);
	if (!type_decl) return false;

	foreach (Node* field_node : type_decl.as(StructDecl).fields) {
		if (!field_node || field_node.kind != VAR_DECL) continue;

		VarDecl* field = field_node.as(VarDecl);
		if (!field.name || field.name.text.len == 0) continue;

		String name = field.name.text;
		if (ctx.prefix.len > 0 && !name_matches_fuzzy(name, ctx.prefix)) continue;
		if (field_already_set(ctx, site.brace, name)) continue;

		// The '.' is already on the line in the designated case; writing it
		// again would give '..x'.
		String written = site.designated ? name : ctx.dstring_pool.cat(".", name);

		items.push(
			{
				.label = written,
				.kind = FIELD,
				.detail = field.type ? (cursor::spelling(field.type, ctx.allocator) ?? "") : "",
				.insert_text = ctx.dstring_pool.cat(written, " = "),
				.filter_text = name,
				.sort_text = ctx.dstring_pool.cat("0000_", name),
				.documentation = { .value = "Field designator." }
			}
		);
	}

	// A value can be written positionally, so only a '.' settles it.
	return site.designated;
}
