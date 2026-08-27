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

	Scope* leaf = core::find_deepest_scope(ctx.file.root_scope, ctx.location);
	if (!leaf) return;

	List{VisibleVar} symbols = core::collect_visible(tmem, leaf);
	foreach (VisibleVar symbol : symbols) {
		if (!symbol.info || !symbol.info.node) continue;

		VarDecl* decl = symbol.info.node.as(VarDecl);
		String name   = cursor::spelling(symbol.info.node, tmem) ?? "";

		if (ctx.prefix.len > 0 && !name.contains(ctx.prefix)) continue;

		String type_name;
		if (decl.type) {
			type_name = cursor::raw_type_identifier(decl.type) ?? "";
		}

		String details;
		CompletionItemKind kind;
		switch (true) {
			case decl.var_flags.is_const:
				kind = CONSTANT;
				details = string::tformat("(constant) %s", type_name);
				break;
			case decl.var_kind == VAR_GLOBAL && !symbol.is_local:
				kind = VARIABLE;
				details = string::tformat("(global) %s", type_name);
				break;
			case decl.var_kind == VAR_PARAM:
				kind = VARIABLE;
				details = string::tformat("(param) %s", type_name);
				break;
			case decl.var_kind == VAR_LOCAL:
				kind = VARIABLE;
				details = string::tformat("(local) %s", type_name);
				break;
			default:
				kind = VARIABLE;
				details = string::tformat("(local) %s", type_name);
		}

		items.push({ .label = name, .kind = kind, .detail = details, .sort_text = string::tformat("0001_%s", name) });
	}
}