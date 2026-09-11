# dessert 🍰

A universal serialization and deserialization library for the [C3 programming language](https://c3-lang.org/).

## Goal

Dessert provides a flexible, type-safe framework for converting C3 structs to and from various formats. It ships several formats out of the box - **JSON** (serialize + deserialize), **CSV** (serialize), **XML** (serialize), and **dotenv** (deserialize) - and lets you add your own by implementing two interfaces. It uses compile-time macros to generate serialization/deserialization code, ensuring type safety and minimal runtime overhead.

The library is built around two core interfaces:
- **Serializer**: Converts C3 structs into a target format
- **Deserializer**: Parses data from a format back into C3 structs

## Installation

### Using [`c3po`](https://github.com/Ecoral360/c3po);
In your project, run 
```sh
c3po add ecoral360/dessert
```

### Manually
Get started with dessert: 
1. Make sure you have the [C3 compiler installed](https://github.com/c3lang/c3c)
2. Run `c3c init <YOUR_PROJECT>`
4. Clone the this repository into `<YOUR_PROJECT>/lib/dessert.c3l`
5. Add `"dependencies": ["dessert"]` to your `project.json`
6. You are done !

## Usage

### 1. Define Your Struct

Use `$expand(dessert::@derive(...))` to automatically generate `serialize` and `deserialize` methods:

```c3
$expand(dessert::@derive(Animal));
struct Animal {
    String name;
    String specie;
}
```

With no second argument both methods are derived. Pass `serialize` or `deserialize` to derive only one:

```c3
$expand(dessert::@derive(Animal, serialize));   // serialize only
$expand(dessert::@derive(Animal, deserialize)); // deserialize only
```

> **Imports:** `import dessert;` brings in the derive machinery and all the format factories (`json::serializer`, `csv::serializer`, `xml::serializer`, …). Add `import json;` / `import csv;` only when you need to name the value types directly (`JsonValue`, `CSVValue`, `CSVDocument`); XML has no separate value type.

### 2. Serialize

#### To JSON
```c3
Animal sharpie = { .specie = "Cat", .name = "Sharpie" };
String json = json::tstring_serialize(sharpie)!!;
```

#### To CSV

```c3
Animal[] animals = {
    { .name = "Sharpie", .specie = "Cat" },
    { .name = "Gisele",  .specie = "Bunny" },
};
CSVSerializer s = csv::serializer();
CSVDocument doc = ser::serialize(&s, animals)!;
io::printn(doc.to_string());
```

Output:
```
"name","specie"
"Sharpie","Cat"
"Gisele","Bunny"
```

### 3. Deserialize

#### From a JSON String

```c3
String json_str = "{\"name\": \"Sharpie\", \"specie\": \"Cat\"}";
Animal? animal = json::tdeserialize{Animal}(json_str);
```

#### From a Dotenv file

```c3
$expand(dessert::@derive(Settings));
struct Settings @DStruct({ .rename_all = UPPER_CASE }) {
  Maybe{String} api_key;
  long version;
  bool debug;

  Validated{String} url @DField({ .fmt = { `min_length=5` } });

  Loglevel log_level @DField({ .rename = "LOG" });

  Email email @DField({ .required = true });
  String other_email;

  NumberGt{int, 0} age;
}

Settings settings = dotenv::tload{Settings}()!!; // takes an optional path to the file, default is "./.env"
```

## Complete Example

```c3
module example;
import std;
import dessert;

$expand(dessert::@derive(Animal));
struct Animal {
  String name;
  String specie;
}

$expand(dessert::@derive(Person));
struct Person {
  int age;
  String name;
  Animal[] pets;
  Maybe{Person*} friend @DField({ .rename = "my_friend" });
  bool is_cool @DField({ .skip = true });
}

fn int main(String[] args) {
  Animal sharpie = { .name = "Sharpie", .specie = "Cat" };
  Person connor = { .age = 20, .name = "Connor", .is_cool = true };
  connor.pets = { sharpie };

  String json = json::tstring_serialize(connor)!!;
  io::printn(json);

  Person? p = json::tdeserialize{Person}(json);
  if (catch p) {
    io::printn("Error deserializing");
    return -1;
  }

  io::printfn("Person named %s with a %s named %s", p.name, p.pets[0].specie, p.pets[0].name);
  
  return 0;
}

```
## Features

### Serialization

- Recursive struct serialization (nested structs)
- Support for `Maybe` fields (optional values)
- Support for slice/array/List fields
- Enum serialization (as name, ordinal, or associated field)
- Tagged union serialization (named, anonymous, and inlined patterns)
- Field flattening (inline a nested struct's fields into the parent)
- Skip specific fields during serialization
- Skip empty fields (slices, `Maybe`, pointers) via `skip_if_empty`
- Conditionally skip fields via `skip_serializing_<field>` methods
- Custom per-field encoding via `serialize_<field>` methods
- Rename fields for the output
- Bulk field rename via `rename_all` case conventions
- Validate field values before serialization
- Support for all primitive types: `bool`, `char`, `ichar`, `short`, `int`, `long`, `int128`, `ushort`, `uint`, `ulong`, `uint128`, `float`, `double`, `String`, `ZString`

### Deserialization

- Handle nested structures
- Support for `Maybe` fields
- Support for slice/array/List fields
- Enum deserialization (as name, ordinal, or associated field)
- Enum fallback variant for unknown values via `.fallback`
- Tagged union deserialization (named, anonymous, and inlined patterns)
- Field renaming support (different name in the format and in C3)
- Extra accepted keys per field via `.aliases`
- Custom per-field decoding via `deserialize_<field>` methods
- Required fields via `.required` (error when a field is missing)
- Default field values via `.default_value` when a field is missing
- Fixed-size array overflow control via `.array.skip_extra` (discard extras vs. error)
- Duplicate key detection
- Unknown field skipping (or rejection via `deny_unknown_fields`)
- Deserialize arbitrary data into `Object` fields
- Descriptive error messages on deserialization failure
- Support for gathering extra fields in a `HashMap` (with `flatten`) 
- Support for aggregated field in a `List` (with `flatten`)
- Support for all primitive types: `bool`, `char`, `ichar`, `short`, `int`, `long`, `int128`, `ushort`, `uint`, `ulong`, `uint128`, `float`, `double`, `String`, `ZString`

### JSON

The `dessert::format::json` module (reachable as `json::`) provides a complete JSON serializer and deserializer.

**Serializers:**
- `json::serializer` produces a `JsonValue` (with methods like `to_string()` / `to_pretty_string()`). Accepts an optional allocator: `json::serializer(allocator)` (defaults to `tmem`).
- `json::string_serializer` produces a JSON string directly (also allocator-optional, defaults to `tmem`).
- Convenience one-shot macros: `json::string_serialize(allocator, value)` and `json::tstring_serialize(value)` (uses `tmem`) serialize a value straight to a JSON `String`.

**Deserializers** take a `String` **or** an `InStream` as input:
- `json::deserializer(allocator, input, flavor = JSONC)` - deserializer with a custom allocator.
- `json::tdeserializer(input, flavor = JSONC)` - convenience deserializer that uses `tmem`.
- Convenience one-shot macros: `json::deserialize{Type}(allocator, input, flavor)` and `json::tdeserialize{Type}(input, flavor)`.

**JSON flavor:** the `JsonFlavor` enum selects the parsing dialect - `JSON` (strict) or `JSONC` (a relaxed, JSON5-style superset that allows comments and trailing commas). The default for every deserializer is `JSONC`.

> The `debug_deserializer` / `tdebug_deserializer` factories are deprecated - pass `debug: true` to `json::deserializer` / `json::tdeserializer` instead.

### CSV

The `dessert::format::csv` module (reachable as `csv::`) provides a CSV serializer for converting slices of structs into CSV format. Only serialization is supported for now (no CSV deserializer).

- `csv::serializer()` - takes no allocator. Its `.result()` returns a `CSVDocument`; call `.to_string()` on that document to get the CSV text.

### XML

The `dessert::format::xml` module (reachable as `xml::`) provides an XML serializer. Only serialization is supported for now (no XML deserializer yet).

- `xml::serializer()` - takes no allocator. Its `.result()` returns the produced XML `String`.
- `xml::pretty_string(xml, indent_size = 2)` - reformats an XML string with indentation.
- Fields tagged with the `xml:attribute` format attribute are emitted as XML attributes on the enclosing element instead of as child elements. Attribute fields **must** be declared before any element fields of the same struct:

```c3
struct Point {
    int x @DFieldSer({ .fmt = { "xml:attribute" } });
    int y @DFieldSer({ .fmt = { "xml:attribute" } });
}
// { .x = 1, .y = 2 } -> <point x="1" y="2"></point>
```

### Dotenv (`.env`)

The `dessert::format::dotenv` module (reachable as `dotenv::`) provides a deserializer for `.env`-style files (`KEY=value` lines). Only deserialization is supported (no serializer). It reads directly from a file path:

- `dotenv::load{Type}(allocator, filepath = ".env")` - deserialize a `.env` file with a custom allocator.
- `dotenv::tload{Type}(filepath = ".env")` - convenience variant that uses `tmem`.

```c3
struct Config @DStruct({ .rename_all = UPPER_CASE }) {
    String database_url;
    int    port;
    bool   debug;
}

// reads ./.env by default
Config? cfg = dotenv::tload{Config}();
```

### Attributes

Use the `@DField` attribute to customize serialization/deserialization behavior for struct fields:

```c3
struct Person {
    int age;                                  // Serialized as "age"
    String name;                              // Serialized as "name"
    bool is_cool @DFieldSer({ .skip = true });  // Skipped during serialization
    Maybe{Person*} friend @DField({ .rename = "my_friend" }); // Renamed to "my_friend"
    int score @DField({ .validator = "validate_score" }); // Validated before serialization
}
```

**Field attributes:**

| Attribute       | Description                                                                     |
|-----------------|---------------------------------------------------------------------------------|
| `@DField`      | Apply config to both serialization and deserialization                          |
| `@DFieldSer`   | Apply config to serialization only                                              |
| `@DFieldDes`   | Apply config to deserialization only                                            |

**Field attribute options (`DFieldConfig` struct):**

| Option           | Type       | Description                                                                       |
|------------------|------------|-----------------------------------------------------------------------------------|
| `.skip`          | `bool`     | Skip this field during serialization/deserialization                              |
| `.skip_if_empty` | `bool`     | Skip this field during serialization if it is empty (null pointer, empty slice, or unset `Maybe`) |
| `.rename`        | `String`   | Use a different name for this field in the output/input                           |
| `.aliases`       | `String[]` | Alternative names to accept during deserialization          |
| `.validator`     | `String`   | Call a validation method before serialization                                     |
| `.fmt`           | `FieldAttrs` (`String[]`) | Format-specific per-field attributes, e.g. `{ "xml:attribute" }`. Each entry is read as a bare `key` or as `key=value` |
| `.flatten`       | `bool`                   | Flatten a nested struct's fields directly into the parent object |
| `.tagged`        | `DFieldUnionConfig`      | Tagged union configuration (see Union attributes below)          |
| `.default_value` | `String`                 | Expression used as the field's value during deserialization when the field is missing from the input |
| `.required`      | `bool`                   | Fault with `MISSING_REQUIRED_FIELD` during deserialization if the field is absent from the input |
| `.array`         | `DFieldArrayConfig`      | Fixed-size array options; `.array.skip_extra` (`bool`) discards input items beyond the array's capacity instead of faulting |

`.default_value` is a C3 expression (as a string) that is spliced in when a field is absent from the input, instead of leaving it zero-initialized:

```c3
struct Settings {
    String host @DField({ .default_value = `"localhost"` });
    int    port @DField({ .default_value = "8080" });
}
// deserializing "{}" yields { .host = "localhost", .port = 8080 }
```

`.required` is the deserialization-time counterpart: an absent field is an error instead of a zero value. It composes with `.rename` (the field must appear under its renamed key):

```c3
struct Credentials {
    String token @DFieldDes({ .rename = "tok", .required = true });
}
// deserializing "{}" or {"token": "..."} -> MISSING_REQUIRED_FIELD
// deserializing {"tok": "abc"}           -> { .token = "abc" }
```

`.aliases` lists **extra** input keys accepted for a field, on top of its canonical key. It only affects deserialization; serialization always writes the canonical key.

```c3
struct Account {
    String name @DFieldDes({ .aliases = { "nom", "nombre" } });
    int    age;
}
// {"name": "bob"}   -> { .name = "bob" }  (canonical key still works)
// {"nom": "bob"}    -> { .name = "bob" }
// {"nombre": "bob"} -> { .name = "bob" }
// {"namen": "bob"}  -> { .name = "" }     (unlisted key, treated as unknown)
```

It composes with the other naming options:

- with `.rename`, the renamed key and the aliases are accepted, but the field name itself is not;
- aliases are matched **verbatim**: `rename_all` converts the field name only, never the aliases;
- an alias satisfies `.required`, and is never reported as an unknown field under `deny_unknown_fields`.

```c3
struct Config @DStructDes({ .rename_all = UPPER_CASE }) {
    String api @DFieldDes({ .aliases = { "api_key" } });
}
// {"API": "s"}     -> { .api = "s" }   (field name converted by rename_all)
// {"api_key": "s"} -> { .api = "s" }   (alias taken as written)
// {"API_KEY": "s"} -> { .api = "" }    (aliases are not converted)
```

**Fixed-size arrays (`.array`):**

A `T[N]` field has a fixed capacity. During deserialization, an input sequence with **fewer** items than `N` leaves the trailing elements zero-initialized (not an error). An input with **more** than `N` items faults with `TOO_MANY_ELEMENTS_IN_ARRAY` by default; set `.array.skip_extra` to keep the first `N` items and discard the overflow instead:

```c3
struct Sample {
    int[3] scores;                                       // strict
    int[3] top @DFieldDes({ .array.skip_extra = true }); // lenient
}
// {"scores": [1,2],       "top": [1,2,3,4,5]} -> { .scores = {1,2,0}, .top = {1,2,3} }
// {"scores": [1,2,3,4,5], "top": [1,2,3]}     -> TOO_MANY_ELEMENTS_IN_ARRAY
```

(Slices and `List` fields grow to fit the input, so `.array` only applies to fixed-size arrays.)

**Conditional skip methods:**

If a struct has a method named `skip_serializing_<field>` that returns `bool`, dessert will call it before serializing that field and skip the field if it returns `true`:

```c3
struct Person {
    int age;
    String name;
}

fn bool Person.skip_serializing_age(&self) {
    return self.age < 10; // don't serialize age when it's less than 10
}
```

**Custom per-field serialize / deserialize methods:**

To take control of a single field's encoding, give the struct a `serialize_<field>` and/or `deserialize_<field>` method. dessert still writes and reads the field's key and delimiters - the method only handles the *value*. Both methods receive the format-agnostic `Serializer` / `Deserializer` interface, so the same struct works with every format, and their **return type selects the protocol**.

```c3
struct User {
    String   name;
    String   password;
    double   temperature;
    String[] tags;
}
```

**`serialize_<field>(&self, Serializer ser)`** - two modes, chosen by the return type:

1. **Return a value (`Type?`)** - dessert serializes the returned value the normal way. Use this to transform or substitute the value while letting the format handle the encoding.
2. **Return `void?`** - dessert assumes you emitted the value yourself through `ser`.

```c3
// Mode 1: return a value; dessert serializes it normally.
fn String? User.serialize_password(&self, Serializer ser) {
    return "***"; // never leak the real value; encoded as a normal string
}

// Mode 2: return void; you drive the serializer.
fn void? User.serialize_tags(&self, Serializer ser) {
    ser.serialize_slice_start(self.tags.len)!;
    foreach (i, t : self.tags) {
        ser.serialize_string(t)!;
        ser.serialize_slice_item_end(i)!;
    }
    ser.serialize_slice_end(self.tags.len)!;
}
```

**`deserialize_<field>(&self, Deserializer des)`** - the mirror image:

1. **Return a value (`Type?`)** - dessert assigns the returned value to the field. Use this to read then transform the value.
2. **Return `void?`** - dessert assumes you already assigned the field yourself (via `&self`).

```c3
// Mode 1: return the value; dessert assigns it to the field.
fn double? User.deserialize_temperature(&self, Deserializer des) {
    double fahrenheit = des.next_double()!;
    return (fahrenheit - 32.0) * 5.0 / 9.0; // stored as Celsius
}

// Mode 2: return void; assign the field yourself.
fn void? User.deserialize_name(&self, Deserializer des) {
    self.name = des.next_string()!; // write straight into the field via &self
}
```

The methods can read the rest of `self`, and returning a fault (e.g. `return INVALID_VALUE~;`) aborts (de)serialization and propagates the error to the caller.

**Type-level custom serialize / deserialize methods:**

Instead of hooking a single field on the owner struct, a type can define its own `serialize` / `deserialize` methods. dessert detects them and routes any value of that type through them - anywhere it appears (a field, a slice element, a map value). This is how you build reusable newtypes and validated wrappers.

```c3
typedef Email = String;

fn void? Email.serialize(&self, Serializer ser) => ser.serialize_string((String) *self)!;

fn void? Email.deserialize(&self, Deserializer des) {
    String s = des.next_string()!;
    if (!s.contains("@")) return INVALID_EMAIL~;
    *self = (Email) s;
}
```

Both methods may take the field's `DFieldConfig` as an optional **second parameter**, letting a type react to the `@DField` attributes on the field that holds it (e.g. read `.fmt` entries):

```c3
fn void? MyType.serialize(&self, Serializer ser, DFieldConfig config) { ... }
fn void? MyType.deserialize(&self, Deserializer des, DFieldConfig config) { ... }
```

The `dessert::values` module ships experimental wrappers built on this: range-checked `Number{Backing, MIN, MAX}` newtypes and a generic `Validated{Type}` wrapper. `Validated{String}` reads `min_length` / `max_length` from the field's `.fmt` and raises a validation fault when the decoded value is out of bounds:

```c3
Validated{String} url @DField({ .fmt = { `max_length=5` } });
```

**Still experimental**; the API may change.

**Inspecting field configuration (for format authors and macros):**

The config attached to a field is reachable at compile time so custom formats and generic
code can react to it:

- `dessert::@get_fieldconfig($member)` - returns a `DFieldCompleteConfig { DFieldConfig ser; DFieldConfig des; }` for a reflected struct member, merging its `@DField` / `@DFieldSer` / `@DFieldDes` tags.
- `FieldAttrs.@get(needle)` (compile-time) / `FieldAttrs.get(needle)` (runtime) - read a single `.fmt` entry, returning `"true"` for a bare `key` or the right-hand side of a `key=value` entry. This is how the XML serializer detects `xml:attribute`.

```c3
$foreach $member : MyType.members:
    DFieldCompleteConfig $cfg = dessert::@get_fieldconfig($member);
    $if $cfg.des.fmt.@get("allocator") == "true":
        // this field opts into the "allocator" fmt attribute
    $endif
$endforeach
```

**Enum attributes:**

Use `@DEnum` (or `@DEnumSer` / `@DEnumDes`) on an enum type to control how it is serialized:

```c3
enum Color @DEnum({ .as = DESCRIPTION }) {
    RED,
    GREEN,
    BLUE,
}
```

| Attribute         | Description                                                    |
|-------------------|----------------------------------------------------------------|
| `@DEnum`    | Apply enum config to both serialization and deserialization    |
| `@DEnumSer` | Apply enum config to serialization only                        |
| `@DEnumDes` | Apply enum config to deserialization only                      |

**Enum attribute options (`DEnumConfig` struct):**

| Option      | Type          | Description                                                                          |
|-------------|---------------|--------------------------------------------------------------------------------------|
| `.as`       | `DessertEnum` | How to represent the enum: `DESCRIPTION` (default), `ORDINAL`, or `FIELD`           |
| `.rename_all` | `CaseConvention` | Rewrite variant names using a naming convention (applies when the enum is encoded by name, i.e. `.as = DESCRIPTION`) |
| `.field`    | `String`      | Name of the associated field to use when `.as = FIELD`                               |
| `.fallback` | `String`      | Name of the variant to use when the JSON value doesn't match any known variant (deserialization only). If not set, `INVALID_ENUM_VALUE` is raised instead. |

```c3
// Unknown JSON variant -> UNKNOWN instead of raising INVALID_ENUM_VALUE
enum Status @DEnumDes({ .fallback = "UNKNOWN" }) {
    ACTIVE,
    INACTIVE,
    UNKNOWN,
}

// Unknown field value -> NONE instead of raising INVALID_ENUM_VALUE
enum Priority : (String code) @DEnumDes({ .as = FIELD, .field = "code", .fallback = "NONE" }) {
    HIGH   { "high"   },
    MEDIUM { "medium" },
    NONE   { ""       },
}
```

**Struct attributes:**

Use `@DStruct` (or `@DStructSer` / `@DStructDes`) on a struct type to control struct-level behavior:

```c3
struct Function @DStruct({ .deny_unknown_fields = true }) {
    String name;
    String arguments;
}
```

| Attribute            | Description                                                        |
|----------------------|--------------------------------------------------------------------|
| `@DStruct`     | Apply struct config to both serialization and deserialization      |
| `@DStructSer`  | Apply struct config to serialization only                          |
| `@DStructDes`  | Apply struct config to deserialization only                        |

**Struct attribute options (`DStructConfig` struct):**

| Option                  | Type             | Description                                                                         |
|-------------------------|------------------|-------------------------------------------------------------------------------------|
| `.deny_unknown_fields`  | `bool`           | Return `UNKNOWN_FIELD` fault if an unrecognized field is encountered during deserialization (default: skip unknown fields silently) |
| `.deny_dup_keys`        | `bool`           | Raise `DUPLICATED_KEY` if the same field appears more than once during deserialization |
| `.rename_all`           | `CaseConvention` | Rename all fields using a naming convention                                         |

**`CaseConvention` values:**

| Value                   | Example output       |
|-------------------------|----------------------|
| `VERBATIM`              | `verbatim`           |
| `KEBAB_CASE`            | `kebab-case`         |
| `CAMEL_CASE`            | `camelCase`          |
| `PASCAL_CASE`           | `PascalCase`         |
| `CONSTANT_CASE`         | `CONSTANT_CASE`      |
| `SNAKE_CASE`            | `snake_case`         |
| `LOWER_CASE`            | `lower`              |
| `UPPER_CASE`            | `UPPER`              |

```c3
struct UserRecord @DStructSer({ .rename_all = CAMEL_CASE }) {
    String first_name;   // serialized as "firstName"
    String last_name;    // serialized as "lastName"
    int    birth_year;   // serialized as "birthYear"
}
```

**Union attributes:**

Use `@DField({ .tagged = { .by = "field" } })` on a union member to enable tagged dispatch - the value of the named sibling field determines which union member is active. All union configuration lives in the `tagged` sub-struct of `@DField`.

**`DFieldUnionConfig` options (used as `.tagged = { ... }`):**

| Option       | Type                   | Description                                                                          |
|--------------|------------------------|--------------------------------------------------------------------------------------|
| `.by`        | `String`               | Name of the sibling field whose value selects the active union member (**required**) |
| `.inlined`   | `bool`                 | Inline the active member's value directly (no wrapping object, `false` by default)  |
| `.match`     | `DFieldUnionMatch`     | How to match the tag value to a union member (see below)                             |
| `.unmapped`  | `DFieldUnionUnmapped`  | What to do when the tag value matches no union member (default: `ERROR`)             |

**`DFieldUnionMatch` options (used as `.tagged = { .match = { ... } }`):**

| Option    | Type          | Description                                                                                        |
|-----------|---------------|----------------------------------------------------------------------------------------------------|
| `.by`     | `DessertEnum` | How to match: `ORDINAL` (default for non-enum tags), `DESCRIPTION`, or `FIELD`                    |
| `.field`  | `String`      | Associated enum field name (a `String`); required when `.by = FIELD`                              |

**`match.by` modes:**

| Value         | Behavior                                                                                           |
|---------------|----------------------------------------------------------------------------------------------------|
| `ORDINAL`     | Cast tag to `sz`; select member by 0-based index. Used automatically for non-enum tags.           |
| `DESCRIPTION` | Switch on the enum value itself; union member names uppercased must match enum value names.        |
| `FIELD`       | Switch on `tag.<field>` (a `String`); value must equal the union member name exactly.              |

**`DFieldUnionUnmapped` options (used as `.tagged = { .unmapped.as = ... }`):**

| Option | Type         | Serialize behavior             | Deserialize behavior              |
|--------|--------------|--------------------------------|-----------------------------------|
| `.as = ERROR`        | (default)  | Raise `UNMAPPED_UNION_VARIANT` | Raise `UNMAPPED_UNION_VARIANT`    |
| `.as = EMPTY_STRUCT` |            | Write `{}` (empty object)      | Consume next value as `Object*`   |
| `.as = NULL`         |            | Write `null`                   | Consume next value as `Maybe{int}`|
| `.as = ZERO`         |            | Write `0`                      | Consume next value as `int`       |

**Five output patterns:**

*Pattern A - named union field, not inlined (active member wrapped in a nested object):*

```c3
$expand(dessert::@derive(Message));
struct Message {
  int kind;
  union payload @DField({ .tagged.by = "kind" }) {
    int    count;
    double ratio;
    String text;
  }
}
// kind=0 -> {"kind":0,"payload":{"count":42}}
// kind=2 -> {"kind":2,"payload":{"text":"hi"}}
```

*Pattern B - anonymous union field (active member flattened into parent):*

```c3
$expand(dessert::@derive(Message));
struct Message {
  int kind;
  union @DField({ .tagged.by = "kind" }) {
    int    count;
    double ratio;
    String text;
  }
}
// kind=0 -> {"kind":0,"count":42}
// kind=2 -> {"kind":2,"text":"hi"}
```

*Pattern C - named union field with `.inlined = true` (active value inlined, no wrapping object):*

```c3
union Variant {
  int    count;
  struct point { int x; int y; }
  String label;
}

$expand(dessert::@derive(Response));
struct Response {
  int     tag;
  Variant val @DField({ .tagged = { .by = "tag", .inlined = true } });
}
// tag=0 -> {"tag":0,"val":42}
// tag=1 -> {"tag":1,"val":{"x":1,"y":2}}
```

*Pattern D - enum tag with `match.by = DESCRIPTION` (match by enum value name):*

```c3
$expand(dessert::@derive(Shape));
enum Shape { CIRCLE, SQUARE, TRIANGLE }

$expand(dessert::@derive(Drawing));
struct Drawing {
  Shape kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .match.by = DESCRIPTION } }) {
    int    circle;    // matched by enum value CIRCLE
    double square;    // matched by enum value SQUARE
    String triangle;  // matched by enum value TRIANGLE
  }
}
```

*Pattern E - enum tag with `match.by = FIELD` (match by enum associated String field):*

```c3
$expand(dessert::@derive(Format));
enum Format : (String mime) {
  JSON_FMT { "json_fmt" },
  CSV_FMT  { "csv_fmt"  },
}

$expand(dessert::@derive(Output));
struct Output {
  Format kind;
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .match = { .by = FIELD, .field = "mime" } } }) {
    int    json_fmt;  // matched when kind.mime == "json_fmt"
    String csv_fmt;   // matched when kind.mime == "csv_fmt"
  }
}
```

*Using `unmapped.as` to handle unknown tag values gracefully:*

```c3
$expand(dessert::@derive(Request));
struct Request {
  int kind;
  // Out-of-range kind consumed as null instead of raising a fault
  union payload @DField({ .tagged = { .by = "kind", .inlined = true, .unmapped.as = NULL } }) {
    int    ping;
    String text;
  }
}
```

> **Note:** when deserializing an inlined union field, the tag field **must** appear before the union field in the input.

## Architecture

### Serializer Interface

Required methods must be implemented. Optional methods (`@optional`) fall back to a required counterpart if not provided.

```c3
interface Serializer {
  fn void? struct_start(String name);
  fn void? serialize_field_start(String name, FieldAttrs fmt, typeid field_type);
  fn void? serialize_field_end(String name, FieldAttrs fmt, typeid field_type);
  fn void? struct_end(String name);

  fn void? serialize_slice_start(long len);
  fn void? serialize_slice_item_start(usz idx) @optional;
  fn void? serialize_slice_item_end(usz idx) @optional;
  fn void? serialize_slice_end(long len);

  fn void? serialize_null();
  fn void? serialize_bool(bool b);
  fn void? serialize_long(long l);
  fn void? serialize_string(String s);
  fn void? serialize_double(double d);

  fn void? serialize_char(char c) @optional;      // falls back to serialize_string({c})
  fn void? serialize_ichar(ichar c) @optional;    // falls back to serialize_long

  fn void? serialize_short(short s) @optional;    // falls back to serialize_long
  fn void? serialize_int(int i) @optional;        // falls back to serialize_long
  fn void? serialize_int128(int128 i) @optional;  // returns UNSUPPORTED_DATA_TYPE if absent

  fn void? serialize_uint(uint i) @optional;      // falls back to serialize_ulong
  fn void? serialize_ushort(ushort s) @optional;  // falls back to serialize_ulong
  fn void? serialize_ulong(ulong l) @optional;    // falls back to serialize_long
  fn void? serialize_uint128(uint128 i) @optional; // returns UNSUPPORTED_DATA_TYPE if absent

  fn void? serialize_zstring(ZString s) @optional; // falls back to serialize_string

  fn void? serialize_float(float f) @optional;     // falls back to serialize_double
}
```

### Deserializer Interface

Required methods must be implemented. Optional methods (`@optional`) fall back to a required counterpart if not provided.

```c3
interface Deserializer {
  fn void? struct_start(String name);
  fn bool? has_next_field();
  fn String? next_field_name();
  fn String? peek_field_name();       // inspect the next field name without consuming it
  fn void? struct_end(String name);

  fn void? slice_start();
  fn bool? has_next_slice_item();
  fn void? slice_end();

  fn bool? next_null();
  fn bool? next_bool();
  fn String? next_string();
  fn double? next_double();

  fn Object*? next_any() @optional;          // deserialize any value as Object*
  fn void? skip_next_value() @optional;      // discard the next value (unknown fields)
  fn String? next_enum_description() @optional; // falls back to next_string

  fn char? next_char() @optional;   // falls back to next_string()[0]
  fn ichar? next_ichar() @optional;    // falls back to next_long

  fn long? next_long() @optional;      // falls back to next_double
  fn short? next_short() @optional;   // falls back to next_long
  fn int? next_int() @optional;        // falls back to next_long
  fn int128? next_int128() @optional;  // returns UNSUPPORTED_DATA_TYPE if absent

  fn ushort? next_ushort() @optional;  // falls back to next_ulong
  fn uint? next_uint() @optional;      // falls back to next_ulong
  fn ulong? next_ulong() @optional;    // falls back to next_long
  fn uint128? next_uint128() @optional; // returns UNSUPPORTED_DATA_TYPE if absent

  fn ZString? next_zstring() @optional; // falls back to next_string

  fn float? next_float() @optional;    // falls back to next_double

  fn Allocator get_allocator() @optional;

  fn void? error(fault excuse, String msg) @optional; // custom error reporting; falls back to eprintfn
}
```

### Adding Support for New Formats

To add support for a new format (e.g., YAML, MessagePack), implement the `Serializer` and `Deserializer` interfaces (see the [json implementation](./src/formats/json.c3) for a model):

```c3
struct MySerializer (Serializer) {
    // Your implementation
}

fn void? MySerializer.serialize_int(&self, int i) @dynamic {
    // Format-specific implementation
}

struct MyDeserializer (Deserializer) {
    // Your implementation
}

fn int? MyDeserializer.next_int(&self) @dynamic {
    // Format-specific implementation
}
```

## Error Handling

Dessert uses C3's fault system for error handling:

| Fault                    | Module         | Description                                      |
|--------------------------|----------------|--------------------------------------------------|
| `VALIDATOR_ERROR`        | `ser`          | Field validation failed during serialization     |
| `UNSUPPORTED_DATA_TYPE`  | `ser` / `des`  | Type has no supported encoding (e.g. `int128`)   |
| `UNSUPPORTED_ANY`        | `des`          | Format cannot deserialize an arbitrary value into `Object*` |
| `DUPLICATED_KEY`         | `des`          | Duplicate key found during deserialization       |
| `INVALID_ENUM_VALUE`     | `des`          | Enum name not found during deserialization       |
| `UNKNOWN_FIELD`          | `des`          | Unknown field encountered when `deny_unknown_fields` is set |
| `INLINED_UNION_BEFORE_TAG`  | `des`        | Inlined union appeared before its tag field in the input |
| `UNMAPPED_UNION_VARIANT`    | `ser` / `des`| Tag value matched no union member                        |
| `MISSING_REQUIRED_FIELD`    | `des`        | A field marked `.required` was absent from the input     |
| `TOO_MANY_ELEMENTS_IN_ARRAY`| `des`        | Input sequence exceeded a fixed-size array's capacity (and `.array.skip_extra` was not set) |
| `INVALID_CSV_TYPE`       | `dessert::format::csv` | Unsupported value type during CSV serialization  |
| `XML_ATTRIBUTE_AFTER_FIELD` | `dessert::format::xml` | An `xml:attribute` field appeared after a non-attribute field |
| `XML_SLICE_IN_ATTRIBUTE`    | `dessert::format::xml` | A slice/array was used where an XML attribute value is expected |
| `INVALID_JSON_TYPE`      | `json`         | Invalid JSON structure                           |
| `UNEXPECTED_CHARACTER`   | `json`         | Unexpected character while parsing JSON          |
| `INVALID_OBJECT`         | `json`         | Expected JSON object                             |
| `INVALID_FIELD`          | `json`         | Invalid field format                             |
| `INVALID_ARRAY`          | `json`         | Expected JSON array                              |
| `INVALID_STRING`         | `json`         | Invalid string format                            |
| `INVALID_ESCAPE`         | `json`         | Invalid escape sequence in string                |
| `INVALID_NUMBER`         | `json`         | Invalid number format                            |
| `INVALID_BOOLEAN`        | `json`         | Invalid boolean value                            |
| `INVALID_NULL`           | `json`         | Invalid null value                               |
| `INVALID_COMMENT`        | `json`         | Malformed comment (JSONC flavor)                 |

**Custom error reporting:** a deserializer may implement the optional `error(fault excuse, String msg)` method. When deserialization raises an error (unknown field, missing required field, failed value validation, ...) dessert calls this hook with the fault and a formatted message before returning the fault, letting a format collect diagnostics or print its own message. If absent, dessert falls back to `io::eprintfn`.

## Best Practices

1. **Use `@derive` for full round-trip support**: `$expand(dessert::@derive(MyStruct))` generates both `serialize` and `deserialize` at once with no boilerplate.

2. **Use skip for sensitive data**: Mark fields that shouldn't be serialized (e.g., passwords) with `.skip = true` or use the `SecretString` type that serializes to `"*****"`.

3. **Tag fields before union fields**: When deserializing tagged unions, the tag field must appear before the union field in the JSON input. If using `.inlined = true`, the tag must appear first in the wire format to avoid `INLINED_UNION_BEFORE_TAG`.

4. **Handle unmapped union variants**: By default, a tag value that doesn't match any union member raises `UNMAPPED_UNION_VARIANT`. Use `.unmapped = { .as = NULL }` (or `EMPTY_STRUCT` / `ZERO`) on the union field to handle gracefully instead.

## Roadmap

- [x] Serialize to JSON
- [x] Serialize to CSV (slices of structs)
- [x] Serialize to XML (with `xml:attribute` fields)
- [x] Deserialize from `.env` files (`dotenv::load` / `dotenv::tload`)
- [x] JSONC / JSON5-style relaxed parsing (`JsonFlavor`)
- [x] Recursive struct serialization
- [x] Serialize Maybe fields
- [x] Serialize slice fields
- [x] Serialize struct fields
- [x] Serialize enum fields (as name, ordinal, or associated field)
- [x] Skip field
- [x] Skip field if empty (`skip_if_empty`)
- [x] Conditionally skip field via `skip_serializing_<field>` method
- [x] Rename field
- [x] Validate field
- [x] Deserialize from JSON
- [x] Deserialize enum fields (as name, ordinal, or associated field)
- [x] Enum fallback variant via `@DEnum({ .fallback = "VARIANT" })`
- [x] Full primitive type support (all integer, float, string variants)
- [x] Skip unknown fields during deserialization (default)
- [x] Deny unknown fields via `@DStruct({ .deny_unknown_fields = true })`
- [x] Deserialize arbitrary JSON into `Object*`
- [x] Serialize/deserialize tagged union fields (named, anonymous, inlined)
- [x] Field flattening via `@DField({ .flatten = true })`
- [x] Bulk field rename via `@DStruct({ .rename_all = CAMEL_CASE })`
- [x] Bulk enum-variant rename via `@DEnum({ .rename_all = ... })`
- [x] Format-specific field attributes via `@DField({ .fmt = { ... } })`
- [x] Reject duplicate keys via `@DStruct({ .deny_dup_keys = true })`
- [x] Default values for missing fields via `@DField({ .default_value = "..." })`
- [x] Type-level custom `serialize` / `deserialize` methods (with optional `DFieldConfig`)
- [x] Support field validation when deserializing (via types with a custom `deserialize` method)
- [x] Field aliases (`.aliases`)
- [ ] Validated value wrappers in `dessert::values` (experimental)
- [ ] Deserialize from CSV / XML

## License

MIT License
