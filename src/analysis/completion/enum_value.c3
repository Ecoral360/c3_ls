module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::scope;

import lsp::core;

import std::collections::list;
import std::collections::map;

import uri;

fn void provide_enum(Context* ctx, List{CompletionItem}* items) {
	if (!ctx.leaf_node) return;
}
