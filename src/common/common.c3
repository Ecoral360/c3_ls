module lsp;

import std::collections::object;
import std::collections::maybe;

import analyzer::core;
import dessert;

// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification

alias LspUri = String;
alias DocumentUri = String;


$expand(dessert::@derive(WorkspaceFolder));
struct WorkspaceFolder {
	LspUri uri;
	String name;
}

$expand(dessert::@derive(TextDocumentItem));
struct TextDocumentItem @DStruct({ .rename_all = CAMEL_CASE }) {
	DocumentUri uri;
	String language_id;
	int version;
	String text;
}

$expand(dessert::@derive(LspPosition));
struct LspPosition {
	<*
	 Line position in a document (zero-based).
	*>
	uint line;
	<*
	 Character offset on a line in a document (zero-based). The meaning of this
	 offset is determined by the negotiated `PositionEncodingKind`.
	 If the character value is greater than the line length it defaults back
	 to the line length.
	*>
	uint character;
}

fn Location LspPosition.to_location(&self) {
	return { .line = (int)self.line, .column = (int)self.character };
}

$expand(dessert::@derive(LspRange));
struct LspRange {
	LspPosition start;
	LspPosition end;
}

$expand(dessert::@derive(LspLocation));
struct LspLocation {
	DocumentUri uri;
	LspRange range;
}


$expand(dessert::@derive(Diagnostic));
struct Diagnostic {
	LspRange range;
	DiagnosticSeverity severity;
	String source;
	String message;
	DiagnosticTag[] tags;
}

$expand(dessert::@derive(MarkedString));
struct MarkedString {
	String language;
	String value;
}

$expand(dessert::@derive(MarkupContent));
struct MarkupContent {
	MarkupKind kind;
	String value;
}

$expand(dessert::@derive(TextDocumentSyncOptions));
struct TextDocumentSyncOptions @DStruct({ .rename_all = CAMEL_CASE }) {
	<*
	 Open and close notifications are sent to the server. If omitted open
	 close notifications should not be sent.
	*>
	bool open_close;

	TextDocumentSyncKind change;
}

$expand(dessert::@derive(CompletionContext));
struct CompletionContext {
	CompletionTriggerKind trigger_kind;
	<*
	 The trigger character (a single character) that has trigger code
	 complete. Is undefined if
	 `triggerKind !== CompletionTriggerKind.TriggerCharacter`
	*>
	Maybe{String} trigger_character;
}

$expand(dessert::@derive(CompletionItem));
struct CompletionItem @DStruct({ .rename_all = CAMEL_CASE }) {
	String label;
	CompletionItemKind kind;
	<*
	 A human-readable string with additional information
	 about this item, like type or symbol information.
	*>
	String detail @DField({ .skip_if_empty = true });
	MarkupContent documentation;
	<*
	 Omitted when empty on purpose. A present but empty insertText makes a
	 client insert nothing when the item is picked; absent means "use the
	 label", which is what every item without an explicit snippet wants.
	 The same goes for filterText.
	*>
	String insert_text @DField({ .skip_if_empty = true });
	InsertTextFormat insert_text_format;
	String filter_text @DField({ .skip_if_empty = true });
	String sort_text @DField({ .skip_if_empty = true });
	<* custom data *>
	String data @DField({ .skip_if_empty = true });
}

$expand(dessert::@derive(VersionedTextDocumentIdentifier));
struct VersionedTextDocumentIdentifier @DStruct({ .rename_all = CAMEL_CASE }) {
	DocumentUri uri;
	int version;
}
