module serialize_test @test;
import std;
import dessert;
import json;
import csv;

// ── Test types ───────────────────────────────────────────────────────────────

$expand(dessert::@derive(SPoint));
struct SPoint {
  int x;
  int y;
}

$expand(dessert::@derive(SBox));
struct SBox {
  String label;
  SPoint center;
}

$expand(dessert::@derive(SWithPointer, serialize));
struct SWithPointer {
  String name;
  SPoint* extra;
}

$expand(dessert::@derive(SWithArray, serialize));
struct SWithArray {
  String tag;
  SPoint[] items;
}

$expand(dessert::@derive(SSkipField, serialize));
struct SSkipField {
  String kept;
  String secret   @DField({ .skip = true });
  int    internal @DField({ .skip = true });
}
$expand(dessert::@derive(SRenamedField, serialize));
struct SRenamedField {
  String original @DField({ .rename = "alias" });
  int    count    @DField({ .rename = "num" });
}
$expand(dessert::@derive(SSkipIfEmpty, serialize));
struct SSkipIfEmpty {
  String  always;
  String  maybe_str @DField({ .skip_if_empty = true });
  SPoint* maybe_ptr @DField({ .skip_if_empty = true });
  SPoint[] maybe_arr @DField({ .skip_if_empty = true });
}
$expand(dessert::@derive(SConditional, serialize));
struct SConditional {
  String name;
  int    score;
}
fn bool SConditional.skip_serializing_score(&self) => self.score < 0;

// Default: serialize enum variants by name
$expand(dessert::@derive(SDirection, serialize));
enum SDirection {
  NORTH,
  SOUTH,
  EAST,
  WEST,
}
// Serialize enum variants by ordinal (0, 1, 2, ...)
$expand(dessert::@derive(SRank, serialize));
enum SRank @DEnum({ .as = ORDINAL }) {
  BRONZE,
  SILVER,
  GOLD,
}
// Serialize enum via an associated field value
$expand(dessert::@derive(SColor, serialize));
enum SColor : (String hex) @DEnum({ .as = FIELD, .field = "hex" }) {
  RED   { "#FF0000" },
  GREEN { "#00FF00" },
  BLUE  { "#0000FF" },
}
$expand(dessert::@derive(SWithMaybe, serialize));
struct SWithMaybe {
  String    name;
  Maybe{int} opt;
}
$expand(dessert::@derive(SWithValidator, serialize));
struct SWithValidator {
  String name @DField({ .validator = "validate_name" });
}
fn bool SWithValidator.validate_name(&self, String name) => name.len > 0;

$expand(dessert::@derive(SWeatherRow, serialize));
struct SWeatherRow {
  String city;
  double temp;
  bool   sunny;
}
// ── Tests: JSON primitives ────────────────────────────────────────────────────

fn void test_ser_bool_true() @test {
  JsonSerializer s = json::serializer();
  s.serialize_bool(true)!!;
  JsonValue j = s.result()!!;
  assert(j.kind == JsonValueKind.BOOL);
  assert(j.value.b == true);
}

fn void test_ser_bool_false() @test {
  JsonSerializer s = json::serializer();
  s.serialize_bool(false)!!;
  JsonValue j = s.result()!!;
  assert(j.kind == JsonValueKind.BOOL);
  assert(j.value.b == false);
}

fn void test_ser_null() @test {
  JsonSerializer s = json::serializer();
  s.serialize_null()!!;
  JsonValue j = s.result()!!;
  assert(j.kind == JsonValueKind.NULL);
}

fn void test_ser_long_positive() @test {
  JsonSerializer s = json::serializer();
  s.serialize_long(12345)!!;
  JsonValue j = s.result()!!;
  assert(j.kind == JsonValueKind.INT);
  assert(j.value.i == 12345);
}

fn void test_ser_long_negative() @test {
  JsonSerializer s = json::serializer();
  s.serialize_long(-999)!!;
  JsonValue j = s.result()!!;
  assert(j.kind == JsonValueKind.INT);
  assert(j.value.i == -999);
}

fn void test_ser_double() @test {
  JsonSerializer s = json::serializer();
  s.serialize_double(3.14)!!;
  JsonValue j = s.result()!!;
  assert(j.kind == JsonValueKind.FLOAT);
  double diff = j.value.f - 3.14;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_ser_string() @test {
  JsonSerializer s = json::serializer();
  s.serialize_string("hello world")!!;
  JsonValue j = s.result()!!;
  assert(j.kind == JsonValueKind.STRING);
  assert(j.value.s == "hello world");
}

// to_string() must escape embedded quotes so the output is valid JSON
fn void test_ser_string_with_quotes() @test {
  JsonSerializer s = json::serializer();
  s.serialize_string(`say "hi"`)!!;
  JsonValue j = s.result()!!;
  String out = j.to_string()!!;
  // the outer quotes + escaped inner quotes must be in the output
  assert(out == `"say \"hi\""`);
}

// ── Tests: struct serialization ───────────────────────────────────────────────

fn void test_ser_simple_struct() @test {
  SPoint p = { .x = 3, .y = -7 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, p)!!;
  defer j.free();

  assert(j.kind == JsonValueKind.DICT);
  assert(j.value.d.get("x")!!.value.i == 3);
  assert(j.value.d.get("y")!!.value.i == -7);
}

fn void test_ser_nested_struct() @test {
  SBox b = { .label = "outer", .center = { .x = 10, .y = 20 } };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, b)!!;
  defer j.free();

  assert(j.kind == JsonValueKind.DICT);
  assert(j.value.d.get("label")!!.value.s == "outer");
  JsonValue center = j.value.d.get("center")!!;
  assert(center.kind == JsonValueKind.DICT);
  assert(center.value.d.get("x")!!.value.i == 10);
  assert(center.value.d.get("y")!!.value.i == 20);
}

fn void test_ser_null_pointer() @test {
  SWithPointer wp = { .name = "no-extra", .extra = null };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, wp)!!;
  defer j.free();

  assert(j.value.d.get("extra")!!.kind == JsonValueKind.NULL);
}

fn void test_ser_non_null_pointer() @test {
  SPoint pt = { .x = 5, .y = 9 };
  SWithPointer wp = { .name = "with-extra", .extra = &pt };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, wp)!!;
  defer j.free();

  JsonValue extra = j.value.d.get("extra")!!;
  assert(extra.kind == JsonValueKind.DICT);
  assert(extra.value.d.get("x")!!.value.i == 5);
  assert(extra.value.d.get("y")!!.value.i == 9);
}

fn void test_ser_array() @test {
  SPoint[3] pts = { { .x = 1, .y = 2 }, { .x = 3, .y = 4 }, { .x = 5, .y = 6 } };
  SWithArray wa = { .tag = "list", .items = pts[..] };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, wa)!!;
  defer j.free();

  JsonValue items = j.value.d.get("items")!!;
  assert(items.kind == JsonValueKind.ARRAY);
  assert(items.value.l.len() == 3);
  assert(items.value.l[0].value.d.get("x")!!.value.i == 1);
  assert(items.value.l[1].value.d.get("x")!!.value.i == 3);
  assert(items.value.l[2].value.d.get("x")!!.value.i == 5);
}

fn void test_ser_empty_array() @test {
  SWithArray wa = { .tag = "empty", .items = {} };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, wa)!!;
  defer j.free();

  JsonValue items = j.value.d.get("items")!!;
  assert(items.kind == JsonValueKind.ARRAY);
  assert(items.value.l.len() == 0);
}

// ── Tests: attributes ─────────────────────────────────────────────────────────

fn void test_ser_skip_field() @test {
  SSkipField sf = { .kept = "visible", .secret = "hidden", .internal = 42 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, sf)!!;
  defer j.free();

  assert(j.value.d.get("kept")!!.value.s == "visible");
  // skipped fields must not appear in the output
  if (catch j.value.d.get("secret"))   { /* absent: correct */ } else { assert(false); }
  if (catch j.value.d.get("internal")) { /* absent: correct */ } else { assert(false); }
}

fn void test_ser_rename() @test {
  SRenamedField rf = { .original = "hello", .count = 3 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, rf)!!;
  defer j.free();

  // original names must not appear
  if (catch j.value.d.get("original")) { /* correct */ } else { assert(false); }
  if (catch j.value.d.get("count"))    { /* correct */ } else { assert(false); }
  // renamed keys must appear with the right values
  assert(j.value.d.get("alias")!!.value.s == "hello");
  assert(j.value.d.get("num")!!.value.i   == 3);
}

fn void test_ser_skip_if_empty_all_empty() @test {
  // empty string, null pointer, empty slice → all three optional fields absent
  SSkipIfEmpty se = { .always = "present", .maybe_str = "", .maybe_ptr = null };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, se)!!;
  defer j.free();

  assert(j.value.d.get("always")!!.value.s == "present");
  if (catch j.value.d.get("maybe_str")) { /* absent: correct */ } else { assert(false); }
  if (catch j.value.d.get("maybe_ptr")) { /* absent: correct */ } else { assert(false); }
  if (catch j.value.d.get("maybe_arr")) { /* absent: correct */ } else { assert(false); }
}

fn void test_ser_skip_if_empty_non_empty() @test {
  SPoint pt = { .x = 1, .y = 2 };
  SPoint[1] pts = { pt };
  SSkipIfEmpty se = {
    .always    = "x",
    .maybe_str = "filled",
    .maybe_ptr = &pt,
    .maybe_arr = pts[..],
  };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, se)!!;
  defer j.free();

  assert(j.value.d.get("maybe_str")!!.value.s == "filled");
  assert(j.value.d.get("maybe_ptr")!!.kind == JsonValueKind.DICT);
  assert(j.value.d.get("maybe_arr")!!.kind == JsonValueKind.ARRAY);
}

fn void test_ser_conditional_skip_true() @test {
  // score < 0: skip_serializing_score returns true → field absent
  SConditional c = { .name = "alice", .score = -1 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, c)!!;
  defer j.free();

  assert(j.value.d.get("name")!!.value.s == "alice");
  if (catch j.value.d.get("score")) { /* absent: correct */ } else { assert(false); }
}

fn void test_ser_conditional_skip_false() @test {
  // score >= 0: skip_serializing_score returns false → field present
  SConditional c = { .name = "bob", .score = 99 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, c)!!;
  defer j.free();

  assert(j.value.d.get("score")!!.value.i == 99);
}

// ── Tests: enum serialization ─────────────────────────────────────────────────

fn void test_ser_enum_name() @test {
  // default behavior: serialize as the variant name string
  SDirection d = SDirection.EAST;
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, d)!!;
  assert(j.kind == JsonValueKind.STRING);
  assert(j.value.s == "EAST");
}

fn void test_ser_enum_all_names() @test {
  SDirection[4] dirs = { SDirection.NORTH, SDirection.SOUTH, SDirection.EAST, SDirection.WEST };
  String[4] expected = { "NORTH", "SOUTH", "EAST", "WEST" };
  foreach (i, d : dirs) {
    JsonSerializer s = json::serializer();
    JsonValue j = ser::serialize(&s, d)!!;
    assert(j.kind == JsonValueKind.STRING);
    assert(j.value.s == expected[i]);
  }
}

fn void test_ser_enum_ordinal() @test {
  // BRONZE=0, SILVER=1, GOLD=2
  JsonSerializer s0 = json::serializer();
  JsonSerializer s1 = json::serializer();
  JsonSerializer s2 = json::serializer();
  JsonValue j0 = ser::serialize(&s0, SRank.BRONZE)!!;
  JsonValue j1 = ser::serialize(&s1, SRank.SILVER)!!;
  JsonValue j2 = ser::serialize(&s2, SRank.GOLD)!!;

  assert(j0.kind == JsonValueKind.INT && j0.value.i == 0);
  assert(j1.kind == JsonValueKind.INT && j1.value.i == 1);
  assert(j2.kind == JsonValueKind.INT && j2.value.i == 2);
}

fn void test_ser_enum_field() @test {
  // serialize via associated field "hex"
  JsonSerializer sr = json::serializer();
  JsonSerializer sg = json::serializer();
  JsonSerializer sb = json::serializer();
  JsonValue jr = ser::serialize(&sr, SColor.RED)!!;
  JsonValue jg = ser::serialize(&sg, SColor.GREEN)!!;
  JsonValue jb = ser::serialize(&sb, SColor.BLUE)!!;

  assert(jr.kind == JsonValueKind.STRING && jr.value.s == "#FF0000");
  assert(jg.kind == JsonValueKind.STRING && jg.value.s == "#00FF00");
  assert(jb.kind == JsonValueKind.STRING && jb.value.s == "#0000FF");
}

// ── Tests: Maybe ──────────────────────────────────────────────────────────────

fn void test_ser_maybe_empty() @test {
  SWithMaybe wm = { .name = "empty", .opt = {} };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, wm)!!;
  defer j.free();

  assert(j.value.d.get("opt")!!.kind == JsonValueKind.NULL);
}

fn void test_ser_maybe_value() @test {
  SWithMaybe wm = { .name = "full", .opt = maybe::value{int}(42) };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, wm)!!;
  defer j.free();

  JsonValue opt = j.value.d.get("opt")!!;
  assert(opt.kind == JsonValueKind.INT);
  assert(opt.value.i == 42);
}

// ── Tests: validator ──────────────────────────────────────────────────────────

fn void test_ser_validator_pass() @test {
  SWithValidator wv = { .name = "valid-name" };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, wv)!!;
  defer j.free();

  assert(j.value.d.get("name")!!.value.s == "valid-name");
}

fn void test_ser_validator_fail() @test {
  // empty name fails the validator → VALIDATOR_ERROR
  SWithValidator wv = { .name = "" };
  JsonSerializer s = json::serializer();
  JsonValue? j = ser::serialize(&s, wv);
  if (catch err = j) {
    assert(err == ser::VALIDATOR_ERROR);
  } else {
    assert(false); // must have faulted
  }
}

// ── Tests: CSV serialization ──────────────────────────────────────────────────

fn void test_ser_csv_columns() @test {
  SWeatherRow[2] rows = {
    { .city = "Paris",  .temp = 15.5, .sunny = true  },
    { .city = "Berlin", .temp =  8.0, .sunny = false },
  };
  CSVSerializer s = csv::serializer();
  CSVDocument doc = ser::serialize(&s, rows)!!;

  // three columns: city, temp, sunny
  assert(doc.len() == 3);
  // each column has exactly two rows
  assert(doc.get("city")!!.len()  == 2);
  assert(doc.get("temp")!!.len()  == 2);
  assert(doc.get("sunny")!!.len() == 2);
}

fn void test_ser_csv_values() @test {
  SWeatherRow[2] rows = {
    { .city = "Lyon",  .temp = 22.0, .sunny = true  },
    { .city = "Nice",  .temp = 27.5, .sunny = true  },
  };
  CSVSerializer s = csv::serializer();
  CSVDocument doc = ser::serialize(&s, rows)!!;

  CSVValueList cities = doc.get("city")!!;
  assert(cities[0].kind == CSVValueKind.STRING && cities[0].value.s == "Lyon");
  assert(cities[1].kind == CSVValueKind.STRING && cities[1].value.s == "Nice");

  CSVValueList temps = doc.get("temp")!!;
  assert(temps[0].kind == CSVValueKind.FLOAT);
  assert(temps[1].kind == CSVValueKind.FLOAT);

  CSVValueList sunny = doc.get("sunny")!!;
  assert(sunny[0].kind == CSVValueKind.BOOL && sunny[0].value.b == true);
  assert(sunny[1].kind == CSVValueKind.BOOL && sunny[1].value.b == true);
}

// ── Tests: inline sub-struct ──────────────────────────────────────────────────

$expand(dessert::@derive(SWithInlineSub, serialize));
struct SWithInlineSub {
  int id;
  struct pos { 
    int x;
    int y; 
  }
}
$expand(dessert::@derive(SWithFlatSub, serialize));
struct SWithFlatSub {
  int id;
  struct pos @DField({ .flatten = true }) { 
    int x;
    int y; 
  }
}
fn void test_ser_inline_substruct_nested() @test {
  SWithInlineSub s = { .id = 7, .pos = { .x = 3, .y = -4 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.kind == JsonValueKind.DICT);
  assert(j.value.d.get("id")!!.value.i == 7);
  JsonValue pos = j.value.d.get("pos")!!;
  assert(pos.kind == JsonValueKind.DICT);
  assert(pos.value.d.get("x")!!.value.i == 3);
  assert(pos.value.d.get("y")!!.value.i == -4);
}

fn void test_ser_inline_substruct_flatten() @test {
  SWithFlatSub s = { .id = 1, .pos = { .x = 10, .y = 20 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("id")!!.value.i == 1);
  assert(j.value.d.get("x")!!.value.i == 10);
  assert(j.value.d.get("y")!!.value.i == 20);
  if (catch j.value.d.get("pos")) { /* correct: key absent */ } else { assert(false); }
}

// ── Tests: union (custom serialize) ──────────────────────────────────────────

union SUVariant {
  long i;
  double f;
}

$expand(dessert::@derive(STaggedUnion, serialize));
struct STaggedUnion {
  int       tag;
  SUVariant val @DField({ .tagged = { .by = "tag", .inlined = true } });
}
fn void test_ser_union_field() @test {
  STaggedUnion tu = { .tag = 0, .val = { .i = 42 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, tu)!!;
  defer j.free();

  assert(j.kind == JsonValueKind.DICT);
  assert(j.value.d.get("tag")!!.value.i == 0);
  assert(j.value.d.get("val")!!.kind == JsonValueKind.INT);
  assert(j.value.d.get("val")!!.value.i == 42);
}

fn void test_ser_union_negative_value() @test {
  STaggedUnion tu = { .tag = 0, .val = { .i = -999 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, tu)!!;
  defer j.free();

  assert(j.value.d.get("val")!!.value.i == -999);
}

// ── Tests: @DField tagged union (named) ──────────────────────────────────────

$expand(dessert::@derive(SDUnionNamed, serialize));
struct SDUnionNamed {
  int kind;
  union p @DField({ .tagged = { .by = "kind" } }) {
    int    first;
    double second;
    String third;
  }
}
fn void test_ser_dunion_named_first() @test {
  // kind=0 → serialize p.first
  SDUnionNamed s = { .kind = 0, .p = { .first = 42 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.kind == JsonValueKind.DICT);
  assert(j.value.d.get("kind")!!.value.i == 0);
  JsonValue p = j.value.d.get("p")!!;
  assert(p.kind == JsonValueKind.DICT);
  assert(p.value.d.get("first")!!.kind == JsonValueKind.INT);
  assert(p.value.d.get("first")!!.value.i == 42);
}

fn void test_ser_dunion_named_second() @test {
  // kind=1 → serialize p.second
  SDUnionNamed s = { .kind = 1, .p = { .second = 3.14 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  JsonValue p = j.value.d.get("p")!!;
  assert(p.kind == JsonValueKind.DICT);
  assert(p.value.d.get("second")!!.kind == JsonValueKind.FLOAT);
  double diff = p.value.d.get("second")!!.value.f - 3.14;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_ser_dunion_named_third() @test {
  // kind=2 → serialize p.third (String)
  SDUnionNamed s = { .kind = 2, .p = { .third = "hello" } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  JsonValue p = j.value.d.get("p")!!;
  assert(p.kind == JsonValueKind.DICT);
  assert(p.value.d.get("third")!!.kind == JsonValueKind.STRING);
  assert(p.value.d.get("third")!!.value.s == "hello");
}

fn void test_ser_dunion_named_only_active_member() @test {
  // only the active member key must appear in "p"
  SDUnionNamed s = { .kind = 0, .p = { .first = 1 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  JsonValue p = j.value.d.get("p")!!;
  if (catch p.value.d.get("second")) { /* correct: absent */ } else { assert(false); }
  if (catch p.value.d.get("third"))  { /* correct: absent */ } else { assert(false); }
}

// ── Tests: @DField anonymous union (flattened) ────────────────────────────────

$expand(dessert::@derive(SDUnionAnon, serialize));
struct SDUnionAnon {
  int kind;
  union @DField({ .tagged = { .by = "kind" } }) {
    int    foo;
    double bar;
  }
}
fn void test_ser_dunion_anon_first() @test {
  // kind=0 → foo appears as top-level field
  SDUnionAnon s = { .kind = 0, .foo = 99 };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.i == 0);
  assert(j.value.d.get("foo")!!.kind == JsonValueKind.INT);
  assert(j.value.d.get("foo")!!.value.i == 99);
  // "bar" must not appear
  if (catch j.value.d.get("bar")) { /* correct */ } else { assert(false); }
}

fn void test_ser_dunion_anon_second() @test {
  // kind=1 → bar appears as top-level field
  SDUnionAnon s = { .kind = 1, .bar = 2.5 };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("bar")!!.kind == JsonValueKind.FLOAT);
  double diff = j.value.d.get("bar")!!.value.f - 2.5;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
  // "foo" must not appear
  if (catch j.value.d.get("foo")) { /* correct */ } else { assert(false); }
}

// ── Tests: rename_all = CAMEL_CASE ───────────────────────────────────────────

$expand(dessert::@derive(SCamelCase, serialize));
struct SCamelCase @DStructSer({ .rename_all = CAMEL_CASE }) {
  String first_name;
  String last_name;
  int    birth_year;
}
fn void test_ser_camel_case() @test {
  SCamelCase s = { .first_name = "John", .last_name = "Doe", .birth_year = 1990 };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  // snake_case keys must be absent
  if (catch j.value.d.get("first_name")) { /* correct */ } else { assert(false); }
  if (catch j.value.d.get("last_name"))  { /* correct */ } else { assert(false); }
  if (catch j.value.d.get("birth_year")) { /* correct */ } else { assert(false); }
  // camelCase keys must be present with correct values
  assert(j.value.d.get("firstName")!!.value.s == "John");
  assert(j.value.d.get("lastName")!!.value.s == "Doe");
  assert(j.value.d.get("birthYear")!!.value.i == 1990);
}

// ── Tests: tagged union match.by = ORDINAL (enum tag) ────────────────────────
// ORDINAL: enum ordinal (0-based) selects the active union member by index.
// Tag enum serializes as its description string (default). Named inlined union:
// JSON key = union field name ("payload"), value = active member value directly.

$expand(dessert::@derive(SMBOrdinalTag));
enum SMBOrdinalTag { ORD_FIRST, ORD_SECOND, ORD_THIRD }

$expand(dessert::@derive(SMatchByOrdinal, serialize));
struct SMatchByOrdinal {
  SMBOrdinalTag kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .match = { .by = ORDINAL } } }) {
    int    first;    // selected when kind ordinal == 0 (ORD_FIRST)
    double second;   // selected when kind ordinal == 1 (ORD_SECOND)
    String third;    // selected when kind ordinal == 2 (ORD_THIRD)
  }
}
fn void test_ser_match_by_ordinal_first() @test {
  // ORD_FIRST (ordinal 0) → member[0] = first; output: {"kind":"ORD_FIRST","payload":10}
  SMatchByOrdinal s = { .kind = ORD_FIRST, .payload = { .first = 10 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "ORD_FIRST");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.INT);
  assert(j.value.d.get("payload")!!.value.i == 10);
}

fn void test_ser_match_by_ordinal_second() @test {
  // ORD_SECOND (ordinal 1) → member[1] = second; output: {"kind":"ORD_SECOND","payload":2.5}
  SMatchByOrdinal s = { .kind = ORD_SECOND, .payload = { .second = 2.5 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "ORD_SECOND");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.FLOAT);
  double diff = j.value.d.get("payload")!!.value.f - 2.5;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_ser_match_by_ordinal_third() @test {
  // ORD_THIRD (ordinal 2) → member[2] = third; output: {"kind":"ORD_THIRD","payload":"hello"}
  SMatchByOrdinal s = { .kind = ORD_THIRD, .payload = { .third = "hello" } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "ORD_THIRD");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.STRING);
  assert(j.value.d.get("payload")!!.value.s == "hello");
}

// ── Tests: tagged union match.by = DESCRIPTION (enum tag) ────────────────────
// DESCRIPTION: switch on enum VALUE. Union member names uppercased must match
// enum value names. E.g. member "desc_a" → @str_to_upper → "DESC_A" → case DESC_A.

$expand(dessert::@derive(SMBDescTag));
enum SMBDescTag { DESC_A, DESC_B, DESC_C }

$expand(dessert::@derive(SMatchByDesc, serialize));
struct SMatchByDesc {
  SMBDescTag kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .match = { .by = DESCRIPTION } } }) {
    int    desc_a;   // @str_to_upper("desc_a") = "DESC_A" → case DESC_A
    double desc_b;   // → case DESC_B
    String desc_c;   // → case DESC_C
  }
}
fn void test_ser_match_by_desc_first() @test {
  // DESC_A → case DESC_A → member desc_a; output: {"kind":"DESC_A","payload":42}
  SMatchByDesc s = { .kind = DESC_A, .payload = { .desc_a = 42 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "DESC_A");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.INT);
  assert(j.value.d.get("payload")!!.value.i == 42);
}

fn void test_ser_match_by_desc_second() @test {
  // DESC_B → case DESC_B → member desc_b; output: {"kind":"DESC_B","payload":9.9}
  SMatchByDesc s = { .kind = DESC_B, .payload = { .desc_b = 9.9 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "DESC_B");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.FLOAT);
  double diff = j.value.d.get("payload")!!.value.f - 9.9;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_ser_match_by_desc_third() @test {
  // DESC_C → case DESC_C → member desc_c; output: {"kind":"DESC_C","payload":"world"}
  SMatchByDesc s = { .kind = DESC_C, .payload = { .desc_c = "world" } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "DESC_C");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.STRING);
  assert(j.value.d.get("payload")!!.value.s == "world");
}

// ── Tests: tagged union match.by = FIELD (enum with String associated field) ──
// FIELD: switch on enum.variant (String). Value must equal union member name exactly.
// E.g. FLD_A { "fld_a" } → kind.variant == "fld_a" → case "fld_a" → member fld_a.

$expand(dessert::@derive(SMBFieldTag));
enum SMBFieldTag : (String variant) {
  FLD_A { "fld_a" },
  FLD_B { "fld_b" },
  FLD_C { "fld_c" },
  FLD_D { "fld_d" },
}

$expand(dessert::@derive(SubS));
struct SubS {
  String s;
}

$expand(dessert::@derive(SMatchByField, serialize));
struct SMatchByField {
  SMBFieldTag kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .match = { .by = FIELD, .field = "variant" } } }) {
    int    fld_a;   // matched when kind.variant == "fld_a"
    double fld_b;   // matched when kind.variant == "fld_b"
    struct fld_c {  // matched when kind.variant == "fld_c"
      String s;
    }
    SubS fld_d;     // matched when kind.variant == "fld_d"
  }
}
fn void test_ser_match_by_field_first() @test {
  // FLD_A.variant = "fld_a" → case "fld_a" → member fld_a; output: {"kind":"FLD_A","payload":7}
  SMatchByField s = { .kind = FLD_A, .payload = { .fld_a = 7 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "FLD_A");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.INT);
  assert(j.value.d.get("payload")!!.value.i == 7);
}

fn void test_ser_match_by_field_second() @test {
  // FLD_B.variant = "fld_b" → member fld_b; output: {"kind":"FLD_B","payload":3.14}
  SMatchByField s = { .kind = FLD_B, .payload = { .fld_b = 3.14 } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "FLD_B");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.FLOAT);
  double diff = j.value.d.get("payload")!!.value.f - 3.14;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_ser_match_by_field_third() @test {
  // FLD_C.variant = "fld_c" → member fld_c; output: {"kind":"FLD_C","payload":"test"}
  SMatchByField s = { .kind = FLD_C, .payload = { .fld_c.s = "test" } };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.s == "FLD_C");
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.DICT);
  assert(j.value.d.get("payload").value.d.get("s")!!.value.s == "test");
}

fn void test_ser_match_by_field_forth_string() @test {
  // FLD_C.variant = "fld_c" → member fld_c; output: {"kind":"FLD_C","payload":"test"}
  SMatchByField s = { .kind = FLD_D, .payload = { .fld_d.s = "test" } };
  JsonStringSerializer js = json::string_serializer();
  String j = ser::serialize(&js, s)!!;

  assert(j == `{"kind":"FLD_D","payload":{"s":"test"}}`);
}

// ── Tests: tagged union unmapped.as ─────────────────────────────────────────
// unmapped.as controls behavior when the tag value matches no union member.
// Default (ERROR) → UNMAPPED_UNION_VARIANT fault.
// EMPTY_STRUCT → serialize payload as {}. NULL → null. ZERO → 0.

// Default (no unmapped.as = ERROR): out-of-range kind raises UNMAPPED_UNION_VARIANT
$expand(dessert::@derive(SUnmappedError, serialize));
struct SUnmappedError {
  int kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true } }) {
    int    first;
    double second;
    String third;
  }
}
fn void test_ser_unmapped_as_error() @test {
  SUnmappedError s = { .kind = 99 };   // ordinal 99 doesn't match member 0, 1, or 2
  JsonSerializer js = json::serializer();
  JsonValue? j = ser::serialize(&js, s);
  if (catch err = j) {
    assert(err == ser::UNMAPPED_UNION_VARIANT);
    return;
  }
  assert(false);  // expected UNMAPPED_UNION_VARIANT but no fault was raised
}

// unmapped.as = EMPTY_STRUCT: out-of-range kind → payload serialized as {}
$expand(dessert::@derive(SUnmappedEmptyStruct, serialize));
struct SUnmappedEmptyStruct {
  int kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .unmapped = { .as = EMPTY_STRUCT } } }) {
    int    first;
    double second;
  }
}
fn void test_ser_unmapped_as_empty_struct() @test {
  SUnmappedEmptyStruct s = { .kind = 99 };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.i == 99);
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.DICT);
}

// unmapped.as = NULL: out-of-range kind → payload serialized as null
$expand(dessert::@derive(SUnmappedNull, serialize));
struct SUnmappedNull {
  int kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .unmapped = { .as = NULL } } }) {
    int    first;
    double second;
  }
}
fn void test_ser_unmapped_as_null() @test {
  SUnmappedNull s = { .kind = 99 };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.i == 99);
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.NULL);
}

// unmapped.as = ZERO: out-of-range kind → payload serialized as 0
$expand(dessert::@derive(SUnmappedZero, serialize));
struct SUnmappedZero {
  int kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .unmapped = { .as = ZERO } } }) {
    int    first;
    double second;
  }
}
fn void test_ser_unmapped_as_zero() @test {
  SUnmappedZero s = { .kind = 99 };
  JsonSerializer js = json::serializer();
  JsonValue j = ser::serialize(&js, s)!!;
  defer j.free();

  assert(j.value.d.get("kind")!!.value.i == 99);
  assert(j.value.d.get("payload")!!.kind == JsonValueKind.INT);
  assert(j.value.d.get("payload")!!.value.i == 0);
}

// ── Tests: CSV ───────────────────────────────────────────────────────────────

fn void test_ser_csv_to_string_has_header() @test {
  SWeatherRow[1] rows = { { .city = "Toulouse", .temp = 18.0, .sunny = false } };
  CSVSerializer s = csv::serializer();
  CSVDocument doc = ser::serialize(&s, rows)!!;
  String out = doc.to_string();

  // output must be non-empty and start with a quoted header
  assert(out.len > 0);
  assert(out.starts_with(`"`));
  // all header names present in output
  if (catch out.index_of("city"))  { assert(false); }
  if (catch out.index_of("temp"))  { assert(false); }
  if (catch out.index_of("sunny")) { assert(false); }
  if (catch out.index_of("Toulouse")) { assert(false); }
}

$expand(dessert::@derive(FooWithHashMap, serialize));
struct FooWithHashMap {
  HashMap{String, int} found;
  HashMap{String, SWeatherRow} cities @DField({ .flatten = true });
  String bar;
}

// ── Test: HashMap ───────────────────────────────────────────────────────────────

fn void test_foo_with_hashmap() @test {
  FooWithHashMap f = { .bar = "hello" };
  f.found.tinit();
  f.found.set("bar", 1);
  f.found.set("baz", -2);
  f.found.set("baz", -2);
  f.cities.set("toulouse", { .city = "Toulouse", .temp = 18.0, .sunny = false });

  String output = ser::serialize(&&json::string_serializer(), f)!!;
  assert(output == `{"found":{"baz":-2,"bar":1},"toulouse":{"city":"Toulouse","temp":18.000000,"sunny":false},"bar":"hello"}`);

}

$expand(dessert::@derive(DessertKindKebab));
enum DessertKindKebab @DEnum({ .rename_all = KEBAB_CASE }) {
  BANANA_SPLIT,
  CHOCOLATE_CROISSANT,
  PEACH_COBBLER
}

$expand(dessert::@derive(DessertKindUpper));
enum DessertKindUpper @DEnum({ .rename_all = UPPER_CASE }) {
  BANANA_SPLIT,
  CHOCOLATE_CROISSANT,
  PEACH_COBBLER
}

$expand(dessert::@derive(DessertKindVerbatim));
enum DessertKindVerbatim @DEnum({ .rename_all = VERBATIM }) {
  BANANA_SPLIT,
  CHOCOLATE_CROISSANT,
  PEACH_COBBLER
}

$expand(dessert::@derive(DessertKindCamel));
enum DessertKindCamel @DEnum({ .rename_all = CAMEL_CASE }) {
  BANANA_SPLIT,
  CHOCOLATE_CROISSANT,
  PEACH_COBBLER
}

$expand(dessert::@derive(DessertKindPascal));
enum DessertKindPascal @DEnum({ .rename_all = PASCAL_CASE }) {
  BANANA_SPLIT,
  CHOCOLATE_CROISSANT,
  PEACH_COBBLER
}

$expand(dessert::@derive(DessertKindConstant));
enum DessertKindConstant @DEnum({ .rename_all = CONSTANT_CASE }) {
  BANANA_SPLIT,
  CHOCOLATE_CROISSANT,
  PEACH_COBBLER
}

$expand(dessert::@derive(DessertKindSnake));
enum DessertKindSnake @DEnum({ .rename_all = SNAKE_CASE }) {
  BANANA_SPLIT,
  CHOCOLATE_CROISSANT,
  PEACH_COBBLER
}

$expand(dessert::@derive(DessertKindLower));
enum DessertKindLower @DEnum({ .rename_all = LOWER_CASE }) {
  BANANA_SPLIT,
  CHOCOLATE_CROISSANT,
  PEACH_COBBLER
}

fn void test_enum_rename_all() @test => @pool() {
  String kebab_output = json::string_serialize(tmem, DessertKindKebab.PEACH_COBBLER)!!;
  test::eq(kebab_output, `"peach-cobbler"`);

  String upper_output = json::string_serialize(tmem, DessertKindUpper.PEACH_COBBLER)!!;
  test::eq(upper_output, `"PEACH_COBBLER"`);

  String verbatim_output = json::string_serialize(tmem, DessertKindVerbatim.PEACH_COBBLER)!!;
  test::eq(verbatim_output, `"PEACH_COBBLER"`);

  String camel_output = json::string_serialize(tmem, DessertKindCamel.PEACH_COBBLER)!!;
  test::eq(camel_output, `"peachCobbler"`);

  String pascal_output = json::string_serialize(tmem, DessertKindPascal.PEACH_COBBLER)!!;
  test::eq(pascal_output, `"PeachCobbler"`);

  String constant_output = json::string_serialize(tmem, DessertKindConstant.PEACH_COBBLER)!!;
  test::eq(constant_output, `"PEACH_COBBLER"`);

  String snake_output = json::string_serialize(tmem, DessertKindSnake.PEACH_COBBLER)!!;
  test::eq(snake_output, `"peach_cobbler"`);

  String lower_output = json::string_serialize(tmem, DessertKindLower.PEACH_COBBLER)!!;
  test::eq(lower_output, `"peach_cobbler"`);
}

// ── Manual serialize_<field> methods ─────────────────────────────────────────
// A `serialize_<field>` method takes over emitting the value for that one field.
// The derived serializer still writes the key and delimiters around it.

$expand(dessert::@derive(SManualField, serialize));
struct SManualField {
  String name;
  int    secret;
}
// `secret` is emitted as a masked string instead of its numeric value.
fn void? SManualField.serialize_secret(&self, Serializer ser) {
  ser.serialize_string("***")!;
}

$expand(dessert::@derive(SManualDerived, serialize));
struct SManualDerived {
  String first;
  String last;
  String full;
}
// A manual method can read the rest of `self` to build the emitted value; the
// stored `full` field is ignored in favour of the computed one.
fn String? SManualDerived.serialize_full(&self, Serializer ser) {
  return string::tformat("%s %s", self.first, self.last);
}

fn void test_ser_manual_field_overrides_value() @test {
  SManualField v = { .name = "alice", .secret = 42 };
  String out = json::string_serialize(tmem, v)!!;
  test::eq(out, `{"name":"alice","secret":"***"}`);
}

fn void test_ser_manual_field_uses_self() @test {
  SManualDerived v = { .first = "Ada", .last = "Lovelace", .full = "ignored" };
  String out = json::string_serialize(tmem, v)!!;
  test::eq(out, `{"first":"Ada","last":"Lovelace","full":"Ada Lovelace"}`);
}

// The same manual method also feeds the JsonValue (tree) serializer, since it is
// written against the `Serializer` interface rather than a concrete format.
fn void test_ser_manual_field_via_tree() @test {
  SManualField v = { .name = "bob", .secret = 7 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, v)!!;
  defer j.free();

  assert(j.value.d.get("name")!!.value.s == "bob");
  assert(j.value.d.get("secret")!!.value.s == "***");
}

// ── Tests: Object* (dynamically typed values) ────────────────────────────────
// `Object.serialize` is the mirror of the deserializer's `next_any`: the shape
// is only known at runtime, so it drives the serializer events itself.

$expand(dessert::@derive(SWithObject, serialize));
struct SWithObject {
  String  name;
  Object* payload;
}

fn void test_ser_object_scalars() @test => @pool() {
  test::eq(json::tstring_serialize(object::new_string(tmem, "hello"))!!, `"hello"`);
  test::eq(json::tstring_serialize(object::new_int(tmem, 42))!!, "42");
  test::eq(json::tstring_serialize(object::new_int(tmem, -7))!!, "-7");
  test::eq(json::tstring_serialize(object::new_float(tmem, 1.5))!!, "1.500000");
  test::eq(json::tstring_serialize(object::new_bool(true))!!, "true");
  test::eq(json::tstring_serialize(object::new_bool(false))!!, "false");
  test::eq(json::tstring_serialize(object::new_null())!!, "null");
}

fn void test_ser_object_empty_map() @test => @pool() {
  // `new_obj` has type `void` until a key is set: an empty object, not null
  test::eq(json::tstring_serialize(object::new_obj(tmem))!!, "{}");
}

fn void test_ser_object_map() @test => @pool() {
  Object* obj = object::new_obj(tmem);
  obj.set("name", "Sharpie");
  test::eq(json::tstring_serialize(obj)!!, `{"name":"Sharpie"}`);
}

fn void test_ser_object_array() @test => @pool() {
  Object* arr = object::new_array(tmem);
  arr.push(1);
  arr.push("two");
  arr.push(true);
  test::eq(json::tstring_serialize(arr)!!, `[1,"two",true]`);
}

fn void test_ser_object_empty_array() @test => @pool() {
  test::eq(json::tstring_serialize(object::new_array(tmem))!!, "[]");
}

fn void test_ser_object_nested() @test => @pool() {
  Object* root  = object::new_obj(tmem);
  Object* inner = object::new_obj(tmem);
  inner.set("d", "x");
  Object* arr = object::new_array(tmem);
  arr.push(inner);
  root.set("c", arr);
  test::eq(json::tstring_serialize(root)!!, `{"c":[{"d":"x"}]}`);
}

fn void test_ser_object_field_in_struct() @test => @pool() {
  Object* payload = object::new_obj(tmem);
  payload.set("id", 7);
  SWithObject v = { .name = "bob", .payload = payload };
  test::eq(json::tstring_serialize(v)!!, `{"name":"bob","payload":{"id":7}}`);
}

fn void test_ser_object_null_field_in_struct() @test => @pool() {
  SWithObject v = { .name = "bob", .payload = null };
  test::eq(json::tstring_serialize(v)!!, `{"name":"bob","payload":null}`);
}

fn void test_ser_object_roundtrip() @test => @pool() {
  // parse into an Object*, then write it back out unchanged. `next_any` stores
  // every JSON number as a float, so numbers come back in double formatting
  // (`1` would be written back as `1.000000`).
  const String JSON = `{"c":[1.500000,"two",{"d":null},true]}`;
  Object* obj = json::tdeserialize{Object*}(JSON)!!;
  test::eq(json::tstring_serialize(obj)!!, JSON);
}

fn void test_ser_object_via_tree_serializer() @test => @pool() {
  // the same events also feed the JsonValue (tree) serializer
  Object* obj = object::new_obj(tmem);
  obj.set("n", 3);
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, obj)!!;
  defer j.free();

  assert(j.kind == JsonValueKind.DICT);
  assert(j.value.d.get("n")!!.value.i == 3);
}
