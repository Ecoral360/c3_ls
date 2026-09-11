module dessert::ser;
import dessert::utils @public;

import std::io;
import std::core::types;
import std::collections::maybe;
import std::collections::object;

<*
  A `Serializer` receives a stream of structured events describing a value and turns
  them into a concrete output format (JSON, CSV, XML, ...).

  The generic serialization code drives an implementation by calling the methods below
  in a nesting-aware order. A struct is emitted as
  `struct_start` -> (`serialize_field_start` -> *value* -> `serialize_field_end`)* -> `struct_end`;
  a slice as `serialize_slice_start` -> (`serialize_slice_item_start` -> *value* ->
  `serialize_slice_item_end`)* -> `serialize_slice_end`; and a scalar value as a single
  `serialize_*` call. Every method returns an optional so a format error can abort the
  whole operation.

  Methods marked `@optional` may be left unimplemented: the value they handle is then
  routed to a wider fallback method (documented per method). The required methods
  (`struct_start`/`struct_end`, the field/slice boundaries, `serialize_null`,
  `serialize_bool`, `serialize_long`, `serialize_string`, `serialize_double`) form the
  minimal surface every format must provide.

  Implementations are expected to expose a `result()` method returning the finished
  output; it is called by the `serialize` macro once the event stream ends (not part of this
  interface because its return type is format-specific).
*>
interface Serializer {
  <*
    Begin a struct (object). Emitted once before any of the struct's fields, and
    balanced by a matching `struct_end`. Structs may nest.
    @param name : "The fully-qualified type name of the struct being serialized"
  *>
  fn void? struct_start(String name);

  <*
    Begin a single struct field, before its value is serialized. Balanced by a
    matching `serialize_field_end` with the same arguments. **Skipped and flattened
    fields do not produce these calls.**
    @param name : "The field's output name (already resolved through `rename` / `rename_all`)"
    @param fmt : "Format-specific per-field attributes declared via `@DField({ .fmt = ... })` (e.g. `xml:attribute`)"
    @param field_type : "The `typeid` of the field's declared type"
  *>
  fn void? serialize_field_start(String name, FieldAttrs fmt, typeid field_type);

  <*
    End a struct field, after its value has been serialized. Mirrors the preceding
    `serialize_field_start` and receives the same arguments.
    @param name : "The field's output name (already resolved through `rename` / `rename_all`)"
    @param fmt : "Format-specific per-field attributes declared via `@DField({ .fmt = ... })`"
    @param field_type : "The `typeid` of the field's declared type"
  *>
  fn void? serialize_field_end(String name, FieldAttrs fmt, typeid field_type);

  <*
    End a struct, balancing the matching `struct_start`.
    @param name : "The fully-qualified type name of the struct being serialized"
  *>
  fn void? struct_end(String name);

  <*
    Begin a sequence (slice, array or `List`). Balanced by `serialize_slice_end`.
    @param len : "The number of items that will follow"
  *>
  fn void? serialize_slice_start(long len);

  <*
    Begin one item of the current sequence, before its value is serialized. Optional:
    formats that need no per-item framing may omit it.
    @param idx : "The 0-based index of the item within the sequence"
  *>
  fn void? serialize_slice_item_start(usz idx) @optional;

  <*
    End one item of the current sequence, after its value is serialized. Optional.
    @param idx : "The 0-based index of the item within the sequence"
  *>
  fn void? serialize_slice_item_end(usz idx) @optional;

  <*
    End a sequence, balancing the matching `serialize_slice_start`.
    @param len : "The number of items that were emitted"
  *>
  fn void? serialize_slice_end(long len);

  <* Serialize a null value. Emitted for empty `Maybe` values and null pointers. *>
  fn void? serialize_null();

  <* Serialize a boolean. *>
  fn void? serialize_bool(bool b);

  <*
    Serialize a signed integer. This is the sink every signed and (absent
    `serialize_ulong`) unsigned integer type ultimately falls back to, so it must be
    implemented.
  *>
  fn void? serialize_long(long l);

  <* Serialize a UTF-8 string. *>
  fn void? serialize_string(String s);

  <* Serialize a floating-point number. `float` falls back to this when `serialize_float` is absent. *>
  fn void? serialize_double(double d);

  <* Serialize a `char`. Optional: falls back to `serialize_string` with a one-character string. *>
  fn void? serialize_char(char c) @optional;
  <* Serialize an `ichar`. Optional: falls back to `serialize_long`. *>
  fn void? serialize_ichar(ichar c) @optional;

  <* Serialize a `short`. Optional: falls back to `serialize_long`. *>
  fn void? serialize_short(short s) @optional;
  <* Serialize an `int`. Optional: falls back to `serialize_long`. *>
  fn void? serialize_int(int i) @optional;
  <* Serialize an `int128`. Optional: raises `UNSUPPORTED_DATA_TYPE` when absent (no lossless fallback). *>
  fn void? serialize_int128(int128 i) @optional;

  <* Serialize a `uint`. Optional: falls back to `serialize_ulong`, then to `serialize_long`. *>
  fn void? serialize_uint(uint i) @optional;
  <* Serialize a `ushort`. Optional: falls back to `serialize_ulong`, then to `serialize_long`. *>
  fn void? serialize_ushort(ushort s) @optional;
  <* Serialize a `ulong`. Optional: falls back to `serialize_long` when absent. *>
  fn void? serialize_ulong(ulong l) @optional;
  <* Serialize a `uint128`. Optional: raises `UNSUPPORTED_DATA_TYPE` when absent (no lossless fallback). *>
  fn void? serialize_uint128(uint128 i) @optional;

  <* Serialize a `ZString`. Optional: falls back to `serialize_string` on its view. *>
  fn void? serialize_zstring(ZString s) @optional;

  <* Serialize a `float`. Optional: falls back to `serialize_double`. *>
  fn void? serialize_float(float f) @optional;
  // fn void? serialize_float16(float16 f) @optional @if($defined(float16));
  // fn void? serialize_float128(float128 f) @optional @if($defined(float128));
}

faultdef VALIDATOR_ERROR, UNMAPPED_UNION_VARIANT;

// Should be treated as a protocol, don't derive it directly
interface Serializable {
  fn void? serialize(Serializer serializer);
}

<* @require $defined(Serializer s = serializer) *>
macro serialize(serializer, value) {
  serialize_value(serializer, value, (DFieldConfig) {})!;
  return serializer.result();
}

<* @require $defined(Serializer ser = serializer) *>
fn void? impl_serialize(Value s, Ser serializer) <Value, Ser> {
  return impl_serialize_inline(s, serializer);
}

<* @require $defined(s.serialize(serializer)) *>
macro impl_serialize_inline(s, serializer) @local {
  $if $Typeof(s)::kind != POINTER:
    $error "The first parameter must be a &self pointer.";
  $endif

  $switch:
    $case $Typeof(s)::inner.kind == ENUM:
      impl_serialize_enum(s, serializer)!;

    $case $Typeof(s)::inner.kind == CONSTDEF:
      return serialize_value(serializer, ($Typefrom($Typeof(s)::inner.inner)) *s, (DFieldConfig) {});

    $case $Typeof(s)::inner.kind == STRUCT:
      var $type = $Typeof(s)::inner;
      DStructConfig $struct_config = $type.has_tag("dessert:ser:struct") ??? $type.get_tag("dessert:ser:struct") : {};
      $foreach $i, $member : $type.members:
        DFieldConfig $config = $member.has_tag("dessert:ser:field") ??? $member.get_tag("dessert:ser:field") : {};
        $if $i == 0 &&& $type.is_substruct:
          $config = {...$config, .flatten = true};
        $endif

        $if !$config.skip:
          $if $config.validator.len > 0: 
            if (!s.$eval($config.validator)(s.$member)) {
              return VALIDATOR_ERROR~;
            }
          $endif

          $switch:
            $case $config.skip_if_empty:
              if (!@is_empty(s.$member)) {
                @serialize_field(serializer, $config, s, $member, $struct_config)!;
              }

            $case $defined(s.$eval("skip_serializing_" +++ $member.name)()) 
              &&& $Typeof(s.$eval("skip_serializing_" +++ $member.name))::returns == bool:

              if (!s.$eval("skip_serializing_" +++ $member.name)()) {
                @serialize_field(serializer, $config, s, $member, $struct_config)!;
              }

            $default:
              @serialize_field(serializer, $config, s, $member, $struct_config)!;
          $endswitch
        $endif
      $endforeach

    $default:
      $error @sprintf("Unsupported type for serialization %s (%s)", $Typeof(s)::inner, $Typeof(s)::inner.kind);
  $endswitch
}

macro @serialize_field(serializer, DFieldConfig $config, s, $member, DStructConfig $struct_config) @local {
  bool $is_flatten = $config.flatten ||| $member.name.len == 0;

  $if !$is_flatten:
    serializer.serialize_field_start(
      utils::@rename($config, $member.name, $struct_config.rename_all),
      $config.fmt,
      $member.type,
    )!;
  $endif

  $if $member.type.kind == UNION:
    @impl_serialize_union($member.type, s, serializer, $member, $config, $struct_config)!;

  $else
    $switch:
      $case $member.type.name == @sprintf("%s.%s", $Typeof(s)::inner.name, $member.name):
      $case $member.type.name == @sprintf("%s.$anon", $Typeof(s)::inner.name):
        $if !$is_flatten:
          serializer.struct_start($member.type.name)!;
        $endif

        @impl_serialize_struct($member.type, &s.$member, serializer, $struct_config)!;

        $if !$is_flatten:
          serializer.struct_end($member.type.name)!;
        $endif

      $default:
        $if $defined(s.$eval(@sprintf("serialize_%s", $member.name))) &&& $defined(s.$eval(@sprintf("serialize_%s", $member.name))(serializer)):
          $if $Typeof(s.$eval(@sprintf("serialize_%s", $member.name)))::returns == void? :
            s.$eval(@sprintf("serialize_%s", $member.name))(serializer)!;
          $else
            serialize_value(serializer, s.$eval(@sprintf("serialize_%s", $member.name))(serializer)!, $config)!;
          $endif
        $else
          serialize_value(serializer, s.$member, $config)!;
        $endif
    $endswitch
  $endif

  $if !$is_flatten:
    serializer.serialize_field_end(
      utils::@rename($config, $member.name, $struct_config.rename_all),
      $config.fmt,
      $member.type,
    )!;
  $endif
}

macro @impl_serialize_struct($Type, s, serializer, DStructConfig $struct_config_parent) @local {
  DStructConfig $struct_config = $Type::has_tag("dessert:ser:struct") ??? $Type::get_tag("dessert:ser:struct") : $struct_config_parent;
  $foreach $member : $Type::members:
    DFieldConfig $config = $member.has_tag("dessert:ser:field") ??? $member.get_tag("dessert:ser:field") : (DFieldConfig) {};
    $if !$config.skip:
      $if $config.validator.len > 0: 
        if (!s.$eval($config.validator)(s.$member)) {
          return VALIDATOR_ERROR~;
        }
      $endif

      $switch:
        $case $config.skip_if_empty:
          if (!@is_empty(s.$member)) {
            @serialize_field(serializer, $config, s, $member, $struct_config)!;
          }

        $case $defined(s.$eval("skip_serializing_" +++ $member.name)()) 
          &&& $Typeof(s.$eval("skip_serializing_" +++ $member.name))::returns == bool:

          if (!s.$eval("skip_serializing_" +++ $member.name)()) {
            @serialize_field(serializer, $config, s, $member, $struct_config)!;
          }

        $default:
          @serialize_field(serializer, $config, s, $member, $struct_config)!;
      $endswitch
    $endif
  $endforeach
}

macro @impl_serialize_value($Type, s, serializer) @local {
  $switch :
    $case $Type::kind == STRUCT &&& !$defined(s.serialize(serializer)):
      serializer.struct_start($Type::name)!;
      @impl_serialize_struct($Type, &s, serializer, {})!;
      serializer.struct_end($Type::name)!;

    $default:
      serialize_value(serializer, s, {})!;
  $endswitch
}

macro @impl_serialize_union($UType, s, serializer, $member, DFieldConfig $config, DStructConfig $struct_config) @local {
  $if $config.tagged.by.len == 0:
    $error @sprintf("Unions must be tagged by another field's value (member %s with type %s)", $member.name, $UType::name);
  $endif

  $if $config.flatten &&& $config.tagged.inlined:
    $error @sprintf("A field cannot be inlined and flatten. (%s)", $member.name);
  $endif

  $if $config.tagged.inlined:
    $config = { ...$config, .flatten = true };
  $endif

  var tag_value = s.$eval($config.tagged.by);

  var $the_switch = "";

  $switch:
    $case $config.tagged.match.by == ORDINAL ||| $Typeof(tag_value)::kind != ENUM:
      $the_switch = "switch ((sz) tag_value) {";

      $foreach $i, $m : $UType::members:
        $the_switch +++= @sprintf("case %s:\n", $i);
        $if $config.tagged.inlined:
          $the_switch +++= @sprintf("@impl_serialize_value($UType::members[%s].type, s.$member.$eval($UType::members[%s].name), serializer)!;\n", $i, $i);
        $else
          $the_switch +++= @sprintf("@serialize_field(serializer, $config, &s.$member, $UType::members[%s], $struct_config)!;\n", $i);
        $endif
      $endforeach

      $the_switch +++= @default_unmapped($config);

      $the_switch +++= "}";

    $case $config.tagged.match.by == DESCRIPTION:
      $the_switch = "switch (tag_value) {";

      $foreach $i, $m : $UType::members:
        $the_switch +++= @sprintf("case %s:\n", @str_upper($m.name));
        $if $config.tagged.inlined:
          $the_switch +++= @sprintf("@impl_serialize_value($UType::members[%s].type, s.$member.$eval($UType::members[%s].name), serializer)!;\n", $i, $i);
        $else
          $the_switch +++= @sprintf("@serialize_field(serializer, $config, &s.$member $UType::members[%s], $struct_config)!;\n", $i);
        $endif
      $endforeach

      $the_switch +++= @default_unmapped($config);

      $the_switch +++= "}";

    $case $config.tagged.match.by == FIELD:
      var $field_name = $config.tagged.match.field;
      $if $field_name.len == 0:
        $error "While serializing a tagged union: When the 'tagged.match.by' attribute is set to 'FIELD', 'field' must be provided with the name of an associated field of the enum.";
      $endif

      $if !$defined(tag_value.$field_name):
        $error @sprintf("Enum %s doesn't have field '%s'", $Typeof(tag_value)::name, $field_name);
      $endif

      $if $Typeof(tag_value.$field_name) != String:
        $error @sprintf("To be used as a union variant matcher, the field must be an string (was '%s')", $field_name);
      $endif

      $the_switch = @sprintf("switch (tag_value.%s) {", $field_name);

      $foreach $i, $m : $UType::members:
        $the_switch +++= @sprintf("case \"%s\":\n", $m.name);
        $if $config.tagged.inlined:
          $the_switch +++= @sprintf("@impl_serialize_value($UType::members[%s].type, s.$member.$eval($UType::members[%s].name), serializer)!;\n", $i, $i);
        $else
          $the_switch +++= @sprintf("@serialize_field(serializer, $config, &s.$member, $UType::members[%s], $struct_config)!;\n", $i);
        $endif
      $endforeach

      $the_switch +++= @default_unmapped($config);

      $the_switch +++= "}";

  $endswitch

  bool $is_flatten = $config.tagged.inlined ||| $member.name.len == 0;
  $if !$is_flatten:
    serializer.struct_start($member.type.name)!;
  $endif

  $expand($the_switch);

  $if !$is_flatten:
    serializer.struct_end($member.type.name)!;
  $endif

}

macro @default_unmapped(DFieldConfig $config) @local @const {
  $switch $config.tagged.unmapped.as:
    $case ERROR:
      return "default: return UNMAPPED_UNION_VARIANT~;";
    $case EMPTY_STRUCT:
      return "default: serializer.struct_start(\"EMPTY\")!; serializer.struct_end(\"EMPTY\")!;";
    $case NULL:
      return "default: serialize_value(serializer, (Maybe{int}) {}, $config)!;";
    $case ZERO:
      return "default: serialize_value(serializer, 0, $config)!;";
  $endswitch
}


macro @is_empty(#value) {
  $switch:
    $case $defined(#value.len) &&& $defined(#value[0]):
      return #value.len == 0;
    $case utils::@is_maybe_expr(#value):
      var inner = #value.get();
      if (catch inner) {
        return true;
      } else {
        return false;
      }
    $case $Typeof(#value)::kind == POINTER:
      return #value == null;
  $endswitch
}

macro serialize_value(serializer, value, DFieldConfig $config) {
  $switch:
    // An `Object` holds a value whose shape is only known at runtime, so it
    // emits its own struct/slice delimiters instead of being wrapped in the
    // `struct_start`/`struct_end` pair the generic case below adds.
    $case $Typeof(value) == Object ||| $Typeof(value) == Object*:
      $if $Typeof(value) == Object*:
        if (value == null) {
          serializer.serialize_null()!;
          return;
        }
      $endif
      $if !$config.flatten:
        if (value.is_map() || value.is_empty()) serializer.struct_start("Object")!;
      $endif
      value.serialize(serializer)!;
      $if !$config.flatten:
        if (value.is_map() || value.is_empty()) serializer.struct_end("Object")!;
      $endif

    $case $defined(value.serialize) &&& $defined(value.serialize(serializer)):
      var $type = $reflect(value).type;
      $if $type.kind == POINTER:
        $type = $Typeof(value)::inner;
        if (value == null) {
          serializer.serialize_null()!;
          return;
        }
      $endif
      $if $type.kind == STRUCT &&& !$config.flatten:
        serializer.struct_start($type.name)!;
      $endif
      value.serialize(serializer)!;
      $if $type.kind == STRUCT &&& !$config.flatten:
        serializer.struct_end($type.name)!;
      $endif

    $case $defined(value.serialize) &&& $defined(value.serialize(serializer, (DFieldConfig) {})):
      var $type = $reflect(value).type;
      $if $type.kind == POINTER:
        $type = $Typeof(value)::inner;
        if (value == null) {
          serializer.serialize_null()!;
          return;
        }
      $endif
      $if $type.kind == STRUCT &&& !$config.flatten:
        serializer.struct_start($type.name)!;
      $endif
      value.serialize(serializer, $config)!;
      $if $type.kind == STRUCT &&& !$config.flatten:
        serializer.struct_end($type.name)!;
      $endif

    $case $Typeof(value)::kind == POINTER:
      if (value == null) {
        serializer.serialize_null()!;
        return;
      }
      serialize_value(serializer, *value, $config)!;

    $case utils::@is_maybe_expr(value):
      var inner = value.get();
      if (catch inner) {
        serializer.serialize_null()!;
      } else {
        serialize_value(serializer, inner, $config)!;
      }

    $case !$defined(String x = value) &&& $defined(lengthof(value)) &&& $defined(value[0]):
      serializer.serialize_slice_start(lengthof(value))!;

      $if $Typeof(serializer) == Serializer:
        $Typefrom($Typeof(Serializer.serialize_slice_item_start)) cb_start;
        if (&((Serializer) serializer).serialize_slice_item_start) {
          cb_start = &((Serializer) serializer).serialize_slice_item_start;
        }
        $Typefrom($Typeof(Serializer.serialize_slice_item_end)) cb_end;
        if (&((Serializer) serializer).serialize_slice_item_end) {
          cb_end = &((Serializer) serializer).serialize_slice_item_end;
        }

        foreach (i, el: value) {
          if (cb_start) cb_start(serializer, (usz) i)!;
          serialize_value(serializer, el, $config)!;
          if (cb_end) cb_end(serializer, (usz) i)!;
        }
      $else
        foreach (i, el: value) {
          $if $defined(serializer.serialize_slice_item_start):
            serializer.serialize_slice_item_start((usz) i)!;
          $endif
          serialize_value(serializer, el, $config)!;
          $if $defined(serializer.serialize_slice_item_end):
            serializer.serialize_slice_item_end((usz) i)!;
          $endif
        }
      $endif

      serializer.serialize_slice_end(lengthof(value))!;

    $default:
      @serialize_primitive_value(serializer, value)!;
  $endswitch
}

<*
  @require $Typeof(s)::inner.kind == ENUM
*>
macro impl_serialize_enum(s, serializer) @local {
  var $type = $Typeof(s)::inner;
  var $enum_config = $type.has_tag("dessert:ser:enum") ??? $type.get_tag("dessert:ser:enum") : (DEnumConfig) {};

  $switch $enum_config.as:
    $case DESCRIPTION:
      return serialize_value(serializer, utils::rename_enum_description(s.description, $enum_config.rename_all), (DFieldConfig) {});

    $case ORDINAL:
      return serialize_value(serializer, s.ordinal, (DFieldConfig) {});

    $case FIELD:
      var $field_name = $enum_config.field;
      $if $field_name.len == 0:
        $error "While serializing an enum: When the 'as' attribute is set to 'FIELD', 'field' must be provided with the name of an associated field of the enum.";
      $endif
      return serialize_value(serializer, s.$eval($field_name), (DFieldConfig) {});
  $endswitch
}

macro @is_serializable(#value) {
  return $defined(#value.serialize) ||| ($defined(#value.len) &&& $defined(#value[0]) &&& @is_serializable(#value[0])) ||| 
    utils::@is_maybe_expr(#value) ||| @is_primitive_value($Typeof(#value));
}

macro @is_primitive_value($Type) @local {
  $switch $Type:
    $case String:
    $case ZString:
    $case char:
    $case bool:
    $case ichar:
    $case short:
    $case int:
    $case long:
    $case int128:
    $case ushort:
    $case uint:
    $case ulong:
    $case uint128:
    $case float16:
    $case float:
    $case double:
      return true;

    $default:
      return false;
  $endswitch
}

macro @serialize_primitive_value(ser, value) @local {
  $switch $Typeof(value):
    $case String:
      return ser.serialize_string(value);

    $case ZString:
      return utils::@method_fallback{Serializer}(ser, serialize_zstring, ser.serialize_string(value.str_view()), value);

    $case char:
      return utils::@method_fallback{Serializer}(ser, serialize_char, ser.serialize_string({ value }), value);

    $case bool:
      return ser.serialize_bool(value);

    $case ichar:
      return utils::@method_fallback{Serializer}(ser, serialize_ichar, ser.serialize_long((long) value), value)!;

    $case short:
      return utils::@method_fallback{Serializer}(ser, serialize_short, ser.serialize_long((long) value), value)!;

    $case int:
      return utils::@method_fallback{Serializer}(ser, serialize_int, ser.serialize_long((long) value), value)!;

    $case long:
      return ser.serialize_long(value)!;

    $case int128:
      return utils::@method_fallback{Serializer}(ser, serialize_int128, UNSUPPORTED_DATATYPE~, value)!;

    $case ushort:
      return utils::@method_fallback_chain{Serializer}(ser, serialize_ushort, serialize_ulong, serialize_long, #args: value)!;

    $case uint:
      return utils::@method_fallback_chain{Serializer}(ser, serialize_uint, serialize_ulong, serialize_long, #args: value)!;

    $case ulong:
      return utils::@method_fallback{Serializer}(ser, serialize_ulong, ser.serialize_long((long) value), value)!;

    $case uint128:
      return utils::@method_fallback{Serializer}(ser, serialize_uint128, UNSUPPORTED_DATATYPE~)!;

    $case float16:
      return utils::@method_fallback{Serializer}(ser, serialize_float16, ser.serialize_double((double) value), value)!;

    $case float:
      return utils::@method_fallback{Serializer}(ser, serialize_float, ser.serialize_double((double) value), value)!;

    $case double:
      return ser.serialize_double(value)!;

    $default:
      $error @sprintf("Value not serializable: '%s (%s)'", $Typeof(value)::name, $Typeof(value)::kind);
  $endswitch
}
