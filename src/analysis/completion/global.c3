module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::scope;

import lsp::core;

import std::collections::list;
import std::collections::map;

import uri;

fn void provide_global(Context* ctx, List{CompletionItem}* items) {
	if (ctx.access != NONE) return;

	bool types_only     = false;
	Module* current_mod = ctx.mod;

	if (ctx.scope == GLOBAL) {
		types_only = true;
	}

	ctx.session.by_name.@each(; String symbol_name, List{SymbolRef} refs) {
		do SCOPE: {
			if (refs.is_empty()) break SCOPE;

			if (ctx.prefix.len > 0 && !symbol_name.contains(ctx.prefix)) {
				break SCOPE;
			}

			foreach (SymbolRef ref : refs) {
				if (!should_include_node(ref.node, ref.module_name, current_mod, types_only)) {
					continue;
				}

				add_symbol_completion(ctx, items, symbol_name, ref.node, ref.module_name, ctx.prefix);
			}
		};
	};
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