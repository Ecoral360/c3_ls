module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::scope;

import std::collections::list;
import std::collections::map;
import std::collections::set;

import lsp::core;
import uri;
import analyzer::lexer;

struct Context
{
	Uri uri;
	LspPosition position;
	Location location;
	sz offset;
	LspSession* session;
	FileEntry* file;
	SourceFile* sf;
	Module* mod;
	Allocator allocator;
	String prefix;
	ScopeKind scope;
	Node* leaf_node;
	Node* top_level_node;
	<*
	 Contains all tokens of the current file
	*>
	List{Token} tokens;

	LspAccessKind access;
	String base_identifier; // Stores 'variable' or 'Type' string found before the operator
	Location base_location;
}

<*
 The session keeps every file's lexer alive, so the token list is already
 built; nothing needs re-lexing here.
*>
fn void context_populate_tokens(Context* ctx)
{
	ctx.tokens.tinit();

	if (!ctx.sf || !ctx.sf.lexer) return;

	foreach (Token t : ctx.sf.lexer.tokens)
	{
		ctx.tokens.push(t);
	}
}

<*
 @param [&inout] item
*>
fn void? resolve_item(LspProject* project, CompletionItem* item)
{
	if (!item.data) return;
	String metadata = item.data;

	sz split_idx = metadata.index_of_char(';') ?? -1;
	if (split_idx < 0) return;

	String id_str = metadata[..split_idx];

	ulong node_id = id_str.to_ulong() ?? 0;
	if (node_id == 0) return;

	Node* node = find_node_by_id(&project.session, node_id);
	if (!node) return;

	switch (node.kind)
	{
		case FN_DECL:
		{
			item.documentation.kind = MARKDOWN;
			String signature = project.session.node_signature_text(node);
			if (signature.len == 0) signature = "fn";

			FnDecl* decl = node.as(FnDecl);
			if (try val = decl.contract.get())
			{
				item.documentation.value = analysis::format_contract_markdown(val.as(ContractDecl), signature);
			}
			else
			{
				item.documentation.value = signature;
			}
		}
		default:
	}
}

<*
 The old completion payload carried a ModuleSection id; sections are gone,
 so items now carry the NodeID and we look the node back up here.
*>
fn Node* find_node_by_id(LspSession* session, ulong node_id)
{
	Node* found;

	session.ctx.modules.@each(; String name, Module* module_ptr)
	{
		if (!found) { if (try Node* node = module_ptr.node_map.get((NodeID)node_id)) found = node; }
	};

	return found;
}

fn CompletionItem[]? resolve(LspProject* project, Uri uri, LspPosition pos)
{
	log::debug("resolve");

	Context ctx = (Context){
		.uri = uri,
		.position = pos,
		.session = &project.session,
		.allocator = tmem,
	};

	ctx.location = { .line = (int)pos.line, .column = (int)pos.character };

	log::info("resolve - editor location: %s:%s", ctx.location.line + 1, ctx.location.column + 1);

	List{CompletionItem} items; items.init(tmem);

	ctx.file = project.session.entry(uri.path);
	if (!ctx.file || !ctx.file.sf)
	{
		return items.array_view(); // No tracked file yet
	}

	ctx.sf = ctx.file.sf;
	ctx.mod = project.session.module_for_file(uri.path);

	String source = ctx.sf.content;
	sz offset = ctx.file.lines.offset_of(ctx.location);
	ctx.offset = offset;
	ctx.prefix = analysis::extract_prefix(source, offset).trim();

	if (offset > 0 && source[offset - 1] == ':')
	{
		if (offset < 2 || source[offset - 2] != ':')
		{
			log::debug("Aborting completion: Triggered by a single ':' context.");
			return items.array_view();
		}
	}

	ctx.access = NONE;
	ctx.base_identifier = "";

	ctx.top_level_node = core::top_level_at(ctx.sf, ctx.location);
	ctx.leaf_node = cursor::find_at(ctx.sf.ast.statements.array_view(), { ctx.location, ctx.location });

	context_populate_tokens(&ctx);
	detect_access_context(&ctx);
	ctx.scope = analysis::find_scope(&ctx, ctx.location);

	log::info("access: %s", ctx.access.description);
	log::info("Scope: %s", ctx.scope.description);
	log::info("base_ident: %s", ctx.base_identifier);
	log::info("prefix: %s", ctx.prefix);
 
	if (provide_member_access(&ctx, &items)) 
	{
		return items.array_view();
	}
	
	if (ctx.scope == IMPORT)
	{
		provide_imports(&ctx, &items);
		return items.array_view();
	}
	
	if (ctx.scope == EXECUTION || ctx.scope == CONTAINER)
	{
		provide_locals(&ctx, &items);
	}

	provide_global(&ctx, &items);
	provide_module_paths(&ctx, &items);
	provide_keywords(&ctx, &items);

	return items.array_view();
}

fn void provide_imports(Context* ctx, List{CompletionItem}* items)
{
	ctx.session.ctx.modules.@each(; name, mod)
	{
		do SCOPE:
		{
			if (ctx.prefix.len > 0 && !name.starts_with(ctx.prefix))
			{
				break SCOPE;
			}
			
			items.push({
				.label = name,
				.kind = MODULE,
				.detail = "Module",
				.sort_text = string::tformat("0001_%s", name),
				.documentation = { .value = string::tformat("Import the `%s` module into this file context.", name) }
			});
		};
	};

	ctx.prefix = "\0_CONTEXT_LOCK_";
}



