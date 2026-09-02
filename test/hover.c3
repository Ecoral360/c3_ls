module lsp::analysis::hover @test;

import analyzer::core;

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