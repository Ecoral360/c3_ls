module lsp::analysis;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema::scope;

import lsp::core;

import std::collections::list;

<*
 What resolving a type needs to know: where the cursor is, which file and
 module it is in, and the index to look names up in.

 Split out of the completion Context so goto definition and hover resolve
 exactly the way completion does. There is no other type resolution to
 fall back on - the analyzer's sema::resolve is a stub and
 TypeInfo.resolved is never populated - so a second implementation would
 be a second set of answers.
*>
struct TypeContext {
	LspSession* session;
	FileEntry* file;
	Module* mod;
	Location location;
}

struct DeclSite {
	FileEntry* file;
	Location location;
}

<*
 The site the cursor is at, which is where a name being typed is written.
*>
fn DeclSite TypeContext.cursor_site(&self) {
	return { .file = self.file, .location = self.location };
}

<*
 The site `node` is written at.

 @param owner : "the file `node` came from; the cursor's file when the caller cannot say"
*>
fn DeclSite TypeContext.site_of(&self, Node* node, FileEntry* owner = null) {
	if (!node) return self.cursor_site();

	return { .file = owner ?: self.file, .location = node.range.start };
}

fn bool is_type_decl(Node* node) {
	switch (node.kind) {
		case STRUCT_DECL:
		case ENUM_DECL:
		case TYPEDEF_DECL:
		case INTERFACE_DECL:
			return true;
		default:
			return false;
	}
}

<*
 Which declarations a lookup will take.
*>
enum DeclWanted : int {
	ANY,
	TYPE,
	CALLABLE,
}

fn bool is_wanted(Node* node, DeclWanted wanted) {
	switch (wanted) {
		case TYPE:
			return is_type_decl(node);
		case CALLABLE:
			return is_callable_decl(node);
		case ANY:
			return true;
	}
}

fn bool is_callable_decl(Node* node) {
	switch (node.kind) {
		case FN_DECL:
		case MACRO_DECL:
			return true;
		default:
			return false;
	}
}

<*
 Look a declaration up by bare name, in the module the name is written in.

 @param wanted : "which declarations count as an answer"
 @param where : "where the name is written, which is what carries the imports"
*>
fn Node* find_decl(TypeContext ctx, String name, DeclWanted wanted, DeclSite where) {
	if (name.len == 0) return null;

	SemaModuleContext* site = where.file ? where.file.sema_module_at_location(where.location) : null;

	// The module of the section the name sits in, which is not the module
	// of the file being edited once the site is in another file.
	String current = site && site.mod ? site.mod.name : (ctx.mod ? ctx.mod.name : "");

	Node* best;
	DeclReach reach    = NONE;
	String best_module = "";

	foreach (SymbolRef ref : ctx.session.find_symbols(name)) {
		if (!ref.node) continue;
		if (!is_wanted(ref.node, wanted)) continue;

		DeclReach candidate = decl_reach(ref, current, site);

		// Out of view is ignored
		if (candidate == NONE && site) continue;

		// A declaration another module keeps to itself cannot be named from
		// outside it, whichever way that module is in view.
		if (candidate != OWN && ref.node.visibility != PUBLIC) continue;

		if (best && !outranks(candidate, ref.module_name, reach, best_module)) continue;

		best = ref.node;
		reach = candidate;
		best_module = ref.module_name;

		// Nothing outranks the module the name is written in.
		if (reach == OWN) break;
	}

	return best;
}

<*
 How a candidate is in view from the module the name is written in.

 Ordered worst to best: the ranking compares these directly.
*>
enum DeclReach : int @local {
	<* Out of view: no import, no nesting, not std::core. *>
	NONE,
	<* In std::core, which needs no import. *>
	CORE,
	<* A module this one imported. *>
	IMPORTED,
	<* A module this one nests with, parent or child. *>
	NESTED,
	<* The module the name is written in. *>
	OWN,
}

<*
 Where `ref` stands relative to the module the name is written in.

 `site` is that module's section, which is what carries the imports: a
 file declares one per `module` line, and two sections of the same file
 import different things.
*>
fn DeclReach decl_reach(SymbolRef ref, String current, SemaModuleContext* site) @local {
	if (current.len > 0 && ref.module_name == current) return OWN;
	if (modules_nest(current, ref.module_name)) return NESTED;
	if (site && site.imports_module(ref.module_name)) return IMPORTED;
	if (is_core_module(ref.module_name)) return CORE;

	return NONE;
}

<*
 True when the candidate should take the place of the one held so far.
*>
fn bool outranks(DeclReach candidate, String module_name, DeclReach held, String held_module) @local {
	if (candidate != held) return candidate > held;

	return sorts_before(module_name, held_module);
}

fn bool sorts_before(String a, String b) @local {
	usz shared = (usz)min(a.len, b.len);

	for (usz i = 0; i < shared; i++) {
		if (a[i] != b[i]) return a[i] < b[i];
	}

	return a.len < b.len;
}

<*
 True when one module contains the other.
*>
fn bool modules_nest(String a, String b) @local {
	if (a.len == 0 || b.len == 0) return false;

	String outer = a.len < b.len ? a : b;
	String inner = a.len < b.len ? b : a;

	return inner.len > outer.len && inner.starts_with(outer) && inner[outer.len..].starts_with("::");
}

<*
 std::core and everything under it is in view of every module: nothing
 imports it, and every file uses it.
*>
fn bool is_core_module(String module_name) @local {
	return module_name == "std::core" || module_name.starts_with("std::core::");
}

<*
 Declaration of the type a written type expression names.

 @param owner : "the file the expression was written in; the cursor's file when the caller cannot say"
*>
fn Node* type_decl_of(TypeContext ctx, Node* type_expr, FileEntry* owner = null) {
	if (!type_expr) return null;

	String name = cursor::raw_type_identifier(type_expr) ?? "";
	if (name.len == 0) return null;

	return find_decl(ctx, name, TYPE, ctx.site_of(type_expr, owner));
}

<*
 Return type of a function or macro declaration.
*>
fn Node* return_type_decl(TypeContext ctx, Node* callable) {
	if (!callable) return null;

	// The return type is written where the callable is, which is rarely
	// the file being edited.
	FileEntry* owner = ctx.session.entry_for_node(callable);

	switch (callable.kind) {
		case FN_DECL:
			return type_decl_of(ctx, callable.as(FnDecl).ret_type, owner);
		case MACRO_DECL:
			return type_decl_of(ctx, callable.as(MacroDecl).ret_type.get() ?? null, owner);
		default:
			return null;
	}
}

<*
 Declaration of a variable visible at the cursor: a local, a parameter,
 or a file scope global once sema has put it in the root scope.

 The symbol index only carries top level declarations, so the scope tree
 is the only place a local exists. A parameter is also reachable through
 the signature, which is what answers when the body did not parse.
*>
fn Node* variable_decl(TypeContext ctx, String name) {
	if (!ctx.file || name.len == 0) return null;

	SemaModuleContext* sema_module = ctx.file.sema_module_at_location(ctx.location);
	if (!sema_module) return signature_param(ctx, name);

	Scope* leaf = core::find_deepest_scope(sema_module.runtime_scope, ctx.location);
	if (!leaf) return signature_param(ctx, name);

	VariableInfo* info = scope::get_variable(leaf, name);
	if (!info || !info.node || info.node.kind != VAR_DECL) return signature_param(ctx, name);

	return info.node;
}

<*
 The parameter named `name` in the signature the cursor is inside of, or null.
*>
fn Node* signature_param(TypeContext ctx, String name) @local {
	if (!ctx.file || !ctx.file.sf) return null;

	Node* enclosing = core::top_level_at(ctx.file.sf, ctx.location);
	if (!enclosing) return null;

	NodeArray params;
	switch (enclosing.kind) {
		case FN_DECL:
			params = enclosing.as(FnDecl).params;
		case MACRO_DECL:
			params = enclosing.as(MacroDecl).params;
		default:
			return null;
	}

	foreach (Node* param : params) {
		if (!param || param.kind != VAR_DECL) continue;

		VarDecl* decl = param.as(VarDecl);
		if (decl.name && decl.name.text == name) return param;
	}

	return null;
}

<*
 Bare name of the type `self` stands for at the cursor, or "" when the
 cursor is not inside a method.

 A receiver is written `self` or `&self` and carries no written type, so
 the associated type in the enclosing signature is the only thing that
 says what it is.
*>
fn String self_type_name(TypeContext ctx) {
	if (!ctx.file || !ctx.file.sf) return "";

	return core::method_target(core::top_level_at(ctx.file.sf, ctx.location));
}

<*
 The type `self` stands for at the cursor.

 It refers to is the associated type in the enclosing signature.
*>
fn Node* self_type(TypeContext ctx) {
	String type_name = self_type_name(ctx);
	if (type_name.len == 0) return null;

	return find_decl(ctx, type_name, TYPE, ctx.cursor_site());
}

<*
 Declaration of the type a variable in scope was declared with.
*>
fn Node* variable_type(TypeContext ctx, String name) {
	if (Node* decl = variable_decl(ctx, name)) {
		VarDecl* var_decl = decl.as(VarDecl);
		if (var_decl.type) return type_decl_of(ctx, var_decl.type);

		// A receiver is in scope like any other parameter but has no
		// written type, so it resolves through the signature instead.
		if (var_decl.var_flags.is_self) return self_type(ctx);

		return null;
	}

	// Sema drops the receiver from the scope tree when the body does not
	// parse, and the road out of that is the same one.
	if (name == "self") return self_type(ctx);

	return null;
}

<*
 True when a method indexed under a type's bare name really belongs to
 this declaration of it.

 The method index is keyed by the bare name, and names collide across
 modules. A method lives either beside its type or in the module doing
 the extending, so both are accepted and nothing else is.
*>
fn bool reachable_method(TypeContext ctx, Node* type_decl, SymbolRef ref) {
	if (!ref.node) return false;

	Module* owner  = ctx.session.module_of(type_decl);
	String current = ctx.mod ? ctx.mod.name : "";

	if (owner && ref.module_name == owner.name) return true;
	return current.len > 0 && ref.module_name == current;
}

<*
 The method named `name` on `type_decl`, or null.
*>
fn Node* find_method(TypeContext ctx, Node* type_decl, String name) {
	String type_name = cursor::spelling(type_decl, tmem) ?? "";
	if (type_name.len == 0 || name.len == 0) return null;

	foreach (SymbolRef ref : ctx.session.methods_for(type_name)) {
		if (!reachable_method(ctx, type_decl, ref)) continue;
		if ((cursor::spelling(ref.node, tmem) ?? "") == name) return ref.node;
	}

	return null;
}

<*
 The field named `name` on `type_decl`, or null.
*>
fn Node* find_field(Node* type_decl, String name) {
	if (!type_decl || type_decl.kind != STRUCT_DECL || name.len == 0) return null;

	StructDecl* str_decl = type_decl.as(StructDecl);

	foreach (Node* field_node : str_decl.fields) {
		if (!field_node || field_node.kind != VAR_DECL) continue;

		VarDecl* field = field_node.as(VarDecl);
		if (field.name && field.name.text == name) return field_node;
	}

	Node* next = str_decl.next;
	while (next) {
		StructDecl* sub = next.as(StructDecl);
		if (sub.name) {
			if (sub.name.text == name) return next;
		} else {
			Node* result = find_field(next, name);
			if (result) return result;
		}
		next = sub.next;
	}

	return null;
}

<*
 The declaration of a member reachable on a value of `type_decl`: a field
 first, then a method.
*>
fn Node* find_member(TypeContext ctx, Node* type_decl, String name) {
	if (!type_decl) return null;

	Node* field = find_field(type_decl, name);
	if (field) return field;

	return find_method(ctx, type_decl, name);
}

<*
 Declaration of the type an expression evaluates to.

 Walks the AST rather than the token stream, which is what goto
 definition and hover want: they run on a name that is already written,
 so the parse is usually whole.
*>
fn Node* expr_type(TypeContext ctx, Node* expr) {
	if (!expr) return null;

	switch (expr.kind) {
		case IDENT_EXPR:
			IdentExpr* ident = expr.as(IdentExpr);
			if (!ident.ident) return null;

			// A variable shadows a type of the same name.
			Node* declared = variable_type(ctx, ident.ident.text);
			if (declared) return declared;
			return find_decl(ctx, ident.ident.text, TYPE, ctx.site_of(expr));

		case CALL_EXPR:
			return return_type_decl(ctx, expr_decl(ctx, expr.as(CallExpr).callee));

		case ACCESS_EXPR:
			// A field access is a value of the field's type. A bare method
			// reference is not a value, so it has no type here.
			AccessExpr* access = expr.as(AccessExpr);
			if (!access.member) return null;

			Node* base   = expr_type(ctx, access.left);
			Node* member = find_member(ctx, base, cursor::spelling(access.member, tmem) ?? "");
			if (!member || member.kind != VAR_DECL) return null;

			// A field is not a top level statement, so the index cannot say
			// which file it came from: the type it belongs to answers that.
			return type_decl_of(ctx, member.as(VarDecl).type, ctx.session.entry_for_node(base));

		// Transparent wrappers.
		case GROUP_EXPR:
			return expr_type(ctx, expr.as(GroupExpr).inner);
		case OPTIONAL_EXPR:
			return expr_type(ctx, expr.as(OptionalExpr).inner_expr);
		case MAYBE_DEREF_EXPR:
			return expr_type(ctx, expr.as(MaybeDerefExpr).left);
		case CAST_EXPR:
			// A cast is a value of the type cast to, not of the operand.
			return type_decl_of(ctx, expr.as(CastExpr).inner, ctx.file);

		default:
			return null;
	}
}

<*
 The declaration an expression refers to: a variable, a function, a type,
 or the member on the left of a call.
*>
fn Node* expr_decl(TypeContext ctx, Node* expr) {
	if (!expr) return null;

	switch (expr.kind) {
		case IDENT_EXPR:
			IdentExpr* ident = expr.as(IdentExpr);
			if (!ident.ident) return null;
			return find_decl(ctx, ident.ident.text, CALLABLE, ctx.site_of(expr));

		case ACCESS_EXPR:
			AccessExpr* access = expr.as(AccessExpr);
			if (!access.member) return null;

			String name = cursor::spelling(access.member, tmem) ?? "";
			return find_member(ctx, expr_type(ctx, access.left), name);

		case GROUP_EXPR:
			return expr_decl(ctx, expr.as(GroupExpr).inner);

		default:
			return null;
	}
}

struct AccessAtContext @local {
	Location target;
	AccessExpr* found;
}

fn ChildVisitResult access_at_callback(Node* node, Node* parent, void* user_data) @local {
	AccessAtContext* ctx = (AccessAtContext*)user_data;

	if (node.kind == ACCESS_EXPR) {
		AccessExpr* access = node.as(AccessExpr);
		// Deeper matches overwrite shallower ones, so the innermost wins.
		if (access.member && access.member.range.contains(ctx.target)) ctx.found = access;
	}

	return RECURSE;
}

<*
 The innermost member access whose member name covers `loc`, or null.

 The node the cursor lands on is the member identifier itself; what
 decides its meaning is the expression to its left, and nodes carry no
 parent pointer, so the enclosing access has to be searched for.
*>
fn AccessExpr* access_at(SourceFile* sf, Location loc) {
	if (!sf) return null;

	AccessAtContext ctx = { .target = loc };

	foreach (Node* node : sf.ast.statements) {
		if (!node) continue;
		if (!cursor::visit(node, null, { .on_enter = &access_at_callback }, &ctx)) break;
	}

	return ctx.found;
}

<*
 A resolved member reference.

 `type_decl` is carried alongside because a field is not a top level
 statement: the symbol index only knows which file and module a top level
 declaration came from, so the type it belongs to is what answers that
 for its fields.
*>
struct MemberResolution {
	Node* decl;
	Node* type_decl;
}

<*
 The member reference at `loc`, or an empty resolution when the cursor is
 not on one or the base type cannot be resolved.
*>
fn MemberResolution member_at(TypeContext ctx, SourceFile* sf, Location loc) {
	AccessExpr* access = access_at(sf, loc);
	if (!access || !access.member) return { };

	Node* type_decl = expr_type(ctx, access.left);
	if (!type_decl) return { };

	String name = cursor::spelling(access.member, tmem) ?? "";
	return { .decl = find_member(ctx, type_decl, name), .type_decl = type_decl };
}
