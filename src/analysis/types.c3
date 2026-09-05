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
 Look a declaration up by bare name, preferring the current module.

 The index is keyed by bare name, and a name like 'Point' is declared in
 more than one module often enough that taking the first match picks a
 stdlib type and offers its members.
*>
fn Node* find_decl(TypeContext ctx, String name, bool want_type) {
	if (name.len == 0) return null;

	String current = ctx.mod ? ctx.mod.name : "";
	Node* fallback;

	foreach (SymbolRef ref : ctx.session.find_symbols(name)) {
		if (!ref.node) continue;
		if (want_type ? !is_type_decl(ref.node) : !is_callable_decl(ref.node)) continue;

		if (current.len > 0 && ref.module_name == current) return ref.node;
		if (!fallback) fallback = ref.node;
	}

	return fallback;
}

<*
 Declaration of the type a written type expression names.
*>
fn Node* type_decl_of(TypeContext ctx, Node* type_expr) {
	if (!type_expr) return null;

	String name = cursor::raw_type_identifier(type_expr) ?? "";
	if (name.len == 0) return null;

	return find_decl(ctx, name, true);
}

<*
 Return type of a function or macro declaration.
*>
fn Node* return_type_decl(TypeContext ctx, Node* callable) {
	if (!callable) return null;

	switch (callable.kind) {
		case FN_DECL:
			return type_decl_of(ctx, callable.as(FnDecl).ret_type);
		case MACRO_DECL:
			return type_decl_of(ctx, callable.as(MacroDecl).ret_type.get() ?? null);
		default:
			return null;
	}
}

<*
 Declaration of a variable visible at the cursor: a local, a parameter,
 or a file scope global once sema has put it in the root scope.

 The symbol index only carries top level declarations, so the scope tree
 is the only place a local or a parameter exists.
*>
fn Node* variable_decl(TypeContext ctx, String name) {
	if (!ctx.file || name.len == 0) return null;

	Scope* leaf = core::find_deepest_scope(ctx.file.root_rt_scope, ctx.location);
	if (!leaf) return null;

	VariableInfo* info = scope::get_variable(leaf, name);
	if (!info || !info.node || info.node.kind != VAR_DECL) return null;

	return info.node;
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

	return find_decl(ctx, type_name, true);
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

	foreach (Node* field_node : type_decl.as(StructDecl).fields) {
		if (!field_node || field_node.kind != VAR_DECL) continue;

		VarDecl* field = field_node.as(VarDecl);
		if (field.name && field.name.text == name) return field_node;
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
			return find_decl(ctx, ident.ident.text, true);

		case CALL_EXPR:
			return return_type_decl(ctx, expr_decl(ctx, expr.as(CallExpr).callee));

		case ACCESS_EXPR:
			// A field access is a value of the field's type. A bare method
			// reference is not a value, so it has no type here.
			Node* member = expr_decl(ctx, expr);
			if (!member || member.kind != VAR_DECL) return null;
			return type_decl_of(ctx, member.as(VarDecl).type);

		// Transparent wrappers.
		case GROUP_EXPR:
			return expr_type(ctx, expr.as(GroupExpr).inner);
		case OPTIONAL_EXPR:
			return expr_type(ctx, expr.as(OptionalExpr).inner_expr);
		case MAYBE_DEREF_EXPR:
			return expr_type(ctx, expr.as(MaybeDerefExpr).left);
		case CAST_EXPR:
			// A cast is a value of the type cast to, not of the operand.
			return type_decl_of(ctx, expr.as(CastExpr).inner);

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
			return find_decl(ctx, ident.ident.text, false);

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
