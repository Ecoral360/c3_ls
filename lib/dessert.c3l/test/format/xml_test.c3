// Tests for the XML serializer (`dessert::format::xml`). XML is serialize-only.
// The module has no short top-level alias, so it is imported by its full path
// and referenced as `xml::`.
module xml_test @test;
import std;
import dessert;
import dessert::format::xml;

// ── Test types ───────────────────────────────────────────────────────────────

$expand(dessert::@derive(XBook, serialize));
struct XBook {
  String title;
  int    year;
}

$expand(dessert::@derive(XAuthor, serialize));
struct XAuthor {
  String name;
}

$expand(dessert::@derive(XBookAuthored, serialize));
struct XBookAuthored {
  String  title;
  XAuthor author;
}

$expand(dessert::@derive(XList, serialize));
struct XList {
  String label;
  int[]  marks;
}

// Attribute fields must precede element fields (the intended layout).
$expand(dessert::@derive(XPoint, serialize));
struct XPoint {
  int    x @DFieldSer({ .fmt = { "xml:attribute" } });
  int    y @DFieldSer({ .fmt = { "xml:attribute" } });
  String label;
}

// An attribute field placed after an element field is an error.
$expand(dessert::@derive(XBadOrder, serialize));
struct XBadOrder {
  String label;
  int    x @DFieldSer({ .fmt = { "xml:attribute" } });
}

// ── Tests ────────────────────────────────────────────────────────────────────

macro String xml_of(value) {
  XMLSerializer s = xml::serializer();
  return ser::serialize(&s, value)!!;
}

fn void test_xml_flat_struct() @test => @pool() {
  XBook b = { .title = "C3", .year = 2024 };
  // Element name is the lowercased struct name; each field becomes a child.
  test::eq(xml_of(b), `<xbook><title>C3</title><year>2024</year></xbook>`);
}

fn void test_xml_nested_struct() @test => @pool() {
  XBookAuthored b = { .title = "C3", .author = { .name = "ann" } };
  test::eq(
    xml_of(b),
    `<xbookauthored><title>C3</title><author><xauthor><name>ann</name></xauthor></author></xbookauthored>`,
  );
}

fn void test_xml_slice_field_singularizes() @test => @pool() {
  XList l = { .label = "seg", .marks = { 7, 8 } };
  // A "marks" slice emits each item under the singular "mark" element.
  test::eq(xml_of(l), `<xlist><label>seg</label><marks><mark>7</mark><mark>8</mark></marks></xlist>`);
}

fn void test_xml_empty_slice() @test => @pool() {
  XList l = { .label = "seg", .marks = {} };
  test::eq(xml_of(l), `<xlist><label>seg</label><marks></marks></xlist>`);
}

fn void test_xml_attributes_then_element() @test => @pool() {
  XPoint p = { .x = 3, .y = 4, .label = "mid" };
  // Attribute fields land on the opening tag; the element field closes it.
  test::eq(xml_of(p), `<xpoint x="3" y="4"><label>mid</label></xpoint>`);
}

fn void test_xml_attribute_after_element_faults() @test => @pool() {
  XBadOrder b = { .label = "oops", .x = 1 };
  XMLSerializer s = xml::serializer();
  test::@error(ser::serialize(&s, b), xml::XML_ATTRIBUTE_AFTER_FIELD);
}

fn void test_xml_bool_and_null_scalars() @test => @pool() {
  XMLSerializer s = xml::serializer();
  s.serialize_bool(true)!!;
  test::eq(s.result(), "true");

  XMLSerializer s2 = xml::serializer();
  s2.serialize_null()!!;
  test::eq(s2.result(), "null");
}

fn void test_xml_pretty_string_indents() @test => @pool() {
  String flat = xml_of((XBookAuthored) { .title = "C3", .author = { .name = "ann" } });
  String pretty = xml::pretty_string(flat);
  String expected =
`<xbookauthored>
  <title>C3</title>
  <author>
    <xauthor>
      <name>ann</name>
    </xauthor>
  </author>
</xbookauthored>
`;
  test::eq(pretty, expected);
}
