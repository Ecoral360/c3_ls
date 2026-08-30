module lsp::analysis;

import analyzer::core;
import analyzer::cursor;
import analyzer::lexer;
import uri;

import lsp::core;

import std::collections::list;

fn String extract_prefix(String text, sz byte_offset) {
	if (byte_offset == 0 || byte_offset > text.len) return "";

	sz start_idx = byte_offset;
	while (start_idx > 0) {
		char c = text[start_idx - 1];
		if (c.is_alnum() || c == '_') {
			start_idx--;
		} else {
			switch (c) {
				case '@':
				case '#':
				case '$':
					start_idx--;
				default:
			}
			break;
		}
	}

	if (start_idx >= byte_offset) return "";
	// Length based, not an inclusive range: the character at byte_offset is
	// the one under the cursor, and at end of file it does not exist.
	return text[start_idx:byte_offset - start_idx];
}

fn CompletionItemKind completion_kind_from_node(Node* node) {
	NodeKind kind = node.kind;

	switch (kind) {
		case MODULE_DECL: return MODULE;
		case FN_DECL: return FUNCTION;
		case ENUM_DECL: return ENUM;
		case INTERFACE_DECL: return INTERFACE;
		case STRUCT_DECL: return STRUCT;
		case VAR_DECL:
			VarDecl* var_decl = node.as(VarDecl);
			if (var_decl.var_flags.is_const) {
				return CONSTANT;
			}
			switch (var_decl.var_kind) {
				case VAR_FIELD:
					return FIELD;
				default:
					return VARIABLE;
			}
		default:
			return TEXT;
	}
}

<*

*>
fn CompletionContextKind find_ctx_completion_kind(Context* ctx, Location cursor_loc) {
	if (!ctx.top_level_node) return GLOBAL;

	Node* node = ctx.top_level_node;

	// switch (node.kind) {
	// 	case FN_DECL:
	// 		FnDecl* func = node.as(FnDecl);
	// 		if (func.body && !is_before(cursor_loc, func.body.range.start)) {
	// 			return EXECUTION;
	// 		}
	//
	// 	case MACRO_DECL:
	// 		MacroDecl* mac = node.as(MacroDecl);
	// 		if (mac.body && !is_before(cursor_loc, mac.body.range.start)) {
	// 			return EXECUTION;
	// 		}
	// 	
	// 	default:
	// }

	switch (node.kind) {
		case IMPORT_DECL:
			return IMPORT;
		case STRUCT_DECL:
				CompletionContextKind scope = NONE;
				int num_braces;

				foreach (t : ctx.tokens) {
					if (!is_before(t.range.start, cursor_loc)) break;

					if (t.kind == LBRACE) {
						num_braces++;
						scope = CONTAINER;
					}
					if (t.kind == RBRACE) {
						num_braces--;
						if (num_braces <= 0) {
							scope = GLOBAL;
						}
					}
				}
				return scope;

		case FN_DECL:
		case MACRO_DECL:
				CompletionContextKind scope = GLOBAL;
				int parens;
				int braces;

				foreach (t : ctx.tokens) {
					if (!is_before(t.range.start, cursor_loc)) break;

					if (t.kind == LBRACE) {
						braces++;
						scope = EXECUTION;
					} else if (t.kind == RBRACE) {
						braces--;
						scope = (braces == 0) ? GLOBAL : EXECUTION;
					} else if (t.kind == LPAREN) {
						parens++;
						scope = PARAMETER;
					} else if (t.kind == RPAREN) {
						parens--;
						scope = NONE;
					} else if (braces == 0 && parens == 0 && t.kind == IDENT) {
						scope = NONE;
					}
				}
				return scope;

		default:
	}

	return GLOBAL;
}

<*

*>
fn CompletionContextKind get_node_completion_context_kind(Context* ctx, Location cursor_loc) {
	if (!ctx.top_level_node) return GLOBAL;
	Node* node = ctx.top_level_node;
	if (node.range.contains(cursor_loc)) {
		switch (node.kind) {
			case IMPORT_DECL:
				return IMPORT;
			case FN_DECL:
			case MACRO_DECL:
				return EXECUTION;
			case STRUCT_DECL:
				return CONTAINER;

			default:
		}
	}


	return GLOBAL;
}

fn MarkupContent md(String md) {
	return { .value = md, .kind = MARKDOWN };
}

fn List{String} get_expression_chain(Context* ctx) {
	List{String} chain;
	chain.tinit();
	sz cursor_idx = -1;
	for (sz i = 0; i < ctx.tokens.len(); i++) {
		if (!is_before(ctx.tokens[i].range.start, ctx.location)) {
			cursor_idx = i - 1;
			log::info("Found token: idx = %d", cursor_idx);
			break;
		}
	}
	if (cursor_idx == -1) return chain;
	bool expect_ident = true;
	for (sz i = cursor_idx; i >= 0; i--) {
		Token t = ctx.tokens[i];
		if (expect_ident) {
			if (t.kind == DOT || t.kind == SCOPE) continue;
			if (t.kind == IDENT || t.kind == TYPE_IDENT) {
				chain.insert_at(0, t.value);
				expect_ident = false;
				log::info("appened!");
			} else {
				break;
			}
		} else {
			if (t.kind == DOT || t.kind == SCOPE) {
				expect_ident = true;
			} else {
				break;
			}
		}
	}

	return chain;
}

fn Module* find_module_by_identifier(LspSession* session, String current_module_name, String identifier) {
	String scoped_path = "";
	if (current_module_name.len > 0) {
		scoped_path = string::tformat("%s::%s", current_module_name, identifier);
	}
	String suffix_path = string::tformat("::%s", identifier);

	session.ctx.modules.@each(; mod_name, mod) {
		if (mod_name == identifier) return mod;
		if (scoped_path.len > 0 && mod_name == scoped_path) return mod;
		if (mod_name.ends_with(suffix_path)) return mod;
	};

	return null;
}

<*
 True when `label` is still a candidate for what the user has typed.
*>
fn bool matches_prefix(Context* ctx, String label) {
	if (ctx.prefix.len == 0) return true;
	return label.starts_with(ctx.prefix);
}

<*
 The reflection properties a type exposes through '::'.

 Built into a scratch list and then filtered, so that typing a character
 after the operator narrows the list. Every push below predates the
 prefix and none of them consulted it.
*>
fn void inject_type_properties(Context* ctx, List{CompletionItem}* out, NodeKind type_kind) {
	List{CompletionItem} items;
	items.tinit();

	items.push(
		{
			.label = "alignment",
			.kind = PROPERTY,
			.detail = "sz",
			.documentation = md("Alignment of the type in bytes.")
		}
	);
	items.push(
		{
			.label = "kind",
			.kind = PROPERTY,
			.detail = "TypeKind",
			.documentation = md("The underlying kind of the type")
		}
	);
	items.push(
		{ .label = "name", .kind = PROPERTY, .detail = "String", .documentation = md("The short name of the type.") }
	);
	items.push(
		{
			.label = "qname",
			.kind = PROPERTY,
			.detail = "String",
			.documentation = md("The fully qualified name of the type.")
		}
	);
	items.push(
		{ .label = "size", .kind = PROPERTY, .detail = "sz", .documentation = md("Size of the type in bytes.") }
	);
	items.push(
		{ .label = "typeid", .kind = PROPERTY, .detail = "typeid", .documentation = md("The unique type identifier.") }
	);
	items.push(
		{
			.label = "methods",
			.kind = PROPERTY,
			.detail = "any[]",
			.documentation = md("List of methods attached to this type.")
		}
	);

	switch (type_kind) {
		case STRUCT_DECL:
			items.push(
				{
					.label = "members",
					.kind = PROPERTY,
					.detail = "any[]",
					.documentation = md("Array of fields/members.")
				}
			);
			items.push(
				{
					.label = "get_tag",
					.kind = METHOD,
					.detail = "fn any(String)",
					.documentation = md("Get attributes/tags.")
				}
			);
			items.push(
				{
					.label = "has_tag",
					.kind = METHOD,
					.detail = "fn bool(String)",
					.documentation = md("Check if attribute exists.")
				}
			);
			if (type_kind == STRUCT_DECL) {
				items.push({ .label = "is_substruct", .kind = PROPERTY, .detail = "bool" });
				items.push({ .label = "parent", .kind = PROPERTY, .detail = "typeid" });
			}
			break;

		case ENUM_DECL:
			items.push(
				{
					.label = "values",
					.kind = PROPERTY,
					.detail = "any[]",
					.documentation = md("List of all enum variants.")
				}
			);
			items.push(
				{ .label = "len", .kind = PROPERTY, .detail = "sz", .documentation = md("Number of elements.") }
			);
			items.push({ .label = "members", .kind = PROPERTY, .detail = "any[]" });
			items.push({ .label = "from_ordinal", .kind = METHOD, .detail = "fn type(sz)" });
			items.push({ .label = "lookup_field", .kind = METHOD, .detail = "fn any(String)" });
			break;

		case FN_DECL:
			items.push(
				{
					.label = "params",
					.kind = PROPERTY,
					.detail = "any[]",
					.documentation = md("Function parameter types.")
				}
			);
			items.push(
				{
					.label = "returns",
					.kind = PROPERTY,
					.detail = "typeid",
					.documentation = md("Function return type.")
				}
			);
			break;

		default:
			break;
	}

	foreach (CompletionItem item : items) {
		if (matches_prefix(ctx, item.label)) out.push(item);
	}
}

fn String format_contract_markdown(ContractDecl* contract, String signature) {
	DString md = dstring::temp_with_capacity(512);

	md.appendf("```\n%s\n```\n", signature);

	if (contract.comment && contract.comment.text.len > 0) {
		String raw_doc = contract.comment.text;
		log::info("raw doc: %s", raw_doc);
		String doc_clean = raw_doc.trim().treplace("\"", "");
		md.appendf("\n%s\n", doc_clean.trim());
	}

	// if (contract.params)
	// {
	// 	md.append("\n#### Parameters\n");
	// 	foreach (param_node : contract.params)
	// 	{
	// 		Cursor param_cursor = { section, param_node };
	// 		String p_name = param_cursor.spelling(tmem) ?? "";
	// 		String p_desc = param_cursor.source_text() ?? "";
	// 		md.appendf("* **%s** : %s\n", p_name, p_desc);
	// 	}
	// }
	// 
	// if (contract.requires)
	// {
	// 	md.append("\n#### Requires (Preconditions)\n");
	// 	foreach (req_expr : contract.requires)
	// 	{
	// 		Cursor param_cursor = { section, req_expr };
	// 		String expr_str = param_cursor.source_text() ?? "";
	// 		md.appendf("* `assert(%s)`\n", expr_str);
	// 	}
	// }
	// 
	// if (contract.ensures)
	// {
	// 	md.append("\n#### Ensures (Postconditions)\n");
	// 	foreach (ens_expr : contract.ensures)
	// 	{
	// 		Cursor param_cursor = { section, ens_expr };
	// 		String expr_str = param_cursor.source_text() ?? "";
	// 		md.appendf("* `assert(%s)`\n", expr_str);
	// 	}
	// }
	// 
	// if (contract.returns || contract.return_desc)
	// {
	// 	md.append("\n#### Returns\n");
	// 	if (contract.return_desc)
	// 	{
	// 		Cursor cursor = { section, contract.return_desc };
	// 		String desc = cursor.source_text() ?? "";
	// 		md.appendf("* Description: %s\n", desc);
	// 	}
	// 	foreach (ret_node : contract.returns)
	// 	{
	// 		Cursor param_cursor = { section, ret_node };
	// 		String expr_str = param_cursor.source_text() ?? "";
	// 		md.appendf("* %s\n", expr_str);
	// 	}
	// }
	// 
	// if (contract.deprecated)
	// {
	// 	md.append("\n **Deprecated:** ");
	// 	Cursor param_cursor = { section, contract.deprecated };
	// 	String expr_str = param_cursor.source_text() ?? "";
	// 	md.append(expr_str);
	// 	md.append("\n");
	// }

	String raw_str     = md.str_view();
	DString escape_buf = dstring::temp_with_capacity(raw_str.len * 2);

	// Process every single byte sequentially to avoid intermediate allocator overlap
	for (sz i = 0; i < raw_str.len; i++) {
		char c = raw_str[i];
		switch (c) {
			case '\\':
				escape_buf.append("\\\\");
				break;
			case '"':
				escape_buf.append("\\\"");
				break;
			case '\n':
				escape_buf.append("\\n");
				break;
			case '\r':
				escape_buf.append("\\r");
				break;
			case '\t':
				escape_buf.append("\\t");
				break;
			default:
				escape_buf.append_char(c);
				break;
		}
	}

	log::info("formatted markdown: %s", escape_buf.str_view());

	return escape_buf.str_view();
}
<*
 True when `a` comes strictly before `b` in the source.

 The analyzer reports line/column now, so ordering comparisons that used
 to be plain integer offset checks need this.
*>
fn bool is_before(Location a, Location b) {
	if (a.line != b.line) return a.line < b.line;
	return a.column < b.column;
}

fn Node* get_node(LspProject* project, Uri uri, LspPosition pos) {
	Location loc = pos.to_location();

	FileEntry* entry = project.session.entry(uri.path);
	if (!entry || !entry.sf) {
		return null;
	}

	return cursor::node(&entry.sf.ast, loc).node;
}

<*
 A symbol reference as written at the cursor.

 `path` is the module qualifier in front of it - the "string" of
 `string::tformat` - with the trailing "::" removed, or empty when the
 name was written bare.
*>
struct QualifiedSymbol {
	String name;
	String path;
}

<*
 The symbol the cursor is on, keeping any module qualifier.

 The qualifier is not part of the name and does not live in the same
 place for every node: an identifier carries it on IdentExpr.path_expr, a
 type on TypeExpr.unresolved.path, and a call hides both behind its
 callee. cursor::spelling flattens all of that to a bare name (or, for a
 type, to a concatenation that matches nothing in the index), which is
 why this reads the fields directly.
*>
fn QualifiedSymbol qualified_symbol_at(Node* node, Location loc) {
	if (!node) return { };

	switch (node.kind) {
		case CALL_EXPR:
			// 'string::tformat(x)' - the qualifier is on the callee.
			return qualified_symbol_at(node.as(CallExpr).callee, loc);

		case IDENT_EXPR:
			IdentExpr* ident = node.as(IdentExpr);
			if (!ident.ident) return { };
			return { .name = ident.ident.text, .path = path_prefix(ident.path_expr) };

		case TYPE_EXPR:
			TypeExpr* type_expr = node.as(TypeExpr);
			if (type_expr.type_kind != TYPE_IDENTIFIER || !type_expr.unresolved.name) {
				return { .name = cursor::raw_type_identifier(node) ?? "" };
			}
			return {
				.name = type_expr.unresolved.name.text,
				.path = path_prefix(type_expr.unresolved.path),
			};

		// On a declaration's own name, which is where goto definition is
		// asked to jump to the thing under the cursor rather than from it.
		case FN_DECL:
			FnDecl* fn_decl = node.as(FnDecl);
			if (!fn_decl.name || !fn_decl.name.range.contains(loc)) return { };
			return { .name = fn_decl.name.text };

		case STRUCT_DECL:
			StructDecl* struct_decl = node.as(StructDecl);
			if (!struct_decl.name || !struct_decl.name.range.contains(loc)) return { };
			return { .name = struct_decl.name.text };

		case VAR_DECL:
			VarDecl* var_decl = node.as(VarDecl);
			if (!var_decl.name || !var_decl.name.range.contains(loc)) return { };
			return { .name = var_decl.name.text };

		default:
			return { .name = cursor::spelling(node, tmem) ?? "" };
	}
}

<*
 Module qualifier written on a path node, without its trailing "::".
*>
fn String path_prefix(Node* path_node) @local {
	if (!path_node || path_node.kind != PATH_EXPR) return "";

	PathExpr* path = path_node.as(PathExpr);
	if (!path.path) return "";

	return path.path.text.strip_suffix("::");
}

<*
 The single declaration a member reference resolves to, wrapped so it
 reads like any other lookup result.
*>
fn List{SymbolRef} member_refs(LspSession* session, MemberResolution member) @local {
	List{SymbolRef} refs;
	refs.tinit();

	if (!member.decl) return refs;

	// A method is a top level declaration and the index knows where it came
	// from. A field is not, so its type answers for it.
	Node* anchor = session.entry_for_node(member.decl) ? member.decl : member.type_decl;

	FileEntry* owner = session.entry_for_node(anchor);
	Module* mod      = session.module_of(anchor);

	refs.push({ .node = member.decl, .module_name = mod ? mod.name : "", .owner = owner });
	return refs;
}

<*
 Every declaration a reference at `loc` can mean.

 A member access is resolved through the type of what is on its left, so
 'p.magnitude' is the one method on Point rather than every 'magnitude'
 in the workspace. Anything else falls back to the name, qualified by its
 module when one was written.
*>
fn List{SymbolRef} lookup_reference(LspSession* session, String path, Location loc, Node* node) {
	FileEntry* entry = session.entry(path);
	Module* current  = session.module_for_file(path);

	if (entry && entry.sf) {
		TypeContext types = {
			.session = session,
			.file = entry,
			.mod = current,
			.location = loc,
		};

		MemberResolution member = member_at(types, entry.sf, loc);
		if (member.decl) return member_refs(session, member);
	}

	return lookup_symbol(session, current, qualified_symbol_at(node, loc));
}

<*
 Every declaration a written name can mean.

 A bare name matches everywhere it is declared, which is the best that
 can be done for one. A qualified name is narrowed to the module it
 names, so `string::tformat` stops offering every tformat in the
 workspace.
*>
fn List{SymbolRef} lookup_symbol(LspSession* session, Module* current, QualifiedSymbol symbol) {
	if (symbol.name.len == 0) return { };
	if (symbol.path.len == 0) return session.find_symbols(symbol.name);

	String current_name = current ? current.name : "";
	Module* target      = find_module_by_identifier(session, current_name, symbol.path);

	// An unknown qualifier is more likely a gap in the index than a
	// deliberate reference to nothing, so fall back to the bare name
	// rather than answering with silence.
	if (!target) return session.find_symbols(symbol.name);

	return session.find_in_module(target.name, symbol.name);
}
