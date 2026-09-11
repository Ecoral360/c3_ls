module deserialize_test @test;
import std;
import dessert;
import json;

// ── Test types ───────────────────────────────────────────────────────────────

$expand(dessert::@derive(DPoint));
struct DPoint {
  int x;
  int y;
}

$expand(dessert::@derive(DBox, deserialize));
struct DBox {
  String label;
  DPoint center;
}

$expand(dessert::@derive(DWithPointer, deserialize));
struct DWithPointer {
  String name;
  DPoint* extra;
}

$expand(dessert::@derive(DWithArray, deserialize));
struct DWithArray {
  String  tag;
  DPoint[] items;
}

// skip=true on des: JSON field is consumed but not assigned to the struct field
$expand(dessert::@derive(DWithSkipDes, deserialize));
struct DWithSkipDes {
  String kept;
  String dropped @DFieldDes({ .skip = true });
}

// rename: JSON key "alias" maps to field "original"
$expand(dessert::@derive(DWithRenameDes, deserialize));
struct DWithRenameDes {
  String original @DFieldDes({ .rename = "alias" });
  int    count    @DFieldDes({ .rename = "num" });
}

// deny_unknown_fields: error on unexpected JSON keys
$expand(dessert::@derive(DDenyUnknown, deserialize));
struct DDenyUnknown @DStruct({ .deny_unknown_fields = true }) {
  String name;
  int    value;
}

// Struct for duplicate key test
$expand(dessert::@derive(DDupCheck, deserialize));
struct DDupCheck @DStruct({ .deny_dup_keys = true }) {
  String name;
  int    age;
}

// Default enum: serialize / deserialize by variant name
$expand(dessert::@derive(DDirection, deserialize));
enum DDirection {
  NORTH,
  SOUTH,
  EAST,
  WEST,
}

$expand(dessert::@derive(DWithDirection, deserialize));
struct DWithDirection {
  String     label;
  DDirection dir;
}

// Ordinal enum: deserialize from integer position
$expand(dessert::@derive(DRank, deserialize));
enum DRank @DEnum({ .as = ORDINAL }) {
  BRONZE,
  SILVER,
  GOLD,
}

$expand(dessert::@derive(DWithRank, deserialize));
struct DWithRank {
  String label;
  DRank  rank;
}

// Field enum: deserialize by matching an associated field value
$expand(dessert::@derive(DColor, deserialize));
enum DColor : (String hex) @DEnum({ .as = FIELD, .field = "hex" }) {
  RED   { "#FF0000" },
  GREEN { "#00FF00" },
  BLUE  { "#0000FF" },
}

$expand(dessert::@derive(DWithColor, deserialize));
struct DWithColor {
  String label;
  DColor color;
}

// Invalid enum (no such variant) → INVALID_ENUM_VALUE
$expand(dessert::@derive(DWithDirInvalid, deserialize));
struct DWithDirInvalid {
  DDirection dir;
}

// Fallback enum (DESCRIPTION mode): unknown variant → fallback value
$expand(dessert::@derive(DStatus, deserialize));
enum DStatus @DEnumDes({ .fallback = "UNKNOWN" }) {
  ACTIVE,
  INACTIVE,
  UNKNOWN,
}

$expand(dessert::@derive(DWithStatus, deserialize));
struct DWithStatus {
  String  label;
  DStatus status;
}

// Fallback enum (FIELD mode): unknown field value → fallback value
$expand(dessert::@derive(DPriority, deserialize));
enum DPriority : (String code) @DEnumDes({ .as = FIELD, .field = "code", .fallback = "NONE" }) {
  HIGH   { "high"   },
  MEDIUM { "medium" },
  NONE   { ""       },
}

$expand(dessert::@derive(DWithPriority, deserialize));
struct DWithPriority {
  String    label;
  DPriority priority;
}

// Maybe field
$expand(dessert::@derive(DWithMaybe, deserialize));
struct DWithMaybe {
  String    name;
  Maybe{int} opt;
}

// Full struct for roundtrip testing (needs both ser + des)
$expand(dessert::@derive(DFull));
struct DFull {
  String name;
  int    age;
  bool   active;
  double score;
}

$expand(dessert::@derive(DComplex));
struct DComplex {
  String   title;
  DPoint   origin;
  DPoint[] path;
  DPoint*  target;
}

// ── Tests: JSON primitives ────────────────────────────────────────────────────

fn void test_des_bool_true() @test => @pool()  {
  bool v = des::deserialize{bool}(&&json::tdeserializer("true"))!!;
  assert(v == true);
}

fn void test_des_bool_false() @test => @pool()  {
  bool v = des::deserialize{bool}(&&json::tdeserializer("false"))!!;
  assert(v == false);
}

fn void test_des_long_positive() @test => @pool()  {
  long v = des::deserialize{long}(&&json::tdeserializer("42"))!!;
  assert(v == 42);
}

fn void test_des_long_negative() @test => @pool()  {
  long v = des::deserialize{long}(&&json::tdeserializer("-100"))!!;
  assert(v == -100);
}

fn void test_des_double() @test => @pool()  {
  double v = des::deserialize{double}(&&json::tdeserializer("2.718"))!!;
  double diff = v - 2.718;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_des_string() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`"hello"`))!!;
  assert(v == "hello");
}

fn void test_des_empty_string() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`""`))!!;
  assert(v.len == 0);
}

// ── Tests: JSON escape sequences in strings ───────────────────────────────────

fn void test_des_escape_newline() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`"line1\nline2"`))!!;
  assert(v.len == 11); // "line1" + '\n' + "line2"
  assert(v[5] == '\n');
}

fn void test_des_escape_tab() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`"col1\tcol2"`))!!;
  assert(v[4] == '\t');
}

fn void test_des_escape_backslash() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`"a\\b"`))!!;
  assert(v == `a\b`);
}

fn void test_des_escape_quote() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`"say \"hi\""`) )!!;
  assert(v == `say "hi"`);
}

fn void test_des_escape_carriage_return() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`"a\rb"`))!!;
  assert(v[1] == '\r');
}

// ── Tests: struct deserialization ─────────────────────────────────────────────

fn void test_des_simple_struct() @test => @pool()  {
  const String JSON = `{"x": 7, "y": -3}`;
  DPoint p = des::deserialize{DPoint}(&&json::tdeserializer(JSON))!!;
  assert(p.x == 7);
  assert(p.y == -3);
}

fn void test_des_struct_whitespace() @test => @pool()  {
  // whitespace around tokens must be ignored
  const String JSON = `{  "x" :  42 ,  "y"  :  0  }`;
  DPoint p = des::deserialize{DPoint}(&&json::tdeserializer(JSON))!!;
  assert(p.x == 42);
  assert(p.y == 0);
}

fn void test_des_nested_struct() @test => @pool()  {
  const String JSON = `{"label": "mybox", "center": {"x": 5, "y": 8}}`;
  DBox b = des::deserialize{DBox}(&&json::tdeserializer(JSON))!!;
  assert(b.label == "mybox");
  assert(b.center.x == 5);
  assert(b.center.y == 8);
}

fn void test_des_null_pointer() @test => @pool()  {
  const String JSON = `{"name": "test", "extra": null}`;
  DWithPointer wp = des::deserialize{DWithPointer}(&&json::tdeserializer(JSON))!!;
  assert(wp.name == "test");
  assert(wp.extra == null);
}

fn void test_des_non_null_pointer() @test => @pool()  {
  const String JSON = `{"name": "test", "extra": {"x": 11, "y": 22}}`;
  DWithPointer wp = des::deserialize{DWithPointer}(&&json::tdeserializer(JSON))!!;
  assert(wp.name == "test");
  assert(wp.extra != null);
  assert(wp.extra.x == 11);
  assert(wp.extra.y == 22);
}

fn void test_des_array() @test => @pool()  {
  const String JSON = `{"tag": "pts", "items": [{"x":1,"y":2},{"x":3,"y":4}]}`;
  DWithArray wa = des::deserialize{DWithArray}(&&json::tdeserializer(JSON))!!;
  assert(wa.tag == "pts");
  assert(wa.items.len == 2);
  assert(wa.items[0].x == 1);
  assert(wa.items[0].y == 2);
  assert(wa.items[1].x == 3);
  assert(wa.items[1].y == 4);
}

fn void test_des_empty_array() @test => @pool()  {
  const String JSON = `{"tag": "empty", "items": []}`;
  DWithArray wa = des::deserialize{DWithArray}(&&json::tdeserializer(JSON))!!;
  assert(wa.items.len == 0);
}

fn void test_des_missing_field_stays_default() @test => @pool()  {
  // field "y" absent from JSON → stays at 0
  const String JSON = `{"x": 5}`;
  DPoint p = des::deserialize{DPoint}(&&json::tdeserializer(JSON))!!;
  assert(p.x == 5);
  assert(p.y == 0);
}

// ── Tests: attributes ─────────────────────────────────────────────────────────

fn void test_des_skip_field_with_key_present() @test => @pool()  {
  // "dropped" key is in the JSON but must not be assigned to the struct field
  const String JSON = `{"kept": "visible", "dropped": "invisible"}`;
  DWithSkipDes? v = des::deserialize{DWithSkipDes}(&&json::tdeserializer(JSON));
  if (catch e = v) {
    assert(e == json::INVALID_FIELD);
  } else {
    assert(false, "Should be invalid because skipped");
  }
}

fn void test_des_skip_field_with_key_absent() @test => @pool()  {
  // "dropped" key is absent → field stays at default
  const String JSON = `{"kept": "only"}`;
  DWithSkipDes v = des::deserialize{DWithSkipDes}(&&json::tdeserializer(JSON))!!;
  assert(v.kept == "only");
  assert(v.dropped == "");
}

fn void test_des_rename() @test => @pool()  {
  // JSON uses the renamed keys "alias" and "num"
  const String JSON = `{"alias": "hello", "num": 7}`;
  DWithRenameDes v = des::deserialize{DWithRenameDes}(&&json::tdeserializer(JSON))!!;
  assert(v.original == "hello");
  assert(v.count == 7);
}

fn void test_des_extra_fields_ignored() @test => @pool()  {
  // extra JSON fields not in the struct are silently skipped
  const String JSON = `{"name": "alice", "value": 10, "unknown_field": "surprise", "another": 99}`;
  DDenyUnknown? v = des::deserialize{DDenyUnknown}(&&json::tdeserializer(JSON));
  // DDenyUnknown has deny_unknown_fields so this MUST fault
  if (catch err = v) {
    assert(err == des::UNKNOWN_FIELD);
  } else {
    assert(false);
  }
}

fn void test_des_extra_fields_ignored_without_deny() @test => @pool()  {
  // without deny_unknown_fields, extra keys are silently consumed
  const String JSON = `{"x": 1, "y": 2, "z": 999, "label": "extra"}`;
  DPoint p = des::deserialize{DPoint}(&&json::tdeserializer(JSON))!!;
  assert(p.x == 1);
  assert(p.y == 2);
}

fn void test_des_deny_unknown_fields() @test => @pool()  {
  const String JSON = `{"name": "bob", "value": 5, "nope": "bad"}`;
  DDenyUnknown? v = des::deserialize{DDenyUnknown}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == des::UNKNOWN_FIELD);
  } else {
    assert(false); // must have faulted
  }
}

fn void test_des_deny_unknown_fields_passes_when_clean() @test => @pool()  {
  // all fields known → no fault
  const String JSON = `{"name": "bob", "value": 5}`;
  DDenyUnknown v = des::deserialize{DDenyUnknown}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "bob");
  assert(v.value == 5);
}

fn void test_des_duplicate_key() @test => @pool()  {
  // same key appears twice → DUPLICATED_KEY
  const String JSON = `{"name": "first", "age": 1, "name": "second"}`;
  DDupCheck? v = des::deserialize{DDupCheck}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == des::DUPLICATED_KEY);
  } else {
    assert(false); // must have faulted
  }
}

// ── Tests: enum deserialization ───────────────────────────────────────────────

fn void test_des_enum_name() @test => @pool()  {
  const String JSON = `{"label": "go", "dir": "EAST"}`;
  DWithDirection v = des::deserialize{DWithDirection}(&&json::tdeserializer(JSON))!!;
  assert(v.dir == DDirection.EAST);
}

fn void test_des_enum_name_all_variants() @test => @pool()  {
  String[4] jsons = {
    `{"label": "a", "dir": "NORTH"}`,
    `{"label": "b", "dir": "SOUTH"}`,
    `{"label": "c", "dir": "EAST"}`,
    `{"label": "d", "dir": "WEST"}`,
  };
  DDirection[4] expected = { DDirection.NORTH, DDirection.SOUTH, DDirection.EAST, DDirection.WEST };
  foreach (i, js : jsons) {
    DWithDirection v = des::deserialize{DWithDirection}(&&json::tdeserializer(js))!!;
    assert(v.dir == expected[i]);
  }
}

fn void test_des_enum_invalid_name() @test => @pool()  {
  // "NORTHEAST" is not a valid DDirection variant → INVALID_ENUM_VALUE
  const String JSON = `{"label": "bad", "dir": "NORTHEAST"}`;
  DWithDirection? v = des::deserialize{DWithDirection}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == des::INVALID_ENUM_VALUE);
  } else {
    assert(false);
  }
}

fn void test_des_enum_ordinal() @test => @pool()  {
  // BRONZE=0, SILVER=1, GOLD=2
  const String JSON0 = `{"label": "a", "rank": 0}`;
  const String JSON1 = `{"label": "b", "rank": 1}`;
  const String JSON2 = `{"label": "c", "rank": 2}`;
  DWithRank v0 = des::deserialize{DWithRank}(&&json::tdeserializer(JSON0))!!;
  DWithRank v1 = des::deserialize{DWithRank}(&&json::tdeserializer(JSON1))!!;
  DWithRank v2 = des::deserialize{DWithRank}(&&json::tdeserializer(JSON2))!!;
  assert(v0.rank == DRank.BRONZE);
  assert(v1.rank == DRank.SILVER);
  assert(v2.rank == DRank.GOLD);
}

fn void test_des_enum_field() @test => @pool()  {
  // DColor uses the "hex" associated field for lookup
  const String JSON = `{"label": "paint", "color": "#00FF00"}`;
  DWithColor v = des::deserialize{DWithColor}(&&json::tdeserializer(JSON))!!;
  assert(v.color == DColor.GREEN);
}

fn void test_des_enum_field_all_variants() @test => @pool()  {
  String[3] jsons = {
    `{"label": "r", "color": "#FF0000"}`,
    `{"label": "g", "color": "#00FF00"}`,
    `{"label": "b", "color": "#0000FF"}`,
  };
  DColor[3] expected = { DColor.RED, DColor.GREEN, DColor.BLUE };
  foreach (i, js : jsons) {
    DWithColor v = des::deserialize{DWithColor}(&&json::tdeserializer(js))!!;
    assert(v.color == expected[i]);
  }
}

// ── Tests: enum fallback deserialization ─────────────────────────────────────
// .fallback = "VARIANT" → use that variant when JSON doesn't match any known name.

fn void test_des_enum_fallback_known_variant() @test => @pool()  {
  // Known variant still maps correctly
  const String JSON = `{"label": "a", "status": "ACTIVE"}`;
  DWithStatus v = des::deserialize{DWithStatus}(&&json::tdeserializer(JSON))!!;
  assert(v.status == DStatus.ACTIVE);
}

fn void test_des_enum_fallback_known_variant_inactive() @test => @pool()  {
  const String JSON = `{"label": "b", "status": "INACTIVE"}`;
  DWithStatus v = des::deserialize{DWithStatus}(&&json::tdeserializer(JSON))!!;
  assert(v.status == DStatus.INACTIVE);
}

fn void test_des_enum_fallback_unknown_uses_fallback() @test => @pool()  {
  // "DEPRECATED" is not a valid DStatus → fallback UNKNOWN used, no fault
  const String JSON = `{"label": "c", "status": "DEPRECATED"}`;
  DWithStatus v = des::deserialize{DWithStatus}(&&json::tdeserializer(JSON))!!;
  assert(v.status == DStatus.UNKNOWN);
}

fn void test_des_enum_fallback_empty_string_uses_fallback() @test => @pool()  {
  // Empty string doesn't match any variant → fallback
  const String JSON = `{"label": "d", "status": ""}`;
  DWithStatus v = des::deserialize{DWithStatus}(&&json::tdeserializer(JSON))!!;
  assert(v.status == DStatus.UNKNOWN);
}

fn void test_des_enum_fallback_field_known() @test => @pool()  {
  // Known code value maps correctly
  const String JSON = `{"label": "e", "priority": "high"}`;
  DWithPriority v = des::deserialize{DWithPriority}(&&json::tdeserializer(JSON))!!;
  assert(v.priority == DPriority.HIGH);
}

fn void test_des_enum_fallback_field_known_medium() @test => @pool()  {
  const String JSON = `{"label": "f", "priority": "medium"}`;
  DWithPriority v = des::deserialize{DWithPriority}(&&json::tdeserializer(JSON))!!;
  assert(v.priority == DPriority.MEDIUM);
}

fn void test_des_enum_fallback_field_unknown_uses_fallback() @test => @pool()  {
  // "critical" is not a valid DPriority code → fallback NONE used, no fault
  const String JSON = `{"label": "g", "priority": "critical"}`;
  DWithPriority v = des::deserialize{DWithPriority}(&&json::tdeserializer(JSON))!!;
  assert(v.priority == DPriority.NONE);
}

// ── Tests: Maybe ──────────────────────────────────────────────────────────────

fn void test_des_maybe_null() @test => @pool()  {
  const String JSON = `{"name": "empty", "opt": null}`;
  DWithMaybe v = des::deserialize{DWithMaybe}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "empty");
  // opt must be empty (get() must fault)
  if (catch v.opt.get()) { /* correct: empty Maybe */ } else { assert(false); }
}

fn void test_des_maybe_value() @test => @pool()  {
  const String JSON = `{"name": "full", "opt": 99}`;
  DWithMaybe v = des::deserialize{DWithMaybe}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "full");
  assert(v.opt.get()!! == 99);
}

// ── Tests: JSON parse errors ──────────────────────────────────────────────────

fn void test_des_invalid_object() @test => @pool()  {
  DPoint? p = des::deserialize{DPoint}(&&json::tdeserializer("not-an-object"));
  assert(@catch(p));
}

fn void test_des_invalid_bool() @test => @pool()  {
  bool? b = des::deserialize{bool}(&&json::tdeserializer("maybe"));
  assert(@catch(b));
}

fn void test_des_invalid_number() @test => @pool()  {
  // leading zero followed by digit is invalid JSON number (strict flavor)
  long? n = des::deserialize{long}(&&json::tdeserializer("01", JSON));
  assert(@catch(n));
}

// ── Tests: large / edge-case numbers ─────────────────────────────────────────

fn void test_des_large_int() @test => @pool()  {
  // INT_MAX / INT_MIN — representable exactly as f64 (2^31 < 2^53)
  const String JSON = `{"x": 2147483647, "y": -2000000000}`;
  DPoint p = des::deserialize{DPoint}(&&json::tdeserializer(JSON))!!;
  assert(p.x == 2147483647);
  assert(p.y == -2000000000);
}

fn void test_des_zero_values() @test => @pool()  {
  const String JSON = `{"x": 0, "y": 0}`;
  DPoint p = des::deserialize{DPoint}(&&json::tdeserializer(JSON))!!;
  assert(p.x == 0);
  assert(p.y == 0);
}

// ── Tests: Object* (next_any) ─────────────────────────────────────────────────

fn void test_des_object_any_basic() @test => @pool()  {
  const String JSON = `{"count": 3, "ok": true, "msg": "hello", "empty": null}`;
  Object* obj = des::deserialize{Object*}(&&json::tdeserializer(JSON, debug: true))!!;
  assert(obj != null);
}

fn void test_des_object_any_nested() @test => @pool()  {
  const String JSON = `{"outer": {"inner": 42}}`;
  Object* obj = des::deserialize{Object*}(&&json::tdeserializer(JSON))!!;
  assert(obj != null);
}

// ── Tests: roundtrip ─────────────────────────────────────────────────────────

fn void test_des_roundtrip_simple() @test => @pool()  {
  DFull original = { .name = "Alice", .age = 30, .active = true, .score = 9.75 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, original)!!;
  defer j.free();

  DFull copy = des::deserialize{DFull}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.name   == "Alice");
  assert(copy.age    == 30);
  assert(copy.active == true);
  double diff = copy.score - 9.75;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-6);
}

fn void test_des_roundtrip_complex() @test => @pool()  {
  DPoint[2] path_arr = { { .x = 1, .y = 0 }, { .x = 2, .y = 3 } };
  DPoint tgt = { .x = 99, .y = -1 };
  DComplex original = {
    .title  = "route",
    .origin = { .x = 0, .y = 0 },
    .path   = path_arr[..],
    .target = &tgt,
  };

  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, original)!!;
  defer j.free();

  DComplex copy = des::deserialize{DComplex}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.title        == "route");
  assert(copy.origin.x     == 0);
  assert(copy.origin.y     == 0);
  assert(copy.path.len     == 2);
  assert(copy.path[0].x    == 1);
  assert(copy.path[1].x    == 2);
  assert(copy.target       != null);
  assert(copy.target.x     == 99);
  assert(copy.target.y     == -1);
}

// ── Tests: inline sub-struct ──────────────────────────────────────────────────

$expand(dessert::@derive(DWithInlineSub));
struct DWithInlineSub {
  int id;
  struct pos {
    int x;
    int y;
  }
}

fn void test_des_inline_substruct() @test => @pool()  {
  const String JSON = `{"id": 5, "pos": {"x": 11, "y": -2}}`;
  DWithInlineSub v = des::deserialize{DWithInlineSub}(&&json::tdeserializer(JSON))!!;
  assert(v.id == 5);
  assert(v.pos.x == 11);
  assert(v.pos.y == -2);
}

fn void test_des_inline_substruct_missing_field() @test => @pool()  {
  const String JSON = `{"id": 3, "pos": {"x": 7}}`;
  DWithInlineSub v = des::deserialize{DWithInlineSub}(&&json::tdeserializer(JSON))!!;
  assert(v.id == 3);
  assert(v.pos.x == 7);
  assert(v.pos.y == 0);
}

fn void test_des_inline_substruct_roundtrip() @test => @pool()  {
  DWithInlineSub orig = { .id = 99, .pos = { .x = 7, .y = -3 } };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DWithInlineSub copy = des::deserialize{DWithInlineSub}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.id == 99);
  assert(copy.pos.x == 7);
  assert(copy.pos.y == -3);
}

// ── Tests: union (custom serialize/deserialize) ───────────────────────────────

union DUVariant {
  long i;
  double f;
}

$expand(dessert::@derive(DTaggedUnion));
struct DTaggedUnion {
  int       tag;
  DUVariant val @DField({ .tagged = { .by = "tag", .inlined = true } });
}

fn void test_des_union_field() @test => @pool()  {
  const String JSON = `{"tag": 0, "val": 999}`;
  DTaggedUnion v = des::deserialize{DTaggedUnion}(&&json::tdeserializer(JSON))!!;
  assert(v.tag == 0);
  assert(v.val.i == 999);
}

fn void test_des_union_negative() @test => @pool()  {
  const String JSON = `{"tag": 0, "val": -12345}`;
  DTaggedUnion v = des::deserialize{DTaggedUnion}(&&json::tdeserializer(JSON))!!;
  assert(v.val.i == -12345);
}

fn void test_des_union_roundtrip() @test => @pool()  {
  DTaggedUnion orig = { .tag = 0, .val = { .i = 42 } };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DTaggedUnion copy = des::deserialize{DTaggedUnion}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.tag == 0);
  assert(copy.val.i == 42);
}

// ── Tests: @DField tagged union (named) ──────────────────────────────────────

$expand(dessert::@derive(DDUnionNamed));
struct DDUnionNamed {
  int kind;
  union p @DField({ .tagged = { .by = "kind" } }) {
    int    first;
    double second;
    String third;
  }
}

fn void test_des_dunion_named_first() @test => @pool()  {
  const String JSON = `{"kind": 0, "p": {"first": 42}}`;
  DDUnionNamed v = des::deserialize{DDUnionNamed}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == 0);
  assert(v.p.first == 42);
}

fn void test_des_dunion_named_second() @test => @pool()  {
  const String JSON = `{"kind": 1, "p": {"second": 3.14}}`;
  DDUnionNamed v = des::deserialize{DDUnionNamed}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == 1);
  double diff = v.p.second - 3.14;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_des_dunion_named_third() @test => @pool()  {
  const String JSON = `{"kind": 2, "p": {"third": "hello"}}`;
  DDUnionNamed v = des::deserialize{DDUnionNamed}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == 2);
  assert(v.p.third == "hello");
}

fn void test_des_dunion_named_roundtrip_first() @test => @pool()  {
  DDUnionNamed orig = { .kind = 0, .p = { .first = 99 } };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DDUnionNamed copy = des::deserialize{DDUnionNamed}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.kind == 0);
  assert(copy.p.first == 99);
}

fn void test_des_dunion_named_roundtrip_second() @test => @pool()  {
  DDUnionNamed orig = { .kind = 1, .p = { .second = 1.5 } };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DDUnionNamed copy = des::deserialize{DDUnionNamed}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.kind == 1);
  double diff = copy.p.second - 1.5;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

// ── Tests: @DField anonymous union (flattened) ────────────────────────────────

$expand(dessert::@derive(DDUnionAnon));
struct DDUnionAnon {
  int kind;
  union @DField({ .tagged = { .by = "kind" } }) {
    int    foo;
    double bar;
  }
}

fn void test_des_dunion_anon_first() @test => @pool()  {
  // foo is a top-level key (union flattened into parent)
  const String JSON = `{"kind": 0, "foo": 77}`;
  DDUnionAnon v = des::deserialize{DDUnionAnon}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == 0);
  assert(v.foo == 77);
}

fn void test_des_dunion_anon_second() @test => @pool()  {
  const String JSON = `{"kind": 1, "bar": 9.9}`;
  DDUnionAnon v = des::deserialize{DDUnionAnon}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == 1);
  double diff = v.bar - 9.9;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_des_dunion_anon_roundtrip_first() @test => @pool()  {
  DDUnionAnon orig = { .kind = 0, .foo = 55 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DDUnionAnon copy = des::deserialize{DDUnionAnon}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.kind == 0);
  assert(copy.foo == 55);
}

fn void test_des_dunion_anon_roundtrip_second() @test => @pool()  {
  DDUnionAnon orig = { .kind = 1, .bar = 7.25 };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DDUnionAnon copy = des::deserialize{DDUnionAnon}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.kind == 1);
  double diff = copy.bar - 7.25;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

// ── Tests: tagged union match.by = ORDINAL (enum tag) ────────────────────────
// Named inlined union: JSON key is the union field name ("payload");
// value is the active member's value directly. kind serialized as ordinal int.

$expand(dessert::@derive(DMBOrdinalTag));
enum DMBOrdinalTag { ORD_FIRST, ORD_SECOND, ORD_THIRD }

$expand(dessert::@derive(DMatchByOrdinal));
struct DMatchByOrdinal {
  DMBOrdinalTag kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .match = { .by = ORDINAL } } }) {
    int    first;    // selected when kind ordinal == 0 (ORD_FIRST)
    double second;   // selected when kind ordinal == 1 (ORD_SECOND)
    String third;    // selected when kind ordinal == 2 (ORD_THIRD)
  }
}

fn void test_des_match_by_ordinal_first() @test => @pool()  {
  // ORD_FIRST (ordinal 0) → member[0] = first; payload value read at "payload" key
  const String JSON = `{"kind": "ORD_FIRST", "payload": 10}`;
  DMatchByOrdinal v = des::deserialize{DMatchByOrdinal}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == DMBOrdinalTag.ORD_FIRST);
  assert(v.payload.first == 10);
}

fn void test_des_match_by_ordinal_second() @test => @pool()  {
  const String JSON = `{"kind": "ORD_SECOND", "payload": 2.5}`;
  DMatchByOrdinal v = des::deserialize{DMatchByOrdinal}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == DMBOrdinalTag.ORD_SECOND);
  double diff = v.payload.second - 2.5;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_des_match_by_ordinal_roundtrip() @test => @pool()  {
  DMatchByOrdinal orig = { .kind = ORD_THIRD, .payload = { .third = "roundtrip" } };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DMatchByOrdinal copy = des::deserialize{DMatchByOrdinal}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.kind == DMBOrdinalTag.ORD_THIRD);
  assert(copy.payload.third == "roundtrip");
}

// ── Tests: tagged union match.by = DESCRIPTION (enum tag) ────────────────────
// DESCRIPTION: switch on enum VALUE. Union member names uppercased must match
// enum value names. E.g. member "desc_a" → @str_to_upper → "DESC_A" → case DESC_A.

$expand(dessert::@derive(DMBDescTag));
enum DMBDescTag { DESC_A, DESC_B, DESC_C }

$expand(dessert::@derive(DMatchByDesc));
struct DMatchByDesc {
  DMBDescTag kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .match = { .by = DESCRIPTION } } }) {
    int    desc_a;   // @str_to_upper("desc_a") = "DESC_A" → case DESC_A
    double desc_b;   // → case DESC_B
    String desc_c;   // → case DESC_C
  }
}

fn void test_des_match_by_desc_first() @test => @pool()  {
  const String JSON = `{"kind": "DESC_A", "payload": 42}`;
  DMatchByDesc v = des::deserialize{DMatchByDesc}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == DMBDescTag.DESC_A);
  assert(v.payload.desc_a == 42);
}

fn void test_des_match_by_desc_second() @test => @pool()  {
  const String JSON = `{"kind": "DESC_B", "payload": 9.9}`;
  DMatchByDesc v = des::deserialize{DMatchByDesc}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == DMBDescTag.DESC_B);
  double diff = v.payload.desc_b - 9.9;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_des_match_by_desc_roundtrip() @test => @pool()  {
  DMatchByDesc orig = { .kind = DMBDescTag.DESC_C, .payload = { .desc_c = "desc" } };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DMatchByDesc copy = des::deserialize{DMatchByDesc}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.kind == DMBDescTag.DESC_C);
  assert(copy.payload.desc_c == "desc");
}

// ── Tests: tagged union match.by = FIELD (enum with String associated field) ──
// FIELD: switch on enum.variant (String). Value must equal union member name exactly.
// E.g. FLD_A { "fld_a" } → kind.variant == "fld_a" → case "fld_a" → member fld_a.

$expand(dessert::@derive(DMBFieldTag));
enum DMBFieldTag : (String variant) {
  FLD_A { "fld_a" },
  FLD_B { "fld_b" },
  FLD_C { "fld_c" },
}

$expand(dessert::@derive(DMatchByField));
struct DMatchByField {
  DMBFieldTag kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .match = { .by = FIELD, .field = "variant" } } }) {
    int    fld_a;   // matched when kind.variant == "fld_a"
    double fld_b;   // matched when kind.variant == "fld_b"
    String fld_c;   // matched when kind.variant == "fld_c"
  }
}

fn void test_des_match_by_field_first() @test => @pool()  {
  const String JSON = `{"kind": "FLD_A", "payload": 7}`;
  DMatchByField v = des::deserialize{DMatchByField}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == DMBFieldTag.FLD_A);
  assert(v.payload.fld_a == 7);
}

fn void test_des_match_by_field_second() @test => @pool()  {
  const String JSON = `{"kind": "FLD_B", "payload": 3.14}`;
  DMatchByField v = des::deserialize{DMatchByField}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == DMBFieldTag.FLD_B);
  double diff = v.payload.fld_b - 3.14;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_des_match_by_field_roundtrip() @test => @pool()  {
  DMatchByField orig = { .kind = DMBFieldTag.FLD_C, .payload = { .fld_c = "field" } };
  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, orig)!!;
  defer j.free();

  DMatchByField copy = des::deserialize{DMatchByField}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.kind == DMBFieldTag.FLD_C);
  assert(copy.payload.fld_c == "field");
}

// ── Tests: tagged union unmapped.as ─────────────────────────────────────────
// unmapped.as controls behavior when the tag value matches no union member.
// Default (ERROR) → UNMAPPED_UNION_VARIANT fault.
// EMPTY_STRUCT → consume payload as Object*. NULL → Maybe{int}. ZERO → int.

// Default (no unmapped.as = ERROR): out-of-range kind raises UNMAPPED_UNION_VARIANT
$expand(dessert::@derive(DUnmappedError, deserialize));
struct DUnmappedError {
  int kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true } }) {
    int    first;
    double second;
    String third;
  }
}

fn void test_des_unmapped_as_error() @test => @pool()  {
  const String JSON = `{"kind": 99, "payload": 0}`;  // ordinal 99 doesn't match member 0, 1, or 2
  DUnmappedError? v = des::deserialize{DUnmappedError}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == des::UNMAPPED_UNION_VARIANT);
    return;
  }
  assert(false);  // expected UNMAPPED_UNION_VARIANT but no fault was raised
}

// unmapped.as = EMPTY_STRUCT: out-of-range kind → consume payload as Object* {}
$expand(dessert::@derive(DUnmappedEmptyStruct, deserialize));
struct DUnmappedEmptyStruct {
  int kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .unmapped = { .as = EMPTY_STRUCT } } }) {
    int    first;
    double second;
  }
}

fn void test_des_unmapped_as_empty_struct() @test => @pool()  {
  const String JSON = `{"kind": 99, "payload": {}}`;
  DUnmappedEmptyStruct v = des::deserialize{DUnmappedEmptyStruct}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == 99);
}

// unmapped.as = NULL: out-of-range kind → consume payload as null
$expand(dessert::@derive(DUnmappedNull, deserialize));
struct DUnmappedNull {
  int kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .unmapped = { .as = NULL } } }) {
    int    first;
    double second;
  }
}

fn void test_des_unmapped_as_null() @test => @pool()  {
  const String JSON = `{"kind": 99, "payload": null}`;
  DUnmappedNull v = des::deserialize{DUnmappedNull}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == 99);
}

// unmapped.as = ZERO: out-of-range kind → consume payload as int
$expand(dessert::@derive(DUnmappedZero, deserialize));
struct DUnmappedZero {
  int kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .unmapped = { .as = ZERO } } }) {
    int    first;
    double second;
  }
}

fn void test_des_unmapped_as_zero() @test => @pool()  {
  const String JSON = `{"kind": 99, "payload": 0}`;
  DUnmappedZero v = des::deserialize{DUnmappedZero}(&&json::tdeserializer(JSON))!!;
  assert(v.kind == 99);
}

fn void test_des_roundtrip_null_pointer() @test => @pool()  {
  DComplex original = {
    .title  = "no-target",
    .origin = { .x = 5, .y = 5 },
    .path   = {},
    .target = null,
  };

  JsonSerializer s = json::serializer();
  JsonValue j = ser::serialize(&s, original)!!;
  defer j.free();

  DComplex copy = des::deserialize{DComplex}(&&json::tdeserializer(j.to_string()!!))!!;
  assert(copy.title    == "no-target");
  assert(copy.target   == null);
  assert(copy.path.len == 0);
}

$expand(dessert::@derive(SWeatherRow, deserialize));
struct SWeatherRow {
  String city;
  double temp;
  bool   sunny;
}

$expand(dessert::@derive(FooWithHashMap, deserialize));
struct FooWithHashMap {
  String bar;
  HashMap{String, int} found;
  HashMap{String, SWeatherRow} cities @DField({ .flatten = true });
}

// ── Test: HashMap ───────────────────────────────────────────────────────────────

fn void test_des_foo_with_hashmap() @test => @pool()  {
  String input = `{"found":{"baz":-2,"bar":1},"bar":"hello","toulouse":{"city":"Toulouse","temp":18.000000,"sunny":false}}`;

  FooWithHashMap f;

  @pool() {
    f = des::deserialize{FooWithHashMap}(&&json::deserializer(mem, input))!!;
  };

  assert(f.cities["toulouse"].city!! == "Toulouse");
  assert(f.found["baz"]!! == -2);

  foreach (v : f.cities.value_iter()) {
    alloc::free(mem, v.city);
  }

  alloc::free(mem, f.bar);
  f.found.free();
  f.cities.free();
}

// ── Tests: JSONC flavor (relaxed superset) ─────────────────────────────────────────────────

// JSON5 is a superset of JSON: plain JSON must still parse.
fn void test_jsonc_plain_json() @test => @pool()  {
  DFull v = des::deserialize{DFull}(&&json::tdeserializer(
    `{"name":"ada","age":36,"active":true,"score":9.5}`))!!;
  assert(v.name == "ada");
  assert(v.age == 36);
  assert(v.active == true);
  assert(v.score == 9.5);
}

// Unquoted keys, single-quoted strings, line + block comments, trailing comma.
fn void test_jsonc_relaxed_object() @test => @pool()  {
  String src = `{
    // a line comment
    name: 'grace', /* a block comment */
    age: 85,
    active: false,
    score: 1.0,
  }`;
  DFull v = des::deserialize{DFull}(&&json::tdeserializer(src))!!;
  assert(v.name == "grace");
  assert(v.age == 85);
  assert(v.active == false);
  assert(v.score == 1.0);
}

fn void test_jsonc_single_quoted_string() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`'hello'`))!!;
  assert(v == "hello");
}

// A double quote needs no escaping inside a single-quoted string.
fn void test_jsonc_single_quoted_with_double() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`'say "hi"'`))!!;
  assert(v == `say "hi"`);
}

fn void test_jsonc_hex_escape() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`"\x21\x21"`))!!;
  assert(v == "!!");
}

fn void test_jsonc_unicode_escape() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer(`"AB"`))!!;
  assert(v == "AB");
}

fn void test_jsonc_string_line_continuation() @test => @pool()  {
  String v = des::deserialize{String}(&&json::tdeserializer("\"line1\\\nline2\""))!!;
  assert(v == "line1line2");
}

fn void test_jsonc_hex_number() @test => @pool()  {
  long v = des::deserialize{long}(&&json::tdeserializer("0xFF"))!!;
  assert(v == 255);
}

fn void test_jsonc_leading_plus() @test => @pool()  {
  long v = des::deserialize{long}(&&json::tdeserializer("+42"))!!;
  assert(v == 42);
}

fn void test_jsonc_infinity() @test => @pool()  {
  double v = des::deserialize{double}(&&json::tdeserializer("Infinity"))!!;
  assert(math::is_inf(v) && v > 0);
}

fn void test_jsonc_negative_infinity() @test => @pool()  {
  double v = des::deserialize{double}(&&json::tdeserializer("-Infinity"))!!;
  assert(math::is_inf(v) && v < 0);
}

fn void test_jsonc_nan() @test => @pool()  {
  double v = des::deserialize{double}(&&json::tdeserializer("NaN"))!!;
  assert(math::is_nan(v));
}

fn void test_jsonc_array_trailing_comma() @test => @pool()  {
  long[] v = des::deserialize{long[]}(&&json::tdeserializer("[1, 2, 3,]"))!!;
  assert(v.len == 3);
  assert(v[0] == 1 && v[2] == 3);
}

fn void test_jsonc_nested_with_comments() @test => @pool()  {
  String src = `{
    name: "outer",
    age: 1,
    active: true,
    score: 2.5, // trailing line comment
  }`;
  DFull v = des::deserialize{DFull}(&&json::tdeserializer(src))!!;
  assert(v.name == "outer");
  assert(v.score == 2.5);
}

// ── Tests: strict JSON flavor rejects JSONC extensions ────────────────────────

fn void test_json_strict_rejects_comment() @test => @pool()  {
  DFull? v = des::deserialize{DFull}(&&json::tdeserializer(
    `{ // comment
      "name":"x","age":1,"active":true,"score":0.0 }`, JSON));
  assert(@catch(v));
}

fn void test_json_strict_rejects_unquoted_key() @test => @pool()  {
  DFull? v = des::deserialize{DFull}(&&json::tdeserializer(
    `{name:"x","age":1,"active":true,"score":0.0}`, JSON));
  assert(@catch(v));
}

fn void test_json_strict_rejects_single_quote() @test => @pool()  {
  String? v = des::deserialize{String}(&&json::tdeserializer(`'x'`, JSON));
  assert(@catch(v));
}

fn void test_json_strict_rejects_trailing_comma() @test => @pool()  {
  long[]? v = des::deserialize{long[]}(&&json::tdeserializer("[1, 2,]", JSON));
  assert(@catch(v));
}

fn void test_json_strict_hex_not_parsed() @test => @pool()  {
  // strict JSON does not understand hex: it reads the leading 0 and stops.
  long strict = des::deserialize{long}(&&json::tdeserializer("0xFF", JSON))!!;
  assert(strict == 0);
  // JSONC reads the whole hex literal.
  long jsonc = des::deserialize{long}(&&json::tdeserializer("0xFF"))!!;
  assert(jsonc == 255);
}

fn void test_json_strict_rejects_infinity() @test => @pool()  {
  double? v = des::deserialize{double}(&&json::tdeserializer("Infinity", JSON));
  assert(@catch(v));
}

fn void test_json_strict_plain_json_ok() @test => @pool()  {
  // strict flavor still accepts valid JSON
  DFull v = des::deserialize{DFull}(&&json::tdeserializer(
    `{"name":"ok","age":3,"active":false,"score":1.5}`, JSON))!!;
  assert(v.name == "ok");
  assert(v.score == 1.5);
}

// ── Tests: The correct allocator is used ────────────────────────

$expand(dessert::@derive(TestDeserializedAllocator));
struct TestDeserializedAllocator {
  int[] numbers;
}

// Test that the allocator is being used
fn void test_allocator_used() @test => @pool()  {
  String src = `{ "numbers": [1, 2, 3], "other": {} }`;
  TestDeserializedAllocator v;
  @pool() {
    v = des::deserialize{TestDeserializedAllocator}(&&json::deserializer(mem, src))!!;
  };

  test::eq(v.numbers, (int[]) { 1, 2, 3 });
  alloc::free(mem, v.numbers);
}


$expand(dessert::@derive(TestList));
struct TestList {
  List{int} numbers;
}

// Test that the allocator is being used
fn void test_list() @test => @pool()  {
  String src = `{ "numbers": [1, 2, 3] }`;
  TestList v;
  defer v.numbers.free();

  @pool() {
    v = des::deserialize{TestList}(&&json::deserializer(mem, src))!!;
  };

  test::eq(v.numbers.to_tarray(), (int[]) { 1, 2, 3 });
}

$expand(dessert::@derive(TestListPointer));
struct TestListPointer {
  List{int}* numbers;
}

// Test that the allocator is being used
fn void test_list_pointer() @test => @pool()  {
  String src = `{ "numbers": [1, 2, 3] }`;
  TestListPointer v;

  @pool() {
    v = des::deserialize{TestListPointer}(&&json::deserializer(mem, src))!!;
  };

  test::eq(v.numbers.to_tarray(), (int[]) { 1, 2, 3 });

  v.numbers.free();
  alloc::free(mem, v.numbers);
}

$expand(dessert::@derive(TestListFlat));
struct TestListFlat {
  List{int} numbers @DField({ .flatten = true });
}

// Test that the allocator is being used
fn void test_list_flat() @test => @pool() {
  String src = `{ "numbers": 1, "numbers": 2, "numbers": 3 }`;
  TestListFlat v;
  defer v.numbers.free();

  @pool() {
    v = des::deserialize{TestListFlat}(&&json::deserializer(mem, src))!!;
  };

  test::eq(v.numbers.to_tarray(), (int[]) { 1, 2, 3 });
}

$expand(dessert::@derive(TestListFlatPointer));
struct TestListFlatPointer {
  List{int}* numbers @DField({ .flatten = true });
}

// Test that the allocator is being used
fn void test_list_flat_pointer() @test => @pool() {
  String src = `{ "numbers": 1, "numbers": 2, "numbers": 3 }`;
  TestListFlatPointer v;

  @pool() {
    v = des::deserialize{TestListFlatPointer}(&&json::deserializer(mem, src))!!;
  };

  test::eq(v.numbers.to_tarray(), (int[]) { 1, 2, 3 });

  v.numbers.free();
  alloc::free(mem, v.numbers);
}


$expand(dessert::@derive(DessertKind));
enum DessertKind @DEnum({ .rename_all = KEBAB_CASE }) {
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
  DessertKind kebab = json::deserialize{DessertKind}(mem, `"peach-cobbler"`)!!;
  test::eq(kebab, DessertKind.PEACH_COBBLER);

  DessertKindUpper upper = json::deserialize{DessertKindUpper}(mem, `"PEACH_COBBLER"`)!!;
  test::eq(upper, DessertKindUpper.PEACH_COBBLER);

  DessertKindVerbatim verbatim = json::deserialize{DessertKindVerbatim}(mem, `"PEACH_COBBLER"`)!!;
  test::eq(verbatim, DessertKindVerbatim.PEACH_COBBLER);

  DessertKindCamel camel = json::deserialize{DessertKindCamel}(mem, `"peachCobbler"`)!!;
  test::eq(camel, DessertKindCamel.PEACH_COBBLER);

  DessertKindPascal pascal = json::deserialize{DessertKindPascal}(mem, `"PeachCobbler"`)!!;
  test::eq(pascal, DessertKindPascal.PEACH_COBBLER);

  DessertKindConstant constant = json::deserialize{DessertKindConstant}(mem, `"PEACH_COBBLER"`)!!;
  test::eq(constant, DessertKindConstant.PEACH_COBBLER);

  DessertKindSnake snake = json::deserialize{DessertKindSnake}(mem, `"peach_cobbler"`)!!;
  test::eq(snake, DessertKindSnake.PEACH_COBBLER);

  DessertKindLower lower = json::deserialize{DessertKindLower}(mem, `"peach_cobbler"`)!!;
  test::eq(lower, DessertKindLower.PEACH_COBBLER);
}

// ── required fields ──────────────────────────────────────────────────────────
// A field marked `required` must be present in the input; otherwise
// deserialization faults with MISSING_REQUIRED_FIELD.

$expand(dessert::@derive(DRequired, deserialize));
struct DRequired {
  String name @DFieldDes({ .required = true });
  int    age;
}

// required combined with rename: the field must appear under its renamed key.
$expand(dessert::@derive(DRequiredRenamed, deserialize));
struct DRequiredRenamed {
  String token @DFieldDes({ .rename = "tok", .required = true });
}

fn void test_des_required_present() @test => @pool() {
  const String JSON = `{"name": "bob", "age": 5}`;
  DRequired v = des::deserialize{DRequired}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "bob");
  assert(v.age == 5);
}

fn void test_des_required_missing_faults() @test => @pool() {
  // "name" is required but absent → must fault.
  const String JSON = `{"age": 5}`;
  DRequired? v = des::deserialize{DRequired}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == des::MISSING_REQUIRED_FIELD);
  } else {
    assert(false); // must have faulted
  }
}

fn void test_des_required_non_required_field_may_be_absent() @test => @pool() {
  // only the required "name" is present; the optional "age" defaults to 0.
  const String JSON = `{"name": "bob"}`;
  DRequired v = des::deserialize{DRequired}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "bob");
  assert(v.age == 0);
}

fn void test_des_required_renamed_present() @test => @pool() {
  const String JSON = `{"tok": "abc"}`;
  DRequiredRenamed v = des::deserialize{DRequiredRenamed}(&&json::tdeserializer(JSON))!!;
  assert(v.token == "abc");
}

fn void test_des_required_renamed_original_key_faults() @test => @pool() {
  // the required field is renamed to "tok"; supplying "token" leaves it missing.
  const String JSON = `{"token": "abc"}`;
  DRequiredRenamed? v = des::deserialize{DRequiredRenamed}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == des::MISSING_REQUIRED_FIELD);
  } else {
    assert(false); // must have faulted
  }
}

// ── Manual deserialize_<field> methods ───────────────────────────────────────
// A `deserialize_<field>` method takes over reading the value for that field and
// returns the value to store. The derived deserializer still consumes the key.

faultdef NEGATIVE_NOT_ALLOWED;

$expand(dessert::@derive(DManualTemp, deserialize));
struct DManualTemp {
  String city;
  double celsius;
}
// The input carries Fahrenheit under "celsius"; convert it to Celsius on read.
fn void? DManualTemp.deserialize_celsius(&self, Deserializer des) {
  double f = des.next_double()!;
  self.celsius = (f - 32.0) * 5.0 / 9.0;
}
// The input carries Fahrenheit under "celsius"; convert it to Celsius on read.
fn String? DManualTemp.deserialize_city(&self, Deserializer des) {
  return des.next_string()!;
}

$expand(dessert::@derive(DManualGuard, deserialize));
struct DManualGuard {
  int amount;
}
// A manual reader may reject the value by returning a fault, which propagates.
fn int? DManualGuard.deserialize_amount(&self, Deserializer des) {
  double v = des.next_double()!;
  if (v < 0) return NEGATIVE_NOT_ALLOWED~;
  return (int) v;
}

fn void test_des_manual_field_transforms_value() @test => @pool() {
  const String JSON = `{"city": "NYC", "celsius": 212}`;
  DManualTemp v = des::deserialize{DManualTemp}(&&json::tdeserializer(JSON))!!;
  assert(v.city == "NYC");
  double diff = v.celsius - 100.0;
  if (diff < 0) diff = -diff;
  assert(diff < 1e-9);
}

fn void test_des_manual_field_ok() @test => @pool() {
  const String JSON = `{"amount": 5}`;
  DManualGuard v = des::deserialize{DManualGuard}(&&json::tdeserializer(JSON))!!;
  assert(v.amount == 5);
}

fn void test_des_manual_field_fault_propagates() @test => @pool() {
  const String JSON = `{"amount": -3}`;
  DManualGuard? v = des::deserialize{DManualGuard}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == NEGATIVE_NOT_ALLOWED);
  } else {
    assert(false); // the manual reader must have faulted
  }
}

// ── Fixed-size arrays: extra elements ────────────────────────────────────────
// A `T[N]` field has a fixed capacity. When the input sequence carries more than
// N items, the default is to fault (TOO_MANY_ELEMENTS_IN_ARRAY); opting into
// `.array.skip_extra` discards the overflow instead.

$expand(dessert::@derive(DFixedArr, deserialize));
struct DFixedArr {
  int[3] scores;
}

$expand(dessert::@derive(DFixedArrSkip, deserialize));
struct DFixedArrSkip {
  int[3] scores @DFieldDes({ .array = { .skip_extra = true } });
}

fn void test_des_array_exact_fit() @test => @pool() {
  const String JSON = `{"scores": [1, 2, 3]}`;
  DFixedArr v = des::deserialize{DFixedArr}(&&json::tdeserializer(JSON))!!;
  assert(v.scores[0] == 1);
  assert(v.scores[1] == 2);
  assert(v.scores[2] == 3);
}

fn void test_des_array_fewer_than_capacity() @test => @pool() {
  // Missing trailing elements stay zero-initialized; this is not an error.
  const String JSON = `{"scores": [7, 8]}`;
  DFixedArr v = des::deserialize{DFixedArr}(&&json::tdeserializer(JSON))!!;
  assert(v.scores[0] == 7);
  assert(v.scores[1] == 8);
  assert(v.scores[2] == 0);
}

fn void test_des_array_extra_without_skip_faults() @test => @pool() {
  // 5 items into an int[3] and skip_extra is off → must fault.
  const String JSON = `{"scores": [1, 2, 3, 4, 5]}`;
  DFixedArr? v = des::deserialize{DFixedArr}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == des::TOO_MANY_ELEMENTS_IN_ARRAY);
  } else {
    assert(false); // must have faulted
  }
}

fn void test_des_array_extra_with_skip_kept_prefix() @test => @pool() {
  // Same overflow, but skip_extra keeps the first 3 and discards the rest.
  const String JSON = `{"scores": [1, 2, 3, 4, 5]}`;
  DFixedArrSkip v = des::deserialize{DFixedArrSkip}(&&json::tdeserializer(JSON))!!;
  assert(v.scores[0] == 1);
  assert(v.scores[1] == 2);
  assert(v.scores[2] == 3);
}

fn void test_des_array_skip_extra_exact_fit_unaffected() @test => @pool() {
  // skip_extra must not disturb the normal exact-fit case.
  const String JSON = `{"scores": [9, 9, 9]}`;
  DFixedArrSkip v = des::deserialize{DFixedArrSkip}(&&json::tdeserializer(JSON))!!;
  assert(v.scores[0] == 9);
  assert(v.scores[1] == 9);
  assert(v.scores[2] == 9);
}

// ── Manual deserialize_<field>: void? self-assign mode ───────────────────────
// When the method returns `void?`, dessert does NOT assign the field for you;
// the method must write it through `&self`. (The `Type?`-returning mode, where
// dessert assigns the returned value, is covered by DManualTemp/DManualGuard.)

$expand(dessert::@derive(DManualSelfAssign, deserialize));
struct DManualSelfAssign {
  String tag;
  int    count;
}
// Reads the value and assigns the field itself; returns void.
fn void? DManualSelfAssign.deserialize_count(&self, Deserializer des) {
  double v = des.next_double()!;
  self.count = (int) v + 100; // written via &self, nothing returned
}

fn void test_des_manual_field_void_self_assign() @test => @pool() {
  const String JSON = `{"tag": "x", "count": 5}`;
  DManualSelfAssign v = des::deserialize{DManualSelfAssign}(&&json::tdeserializer(JSON))!!;
  assert(v.tag == "x");        // ordinary field still deserialized normally
  assert(v.count == 105);      // manual void? method assigned self.count
}

fn void test_des_manual_field_void_fault_propagates() @test => @pool() {
  // A fault from the void? method still aborts deserialization.
  const String JSON = `{"tag": "x", "count": "not a number"}`;
  DManualSelfAssign? v = des::deserialize{DManualSelfAssign}(&&json::tdeserializer(JSON));
  assert(@catch(v)); // next_double faults on a string value
}

// ── Field aliases (.aliases) ─────────────────────────────────────────────────
// `.aliases` lists extra input keys accepted for a field. The canonical key
// (the field name, or `.rename` when set) keeps working, and every alias is
// matched verbatim: no `rename_all` conversion is applied to it.

$expand(dessert::@derive(DAliased, deserialize));
struct DAliased {
  String name @DFieldDes({ .aliases = { "nom", "nombre" } });
  int    age;
}

// aliases next to rename: the renamed key AND the aliases are accepted, but the
// field name itself no longer is.
$expand(dessert::@derive(DAliasedRenamed, deserialize));
struct DAliasedRenamed {
  String ident @DFieldDes({ .rename = "id", .aliases = { "identifier" } });
}

// rename_all applies to the field name only; aliases are taken as written.
$expand(dessert::@derive(DAliasedRenameAll, deserialize));
struct DAliasedRenameAll @DStructDes({ .rename_all = UPPER_CASE }) {
  String api @DFieldDes({ .aliases = { "api_key" } });
  int    port;
}

// an alias must satisfy `required`, and must not count as an unknown field.
$expand(dessert::@derive(DAliasedRequired, deserialize));
struct DAliasedRequired @DStructDes({ .deny_unknown_fields = true }) {
  String token @DFieldDes({ .aliases = { "tok" }, .required = true });
}

fn void test_des_alias_canonical_name_still_works() @test => @pool() {
  const String JSON = `{"name": "bob", "age": 5}`;
  DAliased v = des::deserialize{DAliased}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "bob");
  assert(v.age == 5);
}

fn void test_des_alias_first_alias() @test => @pool() {
  const String JSON = `{"nom": "bob", "age": 5}`;
  DAliased v = des::deserialize{DAliased}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "bob");
  assert(v.age == 5);
}

fn void test_des_alias_second_alias() @test => @pool() {
  // every entry of the alias list is accepted, not only the first one
  const String JSON = `{"nombre": "bob", "age": 5}`;
  DAliased v = des::deserialize{DAliased}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "bob");
  assert(v.age == 5);
}

fn void test_des_alias_unlisted_key_is_not_matched() @test => @pool() {
  // "namen" is not an alias → the field stays at its default
  const String JSON = `{"namen": "bob", "age": 5}`;
  DAliased v = des::deserialize{DAliased}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "");
  assert(v.age == 5);
}

fn void test_des_alias_with_rename_uses_renamed_key() @test => @pool() {
  const String JSON = `{"id": "abc"}`;
  DAliasedRenamed v = des::deserialize{DAliasedRenamed}(&&json::tdeserializer(JSON))!!;
  assert(v.ident == "abc");
}

fn void test_des_alias_with_rename_uses_alias() @test => @pool() {
  const String JSON = `{"identifier": "abc"}`;
  DAliasedRenamed v = des::deserialize{DAliasedRenamed}(&&json::tdeserializer(JSON))!!;
  assert(v.ident == "abc");
}

fn void test_des_alias_with_rename_field_name_not_accepted() @test => @pool() {
  // `.rename` replaces the field name; "ident" is neither the key nor an alias
  const String JSON = `{"ident": "abc"}`;
  DAliasedRenamed v = des::deserialize{DAliasedRenamed}(&&json::tdeserializer(JSON))!!;
  assert(v.ident == "");
}

fn void test_des_alias_is_verbatim_under_rename_all() @test => @pool() {
  // the alias is matched as written; rename_all only converts the field name
  const String JSON = `{"api_key": "secret", "PORT": 8080}`;
  DAliasedRenameAll v = des::deserialize{DAliasedRenameAll}(&&json::tdeserializer(JSON))!!;
  assert(v.api == "secret");
  assert(v.port == 8080);
}

fn void test_des_alias_not_converted_by_rename_all() @test => @pool() {
  // "API_KEY" is the rename_all form of the alias, which is never generated
  const String JSON = `{"API_KEY": "secret", "PORT": 8080}`;
  DAliasedRenameAll v = des::deserialize{DAliasedRenameAll}(&&json::tdeserializer(JSON))!!;
  assert(v.api == "");
  assert(v.port == 8080);
}

fn void test_des_alias_canonical_key_still_renamed_all() @test => @pool() {
  // the field name itself is still converted: "api" → "API"
  const String JSON = `{"API": "secret", "PORT": 8080}`;
  DAliasedRenameAll v = des::deserialize{DAliasedRenameAll}(&&json::tdeserializer(JSON))!!;
  assert(v.api == "secret");
  assert(v.port == 8080);
}

fn void test_des_alias_satisfies_required() @test => @pool() {
  // the required field arrives under its alias → no MISSING_REQUIRED_FIELD,
  // and deny_unknown_fields does not treat the alias as unknown
  const String JSON = `{"tok": "abc"}`;
  DAliasedRequired v = des::deserialize{DAliasedRequired}(&&json::tdeserializer(JSON))!!;
  assert(v.token == "abc");
}

fn void test_des_alias_required_still_faults_when_absent() @test => @pool() {
  // neither the canonical key nor an alias is present
  const String JSON = `{"other": "abc"}`;
  DAliasedRequired? v = des::deserialize{DAliasedRequired}(&&json::tdeserializer(JSON));
  if (catch err = v) {
    assert(err == des::UNKNOWN_FIELD || err == des::MISSING_REQUIRED_FIELD);
  } else {
    assert(false); // must have faulted
  }
}

// ── Flattened HashMap: keys arriving out of declaration order ────────────────
// A flattened `HashMap` gathers the keys that match no declared field. It must
// only take those: a key belonging to a field declared *after* the map still
// has to reach that field, whatever order the input lists them in.

$expand(dessert::@derive(DFlatMapOrder, deserialize));
struct DFlatMapOrder {
  String name;
  int    age;
  HashMap{String, int} extra @DFieldDes({ .flatten = true });
}

fn void test_des_flatten_hashmap_out_of_order() @test => @pool() {
  // "age" is declared after the flattened map and arrives between two of the
  // map's own keys
  const String JSON = `{"name": "bob", "x": 1, "age": 30, "y": 2}`;
  DFlatMapOrder v = des::deserialize{DFlatMapOrder}(&&json::tdeserializer(JSON))!!;
  assert(v.name == "bob");
  assert(v.age == 30);
  assert(v.extra.len() == 2);
  assert(v.extra["x"]!! == 1);
  assert(v.extra["y"]!! == 2);
  assert(@catch(v.extra["age"]));  // must have gone to the `age` field
  assert(@catch(v.extra["name"])); // must have gone to the `name` field
}
