module lsp::analysis @test;

import analyzer::core;
import analyzer::cursor;

import lsp::core;
import lsp::test_support;

import std::collections::list;

// ---------------------------------------------------------------------
// extract_prefix
// ---------------------------------------------------------------------

fn void extract_prefix_bounds() {
	test::eq(extract_prefix("hello", 0), "");
	test::eq(extract_prefix("hello", 99), "");
	test::eq(extract_prefix("", 0), "");
}

fn void extract_prefix_identifiers() {
	test::eq(extract_prefix("hello", 5), "hello");
	test::eq(extract_prefix("hello", 3), "hel");
	test::eq(extract_prefix("foo bar", 7), "bar");
	test::eq(extract_prefix("some_name2", 10), "some_name2");
}

fn void extract_prefix_stops_at_punctuation() {
	test::eq(extract_prefix("foo.", 4), "");
	test::eq(extract_prefix("foo.ba", 6), "ba");
	test::eq(extract_prefix("a::b", 4), "b");
}

<*
 The sigils are pulled into the prefix, since completion has to be able
 to filter macros and compile time names by them.
*>
fn void extract_prefix_keeps_sigils() {
	test::eq(extract_prefix("@macro_name", 11), "@macro_name");
	test::eq(extract_prefix("$Type", 5), "$Type");
	test::eq(extract_prefix("#expr", 5), "#expr");
	test::eq(extract_prefix("@", 1), "@");
}

// ---------------------------------------------------------------------
// is_before
// ---------------------------------------------------------------------

fn void is_before_orders_locations() {
	Location a = { .line = 2, .column = 5 };

	test::@check(is_before({ .line = 1, .column = 99 }, a), "an earlier line always comes first");
	test::@check(!is_before({ .line = 3, .column = 0 }, a), "a later line never comes first");
	test::@check(is_before({ .line = 2, .column = 4 }, a), "same line, earlier column");
	test::@check(!is_before({ .line = 2, .column = 6 }, a), "same line, later column");
	test::@check(!is_before(a, a), "a location does not come before itself");
}

// ---------------------------------------------------------------------
// completion_kind_from_node
// ---------------------------------------------------------------------

<*
 The const versus plain split is the guard for VarDecl.var_flags.is_const.
 Writing `.flags.is_const` instead resolves to the inlined Node.flags and
 compiles clean, so only a behavioural test catches it.
*>
fn void completion_kind_from_node_maps_declarations() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Node* add     = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "add");
	Node* point   = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "Point");
	Node* color   = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "Color");
	Node* limit   = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "LIMIT");
	Node* counter = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "counter");

	test::eq(completion_kind_from_node(add), CompletionItemKind.FUNCTION);
	test::eq(completion_kind_from_node(point), CompletionItemKind.STRUCT);
	test::eq(completion_kind_from_node(color), CompletionItemKind.ENUM);
	test::eq(completion_kind_from_node(limit), CompletionItemKind.CONSTANT);
	test::eq(completion_kind_from_node(counter), CompletionItemKind.VARIABLE);

	StructDecl* decl = point.as(StructDecl);
	test::gt(decl.fields.len, 0);
	test::eq(completion_kind_from_node(decl.fields[0]), CompletionItemKind.FIELD);
}

// ---------------------------------------------------------------------
// find_module_by_identifier
// ---------------------------------------------------------------------

fn void find_module_by_identifier_resolves_paths() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file(test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	session.set_file(test_support::OUTER_PATH, test_support::OUTER_SRC);
	session.set_file(test_support::INNER_PATH, test_support::INNER_SRC);
	session.rebuild_index();

	Module* outer = find_module_by_identifier(&session, "fixture", "outer");
	test::ne(outer, null);
	test::eq(outer.name, "outer");

	// Resolved relative to the module the cursor is in.
	Module* scoped = find_module_by_identifier(&session, "outer", "inner");
	test::ne(scoped, null);
	test::eq(scoped.name, "outer::inner");

	// Same leaf, but with no current module to anchor it.
	Module* suffix = find_module_by_identifier(&session, "", "inner");
	test::ne(suffix, null);
	test::eq(suffix.name, "outer::inner");

	test::eq(find_module_by_identifier(&session, "fixture", "no_such_module"), null);
}

// ---------------------------------------------------------------------
// md
// ---------------------------------------------------------------------

fn void md_wraps_markdown() {
	MarkupContent content = md("# heading");
	test::eq(content.value, "# heading");
	test::eq(content.kind, MarkupKind.MARKDOWN);
}

// ---------------------------------------------------------------------
// format_contract_markdown
// ---------------------------------------------------------------------

<*
 The hover and completion documentation both go through this, and the
 result is embedded straight into a JSON string, so every control
 character has to come back escaped.
*>
fn void format_contract_markdown_renders_the_doc_comment() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Node* add     = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "add");
	FnDecl* decl  = add.as(FnDecl);
	Node* node    = decl.contract.get()!!;
	String markup = format_contract_markdown(node.as(ContractDecl), session.node_signature_text(add));

	test::@check(markup.contains("fn int add(int a, int b)"), "the signature is missing: %s", markup);
	test::@check(markup.contains("Adds two numbers"), "the doc comment is missing: %s", markup);
	test::@check(!markup.contains("\n"), "a raw newline survived escaping: %s", markup);
	test::@check(markup.contains(`\n`), "the newlines were dropped instead of escaped: %s", markup);
}

fn void format_contract_markdown_escapes_the_signature() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Node* add    = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "add");
	FnDecl* decl = add.as(FnDecl);
	Node* node   = decl.contract.get()!!;

	String markup = format_contract_markdown(node.as(ContractDecl), `fn void f(String s = "x")`);

	test::@check(markup.contains(`\"x\"`), "quotes were not escaped: %s", markup);
	test::@check(!markup.contains(`"x"`), "an unescaped quote survived: %s", markup);
}

// ---------------------------------------------------------------------
// Module qualified references
// ---------------------------------------------------------------------

const String QUALIFIED_SRC = `module user;

import fixture;

fn void go()
{
	int a = fixture::add(1, 2);
	int b = add(1, 2);
	fixture::Point p;
	Point q;
}
`;

const String QUALIFIED_PATH = "/virtual/user.c3";

<*
 The qualifier is not part of the name, and it does not live in the same
 place for every node: on IdentExpr.path_expr for a value, on
 TypeExpr.unresolved.path for a type, and behind the callee for a call.
*>
fn void qualified_symbol_at_reads_the_module_prefix() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();
	test_support::setup_qualified(&session, QUALIFIED_PATH, QUALIFIED_SRC);

	QualifiedSymbol call = qualified_symbol_at(
		test_support::node_at(&session, QUALIFIED_PATH, QUALIFIED_SRC, "fixture::add"),
		{ }
	);
	test::eq(call.name, "add");
	test::eq(call.path, "fixture");

	QualifiedSymbol bare = qualified_symbol_at(
		test_support::node_at(&session, QUALIFIED_PATH, QUALIFIED_SRC, "add(1, 2);\n\tfixture::Point"),
		{ }
	);
	test::eq(bare.name, "add");
	test::eq(bare.path, "");

	QualifiedSymbol type = qualified_symbol_at(
		test_support::node_at(&session, QUALIFIED_PATH, QUALIFIED_SRC, "Point p"),
		{ }
	);
	test::eq(type.name, "Point");
	test::eq(type.path, "fixture");

	QualifiedSymbol bare_type = qualified_symbol_at(
		test_support::node_at(&session, QUALIFIED_PATH, QUALIFIED_SRC, "Point q"),
		{ }
	);
	test::eq(bare_type.name, "Point");
	test::eq(bare_type.path, "");

	test::eq(qualified_symbol_at(null, { }).name, "");
}

<*
 A qualified reference means one module's declaration. Without this,
 'string::tformat' offered every tformat in the workspace, and a
 qualified type resolved to nothing at all because cursor::spelling
 flattens it to 'std::io::File', which is not how the index is keyed.
*>
fn void lookup_symbol_narrows_to_the_named_module() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();
	test_support::setup_qualified(&session, QUALIFIED_PATH, QUALIFIED_SRC);

	Module* current = session.module_for_file(QUALIFIED_PATH);

	// Both modules declare 'add', so the bare name stays ambiguous.
	test::eq(lookup_symbol(&session, current, { .name = "add" }).len(), 2);

	List{SymbolRef} narrowed = lookup_symbol(&session, current, { .name = "add", .path = "fixture" });
	test::eq(narrowed.len(), 1);
	test::eq(narrowed[0].module_name, "fixture");

	List{SymbolRef} other = lookup_symbol(&session, current, { .name = "add", .path = "other" });
	test::eq(other.len(), 1);
	test::eq(other[0].module_name, "other");

	// A qualified type resolves the same way.
	test::eq(lookup_symbol(&session, current, { .name = "Point", .path = "fixture" }).len(), 1);

	// A qualifier naming no known module is more likely a gap in the index
	// than a deliberate reference to nothing, so it falls back to the name.
	test::eq(lookup_symbol(&session, current, { .name = "add", .path = "no_such_module" }).len(), 2);

	test::@check(lookup_symbol(&session, current, { .name = "" }).is_empty());
}