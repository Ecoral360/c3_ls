module lsp::analysis::hover @test;

import analyzer::core;
import analyzer::cursor;

import lsp::core;
import lsp::test_support;

const String RECEIVER_SRC = `module receiver;

struct Inner
{
	int v;
}

fn int Inner.by_ref(&self)
{
	return self.v;
}

fn int Inner.by_value(self)
{
	return self.v;
}

fn void plain(int a)
{
	int b = a;
}
`;

const String RECEIVER_PATH = "/virtual/receiver.c3";

<*
 A receiver is written `&self`, which is all there is to slice out of the
 source and says nothing about what it is. What it stands for is the
 associated type of the method it belongs to.
*>
fn void receiver_signature_names_the_associated_type() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, RECEIVER_PATH, RECEIVER_SRC);

	SourceFile* sf = session.entry(RECEIVER_PATH).sf;

	Node* by_ref   = test_support::find_top_level(&session, RECEIVER_PATH, "by_ref");
	Node* by_value = test_support::find_top_level(&session, RECEIVER_PATH, "by_value");
	Node* plain    = test_support::find_top_level(&session, RECEIVER_PATH, "plain");

	Node* ref_self   = by_ref.as(FnDecl).params[0];
	Node* value_self = by_value.as(FnDecl).params[0];
	Node* param      = plain.as(FnDecl).params[0];

	// From inside the body, which is where `self` is usually hovered.
	Location in_ref_body = test_support::loc_after(RECEIVER_SRC, "return self");
	test::eq(receiver_signature(sf, in_ref_body, ref_self), "Inner* self");

	// And from the signature itself.
	Location on_ref_param = test_support::loc_of(RECEIVER_SRC, "&self)");
	test::eq(receiver_signature(sf, on_ref_param, ref_self), "Inner* self");

	// A by value receiver is the type itself, not a pointer to it.
	Location in_value_body = test_support::loc_of(RECEIVER_SRC, "self)\n{\n\treturn self.v;\n}\n");
	test::eq(receiver_signature(sf, in_value_body, value_self), "Inner self");

	// An ordinary parameter is not a receiver, and neither is a non node.
	test::eq(receiver_signature(sf, test_support::loc_of(RECEIVER_SRC, "int b = a"), param), "");
	test::eq(receiver_signature(sf, in_ref_body, null), "");
}
const String CONTRACT_SRC = `module documented;

<*
 Doubles a number.

 @param [in] x : "the number to double"
 @param plain
 @require x > 0 : "must be positive"
 @require x < 100
 @ensure return > x
 @return "twice x"
 @return? IoError.EOF, IoError.FILE_NOT_FOUND
 @pure
 @deprecated "use scale instead"
*>
fn int twice(int x, int plain)
{
	return x * 2;
}

<*
 Says nothing else.
*>
fn void described()
{
}

fn void bare()
{
}
`;

const String CONTRACT_PATH = "/virtual/documented.c3";

<*
 A doc comment is more than its description, and everything else in it is
 what a caller reads a signature for.
*>
fn void contract_markdown_renders_every_directive() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, CONTRACT_PATH, CONTRACT_SRC);

	FileEntry* entry = session.entry(CONTRACT_PATH);
	Node* twice      = test_support::find_top_level(&session, CONTRACT_PATH, "twice");

	ContractDecl* contract = cursor::contract(twice)!!;

	test::eq(
		contract_markdown(&session, contract, entry),
		"Doubles a number.\n\n**Parameters**\n- `[in] x` - the number to double\n- `plain`\n\n**Requires**\n- `x > 0` - must be positive\n- `x < 100`\n\n**Ensures**\n- `return > x`\n\n**Returns** twice x\n\n**Faults**\n- `IoError.EOF`\n- `IoError.FILE_NOT_FOUND`\n\n**Pure**\n\n**Deprecated** use scale instead"
	);
}

<*
 The description alone is still the common case, and a declaration with
 no doc comment at all has to come back empty so the hover falls back to
 the signature.
*>
fn void contract_markdown_handles_the_plain_cases() => @pool() {
	LspSession session;
	session.init(mem);
	defer session.free();

	test_support::load(&session, CONTRACT_PATH, CONTRACT_SRC);

	FileEntry* entry = session.entry(CONTRACT_PATH);

	Node* described = test_support::find_top_level(&session, CONTRACT_PATH, "described");
	test::eq(contract_markdown(&session, cursor::contract(described)!!, entry), "Says nothing else.");

	// cursor::contract answers with a null for an undocumented one.
	Node* bare = test_support::find_top_level(&session, CONTRACT_PATH, "bare");
	test::eq(contract_markdown(&session, cursor::contract(bare) ?? null, entry), "");
}
