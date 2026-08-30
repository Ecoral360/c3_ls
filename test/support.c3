module lsp::test_support;

import analyzer::core;
import analyzer::cursor;

import lsp::analysis;
import lsp::analysis::completion;
import lsp::core;

import std::collections::list;

<*
 A small, stable module used by most of the session level tests.

 Deliberately boring: one file scope variable, one documented function
 with a body local, one struct with fields, one constant and one macro.
 That is enough to reach every branch the building blocks care about.
*>
const String FIXTURE_SRC = `module fixture;

int counter;

<*
 Adds two numbers.
*>
fn int add(int a, int b)
{
	int sum = a + b;
	return sum;
}

struct Point
{
	int x;
	int y;
}

const int LIMIT = 10;

enum Color
{
	RED,
	GREEN,
}

macro @twice(x)
{
	return x * 2;
}
`;

const String FIXTURE_PATH = "/virtual/fixture.c3";

<*
 A second module, so the tests can check cross module behaviour. `add`
 is declared here too, under a different module name.
*>
const String OTHER_SRC = `module other;

fn int add(int a)
{
	return a;
}

int other_global;

struct Widget
{
	int id;
}

fn void hidden() @private
{
	return;
}
`;

const String OTHER_PATH = "/virtual/other.c3";

<*
 Exercises every node kind cursor::spelling knows how to name: declarations
 with their own identifier, expressions that carry a name, and the wrappers
 that answer with what they wrap.
*>
const String SPELLING_SRC = `module spelled;

import std::io;

faultdef OOPS;

attrdef @Marker = { @inline };

std::io::File handle;

struct Holder
{
	int field;
}

<*
 @param [&in] thing : "a thing"
*>
fn void go(int thing) @inline
{
	int cast_value = (int)handle;
	int grouped = (cast_value);
	int number = 42;
	String text = "hi";
	bool flag = true;
	Holder built = { .field = 1 };
	int member = built.field;
	int line = $$LINE;
	go(thing: 1);
	go(...rest);
}
`;

const String SPELLING_PATH = "/virtual/spelled.c3";

<*
 A nested module pair, for the module path lookups.
*>
const String OUTER_SRC = `module outer;

fn void from_outer()
{
	return;
}
`;

const String OUTER_PATH = "/virtual/outer.c3";

const String INNER_SRC = `module outer::inner;

fn void from_inner()
{
	return;
}
`;

const String INNER_PATH = "/virtual/inner.c3";

const String DEEP_SRC = `module outer::inner::deep;

fn void from_deep()
{
	return;
}
`;

const String DEEP_PATH = "/virtual/deep.c3";

<*
 Run the pipeline in the order LspProject.update runs it, for one file.

 @param [&inout] session
*>
fn void load(LspSession* session, String path, String text) {
	session.set_file(path, text);
	session.rebuild_index();
	session.analyze(path);
}

<*
 Top level declaration named `name` in `path`, or null.
*>
fn Node* find_top_level(LspSession* session, String path, String name) => @pool() {
	FileEntry* entry = session.entry(path);
	if (!entry || !entry.sf) return null;

	foreach (Node* node : entry.sf.ast.statements) {
		if (!node) continue;
		String spelling = cursor::spelling(node, tmem) ?? "";
		if (spelling == name) return node;
	}

	return null;
}

<*
 Line/column of the first occurrence of `needle` in `text`.

 Counts newlines by hand rather than going through LineIndex, so the
 position tests are not checking the index against itself.
*>
fn Location loc_of(String text, String needle) {
	sz idx = text.index_of(needle) ?? -1;
	if (idx < 0) return { .line = -1, .column = -1 };

	return offset_to_location(text, idx);
}

<*
 Line/column of the character just past the first occurrence of
 `needle`, which is where a cursor sits after typing it.
*>
fn Location loc_after(String text, String needle) {
	sz idx = text.index_of(needle) ?? -1;
	if (idx < 0) return { .line = -1, .column = -1 };

	return offset_to_location(text, idx + needle.len);
}

fn Location offset_to_location(String text, sz offset) @local {
	int line   = 0;
	int column = 0;

	for (sz i = 0; i < offset && i < text.len; i++) {
		if (text[i] == '\n') {
			line++;
			column = 0;
		} else {
			column++;
		}
	}

	return { .line = line, .column = column };
}

<*
 Build a completion Context the way completion::resolve does.

 Kept in step with src/analysis/completion/completion.c3 on purpose: the
 unit tests are only meaningful if the context they inspect is assembled
 the same way the server assembles it.

 @require session.entry(path) != null : "the file has to be loaded first"
*>
fn Context make_completion_context(LspSession* session, String path, Location loc) {
	Context ctx = {
		.session = session,
		.allocator = tmem,
		.location = loc,
	};

	ctx.file = session.entry(path);
	ctx.sf = ctx.file.sf;
	ctx.mod = session.module_for_file(path);

	ctx.offset = ctx.file.lines.offset_of(loc);
	ctx.prefix = analysis::extract_prefix(ctx.sf.content, ctx.offset).trim();

	ctx.top_level_node = core::top_level_at(ctx.sf, loc);
	ctx.leaf_node = cursor::find_at(ctx.sf.ast.statements.array_view(), { loc, loc });

	completion::context_populate_tokens(&ctx);
	completion::detect_access_context(&ctx);
	ctx.scope = analysis::find_ctx_completion_kind(&ctx, loc);

	return ctx;
}

<*
 The Keywords entry whose name is `name`.

 Lets the keyword tests re-derive what scope a completion label belongs
 to instead of hard coding the tables from src/common/enums.c3.
*>
fn lsp::Keywords keyword_named(String name) {
	foreach (kw : lsp::Keywords::values) {
		if (kw.name == name) return kw;
	}
	unreachable("no keyword named '%s'", name);
}

<*
 True when `items` carries a completion labelled `label`.
*>
fn bool has_label(List{CompletionItem} items, String label) {
	foreach (CompletionItem item : items) {
		if (item.label == label) return true;
	}
	return false;
}
<*
 First top level statement of `kind` in `path`.

 Only scans the file's own statements. Deeper nodes are reached by the
 tests through explicit fields rather than a generic walk, because
 cursor::visit does not descend into every child list yet (CallExpr.args,
 FnDecl.attributes, FaultdefDecl.faults and initializer lists are all
 skipped).
*>
fn Node* top_level_kind(LspSession* session, String path, NodeKind kind) {
	FileEntry* entry = session.entry(path);
	if (!entry || !entry.sf) return null;

	foreach (Node* node : entry.sf.ast.statements) {
		if (node && node.kind == kind) return node;
	}

	return null;
}

<*
 Statement number `index` in the body of the first function in `path`.
*>
fn Node* body_statement(LspSession* session, String path, int index) {
	Node* fn_node = top_level_kind(session, path, FN_DECL);
	if (!fn_node) return null;

	FnDecl* decl = fn_node.as(FnDecl);
	if (!decl.body) return null;

	Node*[] statements = decl.body.as(CompoundStmt).statements;
	if (index >= statements.len) return null;

	return statements[index];
}

<*
 Initializer of a VAR_DECL statement, which is how most of the expression
 cases are reached.
*>
fn Node* init_of(Node* var_node) {
	if (!var_node || var_node.kind != VAR_DECL) return null;
	return var_node.as(VarDecl).init_expr;
}

<*
 Inner expression of an EXPR_STMT statement.
*>
fn Node* expr_of(Node* stmt_node) {
	if (!stmt_node || stmt_node.kind != EXPR_STMT) return null;
	return stmt_node.as(ExprStmt).expr_stmt;
}

<*
 Argument number `index` of a call expression.
*>
fn Node* arg_of(Node* call_node, int index) {
	if (!call_node || call_node.kind != CALL_EXPR) return null;

	CallExpr* call = call_node.as(CallExpr);
	if (index >= call.args.len) return null;

	return call.args[index];
}

<*
 Element number `index` of an initializer list.
*>
fn Node* element_of(Node* list_node, int index) {
	if (!list_node || list_node.kind != INITIALIZER_LIST_EXPR) return null;

	InitializerListExpr* list = list_node.as(InitializerListExpr);
	if (index >= list.exprs.len) return null;

	return list.exprs[index];
}

<*
 Shorthand for the spelling of a node, with the two failure modes spelled
 out so a missing node fails differently from an empty spelling.
*>
fn String spell(Node* node) {
	if (!node) return "<none>";
	return cursor::spelling(node, tmem) ?? "<err>";
}

<*
 Spelling of a variable declaration's initializer, which is how the
 literal cases are reached.
*>
fn String literal_text(Node* var_node) {
	return spell(init_of(var_node));
}

<*
 Number of member completions offered with `typed` written on the
 PLACEHOLDER line of `src`, with the cursor at the end of it.
*>
fn int member_labels(LspSession* session, String src, String typed) {
	String text = src.treplace("PLACEHOLDER", typed);
	load(session, "/virtual/typed.c3", text);

	Context ctx = make_completion_context(session, "/virtual/typed.c3", placeholder_cursor(src, text, typed));

	List{CompletionItem} items;
	items.tinit();
	completion::provide_member_access(&ctx, &items);

	return (int)items.len();
}

<*
 Re-index one file the way LspProject.update does: take the old
 contribution out before set_file resets the arena that holds it.

 @param [&inout] session
*>
fn void reindex(LspSession* session, String path, String text) {
	session.unindex(path);
	session.set_file(path, text);
	session.index(path);
	session.analyze(path);
}

<*
 Labels of the member completions offered with `typed` written on the
 PLACEHOLDER line of `src`, with the cursor at the end of it.
*>
fn String[] member_labels_of(LspSession* session, String src, String typed) {
	String text = src.treplace("PLACEHOLDER", typed);
	load(session, "/virtual/typed.c3", text);

	Context ctx = make_completion_context(session, "/virtual/typed.c3", placeholder_cursor(src, text, typed));

	List{CompletionItem} items;
	items.tinit();
	completion::provide_member_access(&ctx, &items);

	List{String} labels;
	labels.tinit();
	foreach (CompletionItem item : items) labels.push(item.label);

	return labels.to_tarray();
}

fn bool has(String[] labels, String wanted) {
	foreach (String label : labels) {
		if (label == wanted) return true;
	}
	return false;
}

<*
 Node the cursor lands on for the first occurrence of `needle`, the way
 goto definition and hover find it.
*>
fn Node* node_at(LspSession* session, String path, String src, String needle) {
	FileEntry* entry = session.entry(path);
	if (!entry || !entry.sf) return null;

	return cursor::node_entry(&entry.sf.ast, loc_of(src, needle)).node;
}

<*
 Load a file alongside the two fixture modules, so a bare name really is
 ambiguous: both of them declare `add`.

 @param [&inout] session
*>
fn void setup_qualified(LspSession* session, String path, String src) {
	session.set_file(FIXTURE_PATH, FIXTURE_SRC);
	session.set_file(OTHER_PATH, OTHER_SRC);
	session.set_file(path, src);
	session.rebuild_index();
	session.analyze(path);
}

<*
 Cursor at the end of the text that replaced PLACEHOLDER.

 Derived from where the placeholder stood rather than by searching for
 `typed`: a short fragment like "f." also occurs inside "self.".
*>
fn Location placeholder_cursor(String src, String text, String typed) {
	sz placeholder = src.index_of("PLACEHOLDER") ?? 0;
	return offset_to_location(text, placeholder + typed.len);
}

const String MEMBER_PATH = "/virtual/members.c3";

<*
 Load a member-access fixture next to a rival module declaring the same
 names, so a bare lookup is genuinely ambiguous.

 @param [&inout] session
*>
fn void setup_members(LspSession* session, String rival_src, String member_src) {
	session.set_file("/virtual/rival.c3", rival_src);
	session.set_file(MEMBER_PATH, member_src);
	session.rebuild_index();
	session.analyze(MEMBER_PATH);
}

fn TypeContext member_types(LspSession* session) {
	return {
		.session = session,
		.file = session.entry(MEMBER_PATH),
		.mod = session.module_for_file(MEMBER_PATH),
	};
}

const String IMPORT_TYPING_PATH = "/virtual/typing.c3";

<*
 Load the three nested fixture modules plus a file of `src`.

 @param [&inout] session
*>
fn Context import_context(LspSession* session, String src, String needle) {
	session.set_file(OUTER_PATH, OUTER_SRC);
	session.set_file(INNER_PATH, INNER_SRC);
	session.set_file(DEEP_PATH, DEEP_SRC);

	session.set_file(IMPORT_TYPING_PATH, src);
	session.rebuild_index();
	session.analyze(IMPORT_TYPING_PATH);

	return make_completion_context(session, IMPORT_TYPING_PATH, loc_after(src, needle));
}

fn String[] import_labels(Context* ctx) {
	List{CompletionItem} items;
	items.tinit();
	completion::provide_imports(ctx, &items);

	List{String} labels;
	labels.tinit();
	foreach (CompletionItem item : items) labels.push(item.label);

	return labels.to_tarray();
}