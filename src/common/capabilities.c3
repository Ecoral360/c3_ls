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

$expand(dessert::@derive(SignatureHelpOptions));
struct SignatureHelpOptions @DStruct({ .rename_all = CAMEL_CASE }){
	String[] trigger_characters;
	String[] retrigger_characters;
}

$expand(dessert::@derive(SemanticTokensLegend));
struct SemanticTokensLegend @DStruct({ .rename_all = CAMEL_CASE }){
	String[] token_types;
	String[] token_modifiers;
}

$expand(dessert::@derive(SemanticTokensOptions));
struct SemanticTokensOptions @DStruct({ .rename_all = CAMEL_CASE }){
	SemanticTokensLegend legend;
	bool full;
}

$expand(dessert::@derive(RenameOptions));
struct RenameOptions @DStruct({ .rename_all = CAMEL_CASE }){
	bool prepare_provider;
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
	SignatureHelpOptions signature_help_provider;
	bool references_provider;
	RenameOptions rename_provider;
	SemanticTokensOptions semantic_tokens_provider;
	bool document_symbol_provider;
	bool workspace_symbol_provider;
	bool inlay_hint_provider;
	bool folding_range_provider;
	bool document_formatting_provider;
	bool document_range_formatting_provider;
}
