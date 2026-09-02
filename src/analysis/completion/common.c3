module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::scope;
import analyzer::lexer;

import lsp::core;

import std::collections::list;
import std::collections::map;

import uri;

struct Context {
	Uri uri;
	LspPosition position;
	Location location;
	sz offset;
	DStringPool* dstring_pool;
	LspSession* session;
	FileEntry* file;
	SourceFile* sf;
	Module* mod;
	Allocator allocator;

	LspAccessKind access;
	// stores the last Type before the typed thing.
	// i.e : in `a.b.c`, base_node is the node corresponding to where the type of `b` is defined
	Node* base_node;
	String base_identifier; // Stores 'variable' or 'Type' string found before the operator
	String prefix;

	CompletionContextKind scope;
	Node* leaf_node;
	Node* top_level_node;
	<*
	 Contains all tokens of the current file
	*>
	List{Token} tokens;

	Location base_location;
}

fn void provide_keywords(Context* ctx, List{CompletionItem}* items) {
	if (ctx.access != NONE) return;

	foreach (kw : lsp::Keywords::values) {
		switch (ctx.scope) {
			case GLOBAL:
				if (!kw.is_top_level()) continue;
				break;

			case CONTAINER:
				if (!kw.is_container()) continue;
				break;

			case EXECUTION:
				if (!kw.is_statement() && !kw.is_expression()) continue;
				break;

			case TYPE_ASSIGNMENT:
				if (!kw.is_value()) continue;
				break;
			default:
		}
		if (ctx.prefix.len == 0 || kw.name.starts_with(ctx.prefix)) {
			items.push(
				{
					.label = kw.name,
					.documentation = { .value = kw.docs },
					.kind = KEYWORD,
					.sort_text = ctx.dstring_pool.cat("0010_", kw.name),
				}
			);
		}
	}
}

fn bool name_matches_fuzzy(String symbol_name, String prefix) {
	foreach (c : prefix) {
		if (try idx = symbol_name.index_of_char(c)) {
			if (idx + 1 == symbol_name.len) {
				symbol_name = "";
			} else {
				symbol_name = symbol_name[idx + 1..];
			}
		} else {
			return false;
		}
	}

	return true;
}

fn void add_symbol_completion(
	Context* ctx,
	List{CompletionItem}* items,
	String symbol_name,
	Node* node,
	String base_identifier,
	String prefix = ""
) {
	if (!node) return;

	CompletionItemKind item_kind = CompletionItemKind.VALUE;
	String type_desc             = "Symbol";
	String insert_text           = symbol_name;
	if (prefix.len > 0 && prefix.starts_with("@")) {
		insert_text = symbol_name.strip_prefix("@");
	}

	InsertTextFormat format = PLAIN_TEXT;

	switch (node.kind) {
		case FN_DECL:
			item_kind = FUNCTION;
			type_desc = "fn";
			insert_text = ctx.dstring_pool.cat(insert_text, "($1)");
			format = SNIPPET;
			break;

		case MACRO_DECL:
			item_kind = FUNCTION;
			type_desc = "macro";
			insert_text = ctx.dstring_pool.cat(insert_text, "($1)");
			format = SNIPPET;
			break;

		case INTERFACE_DECL:
			item_kind = INTERFACE;
			type_desc = "interface";
			insert_text = ctx.dstring_pool.cat(insert_text, "($1)");
			format = SNIPPET;
			break;

		case STRUCT_DECL:
			item_kind = STRUCT;
			type_desc = "struct";
			break;

		case ENUM_DECL:
			item_kind = ENUM;
			type_desc = "enum";
			break;

		case VAR_DECL:

			{
				VarDecl* decl = node.as(VarDecl);
				if (decl.var_flags.is_const) {
					item_kind = CONSTANT;
					type_desc = "constant";
					break;
				}

				item_kind = VARIABLE;
				type_desc = "global var";
				break;
			}
		default:
			break;
	}

	String detail_string = ctx.dstring_pool.cat(type_desc, " via ", base_identifier);

	String filter_text = symbol_name;
	if (filter_text.len > 0 && filter_text[0] == '@') {
		filter_text = filter_text[1..];
	}

	items.push(
		{
			.label = symbol_name,
			.kind = item_kind,
			.detail = detail_string,
			.insert_text = insert_text,
			.insert_text_format = format,
			.filter_text = filter_text,
			.sort_text = ctx.dstring_pool.cat("0005_", symbol_name),
			.data = ctx.dstring_pool.format("%d;%s", (ulong)node.id, symbol_name)
		}
	);
}
