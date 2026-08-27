module lsp::analysis::goto_definition;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;

import std::collections::list;
import std::collections::map;

import lsp::core;

import uri;

fn LspLocation[]? goto_definition(LspProject* project, Uri uri, LspPosition pos) {
	log::info("goto definition");

	Location loc = pos.to_location();

	log::info("resolve - editor location: %s:%s", loc.line + 1, loc.column + 1);

	FileEntry* entry = project.session.entry(uri.path);
	if (!entry || !entry.sf) {
		log::info("No tracked file for: %s", uri.path);
		return { };
	}

	Node* node = cursor::node(&entry.sf.ast, loc).node;
	if (!node || !node.is_valid()) {
		log::error("Cursor not found!");
		return { };
	}

	log::info("Kind: %s", node.kind.description);

	String symbol = extract_symbol_at_cursor(node, loc) ?? "";
	if (!symbol) {
		log::error("No valid symbol targeted at this offset context.");
		return { };
	}

	log::info("symbol: %s", symbol);

	List{LspLocation} locations;
	locations.tinit();
	List{SymbolRef} entries = project.session.find_symbols(symbol);

	if (entries.len() <= 0) {
		log::error("No entries found for symbol: %s", symbol);
	}

	foreach (SymbolRef ref : entries) {
		if (!ref.node || !ref.owner) continue;

		Range range = ref.node.range;

		log::debug("Adding location: %s-%s", range.start.line, range.start.column);

		LspLocation entry_loc = {
			.uri = (DocumentUri)string::tformat("%s", uri::from_file_path(tmem, ref.owner.path)),
			.range = {
				.start = { .line = (uint)range.start.line, .character = (uint)range.start.column },
				.end = { .line = (uint)range.end.line, .character = (uint)range.end.column }
			}
		};
		locations.push(entry_loc);
	}

	log::info("Sending %d", locations.len());

	return locations.array_view();
}

fn String? extract_symbol_at_cursor(Node* node, Location loc) {
	if (!node || !node.is_valid()) return "";

	switch (node.kind) {
		case FN_DECL:
			FnDecl* fndecl = node.as(FnDecl);

			if (!fndecl.name || !fndecl.name.range.contains(loc)) {
				log::info("Cursor inside FN_DECL but missed the name token.");
				return "";
			}
			return fndecl.name.text;
		case STRUCT_DECL:
			StructDecl* structdecl = node.as(StructDecl);

			if (!structdecl.name || !structdecl.name.range.contains(loc)) return "";

			return structdecl.name.text;

		case VAR_DECL:
			VarDecl* vardecl = node.as(VarDecl);

			if (!vardecl.name || !vardecl.name.range.contains(loc)) return "";
			return vardecl.name.text;
		case TYPE_EXPR:
			return cursor::raw_type_identifier(node);
		default:
			return cursor::spelling(node, tmem);
	}
}
