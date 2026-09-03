module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::scope;
import analyzer::lexer;

import std::collections::list;
import std::collections::map;
import std::collections::set;

import lsp::core;
import uri;


<*
 The session keeps every file's lexer alive, so the token list is already
 built; nothing needs re-lexing here.
*>
fn void context_populate_tokens(Context* ctx) {
	ctx.tokens.tinit();

	if (!ctx.sf || !ctx.sf.lexer) return;

	foreach (Token t : ctx.sf.lexer.tokens) {
		ctx.tokens.push(t);
	}
}

<*
 @param [&inout] item
*>
fn void? resolve_item(LspProject* project, CompletionItem* item) {
	if (!item.data) return;
	String metadata = item.data;

	sz split_idx = metadata.index_of_char(';') ?? -1;
	if (split_idx < 0) return;

	// Exclusive: an inclusive range would keep the ';' and the parse below
	// would fail, silently dropping the documentation.
	String id_str = metadata[:split_idx];

	ulong node_id = id_str.to_ulong() ?? 0;
	if (node_id == 0) return;

	Node* node = find_node_by_id(&project.session, node_id);
	if (!node) return;

	switch (node.kind) {
		case FN_DECL:
			item.documentation.kind = MARKDOWN;
			String signature = project.session.node_signature_text(node);
			if (signature.len == 0) signature = "fn";

			FnDecl* decl = node.as(FnDecl);
			if (try val = decl.contract.get()) {
				item.documentation.value = analysis::format_contract_markdown(val.as(ContractDecl), signature);
			} else {
				item.documentation.value = signature;
			}
		default:
	}
}

<*
 The old completion payload carried a ModuleSection id; sections are gone,
 so items now carry the NodeID and we look the node back up here.
*>
fn Node* find_node_by_id(LspSession* session, ulong node_id) {
	Node* found;

	session.ctx.modules.@each(; String name, Module* module_ptr) {
		if (!found) {
			if (try Node* node = module_ptr.node_map.get((NodeID)node_id)) found = node;
		}
	};

	return found;
}

<*
 Last pass over a completion list before it goes on the wire.

 Neither MarkupContent.kind nor InsertTextFormat has a valid zero value,
 so an item that set neither would serialize as {"kind": "", "value": ""}
 and "insertTextFormat": 0. Both are outside what the protocol allows,
 and a client is within its rights to drop the item.

 @param [&inout] items
*>
fn CompletionItem[] finish(List{CompletionItem}* items) {
	foreach (&item : items) {
		if (item.documentation.kind.len == 0) item.documentation.kind = PLAIN_TEXT;
		if (item.insert_text_format == (InsertTextFormat)0) item.insert_text_format = PLAIN_TEXT;
	}

	return items.size > 200 ? items.array_view()[:200] : items.array_view();
}

fn CompletionItem[]? resolve(LspProject* project, Uri uri, LspPosition pos) {
	log::debug("resolve");

	Context ctx = (Context) {
		.uri = uri,
		.position = pos,
		.session = &project.session,
		.allocator = tmem,
		.dstring_pool = &project.dstring_pool,
	};

	ctx.location = { .line = (int)pos.line, .column = (int)pos.character };

	log::info("resolve - editor location: %s:%s", ctx.location.line + 1, ctx.location.column + 1);

	List{CompletionItem} items;
	items.init(tmem);

	ctx.file = project.session.entry(uri.path);
	if (!ctx.file || !ctx.file.sf) {
		return finish(&items); // No tracked file yet
	}

	ctx.sf = ctx.file.sf;
	ctx.mod = project.session.module_for_file(uri.path);

	String source = ctx.sf.content;
	sz offset     = ctx.file.lines.offset_of(ctx.location);
	ctx.offset = offset;
	ctx.prefix = analysis::extract_prefix(source, offset).trim();

	if (offset > 0 && source[offset - 1] == ':') {
		if (offset < 2 || source[offset - 2] != ':') {
			log::debug("Aborting completion: Triggered by a single ':' context.");
			return finish(&items);
		}
	}

	ctx.access = NONE;
	ctx.base_identifier = "";

	NodeEntry node_entry = cursor::node_entry(&ctx.sf.ast, ctx.location);

	ctx.top_level_node = ctx.sf.ast.node_at(node_entry.path, depth: 0) ?? null;
	ctx.leaf_node = node_entry.node;

	context_populate_tokens(&ctx);
	detect_access_context(&ctx);
	ctx.scope = analysis::find_ctx_completion_kind(&ctx, ctx.location);

	log::info("access: %s", ctx.access.description);
	log::info("Scope: %s", ctx.scope.description);
	log::info("base_ident: %s", ctx.base_identifier);
	log::info("prefix: %s", ctx.prefix);

	if (ctx.scope == IMPORT) {
		provide_imports(&ctx, &items);
		return finish(&items);
	}

	if (provide_member_access(&ctx, &items)) {
		return finish(&items);
	}

	if (provide_struct_init(&ctx, &items)) {
		return finish(&items);
	}

	provide_named_args(&ctx, &items);

	if (ctx.scope == EXECUTION || ctx.scope == CONTAINER) {
		provide_locals(&ctx, &items);
	}

	provide_global(&ctx, &items);
	provide_module_paths(&ctx, &items);
	provide_keywords(&ctx, &items);

	return finish(&items);
}

<*
 Module names for an `import` line, matched against the whole path typed
 so far rather than ctx.prefix.

 ctx.prefix stops at the last `::`, so it is "li" in
 `import std::collections::li` and would match every module in the
 workspace whose name happens to start that way. Matching the full path
 is what makes a deep name reachable.

 The label carries the whole path, but insertText and filterText carry
 only the tail past the last `::`. A client matches and replaces the word
 under the cursor, and `::` is not a word character, so the part already
 typed must not be repeated in what gets inserted.
*>
fn void provide_imports(Context* ctx, List{CompletionItem}* items) {
	ImportPrefix typed = analysis::import_prefix_at(ctx, ctx.location);
	if (!typed.found) return;

	String own_module = ctx.mod ? ctx.mod.name : "";

	ctx.session.ctx.modules.@each(; String name, Module* mod) {
		do SCOPE: {
			// Importing the module the file already declares is a no-op.
			if (name == own_module) break SCOPE;
			if (!name_matches_fuzzy(name, typed.path)) break SCOPE;

			String tail = name[typed.base.len..];

			items.push(
				{
					.label = name,
					.kind = MODULE,
					.detail = "Module",
					.insert_text = tail,
					.filter_text = tail,
					.sort_text = ctx.dstring_pool.cat("0001_", name),
					.documentation = {
						.value = ctx.dstring_pool.cat("Import the `", name, "` module into this file context.")
					}
				}
			);
		};
	};
}
