module lsp::msg_handler::signature_help;

import lsp::translator;
import lsp::io_handler;
import lsp::analysis;
import lsp::core;

import std::io;
import std::collections::object;
import std::collections::maybe;
import std::collections::list;

import dessert;

import uri;

$expand(dessert::@derive(LspSignatureHelpResponse));
struct LspSignatureHelpResponse {
	String jsonrpc;
	int id;
	SignatureHelpResult result;
}


fn void response(Allocator allocator, LspProject* project, LspMessage* message) {
	log::info("URI: %s", message.params.signature_help.document.uri);
	Uri? file_uri = uri::parse(tmem, message.params.signature_help.document.uri);
	if (catch err = file_uri) {
		log::error("Failed to parse uri: %s", err);
		return;
	}
	LspPosition pos = message.params.signature_help.position;

	SignatureHelpResult? result = analysis::signature_help::response(project, file_uri, pos);

	LspSignatureHelpResponse res = {
		.jsonrpc = message.rpc,
		.id = message.id.get() ?? -1,
		.result = result ?? { },
	};

	String response_json = translator::encode(res, allocator);

	log::debug("complete response: %s", response_json);
	io_handler::write(response_json);
}
