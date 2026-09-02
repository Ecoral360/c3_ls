module lsp::core;

import std::collections::list;
import std::collections::map;
import std::io;

import analyzer::core;
import analyzer::core::context;
import analyzer::core::diagnostics;
import analyzer::core::source_file;
import analyzer::core::mod;
import analyzer::cursor;
import analyzer::lexer;
import analyzer::parser;
import analyzer::sema;
import analyzer::sema::lookup;
import analyzer::sema::registry;
import analyzer::sema::scope;

const sz ARENA_PAGE_SIZE = 64 * 1024;

<*
 One diagnostic reported by the analyzer.

 The analyzer no longer stores diagnostics anywhere; it pushes them
 through a single global callback. We collect them here, keyed by file
 path, so the publish handler can drain them per file.
*>
struct SessionDiagnostic {
	Range range;
	DiagnosticLevel level;
	String message;
}

<*
 A symbol the LSP can look up by name.

 Replaces the analyzer's old SymbolEntry / Module.symbols, which the new
 version does not have. The registry only indexes by fully qualified
 name, which is not enough for "find this bare identifier" queries.
*>
struct SymbolRef {
	Node* node;
	String module_name;
	FileEntry* owner;
	<*
	 True for a declaration with an associated type, so completion can
	 keep methods out of the bare name list. Recorded here because index
	 works it out anyway, and re-deriving it per candidate would mean
	 walking a TypeExpr for every symbol in the workspace.
	*>
	bool is_method;
}

<*
 Everything we keep for one tracked file.

 Each file owns an arena holding its text, tokens, AST and sema scopes,
 so re-parsing a single file is a reset of that arena and nothing else.
*>
struct FileEntry {
	String path;
	DynamicArenaAllocator arena;
	SourceFile* sf;
	Scope* root_rt_scope;
	Scope* root_ct_scope;
	LineIndex lines;
	String text;

	<*
	 What this file put into the shared index, so it can be taken back out
	 without re-deriving the whole workspace.

	 Session allocated on purpose. Unindexing happens before set_file
	 resets the arena, but these lists have to outlive individual edits and
	 must never point into the per file arena they describe.
	*>
	List{String} index_modules;
	List{ulong} index_node_ids;
	List{IndexedName} index_names;
}

<*
 The two keys one symbol occupies: its bare name in `by_name`, and its
 module qualified name in `by_module`.
*>
struct IndexedName {
	String name;
	String qualified;
	<*
	 Bare name of the type a method is bound to, or empty for anything
	 **that is not a method** -> this is the key it occupies in `by_method`.
	*>
	String method_of;
}

<*
 Owns the AnalyzerContext plus the per-file state, symbol index and
 diagnostics that the analyzer stopped tracking.
*>
struct LspSession {
	AnalyzerContext* ctx;
	Allocator allocator;

	HashMap{String, FileEntry*} entries;

	DynamicArenaAllocator index_arena;
	HashMap{String, List{SymbolRef}} by_name;
	HashMap{String, List{SymbolRef}} by_module;
	<*
	 Methods keyed by the bare name of the type they are bound to.

	 The analyzer has no method registry, and a method is not reachable
	 through its module, so this is the only way to answer "what can be
	 called on a value of this type"
	*>
	HashMap{String, List{SymbolRef}} by_method;
	HashMap{ulong, FileEntry*} node_owner;

	DynamicArenaAllocator diag_arena;
	HashMap{String, List{SessionDiagnostic}} diags;
}

// The diagnostics callback takes no user data, so the active session has
// to be reachable from a global.
LspSession* active_session @local;

<*
 @param [&inout] self
*>
fn void LspSession.init(&self, Allocator allocator) {
	self.allocator = allocator;
	self.ctx = context::new(allocator);

	// context::new builds a registry and a lookup from `allocator`, but
	// rebuild_index replaces both with index arena copies on the first
	// update. Drop the originals now so they are not stranded; nothing
	// between here and that first rebuild reads either one.
	registry::free(allocator, self.ctx.registry);
	lookup::free(self.ctx.lookup);
	self.ctx.registry = null;
	self.ctx.lookup = null;

	self.entries.init(allocator, 64);

	self.index_arena.init(allocator, ARENA_PAGE_SIZE);
	self.by_name.init(allocator, 256);
	self.by_module.init(allocator, 256);
	self.by_method.init(allocator, 256);
	self.node_owner.init(allocator, 256);

	self.diag_arena.init(allocator, ARENA_PAGE_SIZE);
	self.diags.init(allocator, 32);

	active_session = self;
	diagnostics::callback = &on_diagnostic;
}

<*
 @param [&inout] self
*>
fn void LspSession.free(&self) {
	if (active_session == self) {
		active_session = null;
		diagnostics::callback = null;
	}

	self.entries.@each(; String path, FileEntry* entry) {
		entry.free_index_records(self.allocator);
		entry.arena.free();
		entry.path.free(self.allocator);
		alloc::free(self.allocator, entry);
	};
	self.entries.free();

	self.by_name.@each(; String name, List{SymbolRef} refs) {
		refs.free();
	};
	self.by_name.free();

	self.by_module.@each(; String name, List{SymbolRef} refs) {
		refs.free();
	};
	self.by_module.free();

	self.by_method.@each(; String name, List{SymbolRef} refs) {
		refs.free();
	};
	self.by_method.free();
	self.node_owner.free();
	self.index_arena.free();

	self.diags.free();
	self.diag_arena.free();

	// Whatever rebuild_index last installed came from the index arena that
	// was just released, so context::free must not try to reclaim it.
	self.ctx.registry = null;
	self.ctx.lookup = null;

	context::free(self.ctx);
}

fn void on_diagnostic(SourceFile* file, Range range, DiagnosticLevel level, String message) @local {
	LspSession* self = active_session;
	if (!self || !file) return;

	// The message was formatted with whichever arena was active during
	// parse/sema, so it has to be copied somewhere with its own lifetime.
	Allocator alloc = &self.diag_arena;
	String path     = file.path.copy(alloc);

	SessionDiagnostic diag = {
		.range = range,
		.level = level,
		.message = message.copy(alloc),
	};

	if (try List{SessionDiagnostic}* existing = self.diags.get_ref(path)) {
		existing.push(diag);
		return;
	}

	List{SessionDiagnostic} fresh;
	fresh.init(alloc, 4);
	fresh.push(diag);
	self.diags.set(path, fresh);
}

<*
 Drop every collected diagnostic. Called once per update batch, before
 anything is re-parsed.

 @param [&inout] self
*>
fn void LspSession.clear_diagnostics(&self) {
	self.diags.clear();
	self.diag_arena.reset();
}

fn List{SessionDiagnostic} LspSession.diagnostics_for(&self, String path) {
	return self.diags.get(path) ?? (List{SessionDiagnostic}) { };
}

<*
 Lex and parse one file into its own arena.

 Replaces the analyzer's removed `Workspace.reset_source_file`. Note the
 allocator swap: every analyzer entry point allocates from
 `ctx.allocator`, including the token text copies made by the parser, so
 pointing it at the file arena is what gives the file's data its
 lifetime.

 @param [&inout] self
*>
fn void LspSession.set_file(&self, String path, String text) {
	FileEntry* entry = self.entries.get(path) ?? null;

	if (entry) {
		// Both the SourceFile and everything it points at live in the
		// arena we are about to reset.
		(void)self.ctx.files.remove(path);
		entry.arena.reset();
	} else {
		entry = alloc::new(self.allocator, FileEntry);
		entry.path = path.copy(self.allocator);
		entry.arena.init(self.allocator, ARENA_PAGE_SIZE);
		entry.index_modules.init(self.allocator, 2);
		entry.index_node_ids.init(self.allocator, 16);
		entry.index_names.init(self.allocator, 16);
		self.entries.set(entry.path, entry);
	}

	entry.sf = null;
	entry.root_rt_scope = null;
	entry.root_ct_scope = null;

	Allocator file_alloc = &entry.arena;
	Allocator saved      = self.ctx.allocator;
	self.ctx.allocator = file_alloc;

	entry.text = text.copy(file_alloc);
	entry.lines.init(file_alloc, entry.text);

	Lexer* lex = lexer::new(self.ctx, entry.text);

	// Create the SourceFile before tokenizing: the lexer reports its
	// diagnostics against ctx.current_source_file, and the callback drops
	// anything that arrives without one.
	SourceFile* sf = source_file::new(self.ctx, lex, entry.path);
	self.ctx.current_source_file = sf;

	lexer::tokenize(lex);

	ParseContext* parse_ctx = parser::new(self.ctx);
	(void)parser::parse(parse_ctx, sf);

	entry.sf = sf;
	self.ctx.allocator = saved;
}

<*
 @param [&inout] self
*>
fn void LspSession.remove_file(&self, String path) {
	FileEntry* entry = self.entries.get(path) ?? null;
	if (!entry) return;

	self.unindex(path);

	(void)self.ctx.files.remove(path);
	self.entries.remove(path);

	entry.free_index_records(self.allocator);
	entry.arena.free();
	entry.path.free(self.allocator);
	alloc::free(self.allocator, entry);
}

<*
 Forget what this file contributed, releasing the recorded keys.

 The module names are not freed here: they are index arena strings owned
 by the Module itself, only borrowed by this list.

 @param [&inout] self
*>
fn void FileEntry.clear_index_records(&self, Allocator allocator) {
	foreach (IndexedName indexed : self.index_names) {
		indexed.name.free(allocator);
		indexed.qualified.free(allocator);
		if (indexed.method_of.len > 0) indexed.method_of.free(allocator);
	}

	self.index_modules.clear();
	self.index_node_ids.clear();
	self.index_names.clear();
}

<*
 @param [&inout] self
*>
fn void FileEntry.free_index_records(&self, Allocator allocator) {
	self.clear_index_records(allocator);

	self.index_modules.free();
	self.index_node_ids.free();
	self.index_names.free();
}

<*
 Take one file's contribution back out of the shared index.

 Must run before set_file resets that file's arena: every Node* the index
 holds for this file points into it, and the records below are what makes
 removing them possible once the AST itself is gone.

 @param [&inout] self
*>
fn void LspSession.unindex(&self, String path) {
	FileEntry* entry = self.entries.get(path) ?? null;
	if (!entry) return;

	foreach (IndexedName indexed : entry.index_names) {
		self.drop_symbol(&self.by_name, indexed.name, entry);
		self.drop_symbol(&self.by_module, indexed.qualified, entry);
		if (indexed.method_of.len > 0) self.drop_symbol(&self.by_method, indexed.method_of, entry);
	}

	foreach (ulong id : entry.index_node_ids) {
		(void)self.node_owner.remove(id);
	}

	foreach (String mod_name : entry.index_modules) {
		Module* module_ptr = self.ctx.modules.get(mod_name) ?? null;
		if (!module_ptr) continue;

		foreach (ulong id : entry.index_node_ids) {
			(void)module_ptr.node_map.remove((NodeID)id);
		}

		retain_registered(&module_ptr.nodes, &module_ptr.node_map);
		retain_registered_decls(&module_ptr.module_decls, &module_ptr.node_map);

		if (module_ptr.nodes.is_empty()) (void)self.ctx.modules.remove(mod_name);
	}

	entry.clear_index_records(self.allocator);
}

<*
 Keep only the nodes still present in `node_map`, which unindex has
 already had this file's ids removed from.

 @param [&inout] nodes
 @param [&in] node_map
*>
fn void retain_registered(List{Node*}* nodes, HashMap{NodeID, Node*}* node_map) @local {
	sz write = 0;

	for (sz read = 0; read < nodes.len(); read++) {
		Node* node = nodes.get(read);
		if (!node || !node_map.has_key(node.id)) continue;

		nodes.set(write, node);
		write++;
	}

	while (nodes.len() > write) (void)nodes.pop();
}

<*
 @param [&inout] decls
 @param [&in] node_map
*>
fn void retain_registered_decls(List{ModuleDecl*}* decls, HashMap{NodeID, Node*}* node_map) @local {
	sz write = 0;

	for (sz read = 0; read < decls.len(); read++) {
		ModuleDecl* decl = decls.get(read);
		if (!decl || !node_map.has_key(decl.node.id)) continue;

		decls.set(write, decl);
		write++;
	}

	while (decls.len() > write) (void)decls.pop();
}

<*
 Register a freshly parsed file into the module table and symbol index.

 This is registry::register's module bookkeeping without its declaration
 maps: ctx.registry and ctx.lookup are write only - nothing in the LSP or
 in the analyzer's sema ever reads them - and populating them cost a
 formatted qualified name plus two allocations and two map inserts for
 every declaration in the workspace.

 @param [&inout] self
*>
fn void LspSession.index(&self, String path) => @pool() {
	FileEntry* entry = self.entries.get(path) ?? null;
	if (!entry || !entry.sf) return;

	Allocator saved = self.ctx.allocator;
	self.ctx.allocator = &self.index_arena;
	defer self.ctx.allocator = saved;

	Module* current_mod;

	// Top level statements only. The whole node list is two orders of
	// magnitude larger and nothing ever looks a nested node up by id.
	foreach (Node* node : entry.sf.ast.statements) {
		if (!node) continue;
		if (node.kind == CONTRACT_DECL) continue;

		if (node.kind == MODULE_DECL) {
			ModuleDecl* mod_decl = node.as(ModuleDecl);
			if (mod_decl.path && mod_decl.path.kind == PATH_EXPR) {
				current_mod = self.use_module(entry, mod_decl.path.as(PathExpr).path.text);
			}
		}

		// A file with no module declaration is named after itself, the same
		// way registry::register infers it.
		if (!current_mod) {
			Path? file_path = path::tnew(entry.path);
			if (catch err = file_path) {
				diagnostics::log_error("Failed to infer module name: %s", err);
				return;
			}
			current_mod = self.use_module(entry, file_path.basename());
		}

		mod::add_node(current_mod, node);
		entry.index_node_ids.push((ulong)node.id);
		self.node_owner.set((ulong)node.id, entry);

		switch (node.kind) {
			case MODULE_DECL:
			case IMPORT_DECL:
				continue;
			default:
				break;
		}

		String name = cursor::spelling(node, tmem) ?? "";
		if (name.len == 0) continue;

		String method_of = method_target(node);
		SymbolRef ref = {
			.node = node,
			.module_name = current_mod.name,
			.owner = entry,
			.is_method = method_of.len > 0,
		};
		String qualified = qualified_name(current_mod.name, name);

		self.push_symbol(&self.by_name, name, ref);
		self.push_symbol(&self.by_module, qualified, ref);

		if (method_of.len > 0) self.push_symbol(&self.by_method, method_of, ref);

		// The keys are recorded so unindex can find these buckets again.
		// Copies, because the module name lives in the index arena and the
		// rest came from the file arena that set_file will reset.
		entry.index_names.push(
			{
				.name = name.copy(self.allocator),
				.qualified = qualified.copy(self.allocator),
				.method_of = method_of.len > 0 ? method_of.copy(self.allocator) : "",
			}
		);
	}
}

<*
 Get or create `name`, recording that this file declares into it.

 @param [&inout] self
 @param [&inout] entry
*>
fn Module* LspSession.use_module(&self, FileEntry* entry, String name) {
	// mod::new stores the name pointer as given, and the identifier it came
	// from lives in the file arena that set_file resets. Copy on creation
	// only, so re-registering an existing module costs nothing.
	Module* module_ptr = self.ctx.modules.get(name) ?? null;
	if (!module_ptr) module_ptr = mod::new(self.ctx, name.copy(&self.index_arena));

	foreach (String known : entry.index_modules) {
		if (known == module_ptr.name) return module_ptr;
	}

	entry.index_modules.push(module_ptr.name);
	return module_ptr;
}

<*
 Re-derive the whole index. The startup path, and the fallback whenever a
 caller wants to be sure nothing has drifted.

 @param [&inout] self
*>
fn void LspSession.rebuild_index(&self) {
	self.entries.@each(; String path, FileEntry* entry) {
		self.unindex(path);
	};

	self.entries.@each(; String path, FileEntry* entry) {
		self.index(path);
	};
}

<*
 Add one ref to a name bucket.

 Buckets are session allocated rather than index arena allocated: they
 outlive individual files and have to be freed one at a time as files
 come and go. HashMap copies and frees the String key itself, so the key
 needs no copy here.

 @param [&inout] self
 @param [&inout] table
*>
fn void LspSession.push_symbol(&self, HashMap{String, List{SymbolRef}}* table, String key, SymbolRef ref) {
	if (try List{SymbolRef}* existing = table.get_ref(key)) {
		existing.push(ref);
		return;
	}

	List{SymbolRef} fresh;
	fresh.init(self.allocator, 2);
	fresh.push(ref);
	table.set(key, fresh);
}

<*
 Drop every ref `owner` contributed to a name bucket, and the bucket
 itself once it is empty.

 @param [&inout] self
 @param [&inout] table
*>
fn void LspSession.drop_symbol(&self, HashMap{String, List{SymbolRef}}* table, String key, FileEntry* owner) {
	List{SymbolRef}* bucket = table.get_ref(key) ?? null;
	if (!bucket) return;

	sz write = 0;
	for (sz read = 0; read < bucket.len(); read++) {
		SymbolRef ref = bucket.get(read);
		if (ref.owner == owner) continue;

		bucket.set(write, ref);
		write++;
	}

	while (bucket.len() > write) (void)bucket.pop();

	if (bucket.is_empty()) {
		bucket.free();
		(void)table.remove(key);
	}
}

fn String qualified_name(String module_name, String name) {
	return string::tformat("%s::%s", module_name, name);
}

<*
 Run sema for one file and keep the scope tree it builds.

 `sema::analyze_source_file` throws its SemaContext away, so the scopes
 the variable pass produces would be unreachable otherwise. Must run
 after `rebuild_index`, since import resolution reads `ctx.modules`.

 @param [&inout] self
*>
fn void LspSession.analyze(&self, String path) {
	FileEntry* entry = self.entries.get(path) ?? null;
	if (!entry || !entry.sf) return;

	Allocator saved = self.ctx.allocator;
	self.ctx.allocator = &entry.arena;

	SemaContext* sema_ctx = sema::new(self.ctx);
	sema::analyze_source_file(sema_ctx, entry.sf);
	entry.root_rt_scope = sema_ctx.runtime_scope;
	entry.root_ct_scope = sema_ctx.comptime_scope;

	self.ctx.allocator = saved;
}

fn FileEntry* LspSession.entry(&self, String path) {
	return self.entries.get(path) ?? null;
}

fn FileEntry* LspSession.entry_for_node(&self, Node* node) {
	if (!node) return null;
	return self.node_owner.get((ulong)node.id) ?? null;
}

<*
 Replaces the analyzer's removed `Workspace.find_symbol_by_name`.
*>
fn List{SymbolRef} LspSession.find_symbols(&self, String name) {
	return self.by_name.get(name) ?? (List{SymbolRef}) { };
}

<*
 Bare name of the type a function or macro is bound to, or empty when it
 is not a method.

 The single definition of what counts as a method: a declaration with an
 associated type is reachable on a value of that type, and nowhere else -
 not through its module, which is why module completion filters on this
 too.
*>
fn String method_target(Node* node) {
	Node* associated;

	switch (node.kind) {
		case FN_DECL:
			associated = node.as(FnDecl).associated_type;
		case MACRO_DECL:
			associated = node.as(MacroDecl).associated_type.get() ?? null;
		default:
			return "";
	}

	if (!associated) return "";
	return cursor::raw_type_identifier(associated) ?? "";
}

<*
 Every method bound to the type named `type_name`.
*>
fn List{SymbolRef} LspSession.methods_for(&self, String type_name) {
	return self.by_method.get(type_name) ?? (List{SymbolRef}) { };
}

<*
 Replaces the analyzer's removed `Workspace.lookup_in_module`.
*>
fn List{SymbolRef} LspSession.find_in_module(&self, String module_name, String name) {
	return self.by_module.get(qualified_name(module_name, name)) ?? (List{SymbolRef}) { };
}

<*
 Module owning `node`, or null. Top level nodes are stored per module, so
 this is a linear scan over the module table.
*>
fn Module* LspSession.module_of(&self, Node* node) {
	if (!node) return null;

	Module* found;
	self.ctx.modules.@each(; String name, Module* module_ptr) {
		if (!found && module_ptr.node_map.has_key(node.id)) found = module_ptr;
	};

	return found;
}

<*
 First module declared in `path`, which is the one completion and global
 symbol filtering treat as "the current module".
*>
fn Module* LspSession.module_for_file(&self, String path) {
	FileEntry* entry = self.entry(path);
	if (!entry || !entry.sf) return null;

	foreach (Node* node : entry.sf.ast.statements) {
		if (!node || node.kind != MODULE_DECL) continue;
		return self.module_of(node);
	}

	return null;
}

<*
 Raw source text covered by a node's range.

 The analyzer's `cursor::source_text` is commented out upstream, so this
 reimplements it over the file's line index.
*>
fn String LspSession.node_source_text(&self, Node* node) {
	FileEntry* entry = self.entry_for_node(node);
	if (!entry || !node) return "";
	return entry.lines.slice(node.range);
}

<*
 Declaration signature without the body.

 Reimplements the analyzer's commented out `cursor::signature_text`.
*>
fn String LspSession.node_signature_text(&self, Node* node) {
	FileEntry* entry = self.entry_for_node(node);
	if (!entry || !node) return "";

	Node* body;
	switch (node.kind) {
		case FN_DECL:
			body = node.as(FnDecl).body;
		case MACRO_DECL:
			body = node.as(MacroDecl).body;
		default:
			body = null;
	}

	if (!body) {
		return entry.lines.slice(node.range).trim();
	}

	Range signature = { .start = node.range.start, .end = body.range.start };
	return entry.lines.slice(signature).trim().strip_suffix("{").strip_suffix("=>").trim();
}

<*
 Deepest scope containing `loc`.

 Replaces the analyzer's removed `sema::find_deepest_scope`, which took a
 byte offset; scopes now carry line/column ranges.
*>
fn Scope* find_deepest_scope(Scope* root, Location loc) {
	if (!root) return null;

	Scope* best = root;
	foreach (Scope* child : root.children) {
		if (!child) continue;
		if (!child.range.contains(loc)) continue;

		Scope* deeper = find_deepest_scope(child, loc);
		if (deeper) best = deeper;
	}

	return best;
}

<*
 A variable in scope at some position.

 `is_local` says the declaration came from a scope nested inside the file
 root. The analyzer's VarDecl.var_kind cannot answer this: its VAR_LOCAL
 means the `@local` visibility attribute, so a function body variable is
 still reported as VAR_GLOBAL.
*>
struct VisibleVar {
	VariableInfo* info;
	bool is_local;
}

<*
 Every variable visible from `leaf`, innermost first.

 Replaces the analyzer's removed `sema::collect_visible_symbols`.
*>
fn List{VisibleVar} collect_visible(Allocator allocator, Scope* leaf) {
	List{VisibleVar} result;
	result.init(allocator, 16);

	for (Scope* current = leaf; current != null; current = current.parent) {
		bool nested = current.parent != null;

		current.variables.@each(; String name, VariableInfo* info) {
			if (info) result.push({ .info = info, .is_local = nested });
		};
	}

	return result;
}

<*
 Top level statement whose range covers `loc`, or null.

 Replaces the analyzer's removed
 `Workspace.find_top_level_statement_at_location`. `cursor::find_at`
 cannot stand in for it: that one recurses to the innermost node.
*>
fn Node* top_level_at(SourceFile* sf, Location loc) {
	if (!sf) return null;

	Node* trailing;

	foreach (Node* node : sf.ast.statements) {
		if (!node) continue;
		if (node.range.contains(loc)) return node;

		// Range.contains is end exclusive, which is right for "which node
		// is this character part of". A cursor is not a character though:
		// it sits between them, so a completion request lands one past what
		// was just typed - further still when there is trailing space,
		// since "import " parses to a node covering only the keyword.
		// Statements are in source order, so the last node ending on this
		// line at or before the cursor is the one being written.
		if (node.range.end.line == loc.line && node.range.end.column <= loc.column) {
			trailing = node;
		}
	}

	return trailing;
}

<*
 Token whose range covers `loc`, or false if there is none.

 Replaces the analyzer's removed `Lexer.find_token_at`. The session keeps
 each file's lexer alive, so its token list is still there to scan.
*>
fn bool token_at(SourceFile* sf, Location loc, Token* out_token) {
	if (!sf || !sf.lexer) return false;

	foreach (Token t : sf.lexer.tokens) {
		if (t.kind == EOF) break;
		if (!t.range.contains(loc)) continue;

		*out_token = t;
		return true;
	}

	return false;
}