# Changelog

All notable changes to dessert are documented here.

## 0.1.3

- Added support for `aliases` when deserializing
- Added the `SecretString` value type
- Added `json::to_(t)string` as an alias for `json::(t)string_serialize`

## 0.1.2

- Deprecated the old `derive` form
- Changed `derive` to be `dessert::@derive(Type)` which accepts `dessert::@derive(Type, serialize)` and `dessert::@derive(Type, deserialize)` specialized forms
- Added custom error registration with the optional `Deserializer.error` method that will be called with an excuse and an error message.
- Added validated values (in `dessert::values`) **Still experimental**
- Custom serialize and deserialize methods can now take the `DFieldConfig` as a second parameter

## 0.1.1

- Added a `@DField({ array.skip_extra = true|false })` config to allow skipping extra values (default `false`)
- Added support for arrays with exact size in deserialization

## 0.1.0

- Changed the version naming to make it easier to follow, this version is 0.1.0 !
- Added `deserialize_<field>` and `serialize_<field>` methods to customize the de/serialization of a certain field
- Added `required` field option for deserialization

## 2026-07-14
- Added `dotenv` deserializer format
- Added option `rename_all` to `@DEnum` (only for `.as = DESCRIPTION`) for both serialization and deserialization
- Made the required `Deserializer.next_long` optional (now falls back to `(long) Deserializer.next_double()`)

## 2026-07-13
- Added the optional `skip_next_value` for the deserializer
- Added support for all the `rename_all` options
- In rename_all option, renamed `SCREAMING_SNAKE_CASE` to `CONSTANT_CASE`
 
## 2026-07-11
- Added support for `flatten` option on list
- Added `deny_dup_keys` option to structs (default false)

## 2026-06-25

- Added `typeid field_type` to `serialize_field_start` and `serialize_field_end`
- Deprecated `json::debug_deserializer` and `json::tdebug_deserializer`. Use `debug: true` param instead
- Added support for any InStream in the json deserializer
- Added helper macros `json::deserialize` and `json::tdeserialize`
- Added support for JSONC in the json deserializer (use the flavor param)

## 2026-05-21

- Added support for an inline field in a struct (serialization only)
- Added support for constdef values
- Added inlined tag union support for both serialization and deserialization

## 2026-05-20

- Added tag union support for serialization and deserialization
- Added unnamed struct and union field support in structs
- Added `@DUnion` to set union serialization and deserialization options

## 2026-05-15

- Added tag union support inside structs
- Added support for substruct and subunion fields
- Renamed `@DEnum` option `NAME` to `DESCRIPTION` to match the c3 language's name for this

## 2026-04-20

- Added new `$expand(derive{YourType}(serialize, deserialize))` shorthand to implement the required methods
- Added support for C3 `0.8.0`
- Added optional `serialize_slice_item_start(usz idx)` and `serialize_slice_item_end(usz idx)` to the Serializer interface
- Added `flatten` option to serialized struct (will crash if deserialized at the moment)

## 2026-04-19

- Added the `fmt` `@DField` option to pass format specific arguments to the serializer.
- Added `XML` serializer in `dessert::format::xml`
- Fixed a bug that made muli-dimensional arrays impossible to serialize

## 2026-04-18

- Moved `dessert::csv` to `dessert::format::csv`
- Moved `dessert::json` to `dessert::format::json`
- Renamed `@Dessert`, `@DessertSer`, `@DessertDes`, `@DessertEnum`, `@DessertEnumSer`, `@DessertEnumDes`, `@DessertStruct`, `@DessertStructSer`, `@DessertStructDes` to
`@DField`, `@DFieldSer`, `@DFieldDes`, `@DEnum`, `@DEnumSer`, `@DEnumDes`, `@DStruct`, `@DStructSer`, `@DStructDes` (old names are still available, but depricated)

## 2026-04-12

### Added
- Unknown field skipping during deserialization (unknown fields are silently skipped by default)
- `@DessertStruct` / `@DessertStructSer` / `@DessertStructDes` attributes to control struct-level deserialization behavior
- `deny_unknown_fields` option on `@DessertStruct` — returns `UNKNOWN_FIELD` fault when an unrecognized field is encountered
- Deserialization into `Object*` for arbitrary / untyped JSON data
- `next_any()` optional method on the `Deserializer` interface
- `UNKNOWN_FIELD` fault in the `des` module
- `skip_serializing_<field>()` method protocol — if a struct defines a method with this naming pattern returning `bool`, dessert calls it before serializing that field and skips it when `true`
- `skip_if_empty` option on `@Dessert` / `@DessertSer` — skips a field during serialization when it is empty (null pointer, empty slice, or unset `Maybe`)
- Descriptive error messages printed to stderr when deserialization fails, showing the field name and previously deserialized fields

### Fixed
- Quotes inside strings were not escaped in JSON output

## 2026-04-07

### Added
- Enum serialization and deserialization (`@DessertEnum`, `@DessertEnumSer`, `@DessertEnumDes`) with `NAME`, `ORDINAL`, and `FIELD` modes
- `to_pretty_string()` on `JsonValue`
- Full primitive type support for deserialization: `bool`, `char`, `ichar`, `short`, `int`, `long`, `int128`, `ushort`, `uint`, `ulong`, `uint128`, `float`, `double`, `String`, `ZString`
- `c3po add ecoral360/dessert` install instructions

### Fixed
- `ulong` deserialization
- Enum serialization and deserialization edge cases
- `Deserializer` type is now propagated correctly through `impl_deserialize`
- `@is_serializable` now uses `@is_maybe_expr` instead of the compiletime `@is_maybe`

### Removed
- `float16` and `float128` support (unsupported by C3 standard library)

## 2026-03-29 — 2026-04-03

### Added
- Deserialization from JSON strings (`des::deserialize{T}`)
- Direct value serialization (values are serializable without wrapping)
- Dessert packaged as a proper `.c3l` library

### Fixed
- Deserialization of standalone numbers
- Serialization of null pointer values
- `bool` serialization

### Changed
- `deserialize` macro call syntax updated for clarity

## 2026-03-22 — 2026-03-28

### Added
- Initial JSON serializer (`dessert::json`)
- `impl_serialize` / `impl_deserialize` macros for structs
- `@Dessert`, `@DessertSer`, `@DessertDes` field attributes with `skip`, `rename`, and `validator` options
- Support for nested struct serialization
- Support for `Maybe` fields
- Support for slice / array / `List` fields
- Slice serializer fix
