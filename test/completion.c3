module lsp::analysis::completion @test;

import analyzer::core;
import analyzer::lexer;

import lsp::core;
import lsp::test_support;

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
	test::eq(on_import.scope, ScopeKind.IMPORT);

	Context at_global = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_of(SCOPE_SRC, "at_top")
	);
	test::eq(at_global.scope, ScopeKind.GLOBAL);

	Context in_struct = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_of(SCOPE_SRC, "int field")
	);
	test::eq(in_struct.scope, ScopeKind.CONTAINER);

	Context in_params = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_after(SCOPE_SRC, "work(")
	);
	test::eq(in_params.scope, ScopeKind.PARAMETER);

	Context in_body = test_support::make_completion_context(
		&session,
		SCOPE_PATH,
		test_support::loc_of(SCOPE_SRC, "int local")
	);
	test::eq(in_body.scope, ScopeKind.EXECUTION);
}

fn void find_scope_defaults_to_global_outside_declarations() {
	Context ctx;
	test::eq(analysis::find_scope(&ctx, { .line = 0, .column = 0 }), ScopeKind.GLOBAL);
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
	test::eq(ctx.scope, ScopeKind.EXECUTION);

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
	test::eq(ctx.scope, ScopeKind.GLOBAL);

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
	Context ctx = { .scope = ScopeKind.GLOBAL, .access = LspAccessKind.NONE };

	List{CompletionItem} items;
	items.tinit();
	provide_keywords(&ctx, &items);

	test::@check(!items.is_empty());
	foreach (CompletionItem item : items) {
		test::eq(item.kind, CompletionItemKind.KEYWORD);
		test::@check(test_support::keyword_named(item.label)
			.is_top_level(), "'%s' is not legal at file scope", item.label);
	}

	Context body = { .scope = ScopeKind.EXECUTION, .access = LspAccessKind.NONE };
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
	Context ctx = { .scope = ScopeKind.GLOBAL, .access = LspAccessKind.NONE, .prefix = "st" };

	List{CompletionItem} items;
	items.tinit();
	provide_keywords(&ctx, &items);

	test::@check(!items.is_empty());
	foreach (CompletionItem item : items) {
		test::@check(item.label.starts_with("st"), "'%s' does not match the prefix", item.label);
	}
}

fn void provide_keywords_stays_out_of_member_access() {
	Context ctx = { .scope = ScopeKind.EXECUTION, .access = LspAccessKind.INSTANCE };

	List{CompletionItem} items;
	items.tinit();
	provide_keywords(&ctx, &items);

	test::@check(items.is_empty(), "keywords must not be offered after a '.'");
}