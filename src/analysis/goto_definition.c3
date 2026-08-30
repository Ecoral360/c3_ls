module lsp::analysis::goto_definition;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;

import std::collections::list;
import std::collections::map;

import lsp::analysis;
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

	Node* node = cursor::node_entry(&entry.sf.ast, loc).node;
	if (!node || !node.is_valid()) {
		log::error("Cursor not found!");
		return { };
	}

	log::info("Kind: %s", node.kind.description);

	List{SymbolRef} entries = analysis::lookup_reference(&project.session, uri.path, loc, node);

	List{LspLocation} locations;
	locations.tinit();
	if (entries.len() <= 0) {
		log::error("No entries found at %s:%s", loc.line + 1, loc.column + 1);
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