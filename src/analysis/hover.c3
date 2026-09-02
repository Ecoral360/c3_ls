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
			if (contract && contract.comment && contract.comment.text.len > 0) {
				output.push(string::tformat("%s\n\n%s", signature, contract.comment.text.trim()));
				continue;
			}
		}

		output.push(signature);
	}

	return string::tjoin(output.array_view(), "\n---\n");

	// return cursor::spelling(node, tmem);
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
