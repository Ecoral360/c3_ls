module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::scope;

import lsp::core;

import std::collections::list;
import std::collections::map;

import uri;

fn void provide_locals(Context* ctx, List{CompletionItem}* items) {
	if (ctx.scope != EXECUTION) return;
	if (ctx.access != NONE) return;

	if (!ctx.file) return;

	if (Scope* leaf = core::find_deepest_scope(ctx.file.root_rt_scope, ctx.location)) {
		provide_scope_locals(leaf, ctx, items);
	}

	if (Scope* leaf = core::find_deepest_scope(ctx.file.root_ct_scope, ctx.location)) {
		provide_scope_locals(leaf, ctx, items);
	}
}

fn void provide_scope_locals(Scope* leaf, Context* ctx, List{CompletionItem}* items) @private {
	List{VisibleVar} symbols = core::collect_visible(tmem, leaf);

	foreach (VisibleVar symbol : symbols) {
		if (!symbol.info || !symbol.info.node) continue;

		VarDecl* decl = symbol.info.node.as(VarDecl);
		String name   = cursor::spelling(symbol.info.node, tmem) ?? "";

		if (ctx.prefix.len > 0 && !name_matches_fuzzy(name, ctx.prefix)) continue;

		String type_name;
		if (decl.type) {
			type_name = cursor::raw_type_identifier(decl.type) ?? "";
		} else if (decl.var_flags.is_self) {
			// `self` and `&self` carry no written type, so the only place
			// their type is spelled out is the enclosing signature.
			String target = analysis::self_type_name(type_context(ctx));
			if (target.len > 0) {
				type_name = decl.var_flags.is_self_by_ref ? ctx.dstring_pool.cat(target, "*") : target;
			}
		}

		String details;
		CompletionItemKind kind;
		switch (true) {
			case decl.var_flags.is_const:
				kind = CONSTANT;
				details = ctx.dstring_pool.cat("(constant) ", type_name);
				break;
			case decl.var_kind == VAR_GLOBAL && !symbol.is_local:
				kind = VARIABLE;
				details = ctx.dstring_pool.cat("(global) ", type_name);
				break;
			case decl.var_kind == VAR_PARAM:
				kind = VARIABLE;
				details = ctx.dstring_pool.cat("(param) ", type_name);
				break;
			case decl.var_kind == VAR_LOCAL:
				kind = VARIABLE;
				details = ctx.dstring_pool.cat("(local) ", type_name);
				break;
			default:
				kind = VARIABLE;
				details = ctx.dstring_pool.cat("(local) ", type_name);
		}

		items.push({ 
			.label = name, 
			.kind = kind, 
			.detail = details, 
			.sort_text = ctx.dstring_pool.cat("0001_", name) 
		});
	}
}
