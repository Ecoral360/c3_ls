// Tests for the CSV serializer (`dessert::format::csv`, reachable as `csv::`).
// CSV is serialize-only: a slice of structs becomes a `CSVDocument` (an ordered
// map of column name -> column values) whose `.to_string()` renders the table.
module csv_test @test;
import std;
import dessert;
import csv;

// ── Test types ───────────────────────────────────────────────────────────────

$expand(dessert::@derive(CRow, serialize));
struct CRow {
  int    id;
  String name;
  bool   active;
}

$expand(dessert::@derive(CMeasure, serialize));
struct CMeasure {
  String city;
  double temp;
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn void test_csv_document_shape() @test => @pool() {
  CRow[2] rows = {
    { .id = 1, .name = "alice", .active = true },
    { .id = 2, .name = "bob",   .active = false },
  };
  CSVSerializer s = csv::serializer();
  CSVDocument doc = ser::serialize(&s, rows)!!;

  // One column per field, in declaration order.
  test::eq(doc.len(), 3);
  test::@check(doc.has_key("id") && doc.has_key("name") && doc.has_key("active"));

  // Columns are keyed by field name; each holds one value per row.
  List{CSVValue} names = doc.get("name")!!;
  test::eq(names.len(), 2);
  test::eq(names[0].value.s, "alice");
  test::eq(names[1].value.s, "bob");

  List{CSVValue} ids = doc.get("id")!!;
  test::eq(ids[0].value.i, 1);
  test::eq(ids[1].value.i, 2);

  List{CSVValue} active = doc.get("active")!!;
  test::eq(active[0].value.b, true);
  test::eq(active[1].value.b, false);
}

fn void test_csv_to_string_exact() @test => @pool() {
  CRow[2] rows = {
    { .id = 1, .name = "alice", .active = true },
    { .id = 2, .name = "bob",   .active = false },
  };
  CSVSerializer s = csv::serializer();
  CSVDocument doc = ser::serialize(&s, rows)!!;

  // Header row, then one line per record; strings quoted, scalars bare.
  // Raw multi-line literal: embedded newlines and quotes are verbatim.
  String expected = `"id","name","active"
1,"alice",true
2,"bob",false
`;
  test::eq(doc.to_string(), expected);
}

fn void test_csv_quotes_are_escaped() @test => @pool() {
  // Embedded double quotes in a string cell must be backslash-escaped.
  CRow[1] rows = { { .id = 7, .name = `sa"y`, .active = true } };
  CSVSerializer s = csv::serializer();
  CSVDocument doc = ser::serialize(&s, rows)!!;

  String expected = `"id","name","active"
7,"sa\"y",true
`;
  test::eq(doc.to_string(), expected);
}

fn void test_csv_single_row() @test => @pool() {
  CRow[1] rows = { { .id = 42, .name = "solo", .active = false } };
  CSVSerializer s = csv::serializer();
  CSVDocument doc = ser::serialize(&s, rows)!!;

  List{CSVValue} ids = doc.get("id")!!;
  test::eq(ids.len(), 1);
  test::eq(ids[0].value.i, 42);
}

fn void test_csv_float_column() @test => @pool() {
  CMeasure[2] rows = {
    { .city = "Paris", .temp = -3.5 },
    { .city = "Nice",  .temp = 15.0 },
  };
  CSVSerializer s = csv::serializer();
  CSVDocument doc = ser::serialize(&s, rows)!!;

  List{CSVValue} temps = doc.get("temp")!!;
  test::eq(temps[0].kind, CSVValueKind.FLOAT);
  test::eq_approx(temps[0].value.f, -3.5);
  test::eq_approx(temps[1].value.f, 15.0);

  // Float cells are rendered unquoted in the text output.
  test::@check(doc.to_string().contains("-3.5"));
}
