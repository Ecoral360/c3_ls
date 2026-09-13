module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::lexer;

import lsp::core;

import std::collections::list;

struct DeclNameSite {
	bool found;
	String type_name;
}

const String[] STDLIB_ROOTS @local = { "std", "libc" };

fn DeclNameSite decl_name_site_at(Context* ctx) {
	sz cursor_idx = ctx.tokens.len();
	for (sz i = 0; i < ctx.tokens.len(); i++) {
		if (!analysis::is_before(ctx.tokens[i].range.start, ctx.location)) {
			cursor_idx = i;
			break;
		}
	}

	sz i = cursor_idx - 1;
	if (i < 0) return { };

	// The name being typed is a token of its own, and only then: with no
	// prefix the cursor sits after whitespace, where the previous token is
	// the type itself.
	if (ctx.prefix.len > 0 && ctx.tokens[i].kind == IDENT) i--;

	i = skip_type_decorations(ctx, i);

	sz start = type_start(ctx, i);
	if (start < 0) return { };

	if (!opens_a_declaration(ctx, start - 1)) return { };

	return { .found = true, .type_name = ctx.tokens[start].value };
}

<*
 Index of the last token of the type name itself, with the pointers and
 slices that hang off its end stepped over.
*>
fn sz skip_type_decorations(Context* ctx, sz last) @local {
	sz i = last;

	while (i >= 0) {
		if (ctx.tokens[i].kind == ASTERISK) {
			i--;
			continue;
		}

		if (ctx.tokens[i].kind == RBRACKET) {
			sz open = matching_open(ctx, i);
			if (open < 0) return i;

			i = open - 1;
			continue;
		}

		break;
	}

	return i;
}

fn bool opens_a_declaration(Context* ctx, sz before) @local {
	if (before < 0) return true;

	switch (ctx.tokens[before].kind) {
		case EOS:
		case LBRACE:
		case RBRACE:
		case LPAREN:
		case COMMA:
			return true;
		default:
			return false;
	}
}

fn String snake_case(Context* ctx, String name) @local {
	DString out;
	out.init(ctx.allocator, name.len + 8);

	foreach (usz i, char c : name) {
		if (!c.is_upper()) {
			out.append(c);
			continue;
		}

		bool ends_a_word   = i > 0 && (name[i - 1].is_lower() || name[i - 1].is_digit());
		bool starts_a_word = i > 0 && i + 1 < name.len && name[i - 1].is_upper() && name[i + 1].is_lower();

		if (ends_a_word || starts_a_word) out.append('_');
		out.append(c.to_lower());
	}

	return out.str_view();
}

fn bool is_stdlib_type(Context* ctx, String type_name) @local {
	if (type_name.to_lower_tcopy() == type_name) return true;

	// exception for the Allocator type
	if (type_name == "Allocator") return false;

	Node* decl = analysis::find_decl(type_context(ctx), type_name, DeclWanted.TYPE, type_context(ctx).cursor_site());
	if (!decl) return false;

	Module* owner = ctx.session.module_of(decl);
	if (!owner) return false;

	String root = owner.name;
	if (try idx = root.index_of("::")) root = root[:idx];

	foreach (String stdlib_root : STDLIB_ROOTS) {
		if (root == stdlib_root) return true;
	}

	return false;
}

fn void provide_decl_name(Context* ctx, List{CompletionItem}* items) {
	if (ctx.access != NONE) return;

	DeclNameSite site = decl_name_site_at(ctx);
	if (!site.found) return;

	if (is_stdlib_type(ctx, site.type_name)) return;

	String name = snake_case(ctx, site.type_name);
	if (name.len == 0) return;
	if (ctx.prefix.len > 0 && !name_matches_fuzzy(name, ctx.prefix)) return;

	items.push(
		{
			.label = name,
			.kind = VARIABLE,
			.detail = ctx.dstring_pool.cat("(name) ", site.type_name),
			.sort_text = ctx.dstring_pool.cat("0000_", name),
			.documentation = { .value = ctx.dstring_pool.cat("Name derived from the type `", site.type_name, "`.") }
		}
	);
}
