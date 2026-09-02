module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::scope;

import lsp::core;

import std::collections::list;
import std::collections::map;
import std::sort;

import uri;

<*
 How many workspace symbols one response may carry.

 finish() truncates the whole list, and provide_module_paths and
 provide_keywords run after this one, so the budget leaves them room
 rather than filling the response on its own.
*>
const sz MAX_GLOBAL_SYMBOLS @local = 150;

<*
 A symbol that passed the filters, before anything has been built for it.

 The whole point of the two passes below: an accepted symbol costs three
 words here, where a CompletionItem costs five formatted strings. The
 stdlib offers ~6000 of these and at most MAX_GLOBAL_SYMBOLS survive, so
 deciding which ones before decorating them is where the work goes.
*>
struct GlobalCandidate @local {
	String name;
	Node* node;
	String module_name;
	uint rank;
}

fn void provide_global(Context* ctx, List{CompletionItem}* items) {
	if (ctx.access != NONE) return;

	bool types_only     = false;
	Module* current_mod = ctx.mod;

	if (ctx.scope == GLOBAL) {
		types_only = true;
	}

	List{GlobalCandidate} candidates;
	candidates.tinit(256);

	ctx.session.by_name.@each(; String symbol_name, List{SymbolRef} refs) {
		do SCOPE: {
			if (refs.is_empty()) break SCOPE;

			if (ctx.prefix.len > 0 && !name_matches_fuzzy(symbol_name, ctx.prefix)) {
				break SCOPE;
			}

			uint name_rank = match_rank(symbol_name, ctx.prefix);

			foreach (SymbolRef ref : refs) {
				if (!should_include_node(ref.node, ref.module_name, current_mod, types_only)) {
					continue;
				}

				bool own_module = current_mod && ref.module_name == current_mod.name;

				// Match quality leads, the file's own module breaks the
				// tie: a worse match from this module should not outrank
				// an exact one from another.
				candidates.push(
					{
						.name = symbol_name,
						.node = ref.node,
						.module_name = ref.module_name,
						.rank = name_rank * 2 + (own_module ? 0 : 1),
					}
				);
			}
		};
	};

	// by_name is a hash map, so without an order the surviving symbols
	// would be whichever ones hashing happened to reach first, and they
	// would change from one build to the next.
	if (candidates.len() > 1) {
		sort::quicksort(&candidates, &compare_candidates);
	}

	sz kept = min(candidates.len(), MAX_GLOBAL_SYMBOLS);

	for (sz i = 0; i < kept; i++) {
		GlobalCandidate candidate = candidates[i];
		add_symbol_completion(ctx, items, candidate.name, candidate.node, candidate.module_name, ctx.prefix);
	}
}

<*
 How closely `name` answers what was typed.

 name_matches_fuzzy accepts a subsequence, which over a whole workspace
 accepts a great deal: "ad" reaches `list_ensure_capacity`. Everything it
 lets through is offered, but an exact hit and a scattered one must not
 compete for the same slot.
*>
fn uint match_rank(String name, String prefix) @local {
	if (prefix.len == 0) return 2;
	if (name == prefix) return 0;
	if (name.starts_with(prefix)) return 1;
	if (name.contains(prefix)) return 2;

	return 3;
}

fn int compare_candidates(GlobalCandidate a, GlobalCandidate b) @local {
	if (a.rank != b.rank) return a.rank < b.rank ? -1 : 1;

	// A shorter name is the closer answer to the same prefix.
	if (a.name.len != b.name.len) return a.name.len < b.name.len ? -1 : 1;

	sz shared = min(a.name.len, b.name.len);
	for (sz i = 0; i < shared; i++) {
		if (a.name[i] != b.name[i]) return a.name[i] < b.name[i] ? -1 : 1;
	}

	return 0;
}

fn bool should_include_node(Node* node, String module_name, Module* current_mod, bool types_only) @local {
	if (!node || !node.is_valid()) return false;

	if (!current_mod || module_name != current_mod.name) {
		if (node.visibility != PUBLIC) return false;

		switch (node.kind) {
			case VAR_DECL:
				return false;
			default:
				break;
		}
	}

	switch (node.kind) {
		case MODULE_DECL:
		case IMPORT_DECL:
			return false;
		default:
			break;
	}

	if (types_only) {
		switch (node.kind) {
			case FN_DECL:
			case MACRO_DECL:
			case VAR_DECL:
				return false;
			default:
				break;
		}
	}

	return true;
}