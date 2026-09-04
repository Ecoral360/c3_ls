module lsp::analysis::signature_help;
import lsp::core;
import analyzer::core;
import analyzer::cursor;

import uri;

import dessert;

$expand(dessert::@derive(ParameterInformation));
struct ParameterInformation {
	String label;
	String documentation;
}

$expand(dessert::@derive(SignatureInformation));
struct SignatureInformation @DStruct({ .rename_all = CAMEL_CASE }) {
	String label;
	MarkupContent documentation;
	ParameterInformation[] parameters;
	uint active_parameter;
}

$expand(dessert::@derive(SignatureHelpResult));
struct SignatureHelpResult @DStruct({ .rename_all = CAMEL_CASE }) {
	SignatureInformation[] signatures;
	uint active_signature;
	uint active_parameter;
}


fn SignatureHelpResult? response(LspProject* project, Uri uri, LspPosition pos) {
	log::info("signature help");

	Location loc = pos.to_location();

	log::info("resolve - editor location: %s:%s", loc.line + 1, loc.column + 1);

	FileEntry* entry = project.session.entry(uri.path);
	if (!entry || !entry.sf) {
		log::info("No tracked file for: %s", uri.path);
		return { };
	}

	NodeEntry node_entry = cursor::node_entry(&entry.sf.ast, loc);
	Node* node = node_entry.node;
	NodePath path = node_entry.path;
	if (!node || !node.is_valid()) {
		log::error("Cursor not found!");
		return { };
	}

	return (SignatureHelpResult) { .active_signature = 0 };
}
