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
	Context ctx = {
		.scope = CompletionContextKind.GLOBAL,
		.access = LspAccessKind.NONE,
		.dstring_pool = test_support::test_pool(),
	};

	List{CompletionItem} items;
	items.tinit();
	provide_keywords(&ctx, &items);

	test::@check(!items.is_empty());
	foreach (CompletionItem item : items) {
		test::eq(item.kind, CompletionItemKind.KEYWORD);
		test::@check(test_support::keyword_named(item.label)
			.is_top_level(), "'%s' is not legal at file scope", item.label);
	}

	Context body = {
		.scope = CompletionContextKind.EXECUTION,
		.access = LspAccessKind.NONE,
		.dstring_pool = test_support::test_pool(),
	};
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
	Context ctx = {
		.scope = CompletionContextKind.GLOBAL,
		.access = LspAccessKind.NONE,
		.prefix = "st",
		.dstring_pool = test_support::test_pool(),
	};

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
	// base_node is what provide_instance_access reads now; a chain that did
	// not resolve leaves it null.
	ctx.base_identifier = "not_a_variable";
	ctx.base_node = null;

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
// ---------------------------------------------------------------------
// Access chains
// ---------------------------------------------------------------------

const String CHAIN_SRC = `module chained;

struct Point
{
	int x;
	int y;
}

struct Outer
{
	Point inner;
	int id;
}

struct Deep
{
	Outer mid;
}

Point global_point;

fn Point make_point()
{
	Point p;
	return p;
}

fn Outer make_outer()
{
	Outer o;
	return o;
}

fn void go(Point param)
{
	Point local;
	Outer o;
	Deep d;
	Point[4] arr;
	PLACEHOLDER
}
`;

<*
 A base that is more than a bare identifier.

 ctx.base_node holds the declaration the whole chain evaluates to, so
 every hop is resolved before anything is offered: name to declaration,
 declaration to its written type name, that name back to a declaration.
*>
fn void chain_follows_nested_fields() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String[] one = test_support::member_labels_of(&session, CHAIN_SRC, "o.");
	test::eq(one.len, 2);
	test::@check(test_support::has(one, "inner") && test_support::has(one, "id"), "got %s", one);

	// Two hops: the type of o.inner, not of o.
	String[] two = test_support::member_labels_of(&session, CHAIN_SRC, "o.inner.");
	test::eq(two.len, 2);
	test::@check(test_support::has(two, "x") && test_support::has(two, "y"), "got %s", two);

	// Three, with the last one narrowed by what is being typed.
	String[] three = test_support::member_labels_of(&session, CHAIN_SRC, "d.mid.inner.");
	test::@check(test_support::has(three, "x"), "got %s", three);
	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "d.mid.inner.y").len, 1);
}

<*
 'foo().x' - a call stands for whatever it returns, so the chain has to
 step through the function's return type.
*>
fn void chain_follows_call_results() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String[] direct = test_support::member_labels_of(&session, CHAIN_SRC, "make_point().");
	test::eq(direct.len, 2);
	test::@check(test_support::has(direct, "x"), "got %s", direct);

	// A call followed by a field hop.
	String[] nested = test_support::member_labels_of(&session, CHAIN_SRC, "make_outer().inner.");
	test::eq(nested.len, 2);
	test::@check(test_support::has(nested, "y"), "got %s", nested);

	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "make_point().x").len, 1);
}

<*
 An index yields the element, which raw_type_identifier already unwraps,
 and parameters and file scope variables resolve like any other name.
*>
fn void chain_follows_indexes_and_other_bases() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "arr[0].").len, 2);
	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "arr[1].y").len, 1);
	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "param.").len, 2);
	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "global_point.").len, 2);
}

<*
 A chain that cannot be followed offers nothing rather than falling back
 to the global list, which after a dot would be noise.
*>
fn void chain_declines_when_a_hop_fails() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "o.nope.").len, 0);
	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "not_a_thing.").len, 0);

	// Methods would need a method registry the analyzer does not have.
	test::eq(test_support::member_labels_of(&session, CHAIN_SRC, "o.inner.method().").len, 0);
}

<*
 base_node is the declaration the chain names, which is what the comment
 on the field describes: for 'a.b.c' it is where the type of 'b' is
 declared.
*>
fn void chain_sets_base_node_to_the_type_declaration() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String text = CHAIN_SRC.treplace("PLACEHOLDER", "o.inner.x");
	test_support::load(&session, "/virtual/typed.c3", text);

	Context ctx = test_support::make_completion_context(
		&session,
		"/virtual/typed.c3",
		test_support::loc_after(text, "o.inner.x")
	);

	test::eq(ctx.access, LspAccessKind.INSTANCE);
	test::eq(ctx.base_identifier, "inner");
	test::ne(ctx.base_node, null);
	test::eq(ctx.base_node.kind, NodeKind.STRUCT_DECL);
	test::eq(ctx.base_node, test_support::find_top_level(&session, "/virtual/typed.c3", "Point"));
	test::eq(ctx.prefix, "x");
}
<*
 C3 lets a type or a function be defined after the code that uses it, so
 completion has to resolve against declarations that sit below the
 cursor.

 That used to fail for the one shape it matters most in. A trailing '.'
 is the normal state of a half typed access, and parse_access_expr sent
 parse_expr at whatever followed it - which consumed the closing brace
 and then the next declaration, deleting it from the index. 'v.a' worked
 while 'v.' did not, purely because the member token stopped the damage.
*>
const String FORWARD_SRC = `module forward;

fn void go()
{
	Late v;
	PLACEHOLDER
}

struct Late
{
	int a;
	int b;
}

fn Late later()
{
	Late l;
	return l;
}
`;

fn void declarations_below_the_cursor_still_resolve() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	// The struct is declared after the function that uses it.
	String[] fields = test_support::member_labels_of(&session, FORWARD_SRC, "v.");
	test::eq(fields.len, 2);
	test::@check(test_support::has(fields, "a") && test_support::has(fields, "b"), "got %s", fields);

	// And so is the function whose return type this needs.
	String[] returned = test_support::member_labels_of(&session, FORWARD_SRC, "later().");
	test::eq(returned.len, 2);
	test::@check(test_support::has(returned, "a"), "got %s", returned);

	test::eq(test_support::member_labels_of(&session, FORWARD_SRC, "later().b").len, 1);
}

<*
 The declaration after a dangling access has to survive parsing at all -
 the completion above can only work if it is still in the index.
*>
fn void a_dangling_access_does_not_eat_the_next_declaration() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String text = FORWARD_SRC.treplace("PLACEHOLDER", "v.");
	test_support::load(&session, "/virtual/forward.c3", text);

	test::eq(session.find_symbols("Late").len(), 1);
	test::eq(session.find_symbols("later").len(), 1);
	test::eq(session.find_symbols("go").len(), 1);

	// The same file with the access completed indexes identically.
	LspSession complete;
	complete.init(mem);
	defer complete.free();
	test_support::load(&complete, "/virtual/forward.c3", FORWARD_SRC.treplace("PLACEHOLDER", "v.a;"));

	test::eq(session.by_name.len(), complete.by_name.len());
}
// ---------------------------------------------------------------------
// A module base offers no methods
// ---------------------------------------------------------------------

const String MODULE_BASE_SRC = `module modbase;

struct Widget
{
	int id;
}

fn int free_function()
{
	return 1;
}

fn int Widget.method(&self)
{
	return self.id;
}

macro @free_macro()
{
	return 1;
}
`;

const String MODULE_USER_SRC = `module modbase_user;

import modbase;

fn void go()
{
	PLACEHOLDER
}
`;

<*
 A method belongs to its type, not to the module it was written in.
 'modbase::method' is not something that can be written, so offering it
 after a module qualifier is pure noise - it was 86 of the 174 entries
 behind 'io::'.
*>
fn void module_base_offers_no_methods() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file("/virtual/modbase.c3", MODULE_BASE_SRC);

	String text = MODULE_USER_SRC.treplace("PLACEHOLDER", "modbase::");
	session.set_file("/virtual/modbase_user.c3", text);
	session.rebuild_index();
	session.analyze("/virtual/modbase_user.c3");

	Context ctx = test_support::make_completion_context(
		&session,
		"/virtual/modbase_user.c3",
		test_support::loc_after(text, "modbase::")
	);
	test::eq(ctx.access, LspAccessKind.STATIC);

	List{CompletionItem} items;
	items.tinit();
	provide_member_access(&ctx, &items);

	List{String} labels;
	labels.tinit();
	foreach (CompletionItem item : items) labels.push(item.label);
	String[] offered = labels.to_tarray();

	test::@check(test_support::has(offered, "free_function"), "a free function is missing: %s", offered);
	test::@check(test_support::has(offered, "@free_macro"), "a free macro is missing: %s", offered);
	test::@check(test_support::has(offered, "Widget"), "a type is missing: %s", offered);

	test::@check(!test_support::has(offered, "method"), "a method was offered behind a module: %s", offered);
}
// ---------------------------------------------------------------------
// Methods on instance access
// ---------------------------------------------------------------------

const String METHOD_SRC = `module methods;

struct Inner
{
	int v;
	int w;
}

struct Holder
{
	int id;
}

enum Flag
{
	ON,
	OFF,
}

fn Inner Holder.get_inner(&self)
{
	Inner i;
	return i;
}

fn void Holder.reset(&self)
{
	self.id = 0;
}

macro Holder.@doubled(&self)
{
	return 2;
}

fn int Inner.value(&self)
{
	return self.v;
}

fn bool Flag.is_on(&self)
{
	return true;
}

fn void go()
{
	Holder h;
	Inner i;
	Flag f;
	PLACEHOLDER
}
`;

<*
 The analyzer has no method registry, so the session keeps a reverse
 index from a type's bare name to the methods bound to it. Without it a
 dot offered fields only, which is most of a type's surface missing.
*>
fn void instance_access_offers_methods() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String[] offered = test_support::member_labels_of(&session, METHOD_SRC, "h.");

	test::@check(test_support::has(offered, "id"), "the field is missing: %s", offered);
	test::@check(test_support::has(offered, "get_inner"), "a method is missing: %s", offered);
	test::@check(test_support::has(offered, "reset"), "a method is missing: %s", offered);
	test::@check(test_support::has(offered, "@doubled"), "a macro method is missing: %s", offered);

	// Inner's methods belong to Inner, not to Holder.
	test::@check(!test_support::has(offered, "value"), "another type's method leaked in: %s", offered);

	// Typing narrows methods the same way it narrows fields.
	test::eq(test_support::member_labels_of(&session, METHOD_SRC, "h.res").len, 1);
}

<*
 An enum has no fields, but it can still carry methods, so the dot has to
 answer for it rather than declining.
*>
fn void instance_access_offers_methods_without_fields() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String[] offered = test_support::member_labels_of(&session, METHOD_SRC, "f.");
	test::eq(offered.len, 1);
	test::@check(test_support::has(offered, "is_on"), "got %s", offered);
}

<*
 'h.get_inner().' - the hop is through what the method returns, which
 needs the method found before its return type can be read.
*>
fn void chain_follows_method_call_results() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String[] offered = test_support::member_labels_of(&session, METHOD_SRC, "h.get_inner().");
	test::@check(test_support::has(offered, "v"), "the returned type's field is missing: %s", offered);
	test::@check(test_support::has(offered, "value"), "the returned type's method is missing: %s", offered);

	test::eq(test_support::member_labels_of(&session, METHOD_SRC, "h.get_inner().val").len, 1);

	// A method that does not exist resolves to nothing.
	test::eq(test_support::member_labels_of(&session, METHOD_SRC, "h.nope().").len, 0);
}

const String RIVAL_SRC = `module rival;

struct Holder
{
	int other;
}

fn void Holder.rival_only(&self)
{
	return;
}
`;

<*
 The method index is keyed by the bare type name, and 'Holder' here is
 declared in two modules. A method reaches a value only if it sits beside
 that declaration of the type, or in the module doing the extending.
*>
fn void methods_do_not_leak_across_modules() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file("/virtual/rival.c3", RIVAL_SRC);

	String text = METHOD_SRC.treplace("PLACEHOLDER", "h.");
	session.set_file("/virtual/typed.c3", text);
	session.rebuild_index();
	session.analyze("/virtual/typed.c3");

	Context ctx = test_support::make_completion_context(
		&session,
		"/virtual/typed.c3",
		test_support::loc_after(text, "h.")
	);

	List{CompletionItem} items;
	items.tinit();
	provide_member_access(&ctx, &items);

	List{String} labels;
	labels.tinit();
	foreach (CompletionItem item : items) labels.push(item.label);
	String[] offered = labels.to_tarray();

	test::@check(test_support::has(offered, "reset"), "the type's own method is missing: %s", offered);
	test::@check(
		!test_support::has(offered, "rival_only"),
		"a method on another module's same named type leaked in: %s",
		offered
	);
}
// ---------------------------------------------------------------------
// Import completion
// ---------------------------------------------------------------------

<*
 A module path is only a prefix of itself when it is matched whole.

 ctx.prefix stops at the last "::", so `import outer::inn` used to be
 filtered on "inn" alone: no module starts with that, and the list came
 back empty exactly when it was needed most.
*>
fn void import_completion_matches_deep_paths() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	Context ctx = test_support::import_context(&session, "module typing;\n\nimport outer::inn\n", "import outer::inn");
	test::eq(ctx.scope, CompletionContextKind.IMPORT);

	String[] offered = test_support::import_labels(&ctx);
	test::@check(test_support::has(offered, "outer::inner"), "the nested module is missing: %s", offered);
	test::@check(test_support::has(offered, "outer::inner::deep"), "the deeper module is missing: %s", offered);
	test::@check(
		!test_support::has(offered, "outer"),
		"the parent module is not a match for 'outer::inn': %s",
		offered
	);
}

<*
 The whole path is typed, so only what follows the last "::" may be
 inserted: a client replaces the word under the cursor, and "::" does not
 belong to a word.
*>
fn void import_completion_inserts_only_the_untyped_tail() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	Context ctx = test_support::import_context(
		&session,
		"module typing;\n\nimport outer::inner::\n",
		"import outer::inner::"
	);

	List{CompletionItem} items;
	items.tinit();
	provide_imports(&ctx, &items);

	test::eq(items.len(), 1);
	test::eq(items[0].label, "outer::inner::deep");
	test::eq(items[0].insert_text, "deep");
	test::eq(items[0].filter_text, "deep");

	// With nothing typed after the keyword there is no tail to strip.
	Context bare = test_support::import_context(&session, "module typing;\n\nimport \n", "import ");
	List{CompletionItem} all;
	all.tinit();
	provide_imports(&bare, &all);

	foreach (CompletionItem item : all) {
		if (item.label == "outer::inner::deep") test::eq(item.insert_text, "outer::inner::deep");
	}
}

<*
 Module names belong on an import line and nowhere else.

 The parser hands the line under a finished `import` back as that same
 IMPORT_DECL, and a completion request from past the last token resolves
 to no node at all, so neither answer can decide this on its own.
*>
fn void import_completion_only_fires_on_an_import_line() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	// The line under a finished import.
	Context after = test_support::import_context(&session, "module typing;\n\nimport outer;\nout\n", "\nout");
	test::ne(after.scope, CompletionContextKind.IMPORT);
	test::eq(test_support::import_labels(&after).len, 0);

	// A statement inside a function body.
	Context body = test_support::import_context(
		&session,
		"module typing;\n\nimport outer;\n\nfn void go()\n{\n\tout\n}\n",
		"\tout"
	);
	test::ne(body.scope, CompletionContextKind.IMPORT);
	test::eq(test_support::import_labels(&body).len, 0);

	// A declaration whose name merely starts with the keyword.
	Context named = test_support::import_context(&session, "module typing;\n\nint imported;\n", "int imported");
	test::ne(named.scope, CompletionContextKind.IMPORT);
	test::eq(test_support::import_labels(&named).len, 0);

	// Past the ';', the name is finished and there is nothing to complete.
	Context done = test_support::import_context(&session, "module typing;\n\nimport outer; \n", "import outer; ");
	test::ne(done.scope, CompletionContextKind.IMPORT);
	test::eq(test_support::import_labels(&done).len, 0);
}

<*
 A file never needs to import the module it declares.
*>
fn void import_completion_skips_the_files_own_module() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	Context ctx = test_support::import_context(&session, "module outer;\n\nimport out\n", "import out");
	test::eq(ctx.scope, CompletionContextKind.IMPORT);

	String[] offered = test_support::import_labels(&ctx);
	test::@check(!test_support::has(offered, "outer"), "the file's own module was offered: %s", offered);
	test::@check(test_support::has(offered, "outer::inner"), "a sibling module is still importable: %s", offered);
}
// ---------------------------------------------------------------------
// Module qualification of the inserted text
// ---------------------------------------------------------------------

<*
 A bare name only resolves inside its own module.

 So picking `from_inner` out of the unqualified list has to insert
 `inner::from_inner`, while `from_outer`, declared in the file's own
 module, stays as it was typed. Only the last segment: C3 resolves the
 shortest unambiguous suffix of an imported path. The label and
 filterText stay bare either way, because the client matches on what the
 user is typing, not on the path.
*>
fn void global_items_qualify_callables_from_other_modules() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file(test_support::OUTER_PATH, test_support::OUTER_SRC);
	session.set_file(test_support::INNER_PATH, test_support::INNER_SRC);

	String src = "module outer;\n\nfn void here()\n{\n\tint local;\n}\n";
	session.set_file(TYPING_PATH, src);
	session.rebuild_index();
	session.analyze(TYPING_PATH);

	Context ctx = test_support::make_completion_context(&session, TYPING_PATH, test_support::loc_of(src, "int local"));

	List{CompletionItem} items;
	items.tinit();
	provide_global(&ctx, &items);

	CompletionItem nested = test_support::item_named(items, "from_inner");
	test::eq(nested.label, "from_inner");
	test::eq(nested.insert_text, "inner::from_inner();");
	test::eq(nested.filter_text, "from_inner");

	CompletionItem own = test_support::item_named(items, "from_outer");
	test::eq(own.label, "from_outer");
	test::eq(own.insert_text, "from_outer();");
}

<*
 A type name is written as it stands, wherever it comes from.
*>
fn void global_items_leave_type_names_unqualified() => @pool() {
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

	List{CompletionItem} items;
	items.tinit();
	provide_global(&ctx, &items);

	CompletionItem foreign = test_support::item_named(items, "Widget");
	test::eq(foreign.label, "Widget");
	test::eq(foreign.insert_text, "Widget");
	test::eq(foreign.filter_text, "Widget");
}

<*
 A path already on the line must not be written twice.

 `outer::` is answered by provide_static_access, which never reaches
 provide_global, so the item it builds carries the bare name.
*>
fn void static_access_items_stay_unqualified() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file(test_support::OUTER_PATH, test_support::OUTER_SRC);

	String src = "module typing;\n\nimport outer;\n\nfn void here()\n{\n\touter::\n}\n";
	session.set_file(TYPING_PATH, src);
	session.rebuild_index();
	session.analyze(TYPING_PATH);

	Context ctx = test_support::make_completion_context(
		&session,
		TYPING_PATH,
		test_support::loc_after(src, "\touter::")
	);

	List{CompletionItem} items;
	items.tinit();
	provide_member_access(&ctx, &items);

	CompletionItem offered = test_support::item_named(items, "from_outer");
	test::eq(offered.label, "from_outer");
	test::eq(offered.insert_text, "from_outer();");
}
<*
 A method is not callable by its bare name.

 `reset` only means something written after a Holder, so offering it in
 the unqualified list gives the user a name that cannot compile - and in
 a real workspace `init` alone matches dozens of unrelated types.
*>
fn void global_items_leave_methods_to_member_access() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String src = METHOD_SRC.treplace("PLACEHOLDER", "int local;");
	session.set_file("/virtual/typed.c3", src);
	session.rebuild_index();
	session.analyze("/virtual/typed.c3");

	Context ctx = test_support::make_completion_context(
		&session,
		"/virtual/typed.c3",
		test_support::loc_of(src, "int local")
	);
	test::eq(ctx.scope, CompletionContextKind.EXECUTION);

	List{CompletionItem} items;
	items.tinit();
	provide_global(&ctx, &items);

	test::@check(test_support::has_label(items, "go"), "a plain function is missing");
	test::@check(test_support::has_label(items, "Holder"), "a type is missing");

	test::@check(!test_support::has_label(items, "reset"), "a method leaked into the bare name list");
	test::@check(!test_support::has_label(items, "get_inner"), "a method leaked into the bare name list");
	test::@check(!test_support::has_label(items, "value"), "a method leaked into the bare name list");
	test::@check(!test_support::has_label(items, "@doubled"), "a macro method leaked into the bare name list");
}

<*
 The same methods are still what member access is for.
*>
fn void member_access_still_offers_methods() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String[] offered = test_support::member_labels_of(&session, METHOD_SRC, "h.");

	test::@check(test_support::has(offered, "reset"), "the method is missing after a '.': %s", offered);
	test::@check(test_support::has(offered, "get_inner"), "the method is missing after a '.': %s", offered);
	test::@check(test_support::has(offered, "id"), "the field is missing after a '.': %s", offered);
}
// ---------------------------------------------------------------------
// Where the snippet cursor goes
// ---------------------------------------------------------------------

<*
 A `$1` placeholder is only worth putting where the caller has something
 to type.

 A call that takes nothing, and a method whose only parameter is its own
 receiver, both leave the cursor after the parentheses instead.
*>
fn void call_cursor_marks_only_a_real_argument() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::CALL_SHAPE_PATH, test_support::CALL_SHAPE_SRC);

	test::eq(test_support::call_cursor_of(&session, "nothing"), "");
	test::eq(test_support::call_cursor_of(&session, "one"), "$1");
	test::eq(test_support::call_cursor_of(&session, "two"), "$1");

	// The receiver is not something the caller writes.
	test::eq(test_support::call_cursor_of(&session, "clear"), "");
	test::eq(test_support::call_cursor_of(&session, "set"), "$1");
}

<*
 The same rule as it reaches the wire, alongside the trailing ';' a void
 call gets because nothing can be done with its result.
*>
fn void insert_text_combines_the_cursor_and_the_semicolon() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::CALL_SHAPE_PATH, test_support::CALL_SHAPE_SRC);

	test::eq(test_support::insert_text_of(&session, "nothing"), "nothing();");
	test::eq(test_support::insert_text_of(&session, "one"), "one($1)");
	test::eq(test_support::insert_text_of(&session, "two"), "two($1)");
	test::eq(test_support::insert_text_of(&session, "clear"), "clear();");
	test::eq(test_support::insert_text_of(&session, "set"), "set($1);");
}