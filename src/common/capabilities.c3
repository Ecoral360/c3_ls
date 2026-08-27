module lsp;

import dessert;

$expand(dessert::@derive(CompletionOptions));
struct CompletionOptions @DStruct({ .rename_all = CAMEL_CASE }) {
	String[] trigger_characters;
	String[] all_commit_characters;
	bool resolve_provider;
	struct completion_item {
		bool label_detail_support;
	}
}

<*
	https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#serverCapabilities
*>
$expand(dessert::@derive(LspServerCapabilities));
struct LspServerCapabilities @DStruct({ .rename_all = CAMEL_CASE }) {
	TextDocumentSyncOptions text_document_sync;
	CompletionOptions completion_provider;
	bool hover_provider;
	bool definition_provider;
}
