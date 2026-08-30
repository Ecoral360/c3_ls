module lsp::core;

import std::collections::list;
import std::collections::map;

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
}

<*
 Replaces the analyzer's removed `Workspace`.

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

	// context::create builds a registry and a lookup from `allocator`, but
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
		entry.arena.free();
		entry.path.free(self.allocator);
		alloc::free(self.allocator, entry);
	};
	self.entries.free();

	self.by_name.free();
	self.by_module.free();
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

	(void)self.ctx.files.remove(path);
	self.entries.remove(path);

	entry.arena.free();
	entry.path.free(self.allocator);
	alloc::free(self.allocator, entry);
}

<*
 Rebuild the module table and symbol index from every tracked file.

 This has to be a full rebuild: `mod::create` is get-or-create and
 `mod::add_node` appends unconditionally, so registering a file twice
 without clearing would duplicate every node in its module.

 TODO: this is O(all files) per update batch. It only walks top level
 statements, but it should become incremental once the analyzer can
 invalidate a single file's contribution to a module.

 @param [&inout] self
*>
fn void LspSession.rebuild_index(&self) {
	// Module structs and their lists live in the index arena, so the
	// reset below reclaims them; the maps themselves are session owned.
	self.ctx.modules.clear();
	self.by_name.clear();
	self.by_module.clear();
	self.node_owner.clear();
	self.index_arena.reset();

	Allocator index_alloc = &self.index_arena;
	Allocator saved       = self.ctx.allocator;
	self.ctx.allocator = index_alloc;

	// Both of these index into the arena we just reset, and both are
	// keyed by strings that live there too, so they have to be rebuilt
	// alongside it rather than accumulating dangling entries.
	self.ctx.registry = registry::new(index_alloc);
	self.ctx.lookup = lookup::new(self.ctx, index_alloc);

	self.entries.@each(; String path, FileEntry* entry) {
		if (entry.sf) {
			foreach (Node* node : entry.sf.ast.nodes) {
				if (!node) continue;
				self.node_owner.set((ulong)node.id, entry);
			}

			self.ctx.current_source_file = entry.sf;
			registry::register(self.ctx, entry.sf);
		}
	};

	self.ctx.allocator = saved;

	self.ctx.modules.@each(; String mod_name, Module* module_ptr) {
		foreach (Node* node : module_ptr.nodes) {
			if (!node) continue;

			switch (node.kind) {
				case MODULE_DECL:
				case IMPORT_DECL:
				case CONTRACT_DECL:
					continue;
				default:
					break;
			}

			String name = cursor::spelling(node, tmem) ?? "";
			if (name.len == 0) continue;

			SymbolRef ref = {
				.node = node,
				.module_name = mod_name,
				.owner = self.node_owner.get((ulong)node.id) ?? null,
			};

			self.push_symbol(&self.by_name, name, ref);
			self.push_symbol(&self.by_module, qualified_name(mod_name, name), ref);
		}
	};
}

<*
 @param [&inout] self
 @param [&inout] table
*>
fn void LspSession.push_symbol(&self, HashMap{String, List{SymbolRef}}* table, String key, SymbolRef ref) {
	Allocator index_alloc = &self.index_arena;

	if (try List{SymbolRef}* existing = table.get_ref(key)) {
		existing.push(ref);
		return;
	}

	List{SymbolRef} fresh;
	fresh.init(index_alloc, 2);
	fresh.push(ref);
	table.set(key.copy(index_alloc), fresh);
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