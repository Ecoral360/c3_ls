module lsp::analysis::hover;

import analyzer::core;
import analyzer::cursor;
import lsp::analysis;

import std::collections::list;
import std::collections::map;

import lsp::core;

import uri;
import analyzer::lexer;

// fn String contract_param_to_string(ContractParam* param) {
// 	String name = (param.ident ?: &&(Ident) { }).text;
// 	String description = (param.description ?: &&(Ident) { }).text;
// 	InOutModifier modifier = param.modifier;
// 
// 	String modifier_str = modifier == IN ? "" : string::tformat(`[&%s] `, modifier.description.to_lower_tcopy());
// 
// 	return string::tformat(`@param %s%s : %s`, modifier_str, name, description);
// }
// 
// fn String contract_to_string(ContractDecl* contract) {
// 	String comment = (contract.comment ?: &&(Ident) { }).text;
// 
// 	List{String} params;
// 	params.tinit();
// 	foreach (param_node : contract.params) {
// 		ContractParam* param = param_node.as(ContractParam);
// 		params.push(contract_param_to_string(param));
// 	}
// 
// 	return string::tformat("%s\n%s", comment, string::tjoin(params.array_view(), "\n"));
// }

fn String? hover(LspProject* project, Uri uri, LspPosition pos) {
	log::info("hover");

	Location loc = pos.to_location();

	log::info("resolve - editor location: %s:%s", loc.line + 1, loc.column + 1);

	FileEntry* entry = project.session.entry(uri.path);
	if (!entry || !entry.sf) {
		return "";
	}

	SourceFile* sf = entry.sf;

	Token target_token;
	if (core::token_at(sf, loc, &target_token)) {
		switch {
			case target_token.kind.is_keyword():
				return get_keyword_docs(target_token.kind);
			case target_token.kind.is_base_type():
				return get_base_type_docs(target_token.kind);
		}
	}

	Node* node = cursor::node_entry(&sf.ast, loc).node;
	if (!node || !node.is_valid()) return "";

	List{SymbolRef} origins = analysis::lookup_reference(&project.session, uri.path, loc, node);

	if (origins.is_empty()) {
		// An import path names a module, and a module is not a declaration:
		// there is no node for the index to point at, so nothing else in
		// the lookup chain can answer for one.
		String named = cursor::spelling(node, tmem) ?? "";
		if (named.len > 0 && project.session.ctx.modules.has_key(named)) {
			return string::tformat("module %s", named);
		}

		log::error("No valid symbol targeted at this offset context.");
		return "";
	}

	List{String} output;

	output.tinit();

	foreach (origin : origins) {
		if (!origin.node || !origin.owner) continue;

		// A receiver is written `&self`, which is all the source has to
		// slice and says nothing about what it is. The type it stands for
		// is the associated type of the method the cursor is in.
		String signature = receiver_signature(sf, loc, origin.node);
		if (signature.len == 0) signature = project.session.node_signature_text(origin.node, origin.owner);
		if (signature.len == 0) continue;

		// The signature is the part that is always there. A doc comment
		// gets appended when the declaration has one; requiring one meant
		// hovering anything undocumented - most methods included - showed
		// nothing at all.
		if (try ContractDecl* contract = cursor::contract(origin.node)) {
			String documented = contract_markdown(&project.session, contract, origin.owner);
			if (documented.len > 0) {
				output.push(string::tformat("```c3\n%s\n```\n\n%s", signature, documented));
				continue;
			}
		}

		output.push(signature);
	}

	return string::tjoin(output.array_view(), "\n---\n");

	// return cursor::spelling(node, tmem);
}

fn String contract_markdown(LspSession* session, ContractDecl* contract, FileEntry* owner) @private {
	if (!contract) return "";

	DString md = dstring::temp_with_capacity(256);

	if (contract.comment && contract.comment.text.len > 0) {
		md.append(unquoted(contract.comment.text));
	}

	if (contract.params.len > 0) {
		md.append("\n\n**Parameters**");

		foreach (Node* param_node : contract.params) {
			if (!param_node) continue;

			ContractParam* param = param_node.as(ContractParam);
			String name          = param.ident ? param.ident.text : "...";

			md.appendf("\n- `%s%s`", modifier_text(param.modifier, param.by_ref), name);
			append_description(md, param.description);
		}
	}

	if (contract.requires.len > 0) {
		md.append("\n\n**Requires**");

		foreach (Node* require_node : contract.requires) {
			if (!require_node) continue;

			ContractRequire* required = require_node.as(ContractRequire);
			String pinpoint           = required.param_pinpoint ? required.param_pinpoint.text : "";

			append_condition(
				md,
				session,
				owner,
				required.expr,
				pinpoint.len > 0 ? string::tformat("[%s] ", pinpoint) : ""
			);
			append_description(md, required.description);
		}
	}

	append_expressions(md, session, owner, contract.ensures, "**Ensures**");

	if (contract.return_desc) {
		md.appendf("\n\n**Returns** %s", unquoted(session.node_source_text(contract.return_desc, owner)));
	}

	append_expressions(md, session, owner, contract.returns, "**Faults**");

	if (contract.is_pure) md.append("\n\n**Pure**");

	if (contract.deprecated) {
		md.append("\n\n**Deprecated**");

		foreach (Node* reason : contract.deprecated.as(AttributeDecl).exprs) {
			md.appendf(" %s", unquoted(session.node_source_text(reason, owner)));
		}
	}

	return md.str_view().trim();
}

<*
 @param [&inout] md
*>
fn void append_expressions(
	DString md,
	LspSession* session,
	FileEntry* owner,
	NodeArray exprs,
	String heading
) @private {
	if (exprs.len == 0) return;

	md.appendf("\n\n%s", heading);

	foreach (Node* expr : exprs) {
		append_condition(md, session, owner, expr, "");
	}
}

<*
 @param [&inout] md
*>
fn void append_condition(DString md, LspSession* session, FileEntry* owner, Node* node, String prefix) @private {
	if (!node) return;

	if (node.kind != CONTRACT_EXPR) {
		md.appendf("\n- `%s%s`", prefix, session.node_source_text(node, owner).trim());
		return;
	}

	ContractExpr* condition = node.as(ContractExpr);

	md.appendf("\n- `%s%s`", prefix, session.node_source_text(condition.exprs, owner).trim());

	if (condition.expr_string) {
		md.appendf(" - %s", unquoted(session.node_source_text(condition.expr_string, owner)));
	}
}

<*
 @param [&inout] md
*>
fn void append_description(DString md, Ident* description) @private {
	if (!description) return;

	String text = unquoted(description.text);
	if (text.len == 0) return;

	md.appendf(" - %s", text);
}

fn String unquoted(String text) @private {
	String trimmed = text.trim();
	if (trimmed.len < 2) return trimmed;

	char first = trimmed[0];
	if ((first == '"' || first == '`') && trimmed[^1] == first) return trimmed[1..^2];

	return trimmed;
}

<*
 `[&inout] ` for a parameter that declares one, empty otherwise.
*>
fn String modifier_text(InOutModifier modifier, bool by_ref) @private {
	String name;

	switch (modifier) {
		case IN: name = "in";
		case OUT: name = "out";
		case INOUT: name = "inout";
		case DROP: name = "drop";
		case OWN: name = "own";
		default: return "";
	}

	return string::tformat("[%s%s] ", by_ref ? "&" : "", name);
}

<*
 `Type* self` for a method receiver, empty for anything else.
*>
fn String receiver_signature(SourceFile* sf, Location loc, Node* node) @private {
	if (!node || node.kind != VAR_DECL) return "";

	VarDecl* decl = node.as(VarDecl);
	if (!decl.var_flags.is_self) return "";

	String type_name = core::method_target(core::top_level_at(sf, loc));
	if (type_name.len == 0) return "";

	return string::tformat("%s%s self", type_name, decl.var_flags.is_self_by_ref ? "*" : "");
}

fn String get_keyword_docs(TokenKind kind) {
	switch (kind) {
		case ALIAS: return "alias";
		case ASSERT: return "assert";
		case ASM: return "asm block";
		case ATTRDEF: return "attrdef";
		case BITSTRUCT: return "bitstruct";
		case BREAK: return "break";
		case CASE: return "case";
		case CATCH: return "catch";
		case CONSTDEF: return "constdef";
		case CONST: return "const";
		case CONTINUE: return "continue";
		case DEFAULT: return "default";
		case DEFER: return "defer";
		case DO: return "do";
		case ELSE: return "else";
		case ENUM: return "enum";
		case EXTERN: return "extern";
		case FALSE: return "false";
		case FAULTDEF: return "faultdef";
		case FOR: return "for";
		case FOREACH: return "foreach";
		case FOREACH_R: return "foreach_r";
		case FN: return "fn";
		case TLOCAL: return "tlocal";
		case IF: return "if";
		case INLINE: return "inline";
		case IMPORT: return "import";
		case LENGTHOF: return "lengthof";
		case MACRO: return "macro";
		case MODULE: return "module";
		case NEXTCASE: return "nextcase";
		case NULL: return "null";
		case INTERFACE: return "interface";
		case RETURN: return "return";
		case STATIC: return "static";
		case STRUCT: return "struct";
		case SWITCH: return "switch";
		case TRUE: return "true";
		case TRY: return "try";
		case TYPEDEF: return "typedef";
		case UNION: return "union";
		case VAR: return "var";
		case WHILE: return "while";
		default: return "";
	}
}

fn String get_base_type_docs(TokenKind kind) {
	switch (kind) {
		case VOID_TYPE: return "void";
		case BOOL_TYPE: return "bool";
		case CHAR_TYPE: return "char";
		case DOUBLE_TYPE: return "double";
		case FLOAT_TYPE: return "float";
		case FLOAT16_TYPE: return "float16";
		case BFLOAT_TYPE: return "bfloat";
		case INT128_TYPE: return "int128";
		case ICHAR_TYPE: return "ichar";
		case INT_TYPE: return "int";
		case IPTR_TYPE: return "iptr";
		case SZ_TYPE: return "sz";
		case LONG_TYPE: return "long";
		case SHORT_TYPE: return "short";
		case UINT128_TYPE: return "uint128";
		case UINT_TYPE: return "uint";
		case ULONG_TYPE: return "ulong";
		case UPTR_TYPE: return "uptr";
		case USHORT_TYPE: return "ushort";
		case USZ_TYPE: return "usz";
		case FLOAT128_TYPE: return "float128";
		case ANY_TYPE: return "any";
		case FAULT_TYPE: return "fault";
		case TYPEID_TYPE: return "typeid";
		case UNTYPEDLIST_TYPE: return "untypedlist";
		default: return "";
	}
}
