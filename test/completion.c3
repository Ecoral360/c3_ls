module lsp::analysis::completion @test;

import analyzer::core;
import analyzer::lexer;

import lsp::core;
import lsp::test_support;
import lsp::translator;

import dessert;

import std::collections::list;

// ---------------------------------------------------------------------
// Module path splitting (pure)
// ---------------------------------------------------------------------

fn void get_remaining_path_without_static_access() {
	// Nothing to strip unless the cursor is after a '::'.
	test::eq(get_remaining_path("std::io::file", "std", LspAccessKind.NONE), "std::io::file");
	test::eq(get_remaining_path("std::io::file", "std", LspAccessKind.INSTANCE), "std::io::file");
	test::eq(get_remaining_path("std::io::file", "", LspAccessKind.STATIC), "std::io::file");
}

fn void get_remaining_path_strips_the_base() {
	test::eq(get_remaining_path("std::io::file", "std", LspAccessKind.STATIC), "io::file");
	test::eq(get_remaining_path("std::io::file", "io", LspAccessKind.STATIC), "file");
	test::eq(get_remaining_path("std::io::file", "file", LspAccessKind.STATIC), "");
	test::eq(get_remaining_path("std::io", "nope", LspAccessKind.STATIC), "");
}

fn void get_next_segment_splits_on_scope() {
	test::eq(get_next_segment("io::file::path"), "io");
	test::eq(get_next_segment("io"), "io");
	test::eq(get_next_segment(""), "");
	test::eq(get_next_segment("a"), "a");
	test::eq(get_next_segment("::x"), "");
}

// ---------------------------------------------------------------------
// Token population
// ---------------------------------------------------------------------

fn void context_populate_tokens_copies_the_lexer_list() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	FileEntry* entry = session.entry(test_support::FIXTURE_PATH);

	Context ctx = { .sf = entry.sf };
	context_populate_tokens(&ctx);

	test::eq(ctx.tokens.len(), entry.sf.lexer.tokens.len());
	test::eq(ctx.tokens[0].kind, entry.sf.lexer.tokens[0].kind);
	test::eq(ctx.tokens[0].value, entry.sf.lexer.tokens[0].value);
}

fn void context_populate_tokens_tolerates_no_file() {
	Context ctx;
	context_populate_tokens(&ctx);
	test::@check(ctx.tokens.is_empty(), "a context with no source file yields no tokens");
}

// ---------------------------------------------------------------------
// Access detection
// ---------------------------------------------------------------------

const String INSTANCE_SRC = `module access;

fn void use()
{
	value.
}
`;

const String STATIC_SRC = `module access;

fn void use()
{
	Thing::
}
`;

const String PLAIN_SRC = `module access;

fn void use()
{
	value
}
`;

fn void detect_access_context_finds_instance_access() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, "/virtual/access.c3", INSTANCE_SRC);

	Location cursor = test_support::loc_after(INSTANCE_SRC, "value.");
	Context ctx     = test_support::make_completion_context(&session, "/virtual/access.c3", cursor);

	test::eq(ctx.access, LspAccessKind.INSTANCE);
	test::eq(ctx.base_identifier, "value");
	test::eq(ctx.base_location, test_support::loc_of(INSTANCE_SRC, "value."));
}

fn void detect_access_context_finds_static_access() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, "/virtual/access.c3", STATIC_SRC);

	Location cursor = test_support::loc_after(STATIC_SRC, "Thing::");
	Context ctx     = test_support::make_completion_context(&session, "/virtual/access.c3", cursor);

	test::eq(ctx.access, LspAccessKind.STATIC);
	test::eq(ctx.base_identifier, "Thing");
}

fn void detect_access_context_ignores_bare_identifiers() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, "/virtual/access.c3", PLAIN_SRC);

	Location cursor = test_support::loc_after(PLAIN_SRC, "value");
	Context ctx     = test_support::make_completion_context(&session, "/virtual/access.c3", cursor);

	test::eq(ctx.access, LspAccessKind.NONE);
	test::eq(ctx.base_identifier, "");
}

fn void detect_access_context_needs_two_tokens() {
	Context ctx;
	ctx.tokens.tinit();

	detect_access_context(&ctx);
	test::eq(ctx.access, LspAccessKind.NONE);
	test::eq(ctx.base_identifier, "");
}

// ---------------------------------------------------------------------
// find_scope
// ---------------------------------------------------------------------

const String SCOPE_SRC = `module scopes;

import std::io;

int at_top;

struct Holder
{
	int field;
}

fn int work(int arg)
{
	int local = arg;
	return local;
}
`;

const String SCOPE_PATH = "/virtual/scopes.c3";

<*
 find_scope decides which completion providers run, so every branch of it
 is worth pinning. It reads ctx.top_level_node, which has to be the
 enclosing declaration and not the innermost node.
*>
fn void find_scope_classifies_positions() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, SCOPE_PATH, SCOPE_SRC);

	Context on_import = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_of(SCOPE_SRC, "std::io")
	);
	test::eq(on_import.scope, CompletionContextKind.IMPORT);

	Context at_global = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_of(SCOPE_SRC, "at_top")
	);
	test::eq(at_global.scope, CompletionContextKind.GLOBAL);

	Context in_struct = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_of(SCOPE_SRC, "int field")
	);
	test::eq(in_struct.scope, CompletionContextKind.CONTAINER);

	Context in_params = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_after(SCOPE_SRC, "work(")
	);
	test::eq(in_params.scope, CompletionContextKind.PARAMETER);

	Context in_body = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_of(SCOPE_SRC, "int local")
	);
	test::eq(in_body.scope, CompletionContextKind.EXECUTION);
}

fn void find_scope_defaults_to_global_outside_declarations() {
	Context ctx;
	test::eq(analysis::find_ctx_completion_kind(&ctx, { .line = 0, .column = 0 }), CompletionContextKind.GLOBAL);
}

// ---------------------------------------------------------------------
// provide_global (and the should_include_node filter behind it)
// ---------------------------------------------------------------------

fn void provide_global_filters_by_module() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file(test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	session.set_file(test_support::OTHER_PATH, test_support::OTHER_SRC);
	session.rebuild_index();
	session.analyze(test_support::FIXTURE_PATH);

	Context ctx = test_support::make_completion_context(
		&session,
		test_support::FIXTURE_PATH,
		test_support::loc_of(test_support::FIXTURE_SRC, "int sum")
	);
	test::eq(ctx.scope, CompletionContextKind.EXECUTION);

	List{CompletionItem} items;
	items.tinit();
	provide_global(&ctx, &items);

	test::@check(test_support::has_label(items, "add"), "a symbol from the current module is missing");
	test::@check(test_support::has_label(items, "counter"), "a global in the current module is missing");
	test::@check(test_support::has_label(items, "Widget"), "a public type from another module is missing");

	test::@check(!test_support::has_label(items, "hidden"), "a private symbol leaked out of its module");
	test::@check(!test_support::has_label(items, "other_global"), "a global leaked out of its module");
}

<*
 At file scope only type-ish declarations can legally follow, so
 provide_global switches to types only there.
*>
fn void provide_global_offers_only_types_at_file_scope() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Context ctx = test_support::make_completion_context(
		&session,
		test_support::FIXTURE_PATH,
		test_support::loc_of(test_support::FIXTURE_SRC, "int counter")
	);
	test::eq(ctx.scope, CompletionContextKind.GLOBAL);

	List{CompletionItem} items;
	items.tinit();
	provide_global(&ctx, &items);

	test::@check(test_support::has_label(items, "Point"), "types stay available at file scope");
	test::@check(test_support::has_label(items, "Color"), "enums stay available at file scope");

	test::@check(!test_support::has_label(items, "add"), "a function is not a valid file scope completion");
	test::@check(!test_support::has_label(items, "@twice"), "a macro is not a valid file scope completion");
	test::@check(!test_support::has_label(items, "counter"), "a variable is not a valid file scope completion");
}

fn void provide_global_stays_out_of_member_access() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Context ctx = test_support::make_completion_context(
		&session,
		test_support::FIXTURE_PATH,
		test_support::loc_of(test_support::FIXTURE_SRC, "int sum")
	);
	ctx.access = LspAccessKind.INSTANCE;

	List{CompletionItem} items;
	items.tinit();
	provide_global(&ctx, &items);

	test::@check(items.is_empty(), "global symbols must not be offered after a '.'");
}

// ---------------------------------------------------------------------
// Completion item payloads
// ---------------------------------------------------------------------

<*
 The `data` payload is the only link between a completion item and the
 declaration it came from, and resolve_item reads it back through
 find_node_by_id. The round trip broke silently once already, when
 ModuleSection ids were replaced by NodeIDs.
*>
fn void add_symbol_completion_data_round_trips() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Context ctx = test_support::make_completion_context(
		&session,
		test_support::FIXTURE_PATH,
		test_support::loc_of(test_support::FIXTURE_SRC, "int sum")
	);

	Node* add = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "add");

	List{CompletionItem} items;
	items.tinit();
	add_symbol_completion(&ctx, &items, "add", add, "fixture", "");

	test::eq(items.len(), 1);
	CompletionItem item = items[0];
	test::eq(item.label, "add");
	test::eq(item.kind, CompletionItemKind.FUNCTION);

	sz split = item.data.index_of_char(';') ?? -1;
	test::gt(split, 0);
	test::eq(item.data[split + 1..], "add");

	ulong node_id = item.data[:split].to_ulong() ?? 0;
	test::ne(node_id, (ulong)0);
	test::eq(find_node_by_id(&session, node_id), add);

	test::eq(find_node_by_id(&session, 999999), null);
}

fn void add_symbol_completion_strips_the_macro_sigil() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Context ctx = test_support::make_completion_context(
		&session,
		test_support::FIXTURE_PATH,
		test_support::loc_of(test_support::FIXTURE_SRC, "int sum")
	);

	Node* twice = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "@twice");

	List{CompletionItem} items;
	items.tinit();
	add_symbol_completion(&ctx, &items, "@twice", twice, "fixture", "");

	CompletionItem item = items[0];
	test::eq(item.label, "@twice");
	test::eq(item.filter_text, "twice");
	test::@check(item.insert_text.starts_with("@twice("), "an unprefixed insert keeps the sigil");
}

fn void add_symbol_completion_ignores_null_nodes() {
	Context ctx;
	List{CompletionItem} items;
	items.tinit();

	add_symbol_completion(&ctx, &items, "add", null, "fixture", "");
	test::@check(items.is_empty());
}

// ---------------------------------------------------------------------
// Keywords
// ---------------------------------------------------------------------

fn void provide_keywords_filters_by_scope() {
	Context ctx = { .scope = CompletionContextKind.GLOBAL, .access = LspAccessKind.NONE };

	List{CompletionItem} items;
	items.tinit();
	provide_keywords(&ctx, &items);

	test::@check(!items.is_empty());
	foreach (CompletionItem item : items) {
		test::eq(item.kind, CompletionItemKind.KEYWORD);
		test::@check(test_support::keyword_named(item.label)
			.is_top_level(), "'%s' is not legal at file scope", item.label);
	}

	Context body = { .scope = CompletionContextKind.EXECUTION, .access = LspAccessKind.NONE };
	List{CompletionItem} body_items;
	body_items.tinit();
	provide_keywords(&body, &body_items);

	test::@check(!body_items.is_empty());
	foreach (CompletionItem item : body_items) {
		lsp::Keywords kw = test_support::keyword_named(item.label);
		test::@check(kw.is_statement() || kw.is_expression(), "'%s' is not legal in a body", item.label);
	}

	test::ne(items.len(), body_items.len());
}

fn void provide_keywords_filters_by_prefix() {
	Context ctx = { .scope = CompletionContextKind.GLOBAL, .access = LspAccessKind.NONE, .prefix = "st" };

	List{CompletionItem} items;
	items.tinit();
	provide_keywords(&ctx, &items);

	test::@check(!items.is_empty());
	foreach (CompletionItem item : items) {
		test::@check(item.label.starts_with("st"), "'%s' does not match the prefix", item.label);
	}
}

fn void provide_keywords_stays_out_of_member_access() {
	Context ctx = { .scope = CompletionContextKind.EXECUTION, .access = LspAccessKind.INSTANCE };

	List{CompletionItem} items;
	items.tinit();
	provide_keywords(&ctx, &items);

	test::@check(items.is_empty(), "keywords must not be offered after a '.'");
}
// ---------------------------------------------------------------------
// Completion on a file that does not parse
// ---------------------------------------------------------------------

<*
 Every one of these sources has a syntax error, because that is the state
 a file is in while someone is typing in it. cursor::visit_children used
 to refuse to descend into any node whose has_error flag was set, and the
 flag propagates to the top, so a single bad character emptied every sema
 scope in the file and locals and member access silently went dead.
*>
const String TYPING_SRC = `module typing;

struct Point
{
	int x;
	int y;
}

fn void go()
{
	Point p;
	int total = 1;
	p.
}

fn void unterminated(
`;

const String TYPING_PATH = "/virtual/typing.c3";

fn void locals_survive_a_syntax_error() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, TYPING_PATH, TYPING_SRC);

	// Inside go's body, with the errors elsewhere in the file. Both the
	// dangling 'p.' and the unterminated declaration at the end used to be
	// enough to wipe every scope in the file.
	Context ctx = test_support::make_completion_context(
		&session,
		TYPING_PATH,
		test_support::loc_after(TYPING_SRC, "int total = 1;")
	);
	test::eq(ctx.scope, CompletionContextKind.EXECUTION);
	test::eq(ctx.access, LspAccessKind.NONE);

	List{CompletionItem} items;
	items.tinit();
	provide_locals(&ctx, &items);

	test::@check(test_support::has_label(items, "p"), "a local was lost to the syntax error");
	test::@check(test_support::has_label(items, "total"), "a local was lost to the syntax error");
}

<*
 '.' on a variable offers that type's fields.

 The type is resolved by hand - name to VarDecl through the scope chain,
 then the written type name back through the symbol index - because the
 analyzer's sema does not populate TypeInfo.resolved.
*>
fn void instance_access_offers_struct_fields() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, TYPING_PATH, TYPING_SRC);

	Context ctx = test_support::make_completion_context(
		&session,
		TYPING_PATH,
		test_support::loc_after(TYPING_SRC, "p.")
	);
	test::eq(ctx.access, LspAccessKind.INSTANCE);
	test::eq(ctx.base_identifier, "p");

	List{CompletionItem} items;
	items.tinit();
	test::@check(provide_instance_access(&ctx, &items), "member access did not resolve the base type");

	test::eq(items.len(), 2);
	test::@check(test_support::has_label(items, "x"));
	test::@check(test_support::has_label(items, "y"));
	test::eq(items[0].kind, CompletionItemKind.FIELD);
}

fn void instance_access_declines_an_unresolvable_base() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, TYPING_PATH, TYPING_SRC);

	Context ctx = test_support::make_completion_context(
		&session,
		TYPING_PATH,
		test_support::loc_after(TYPING_SRC, "p.")
	);
	ctx.base_identifier = "not_a_variable";

	List{CompletionItem} items;
	items.tinit();
	test::@check(!provide_instance_access(&ctx, &items), "an unknown base must not claim the completion");
	test::@check(items.is_empty());

	test::eq(resolve_variable_type(&ctx, "not_a_variable"), null);
	test::eq(resolve_variable_type(&ctx, ""), null);
}

// ---------------------------------------------------------------------
// Import completion
// ---------------------------------------------------------------------

<*
 A completion request lands one past the last character typed, which is
 outside the declaration's own range: Range.contains is end exclusive.
 Both the unterminated import and the one with only trailing space used
 to fall through to the global symbol list instead of offering modules.
*>
fn void import_context_is_detected_while_typing() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file(test_support::OUTER_PATH, test_support::OUTER_SRC);
	session.set_file(test_support::INNER_PATH, test_support::INNER_SRC);

	String partial = "module typing;\n\nimport out\n";
	session.set_file(TYPING_PATH, partial);
	session.rebuild_index();
	session.analyze(TYPING_PATH);

	Context ctx = test_support::make_completion_context(
		&session,
		TYPING_PATH,
		test_support::loc_after(partial, "import out")
	);
	test::eq(ctx.scope, CompletionContextKind.IMPORT);
	test::eq(ctx.prefix, "out");

	List{CompletionItem} items;
	items.tinit();
	provide_imports(&ctx, &items);

	test::@check(test_support::has_label(items, "outer"), "the matching module is missing");
	test::@check(test_support::has_label(items, "outer::inner"), "the nested module is missing");
	test::@check(!test_support::has_label(items, "typing"), "the prefix filter let a non match through");
}

fn void import_context_survives_trailing_space() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file(test_support::OUTER_PATH, test_support::OUTER_SRC);

	String partial = "module typing;\n\nimport \n";
	session.set_file(TYPING_PATH, partial);
	session.rebuild_index();
	session.analyze(TYPING_PATH);

	Context ctx = test_support::make_completion_context(
		&session,
		TYPING_PATH,
		test_support::loc_after(partial, "import ")
	);
	test::eq(ctx.scope, CompletionContextKind.IMPORT);
	test::eq(ctx.prefix, "");

	List{CompletionItem} items;
	items.tinit();
	provide_imports(&ctx, &items);

	test::@check(test_support::has_label(items, "outer"), "an empty prefix should offer every module");
}
<*
 Typing a character after the operator has to narrow the list.

 The '.' path filtered through collect_struct_fields, but the '::' path
 went through inject_type_properties, which pushed all thirteen
 reflection properties without ever consulting ctx.prefix.
*>
fn void member_access_narrows_as_you_type() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String src = "module typed;\n\nstruct Point\n{\n\tint x;\n\tint y;\n}\n\nfn void go()\n{\n\tPoint p;\n\tPLACEHOLDER\n}\n";

	// '.' offers the fields, and narrows to the one being typed.
	test::eq(test_support::member_labels(&session, src, "p."), 2);
	test::eq(test_support::member_labels(&session, src, "p.x"), 1);
	test::eq(test_support::member_labels(&session, src, "p.zz"), 0);

	// '::' offers the reflection properties, and narrows the same way.
	int all_properties = test_support::member_labels(&session, src, "Point::");
	test::gt(all_properties, 1);
	test::eq(test_support::member_labels(&session, src, "Point::si"), 1);
	test::eq(test_support::member_labels(&session, src, "Point::zz"), 0);
}
// ---------------------------------------------------------------------
// Wire shape
// ---------------------------------------------------------------------

<*
 An item a client can actually apply.

 insertText and filterText used to serialize as "" on every item that did
 not set them, and a present-but-empty insertText makes a client insert
 nothing when the item is picked. insertTextFormat and
 MarkupContent.kind have no valid zero value either, so both went out as
 values the protocol does not define.
*>
fn void completion_items_are_applicable() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Context ctx = test_support::make_completion_context(
		&session,
		test_support::FIXTURE_PATH,
		test_support::loc_of(test_support::FIXTURE_SRC, "int sum")
	);

	List{CompletionItem} items;
	items.tinit();
	provide_keywords(&ctx, &items);
	provide_global(&ctx, &items);
	test::gt(items.len(), 0);

	CompletionItem[] finished = finish(&items);

	foreach (CompletionItem item : finished) {
		test::gt(item.label.len, 0);

		// A snippet has to carry the text it expands to; anything else is
		// free to leave insertText out and let the client use the label.
		if (item.insert_text_format == SNIPPET) test::gt(item.insert_text.len, 0);

		test::@check(
			item.insert_text_format == PLAIN_TEXT || item.insert_text_format == SNIPPET,
			"'%s' carries insertTextFormat %d, which the protocol does not define",
			item.label,
			(int)item.insert_text_format
		);
		test::@check(
			item.documentation.kind == MarkupKind.PLAIN_TEXT || item.documentation.kind == MarkupKind.MARKDOWN,
			"'%s' carries documentation kind '%s'",
			item.label,
			item.documentation.kind
		);

		// The serialized form is the contract that actually matters: an
		// empty insertText on the wire is what made picking an item do
		// nothing.
		String encoded = json::tstring_serialize(item)!!;
		test::@check(
			!encoded.contains(`"insertText":""`),
			"'%s' serializes an empty insertText: %s",
			item.label,
			encoded
		);
		test::@check(
			!encoded.contains(`"filterText":""`),
			"'%s' serializes an empty filterText: %s",
			item.label,
			encoded
		);
		test::@check(
			!encoded.contains(`"insertTextFormat":0`),
			"'%s' serializes an invalid format: %s",
			item.label,
			encoded
		);
		test::@check(!encoded.contains(`"kind":""`), "'%s' serializes an invalid markup kind: %s", item.label, encoded);
	}
}
<*
 completionItem/resolve has to give the item back, not a fresh one.

 Its params are a CompletionItem, not a wrapper around one. Modelling
 them as a struct with an `inline CompletionItem` deserialized to
 all-empty fields, so the reply carried an empty label and no insert
 text, and pressing Enter on a suggestion inserted nothing.
*>
fn void resolve_params_keep_the_item() => @pool() {
	String raw = `{"jsonrpc":"2.0","id":7,"method":"completionItem/resolve","params":`
		+++ `{"label":"add","kind":3,"detail":"fn via m","insertText":"add($1)",`
		+++ `"insertTextFormat":2,"filterText":"add","sortText":"0005_add","data":"15473;add"}}`;

	IoDecodeResult decoded = translator::decode(tmem, raw)!!;
	LspMessage message     = decoded.message;
	test::eq(message.method, MessageKind.COMPLETION_RESOLVE);

	CompletionItem item = message.params.completion_resolve;
	test::eq(item.label, "add");
	test::eq(item.kind, CompletionItemKind.FUNCTION);
	test::eq(item.detail, "fn via m");
	test::eq(item.insert_text, "add($1)");
	test::eq(item.insert_text_format, InsertTextFormat.SNIPPET);
	test::eq(item.filter_text, "add");
	test::eq(item.sort_text, "0005_add");
	test::eq(item.data, "15473;add");
}