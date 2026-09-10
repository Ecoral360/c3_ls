module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::scope;

import lsp::core;

import std::collections::list;
import std::collections::map;

import uri;

struct ContractAttribute @local {
	String name;
	String docs;
}

const ContractAttribute[] CONTRACT_ATTRIBUTES @local = {
	{ "@ensure", "A condition this declaration guarantees on return." },
	{ "@param", "What one parameter is: `@param x` and then its description." },
	{ "@pure", "Declares that this reads nothing outside its parameters." },
	{ "@require", "A condition the caller has to meet: `@require x > 0`." },
	{ "@return", "What the call comes back with." },
	{ "@return?", "The faults it can return instead: `@return? IoError.EOF`." },
};

fn void provide_contract(Context* ctx, List{CompletionItem}* items) {
	if (ctx.scope != CONTRACT) return;
	if (!writing_a_directive(ctx)) return;

	foreach (ContractAttribute attribute : CONTRACT_ATTRIBUTES) {
		if (!attribute.name.starts_with(ctx.prefix)) continue;

		// The '@' is already written, and it is not a word character, so a
		// client replacing the word under the cursor would leave it in
		// front of whatever is inserted.
		String tail = attribute.name[1..];

		items.push(
			{
				.label = attribute.name,
				.kind = KEYWORD,
				.detail = "contract",
				.insert_text = tail,
				.filter_text = tail,
				.sort_text = ctx.dstring_pool.cat("0000_", attribute.name),
				.documentation = { .value = attribute.docs },
			}
		);
	}
}

fn bool writing_a_directive(Context* ctx) @local {
	if (!ctx.prefix.starts_with("@")) return false;

	sz last = cursor_token_index(ctx);
	if (last < 0) return false;

	switch (ctx.tokens[last].kind) {
		case AT:
		case AT_IDENT:
			return true;
		default:
			return false;
	}
}
