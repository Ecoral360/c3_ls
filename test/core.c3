module lsp::core @test;

import analyzer::core;
import analyzer::core::diagnostics;
import analyzer::sema::scope;
import analyzer::cursor;
import analyzer::lexer;

import lsp::test_support;

import std::collections::list;

// ---------------------------------------------------------------------
// LineIndex
// ---------------------------------------------------------------------

const String THREE_LINES = "one\ntwo\nthree";

fn void line_index_counts_lines() {
	LineIndex empty;
	empty.init(mem, "");
	defer empty.free();
	test::eq(empty.line_count(), 1);

	LineIndex single;
	single.init(mem, "only");
	defer single.free();
	test::eq(single.line_count(), 1);

	LineIndex three;
	three.init(mem, THREE_LINES);
	defer three.free();
	test::eq(three.line_count(), 3);

	// A trailing newline opens a final, empty line.
	LineIndex trailing;
	trailing.init(mem, "a\n");
	defer trailing.free();
	test::eq(trailing.line_count(), 2);

	LineIndex crlf;
	crlf.init(mem, "a\r\nbb");
	defer crlf.free();
	test::eq(crlf.line_count(), 2);
}

fn void line_index_line_bounds() {
	LineIndex idx;
	idx.init(mem, THREE_LINES);
	defer idx.free();

	test::eq(idx.line_start(0), 0);
	test::eq(idx.line_start(1), 4);
	test::eq(idx.line_start(2), 8);
	test::eq(idx.line_start(99), THREE_LINES.len);

	test::eq(idx.line_end(0), 3);
	test::eq(idx.line_end(1), 7);
	test::eq(idx.line_end(2), THREE_LINES.len);
	test::eq(idx.line_end(99), THREE_LINES.len);
}

fn void line_index_line_end_strips_crlf() {
	LineIndex idx;
	idx.init(mem, "a\r\nbb");
	defer idx.free();

	test::eq(idx.line_end(0), 1);
	test::eq(idx.line_start(1), 3);
	test::eq(idx.line_end(1), 5);
}

fn void line_index_offset_clamps() {
	LineIndex idx;
	idx.init(mem, THREE_LINES);
	defer idx.free();

	test::eq(idx.offset_of({ .line = -1, .column = 4 }), 0);
	test::eq(idx.offset_of({ .line = 0, .column = -3 }), 0);
	test::eq(idx.offset_of({ .line = 1, .column = 99 }), 7);
	test::eq(idx.offset_of({ .line = 99, .column = 0 }), THREE_LINES.len);
	test::eq(idx.offset_of({ .line = 1, .column = 1 }), 5);
}

fn void line_index_location_of() {
	LineIndex idx;
	idx.init(mem, THREE_LINES);
	defer idx.free();

	test::eq(idx.location_of(0), (Location) { .line = 0, .column = 0 });
	test::eq(idx.location_of(5), (Location) { .line = 1, .column = 1 });
	test::eq(idx.location_of(8), (Location) { .line = 2, .column = 0 });
	test::eq(idx.location_of(9999), idx.location_of(THREE_LINES.len));
}

<*
 Every offset in a LF only file has to survive offset -> location ->
 offset. CRLF is excluded on purpose: the '\n' of a "\r\n" pair sits
 past line_end, so it is not a round trippable position.
*>
fn void line_index_round_trips() {
	String text = "one\ntwo\nthree\n\nfive";

	LineIndex idx;
	idx.init(mem, text);
	defer idx.free();

	for (sz offset = 0; offset <= text.len; offset++) {
		Location loc = idx.location_of(offset);
		sz back      = idx.offset_of(loc);
		test::eq(back, offset);
	}
}

fn void line_index_slice() {
	String text = "hello\nworld";

	LineIndex idx;
	idx.init(mem, text);
	defer idx.free();

	Range whole_first = { .start = { 0, 0 }, .end = { 0, 5 } };
	test::eq(idx.slice(whole_first), "hello");

	Range across = { .start = { 0, 3 }, .end = { 1, 2 } };
	test::eq(idx.slice(across), "lo\nwo");

	// A zero width range is what an empty node reports; it must produce
	// an empty string rather than an out of bounds slice.
	Range empty = { .start = { 1, 2 }, .end = { 1, 2 } };
	test::eq(idx.slice(empty), "");

	Range inverted = { .start = { 1, 4 }, .end = { 0, 1 } };
	test::eq(idx.slice(inverted), "");

	// Both ends clamp into the file, so an over long range is the tail.
	Range past_end = { .start = { 1, 0 }, .end = { 99, 99 } };
	test::eq(idx.slice(past_end), "world");
}

// ---------------------------------------------------------------------
// LspSession lifecycle
// ---------------------------------------------------------------------

<*
 init/free with nothing loaded. This is the pair that leaked the
 registry and lookup context::create builds, so the test allocator
 failing here is the regression signal.
*>
fn void session_init_free_is_clean() {
	LspSession session;
	session.init(mem);
	session.free();
}

fn void session_tracks_a_file() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file(test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	FileEntry* entry = session.entry(test_support::FIXTURE_PATH);
	test::ne(entry, null);
	test::ne(entry.sf, null);
	test::eq(entry.path, test_support::FIXTURE_PATH);
	test::eq(entry.text, test_support::FIXTURE_SRC);
	test::eq(entry.lines.line_count(), test_support::FIXTURE_SRC.count("\n") + 1);

	test::eq(session.entry("/virtual/never-opened.c3"), null);
}

fn void session_remove_file_drops_everything() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	test::eq(session.find_symbols("add").len(), 1);

	session.remove_file(test_support::FIXTURE_PATH);
	test::eq(session.entry(test_support::FIXTURE_PATH), null);

	session.rebuild_index();
	test::@check(session.find_symbols("add").is_empty(), "a removed file leaves no symbols behind");

	// Removing something untracked is a no-op, not a crash.
	session.remove_file("/virtual/never-opened.c3");
}

// ---------------------------------------------------------------------
// Symbol index
// ---------------------------------------------------------------------

fn void session_indexes_top_level_symbols() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	FileEntry* entry = session.entry(test_support::FIXTURE_PATH);

	List{SymbolRef} add_refs = session.find_symbols("add");
	test::eq(add_refs.len(), 1);
	test::eq(add_refs[0].node.kind, NodeKind.FN_DECL);
	test::eq(add_refs[0].module_name, "fixture");
	test::eq(add_refs[0].owner, entry);

	test::eq(session.find_symbols("Point")[0].node.kind, NodeKind.STRUCT_DECL);
	test::eq(session.find_symbols("counter")[0].node.kind, NodeKind.VAR_DECL);
	test::eq(session.find_symbols("LIMIT")[0].node.kind, NodeKind.VAR_DECL);

	// Enums are only reachable by name if cursor::spelling knows about
	// ENUM_DECL; without that they drop out of the index entirely.
	List{SymbolRef} color_refs = session.find_symbols("Color");
	test::@check(!color_refs.is_empty(), "enums are missing from the index");
	test::eq(color_refs[0].node.kind, NodeKind.ENUM_DECL);

	test::eq(session.find_symbols("@twice")[0].node.kind, NodeKind.MACRO_DECL);

	test::@check(session.find_symbols("nope").is_empty());
}

<*
 rebuild_index skips MODULE_DECL, IMPORT_DECL and CONTRACT_DECL, so the
 module's own name must not turn up as a symbol.
*>
fn void session_skips_non_symbol_statements() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	test::@check(session.find_symbols("fixture").is_empty(), "the module declaration is not a symbol");
}

fn void session_find_in_module() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	test::eq(session.find_in_module("fixture", "add").len(), 1);
	test::@check(session.find_in_module("other", "add").is_empty());
	test::eq(qualified_name("a", "b"), "a::b");
}

<*
 mod::create is get-or-create and mod::add_node appends unconditionally,
 so a rebuild that did not clear first would duplicate every node.
*>
fn void session_rebuild_is_idempotent() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	test::eq(session.find_symbols("add").len(), 1);

	session.rebuild_index();
	test::eq(session.find_symbols("add").len(), 1);

	// Re-parsing the same path must replace the file, not add to it.
	session.set_file(test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	session.rebuild_index();
	test::eq(session.find_symbols("add").len(), 1);
}

fn void session_handles_two_modules() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	session.set_file(test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	session.set_file(test_support::OTHER_PATH, test_support::OTHER_SRC);
	session.rebuild_index();

	FileEntry* fixture_entry = session.entry(test_support::FIXTURE_PATH);
	FileEntry* other_entry   = session.entry(test_support::OTHER_PATH);

	test::eq(session.find_symbols("Point").len(), 1);
	test::eq(session.find_symbols("Widget").len(), 1);

	// The same bare name in two modules gives two refs, and find_in_module
	// is what disambiguates them.
	test::eq(session.find_symbols("add").len(), 2);
	test::eq(session.find_in_module("fixture", "add").len(), 1);
	test::eq(session.find_in_module("other", "add").len(), 1);

	Module* fixture_mod = session.module_for_file(test_support::FIXTURE_PATH);
	Module* other_mod   = session.module_for_file(test_support::OTHER_PATH);
	test::ne(fixture_mod, null);
	test::eq(fixture_mod.name, "fixture");
	test::ne(other_mod, null);
	test::eq(other_mod.name, "other");

	Node* widget = test_support::find_top_level(&session, test_support::OTHER_PATH, "Widget");
	test::ne(widget, null);
	test::eq(session.entry_for_node(widget), other_entry);
	test::ne(session.entry_for_node(widget), fixture_entry);
	test::eq(session.entry_for_node(null), null);
	test::eq(session.module_of(widget), other_mod);
	test::eq(session.module_of(null), null);
}

// ---------------------------------------------------------------------
// Source text extraction
// ---------------------------------------------------------------------

fn void session_signature_text_strips_the_body() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Node* add = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "add");
	test::ne(add, null);
	test::eq(session.node_signature_text(add), "fn int add(int a, int b)");

	// A declaration with no body falls back to its whole range.
	Node* point = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "Point");
	test::ne(point, null);
	test::@check(session.node_signature_text(point).starts_with("struct Point"));

	test::eq(session.node_signature_text(null), "");
	test::eq(session.node_source_text(null), "");
}

fn void session_source_text() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	Node* point = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "Point");
	String text = session.node_source_text(point);
	test::@check(text.starts_with("struct Point"), "got '%s'", text);
	test::@check(text.contains("int y"), "the whole declaration should be covered, got '%s'", text);
}

// ---------------------------------------------------------------------
// Position helpers
// ---------------------------------------------------------------------

<*
 top_level_at must report the enclosing declaration, not the innermost
 node. Using cursor::find_at here is what once broke scope detection and
 silently disabled local completion.
*>
fn void session_top_level_at() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	FileEntry* entry = session.entry(test_support::FIXTURE_PATH);

	Node* add = test_support::find_top_level(&session, test_support::FIXTURE_PATH, "add");

	Location in_body = test_support::loc_of(test_support::FIXTURE_SRC, "int sum");
	test::eq(top_level_at(entry.sf, in_body), add);

	Location on_name = test_support::loc_of(test_support::FIXTURE_SRC, "add");
	test::eq(top_level_at(entry.sf, on_name), add);

	// The blank line between declarations belongs to nothing.
	Location gap = test_support::loc_of(test_support::FIXTURE_SRC, "int counter");
	test::eq(top_level_at(entry.sf, { .line = gap.line - 1, .column = 0 }), null);

	test::eq(top_level_at(null, in_body), null);
}

fn void session_token_at() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	FileEntry* entry = session.entry(test_support::FIXTURE_PATH);

	Token found;
	Location on_add = test_support::loc_of(test_support::FIXTURE_SRC, "add");
	test::@check(token_at(entry.sf, on_add, &found), "no token at the 'add' identifier");
	test::eq(found.kind, TokenKind.IDENT);
	test::eq(found.value, "add");

	Location past_eof = { .line = 9999, .column = 0 };
	test::@check(!token_at(entry.sf, past_eof, &found));
	test::@check(!token_at(null, on_add, &found));
}

// ---------------------------------------------------------------------
// Scopes
// ---------------------------------------------------------------------

fn void session_analyze_keeps_the_scope_tree() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	FileEntry* entry = session.entry(test_support::FIXTURE_PATH);

	test::ne(entry.root_rt_scope, null);
	test::eq(entry.root_rt_scope.parent, null);

	Location in_body = test_support::loc_of(test_support::FIXTURE_SRC, "int sum");
	Scope* leaf      = find_deepest_scope(entry.root_rt_scope, in_body);
	test::ne(leaf, null);
	test::ne(leaf, entry.root_rt_scope);
	test::ne(leaf.parent, null);

	Location at_top = { .line = 0, .column = 0 };
	test::eq(find_deepest_scope(entry.root_rt_scope, at_top), entry.root_rt_scope);

	test::eq(find_deepest_scope(null, in_body), null);
}

<*
 Pins the is_local semantics on VisibleVar: the analyzer's
 VarDecl.var_kind == VAR_LOCAL means the `@local` visibility attribute,
 not "declared in a nested scope", so the answer has to come from the
 owning scope's parent chain.
*>
fn void session_collect_visible() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);
	FileEntry* entry = session.entry(test_support::FIXTURE_PATH);

	Location in_body = test_support::loc_of(test_support::FIXTURE_SRC, "return sum");
	Scope* leaf      = find_deepest_scope(entry.root_rt_scope, in_body);
	test::ne(leaf, null);

	List{VisibleVar} visible = collect_visible(tmem, leaf);

	bool saw_sum     = false;
	bool saw_param   = false;
	bool saw_counter = false;

	foreach (VisibleVar visible_var : visible) {
		if (!visible_var.info) continue;

		String name = visible_var.info.name;
		if (name == "sum") {
			saw_sum = true;
			test::@check(visible_var.is_local, "a body local must be reported as local");
		} else if (name == "a") {
			saw_param = true;
			test::@check(visible_var.is_local, "a parameter must be reported as local");
		} else if (name == "counter") {
			saw_counter = true;
			test::@check(!visible_var.is_local, "a file scope variable must not be reported as local");
		}
	}

	test::@check(saw_sum, "'sum' was not visible from inside the body");
	test::@check(saw_param, "'a' was not visible from inside the body");
	test::@check(saw_counter, "'counter' was not visible from inside the body");
}

// ---------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------

const String BROKEN_IMPORT_SRC = `module broken;

import does_not_exist;
`;

const String BROKEN_PATH = "/virtual/broken.c3";

fn void session_collects_sema_diagnostics() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, BROKEN_PATH, BROKEN_IMPORT_SRC);

	List{SessionDiagnostic} diags = session.diagnostics_for(BROKEN_PATH);
	test::@check(!diags.is_empty(), "an unresolvable import must report a diagnostic");

	bool found = false;
	foreach (SessionDiagnostic diag : diags) {
		if (diag.message.contains("does_not_exist")) {
			found = true;
			test::eq(diag.level, DiagnosticLevel.ERROR);
		}
	}
	test::@check(found, "no diagnostic named the missing module");

	test::@check(session.diagnostics_for("/virtual/never-opened.c3").is_empty());
}

<*
 The 0 -> N -> 0 round trip the publish layer depends on: a clean file
 has to end up with an empty list, not a stale one.
*>
fn void session_clear_diagnostics() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, BROKEN_PATH, BROKEN_IMPORT_SRC);
	test::@check(!session.diagnostics_for(BROKEN_PATH).is_empty());

	session.clear_diagnostics();
	test::@check(session.diagnostics_for(BROKEN_PATH).is_empty(), "clear_diagnostics left something behind");

	// Re-run the pipeline on a fixed version of the same file.
	test_support::load(&session, BROKEN_PATH, "module broken;\n");
	test::@check(session.diagnostics_for(BROKEN_PATH).is_empty(), "the fixed file still reports diagnostics");
}

fn void session_clean_file_has_no_diagnostics() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	test::@check(session.diagnostics_for(test_support::FIXTURE_PATH).is_empty(), "the fixture is supposed to be clean");
}

<*
 Guards the ordering in set_file: the SourceFile has to exist before
 lexer::tokenize runs, or the callback drops every lexer diagnostic on
 the floor because it arrives with a null file.
*>
fn void session_collects_lexer_diagnostics() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, "/virtual/lex_error.c3", "module broken;\n\nint x = 1 \\ 2;\n");

	List{SessionDiagnostic} diags = session.diagnostics_for("/virtual/lex_error.c3");
	test::@check(!diags.is_empty(), "a lexer error never reached the session");
	test::eq(diags[0].level, DiagnosticLevel.ERROR);
}
// ---------------------------------------------------------------------
// cursor::spelling
// ---------------------------------------------------------------------

<*
 Every named declaration answers with its own identifier. A declaration
 with no name of its own, such as a contract or a faultdef group, answers
 with the empty string rather than an error.
*>
fn void spelling_names_declarations() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::SPELLING_PATH, test_support::SPELLING_SRC);
	String path = test_support::SPELLING_PATH;

	test::eq(test_support::spell(test_support::top_level_kind(&session, path, MODULE_DECL)), "spelled");
	test::eq(test_support::spell(test_support::top_level_kind(&session, path, IMPORT_DECL)), "std::io");
	test::eq(test_support::spell(test_support::top_level_kind(&session, path, ATTRDEF_DECL)), "@Marker");
	test::eq(test_support::spell(test_support::top_level_kind(&session, path, STRUCT_DECL)), "Holder");
	test::eq(test_support::spell(test_support::top_level_kind(&session, path, FN_DECL)), "go");
	test::eq(test_support::spell(test_support::top_level_kind(&session, path, VAR_DECL)), "handle");

	// A faultdef groups its faults and has no name of its own; the fault
	// inside it does.
	Node* faultdef_node = test_support::top_level_kind(&session, path, FAULTDEF_DECL);
	test::eq(test_support::spell(faultdef_node), "");
	test::eq(test_support::spell(faultdef_node.as(FaultdefDecl).faults[0]), "OOPS");

	// Same for a contract and its parameters.
	Node* contract_node = test_support::top_level_kind(&session, path, CONTRACT_DECL);
	test::eq(test_support::spell(contract_node), "");
	test::eq(test_support::spell(contract_node.as(ContractDecl).params[0]), "thing");

	Node* fn_node = test_support::top_level_kind(&session, path, FN_DECL);
	test::eq(test_support::spell(fn_node.as(FnDecl).attributes[0]), "@inline");
}

<*
 Expressions that carry or point at a name resolve to that name, and the
 transparent wrappers resolve to whatever they wrap.
*>
fn void spelling_resolves_expressions() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::SPELLING_PATH, test_support::SPELLING_SRC);
	String path = test_support::SPELLING_PATH;

	// A module declaration spells as its path expression.
	Node* module_node = test_support::top_level_kind(&session, path, MODULE_DECL);
	test::eq(test_support::spell(module_node.as(ModuleDecl).path), "spelled");

	// A prefixed type keeps its module path.
	Node* handle = test_support::top_level_kind(&session, path, VAR_DECL);
	test::eq(test_support::spell(handle.as(VarDecl).type), "std::io::File");

	// '(int)handle' spells as the value being cast, '(cast_value)' as its
	// contents.
	test::eq(test_support::spell(test_support::init_of(test_support::body_statement(&session, path, 0))), "handle");
	test::eq(test_support::spell(test_support::init_of(test_support::body_statement(&session, path, 1))), "cast_value");

	// '{ .field = 1 }' and 'built.field' both spell as the member.
	Node* list       = test_support::init_of(test_support::body_statement(&session, path, 5));
	Node* designated = test_support::element_of(list, 0);
	test::eq(test_support::spell(designated), "field");
	test::eq(test_support::spell(designated.as(DesignatedInitializerExpr).path), "field");
	test::eq(test_support::spell(test_support::init_of(test_support::body_statement(&session, path, 6))), "field");

	test::eq(test_support::spell(test_support::init_of(test_support::body_statement(&session, path, 7))), "LINE");

	// 'go(thing: 1)' and 'go(...rest)': the call spells as its callee, the
	// arguments as the name each one carries.
	Node* named_call = test_support::expr_of(test_support::body_statement(&session, path, 8));
	test::eq(test_support::spell(named_call), "go");
	test::eq(test_support::spell(test_support::arg_of(named_call, 0)), "thing");

	Node* splat_call = test_support::expr_of(test_support::body_statement(&session, path, 9));
	test::eq(test_support::spell(test_support::arg_of(splat_call, 0)), "rest");
}

fn void spelling_renders_literals() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String src = "module lit;\n\nint number = 42;\nString text = \"hi\";\nbool flag = true;\nvoid* nothing = null;\n";
	test_support::load(&session, "/virtual/lit.c3", src);

	Node* number  = test_support::find_top_level(&session, "/virtual/lit.c3", "number");
	Node* text    = test_support::find_top_level(&session, "/virtual/lit.c3", "text");
	Node* flag    = test_support::find_top_level(&session, "/virtual/lit.c3", "flag");
	Node* nothing = test_support::find_top_level(&session, "/virtual/lit.c3", "nothing");

	test::eq(test_support::literal_text(number), "42");
	test::eq(test_support::literal_text(text), "hi");
	test::eq(test_support::literal_text(flag), "true");
	test::eq(test_support::literal_text(nothing), "null");
}

<*
 Statements have no spelling, and a null node is answered rather than
 dereferenced. The null case matters because the wrapper cases recurse
 into fields that are routinely null on a half typed line.
*>
fn void spelling_has_no_answer_for_unnamed_nodes() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, test_support::SPELLING_PATH, test_support::SPELLING_SRC);
	String path = test_support::SPELLING_PATH;

	Node* fn_node = test_support::top_level_kind(&session, path, FN_DECL);
	test::eq(test_support::spell(fn_node.as(FnDecl).body), "");
	test::eq(test_support::spell(test_support::body_statement(&session, path, 8)), "");

	test::eq(cursor::spelling(null, tmem) ?? "<err>", "");
}
// ---------------------------------------------------------------------
// LspProject queueing
// ---------------------------------------------------------------------

const DocumentUri PROJECT_URI = (DocumentUri)"file:///virtual/queued.c3";
const String PROJECT_PATH     = "/virtual/queued.c3";

const String PROJECT_V1 = "module queued;\n\nfn int one()\n{\n\treturn 1;\n}\n";
const String PROJECT_V2 = "module queued;\n\nfn int two()\n{\n\treturn 2;\n}\n";

<*
 A queued path has to outlive the dispatch that queued it.

 change_file used to queue the path out of a tmem parsed Uri, but
 server::dispatch is itself @pool, so that memory was released before
 update drained the queue. The re-parse then landed under a garbage key,
 leaving the original entry untouched, which is why goto definition and
 hover kept answering from the version before the edit.

 Pointer identity is the assertion rather than string equality: a
 dangling path still compares equal until something else reuses the
 arena, so comparing contents would not catch the regression.
*>
fn void project_queues_owned_paths() => @pool() {
	LspProject project;
	project.init(mem);
	defer project.free();

	project.open_file({ .uri = PROJECT_URI, .text = PROJECT_V1, .version = 1 });

	test::eq(project.process_queue.len(), 1);
	LspFile* file = project.files.get(PROJECT_PATH)!!;
	test::eq(project.process_queue[0].path.ptr, file.uri.path.ptr);

	project.update();

	project.change_file(
		{
			.document = { .uri = PROJECT_URI, .version = 2 },
			.content_changes = { { .text = PROJECT_V2 } },
		}
	);

	test::eq(project.process_queue.len(), 1);
	test::eq(project.process_queue[0].path.ptr, file.uri.path.ptr);
}

<*
 The edit has to replace the file rather than land beside it: one tracked
 entry, holding the new text, with the old symbol gone and the new one
 indexed.
*>
fn void project_change_file_replaces_the_parse() => @pool() {
	LspProject project;
	project.init(mem);
	defer project.free();

	project.open_file({ .uri = PROJECT_URI, .text = PROJECT_V1, .version = 1 });
	project.update();

	test::eq(project.session.entries.len(), 1);
	test::eq(project.session.find_symbols("one").len(), 1);
	test::@check(project.session.find_symbols("two").is_empty());

	// The queueing happens in its own pool, the way dispatch does it, so a
	// path pointing at temporary memory would already be released here.
	@pool() {
		project.change_file(
			{
				.document = { .uri = PROJECT_URI, .version = 2 },
				.content_changes = { { .text = PROJECT_V2 } },
			}
		);
	};

	project.update();

	test::eq(project.session.entries.len(), 1);
	test::@check(project.session.find_symbols("one").is_empty(), "the old declaration is still indexed");
	test::eq(project.session.find_symbols("two").len(), 1);

	FileEntry* entry = project.session.entry(PROJECT_PATH);
	test::ne(entry, null);
	test::eq(entry.text, PROJECT_V2);
}
<*
 A cursor is not a character: it sits between them, and a completion
 request lands one past what was just typed, which Range.contains rejects
 because its end is exclusive. Trailing space widens the gap further -
 "import " parses to a node covering only the keyword.

 Both used to leave the declaration being written unmatched, so the
 completion context fell back to GLOBAL and offered types instead of
 module paths.
*>
fn void session_top_level_at_accepts_a_cursor_past_the_end() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	String src = "module typed;\n\nimport out\n\nint after;\n";
	session.set_file("/virtual/typed.c3", src);
	FileEntry* entry = session.entry("/virtual/typed.c3");

	Node* import_node;
	Node* after_node;
	foreach (Node* node : entry.sf.ast.statements) {
		if (!node) continue;
		if (node.kind == IMPORT_DECL) import_node = node;
		if (node.kind == VAR_DECL) after_node = node;
	}
	test::ne(import_node, null);
	test::ne(after_node, null);

	// One past the last character of "import out".
	test::eq(top_level_at(entry.sf, { .line = 2, .column = 10 }), import_node);

	// And past trailing space, where the node's own range stops earlier.
	String spaced = "module typed;\n\nimport \n\nint after;\n";
	session.set_file("/virtual/spaced.c3", spaced);
	FileEntry* spaced_entry = session.entry("/virtual/spaced.c3");

	Node* spaced_import;
	foreach (Node* node : spaced_entry.sf.ast.statements) {
		if (node && node.kind == IMPORT_DECL) spaced_import = node;
	}
	test::ne(spaced_import, null);
	test::@check(spaced_import.range.end.column < 7, "the node should stop before the trailing space");
	test::eq(top_level_at(spaced_entry.sf, { .line = 2, .column = 7 }), spaced_import);

	// A blank line still belongs to nothing: the fallback is same line only.
	test::eq(top_level_at(entry.sf, { .line = 3, .column = 0 }), null);
}
// ---------------------------------------------------------------------
// Incremental indexing
// ---------------------------------------------------------------------

const String INC_A_PATH = "/virtual/inc_a.c3";
const String INC_B_PATH = "/virtual/inc_b.c3";

const String INC_A = "module inc;\n\nfn int alpha()\n{\n\treturn 1;\n}\n";
const String INC_B = "module inc;\n\nfn int beta()\n{\n\treturn 2;\n}\n";

<*
 Editing one file must not disturb another's symbols, which is the whole
 point of unindexing per file instead of rebuilding the workspace.
*>
fn void incremental_edit_leaves_other_files_alone() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, INC_A_PATH, INC_A);
	test_support::reindex(&session, INC_B_PATH, INC_B);

	test::eq(session.find_symbols("alpha").len(), 1);
	test::eq(session.find_symbols("beta").len(), 1);

	test_support::reindex(&session, INC_A_PATH, "module inc;\n\nfn int gamma()\n{\n\treturn 3;\n}\n");

	test::@check(session.find_symbols("alpha").is_empty(), "the renamed declaration kept its old name");
	test::eq(session.find_symbols("gamma").len(), 1);
	test::@check(!session.find_symbols("beta").is_empty(), "the other file's symbol was collateral damage");
	test::eq(session.find_symbols("beta")[0].owner, session.entry(INC_B_PATH));
}

<*
 Two files declaring into one module: the module's node list has to end up
 holding exactly the surviving nodes of both.
*>
fn void incremental_edit_keeps_the_shared_module_intact() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, INC_A_PATH, INC_A);
	test_support::reindex(&session, INC_B_PATH, INC_B);

	Module* shared = session.ctx.modules.get("inc")!!;
	sz before      = shared.nodes.len();

	test_support::reindex(&session, INC_A_PATH, INC_A);

	Module* after = session.ctx.modules.get("inc")!!;
	test::eq(after.nodes.len(), before);
	test::eq(session.find_in_module("inc", "alpha").len(), 1);
	test::eq(session.find_in_module("inc", "beta").len(), 1);

	// Every node still in the module has to be reachable by id, and the
	// map must not have kept the ids of the nodes that were replaced.
	test::eq(after.node_map.len(), after.nodes.len());
	foreach (Node* node : after.nodes) {
		test::@check(after.node_map.has_key(node.id), "a module node is missing from node_map");
	}
}

<*
 A stale Node* is the failure this design can produce and the old full
 rebuild could not: set_file frees the arena the previous AST lived in.
 Reading the source text back through the ref is what catches it.
*>
fn void incremental_refs_point_at_the_current_parse() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, INC_A_PATH, INC_A);

	test_support::reindex(&session, INC_A_PATH, "module inc;\n\nfn int alpha()\n{\n\treturn 42;\n}\n");

	List{SymbolRef} refs = session.find_symbols("alpha");
	test::eq(refs.len(), 1);

	String text = session.node_source_text(refs[0].node);
	test::@check(text.contains("return 42;"), "the ref still points at the old parse: '%s'", text);
	test::eq(session.node_signature_text(refs[0].node), "fn int alpha()");

	test::eq(session.entry_for_node(refs[0].node), session.entry(INC_A_PATH));
	test::eq(session.module_of(refs[0].node), session.ctx.modules.get("inc")!!);
}

<*
 A module with no files left should stop being offered by import
 completion.
*>
fn void incremental_removing_the_last_file_drops_the_module() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, INC_A_PATH, INC_A);
	test_support::reindex(&session, INC_B_PATH, INC_B);
	test::@check(session.ctx.modules.has_key("inc"));

	session.remove_file(INC_A_PATH);
	test::@check(session.ctx.modules.has_key("inc"), "the module still has a file in it");
	test::@check(session.find_symbols("alpha").is_empty());

	session.remove_file(INC_B_PATH);
	test::@check(!session.ctx.modules.has_key("inc"), "an empty module is still being offered");
	test::@check(session.find_symbols("beta").is_empty());
	test::eq(session.node_owner.len(), 0);
}

<*
 The strongest check available: after a series of edits the incremental
 index has to be indistinguishable from one derived in a single pass.
*>
fn void incremental_index_matches_a_full_rebuild() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, INC_A_PATH, INC_A);
	test_support::reindex(&session, INC_B_PATH, INC_B);
	test_support::reindex(&session, test_support::FIXTURE_PATH, test_support::FIXTURE_SRC);

	test_support::reindex(
		&session,
		INC_A_PATH,
		"module inc;\n\nfn int alpha(int n)\n{\n\treturn n;\n}\n\nstruct Extra\n{\n\tint v;\n}\n"
	);
	test_support::reindex(&session, INC_B_PATH, "module other_inc;\n\nfn int beta()\n{\n\treturn 2;\n}\n");

	sz modules = session.ctx.modules.len();
	sz names   = session.by_name.len();
	sz owners  = session.node_owner.len();

	session.rebuild_index();

	test::eq(session.ctx.modules.len(), modules);
	test::eq(session.by_name.len(), names);
	test::eq(session.node_owner.len(), owners);

	// And the moved declaration followed its file into the new module.
	test::eq(session.find_in_module("other_inc", "beta").len(), 1);
	test::@check(session.find_in_module("inc", "beta").is_empty(), "the old module kept a moved symbol");
	test::eq(session.find_symbols("Extra").len(), 1);
	test::eq(session.find_symbols("add").len(), 1);
}