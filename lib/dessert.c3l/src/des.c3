module dessert::des;
import std::collections::list;
import std::collections::maybe;
import std::collections::map;
import std::collections::object;
import std::io;
import dessert::utils @public;


<*
  A `Deserializer` is a cursor over an input document (JSON text, CSV document, ...) that the generic
  deserialization code pulls values out of, one at a time, to reconstruct a typed value.

  It is a pull parser: the generated code decides *what* type it expects next and calls
  the matching `next_*` method to read it. Structs are read as
  `struct_start` -> (`has_next_field` -> `next_field_name` -> *value*)* -> `struct_end`, and
  sequences as `slice_start` -> (`has_next_slice_item` -> *value*)* -> `slice_end`. A scalar
  is read with a single `next_*` call. Every method returns an optional so a malformed
  document can abort the operation.

  Field ordering is not assumed: `peek_field_name` lets the code look up the target field
  before consuming the name, which is what makes out-of-order keys and inlined tagged
  unions (tag read before the union body) work. Unknown fields are discarded via
  `skip_next_value`.

  Methods marked `@optional` may be omitted: the value is then read through a wider
  fallback method (documented per method). The required methods (the struct/slice
  cursor, `next_null`, `next_bool`, `next_string`, `next_double`) form the
  minimal surface every format must provide.
*>
interface Deserializer {
  <*
    Enter a struct (object), positioning the cursor before its first field. Balanced by
    `struct_end`.
    @param name : "The fully-qualified type name of the struct being deserialized"
  *>
  fn void? struct_start(String name);

  <* @returns "`true` if the current struct has another field to read, `false` once its fields are exhausted" *>
  fn bool? has_next_field();

  <*
    Consume and return the name of the next field, advancing the cursor to its value.
    @returns "The field name (allocated with `tmem` or handled by the deserializer)"
  *>
  fn String? next_field_name();

  <*
    Return the name of the next field **without** consuming it, so the caller can decide
    how to handle it before reading. Must be idempotent until `next_field_name` is called.
    @returns "The field name (allocated with `tmem` or handled by the deserializer)"
  *>
  fn String? peek_field_name();

  <*
    Leave the current struct, balancing the matching `struct_start`.
    @param name : "The fully-qualified type name of the struct being deserialized"
  *>
  fn void? struct_end(String name);

  <* Enter a sequence (slice/array/List), positioning the cursor before its first item. Balanced by `slice_end`. *>
  fn void? slice_start();

  <* Leave the current sequence, balancing the matching `slice_start`. *>
  fn void? slice_end();

  <* @returns "`true` if the current sequence has another item to read, `false` once exhausted" *>
  fn bool? has_next_slice_item();

  <*
    Test for a null value.
    @returns "`true` if the next value is null - in which case it is **consumed** - or `false` if it is not null, in which case it **must not** be consumed and can still be read by another `next_*` method"
  *>
  fn bool? next_null();

  <* Read a boolean value. *>
  fn bool? next_bool();

  <* Read a UTF-8 string. *>
  fn String? next_string();

  <* Read a floating-point number. `float` falls back to this when `next_float` is absent. *>
  fn double? next_double();

  <*
    Read an arbitrary value of unknown shape into a dynamically-typed `Object*`. Used for
    `Object*` fields and to skip unknown fields when `skip_next_value` is not provided.
    Optional: raises `UNSUPPORTED_ANY` when the format cannot represent free-form values.
    @returns "The parsed value, allocated with the deserializer's allocator (caller owns it)"
  *>
  fn Object*? next_any() @optional;

  <*
    Consume and discard the next value, whatever its shape. Called for unknown fields when
    the struct does not deny them. Optional: falls back to reading the value with `next_any`
    and freeing it.
  *>
  fn void? skip_next_value() @optional;

  <*
    Read the textual description of an enum value (used when an enum is encoded by name).
    Optional: falls back to `next_string`. Formats override it only when enum names need
    different lexing than plain strings.
  *>
  fn String? next_enum_description() @optional;

  <* Read a `char`. Optional: falls back to the first byte of `next_string`. *>
  fn char? next_char() @optional;
  <* Read an `ichar`. Optional: falls back to `next_long`. *>
  fn ichar? next_ichar() @optional;

  <* Read a `short`. Optional: falls back to `next_long`. *>
  fn short? next_short() @optional;
  <* Read an `int`. Optional: falls back to `next_long`. *>
  fn int? next_int() @optional;

  <* Read a signed integer. Optional: falls back to `next_double`. *>
  fn long? next_long() @optional;

  <* Read an `int128`. Optional: raises `UNSUPPORTED_DATA_TYPE` when absent (no fallback). *>
  fn int128? next_int128() @optional;

  <* Read a `ushort`. Optional: falls back to `next_ulong`, then to `next_long`. *>
  fn ushort? next_ushort() @optional;
  <* Read a `uint`. Optional: falls back to `next_ulong`, then to `next_long`. *>
  fn uint? next_uint() @optional;
  <* Read a `ulong`. Optional: falls back to `next_long` when absent. *>
  fn ulong? next_ulong() @optional;
  <* Read a `uint128`. Optional: raises `UNSUPPORTED_DATA_TYPE` when absent (no fallback). *>
  fn uint128? next_uint128() @optional;

  <* Read a `ZString`. Optional: falls back to `next_string`. *>
  fn ZString? next_zstring() @optional;

  <* Read a `float`. Optional: falls back to `next_double`. *>
  fn float? next_float() @optional;

  <*
    Return the allocator that owns values produced during deserialization (strings,
    `Object*`, container storage). Optional: falls back to the `tmem` allocator
  *>
  fn Allocator get_allocator() @optional;

  fn void? error(fault excuse, String msg) @optional;
}

faultdef VALIDATOR_ERROR;
faultdef DUPLICATED_KEY, INVALID_ENUM_VALUE, UNKNOWN_FIELD, INLINED_UNION_BEFORE_TAG, UNMAPPED_UNION_VARIANT, MISSING_REQUIRED_FIELD, TOO_MANY_ELEMENTS_IN_ARRAY;
faultdef UNSUPPORTED_DATA_TYPE, UNSUPPORTED_ANY;

// Should be treated as a protocol, don't derive it directly
interface Deserializable {
  fn void? deserialize(Deserializer deserializer);
}

// macro bool @is_hashmap($Type) => $Type::qname.@starts_with("std::collections::map::HashMap");
//
// macro bool @is_list($Type) => $Type::qname.@starts_with("std::collections::list::List");

macro bool String.@starts_with($self, String $other) @const {
  return $self.len >= $other.len &&& $self[:$other.len] == $other;
}

macro @is_deserializable($Output) @const {
  $Output $value;
  return $defined($value.deserialize) ||| $Output::is_generic(HashMap) ||| ($defined($value.len) &&& $defined($value[0]) &&& @is_deserializable($Typeof($value[0]))) ||| $Output::is_generic(Maybe);
}

<*
  @require($defined(Deserializer d = deserializer))
*>
macro Output? deserialize(deserializer) <Output> => @pool() { 
  return deserialize_value{Output}(deserializer, {}); 
}



macro void? impl_deserialize(value, deserializer) {
  return impl_deserialize_generic{$Typeof(value), $Typeof(deserializer)}(value, deserializer);
}

fn void? impl_deserialize_generic(Value value, Des deserializer) <Value, Des> @private {
  return impl_deserialize_inline(value, deserializer);
}

<*
  @require($defined(Deserializer d = deserializer))
*>
macro void? impl_deserialize_inline(value, deserializer) @local {
  $if $Typeof(value)::kind != POINTER:
    $error "The first parameter must be a &self pointer.";
  $endif

  $switch:
    $case $Typeof(value)::inner.kind == ENUM:
      var $type = $Typeof(value)::inner;
      var $enum_config = $type.has_tag("dessert:des:enum") ??? $type.get_tag("dessert:des:enum") : (DEnumConfig) {};

      $Typefrom($Typeof(value)::inner) $fallback;
      bool $found = false;
      $if $enum_config.fallback.len > 0:
        $foreach $v : $type.values:
          $if $v.description == $enum_config.fallback:
            $fallback = $v;
            $found = true;
          $endif
        $endforeach
        $if !$found:
          $error @sprintf("The fallback of an enum must be a valid member of that enum ('%s' is not a member of %s)", $enum_config.fallback, $type.name);
        $endif
        *value = $fallback;
      $endif

      $switch $enum_config.as:
        $case DESCRIPTION:
          Allocator allocator = utils::@method_fallback{Deserializer}(deserializer, get_allocator, tmem);

          String name = utils::@method_fallback{Deserializer}(deserializer, next_enum_description, deserializer.next_string())!;
          defer alloc::free(allocator, name);

          int found = -1;
          var $name_switch = "switch (name) {";

          $foreach $i, $v : $type.names:
            $name_switch +++= @sprintf(`case "%s": *value = %s;`, utils::@rename({}, $v, $enum_config.rename_all), $v);
          $endforeach

          $name_switch +++= `default: 
            $if $enum_config.fallback.len > 0:
              return;
            $else
              return INVALID_ENUM_VALUE~;
            $endif
          `;

          $name_switch +++= "}";
          $expand($name_switch);

        $case ORDINAL:
          $Typefrom($type.inner) ordinal = deserialize{$type.inner}(deserializer)!;
          *value = $type.from_ordinal(ordinal);

        $case FIELD:
          String $field_name = $enum_config.field;
          $if $field_name.len == 0:
            $error "When the 'enum_as' attribute is set to 'FIELD', 'enum_field' must be provided with the name of an associated field of the enum.";
          $endif
          $foreach $member : $type.members:
            $if $member.name == $field_name:
              $Typefrom($member.type) field_value = deserialize{$member.type}(deserializer)!;
              $if $enum_config.fallback.len > 0:
                if (try v = $type.lookup_field($field_name, field_value)) {
                  *value = v;
                }
              $else
                *value =  $type.lookup_field($field_name, field_value)!;
              $endif
            $endif
          $endforeach
      $endswitch

    $case $Typeof(value)::inner.kind == UNION:
    $case $Typeof(value)::inner.kind == STRUCT:
      Allocator allocator = utils::@method_fallback{Deserializer}(deserializer, get_allocator, tmem);

      var $type = $Typeof(value)::inner;
      var $struct_config = $type.has_tag("dessert:des:struct") ??? $type.get_tag("dessert:des:struct") : (DStructConfig) {};
      uint[$Typeof(value)::inner.members.len] names;

      $foreach $member : $Typeof(value)::inner.members:
        DFieldConfig $config = $member.has_tag("dessert:des:field") ??? $member.get_tag("dessert:des:field") : (DFieldConfig) {};
        $if $config.default_value != "":
          $expand(@sprintf("value.$member = %s;", $config.default_value));
        $endif
      $endforeach

      while(deserializer.has_next_field()!) {
        String? next_key = deserializer.peek_field_name();

        if (catch next_key) {
          // io::eprintfn("Error deserializing after deserializing: %s", names);
          next_key!;
          return;
        }
        $if $struct_config.deny_dup_keys:
          if (array::contains(names, next_key.hash())) {
            return DUPLICATED_KEY~;
          }
        $endif

        $foreach $i, $member : $Typeof(value)::inner.members:
          if (@des_field(deserializer, value, $member, next_key, &names, $struct_config, allocator)!) {
            names[$i] = @str_hash($member.name);
            continue;
          }
        $endforeach

        $if $struct_config.deny_unknown_fields:
          var $error_msg = "While deserializing '" +++ $Typeof(value)::inner.name +++ "' (which denies unknown fields), encountered unknown field '%s'.";
          return errorf(deserializer, UNKNOWN_FIELD, $error_msg, next_key)!;
          // return UNKNOWN_FIELD~;
        $else
          // Skip the value if not found
          (void) deserializer.next_field_name()!;
          utils::@method_fallback{Deserializer}(deserializer, skip_next_value, @skip_next_value_fallback(deserializer))!;
        $endif
      }
      $foreach $i, $member : $Typeof(value)::inner.members:
        DFieldConfig $config = $member.has_tag("dessert:des:field") ??? $member.get_tag("dessert:des:field") : (DFieldConfig) {};
        $if $config.required:
          if (!names[$i]) {
            return errorf(deserializer, MISSING_REQUIRED_FIELD, string::tformat("While deserializing '" +++ $Typeof(value)::inner.name +++ "', missing required field '%s'.", $member.name))!;
          }
        $endif
      $endforeach
  $endswitch
}

macro void? errorf(des, fault excuse, String error_fmt, ...) {
  utils::@method_fallback{Deserializer}(des, error, io::eprintfn(error_fmt, ...$vaarg), UNKNOWN_FIELD, string::tformat(error_fmt, ...$vaarg))!;
  return excuse~;
}

macro void? @skip_next_value_fallback(deserializer) @local {
  Object* o = deserialize{Object*}(deserializer)!;
  if (o) o.free(); // we must free the Object* allocated
}

macro bool? @des_field(deserializer, value, $member, next_key, uint[] names, DStructConfig $struct_config, allocator) @local {
  DFieldConfig $config = $member.has_tag("dessert:des:field") ??? $member.get_tag("dessert:des:field") : (DFieldConfig) {};
  var $name = utils::@rename($config, $member.name, $struct_config.rename_all);

  $if $member.type.name == @sprintf("%s.$anon", $Typeof(value)::inner.name):
    $foreach $m : $member.type.members:
      if (@des_field(deserializer, &value.$member, $m, next_key, {}, $member.has_tag("dessert:des:struct") ??? $type.get_tag("dessert:des:struct") : $struct_config, allocator)!) return true;
    $endforeach
  $endif

  $switch:
    $case $config.flatten &&& $member.type.is_generic(HashMap) ||| ($member.type.kind == POINTER &&& $member.type.inner.is_generic(HashMap)):
      if (!value.$member.is_initialized()) value.$member.init(allocator);
      String key = deserializer.next_field_name()!;
      $Typefrom($member.type.generic_args[1]) next_value = deserialize_value{$member.type.generic_args[1]}(deserializer, { ...$config, .flatten = false })!;

      value.$member.set(key, next_value);

      return true;

    $case $config.flatten &&& !$member.type.is_generic(List) &&& !($member.type.kind == POINTER &&& $member.type.inner.is_generic(List)):
      value.$member = deserialize_value{$member.type}(deserializer, $config)!;
      return true;

    $default: 
      if ($name == next_key || @match_alias(next_key, $config.aliases)) {
        $if !$config.skip:
          $if $defined(value.$eval(@sprintf("deserialize_%s", $member.name))) &&& $defined(value.$eval(@sprintf("deserialize_%s", $member.name))(deserializer)):
            (void) deserializer.next_field_name()!;
            $if $Typeof(value.$eval(@sprintf("deserialize_%s", $member.name)))::returns != void? :
              value.$member = value.$eval(@sprintf("deserialize_%s", $member.name))(deserializer)!;
            $else
              value.$eval(@sprintf("deserialize_%s", $member.name))(deserializer)!;
            $endif
          $else
            $switch:
              $case $member.type.kind == UNION &&& $config.tagged.inlined:
                $if $config.tagged.by.len == 0:
                  $error @sprintf("Inlined unions MUST have a 'tagged_by' value for deserialization (%s)", $member.name);
                $endif

                if (!array::contains(names, @str_hash($config.tagged.by))) {
                  io::eprintfn("While deserializing '" +++ $Typeof(value)::inner.name +++ "', encountered inlined union field '%s' before tag key '%s'.", next_key, $config.tagged.by);
                  return INLINED_UNION_BEFORE_TAG~;
                }

                var tag_value = value.$eval($config.tagged.by);
                var next_value = value.$member;

                var $the_switch = "";
                var $UType = $member.type;

                $switch:
                  $case $config.tagged.match.by == ORDINAL ||| $Typeof(tag_value)::kind != ENUM:
                    $the_switch = "switch ((sz) tag_value) {";
                    $foreach $i, $m : $UType::members:
                      $the_switch +++= @sprintf("case %s:\n", $i);
                      $the_switch +++= @sprintf("@des_field(deserializer, &next_value, $UType::members[%s], $UType::members[%s].name, {}, {}, allocator)!;\n", $i, $i);
                    $endforeach
                    $the_switch +++= @default_unmapped($config);
                    $the_switch +++= "}";

                  $case $config.tagged.match.by == DESCRIPTION:
                    $the_switch = "switch (tag_value) {";
                    $foreach $i, $m : $UType::members:
                      $the_switch +++= @sprintf("case %s:\n", @str_upper($m.name));
                      $the_switch +++= @sprintf("@des_field(deserializer, &next_value, $UType::members[%s], $UType::members[%s].name, {}, {}, allocator)!;\n", $i, $i);
                    $endforeach
                    $the_switch +++= @default_unmapped($config);
                    $the_switch +++= "}";

                  $case $config.tagged.match.by == FIELD:
                    var $field_name = $config.tagged.match.field;
                    $if $field_name.len == 0:
                      $error "While serializing a tagged union: When the 'tagged.match_by' attribute is set to 'FIELD', 'field' must be provided with the name of an associated field of the enum.";
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
                      $the_switch +++= @sprintf("@des_field(deserializer, &next_value, $UType::members[%s], $UType::members[%s].name, {}, {}, allocator)!;\n", $i, $i);
                    $endforeach
                    $the_switch +++= @default_unmapped($config);

                    $the_switch +++= "}";

                $endswitch

                $expand($the_switch);

                value.$member = next_value;

              $case $member.type.kind == UNION &&& !$config.tagged.inlined:
              $case $member.type.name == @sprintf("%s.%s", $Typeof(value)::inner.name, $member.name):
              $case $member.type.name == @sprintf("%s.$anon", $Typeof(value)::inner.name):
                (void) deserializer.next_field_name()!;
                deserializer.struct_start($member.type.name)!;
                impl_deserialize_inline(&value.$member, deserializer)!;
                deserializer.struct_end($member.type.name)!;

              $case $member.type.is_generic(List) &&& $config.flatten:
                (void) deserializer.next_field_name()!;

                $Typefrom($member.type.generic_args[0])? next_value = deserialize_value{$member.type.generic_args[0]}(deserializer, { ...$config, .flatten = false });
                if (catch e = next_value) {
                  io::eprintfn("Error [%s] deserializing key: '%s' (%s)", e, next_key, $member.type.name);
                  next_value!;
                  return false;
                }

                if (!value.$member.is_initialized()) value.$member.init(allocator);
                value.$member.push(next_value);

              $case $member.type.kind == POINTER &&& $member.type.inner.is_generic(List) &&& $config.flatten:
                (void) deserializer.next_field_name()!;

                $Typefrom($member.type.inner.generic_args[0])? next_value = deserialize_value{$member.type.inner.generic_args[0]}(deserializer, { ...$config, .flatten = false });
                if (catch e = next_value) {
                  io::eprintfn("Error [%s] deserializing key: '%s' (%s)", e, next_key, $member.type.name);
                  next_value!;
                  return false;
                }

                if (value.$member == null) {
                  value.$member = alloc::alloc(allocator, $member.type.inner);
                  value.$member.init(allocator);
                }
                value.$member.push(next_value);

              $default:
                (void) deserializer.next_field_name()!;

                $Typefrom($member.type)? next_value = deserialize_value{$member.type}(deserializer, $config);
                if (catch e = next_value) {
                  io::eprintfn("Error [%s] deserializing key: '%s' (%s)", e, next_key, $member.type.name);
                  next_value!;
                  return false;
                }

                value.$member = next_value;

            $endswitch
          $endif
        $else
          // skip the key
          (void) deserializer.next_field_name()!;
        $endif
        return true;
      }

      return false;
  $endswitch
}

macro @match_alias(value, String[] $aliases) @local {
  var $cond = "return false ";
  $foreach $alias : $aliases :
    $cond +++= @sprintf(` || value == "%s"`, $alias);
  $endforeach
  $cond +++= ";";
  $expand($cond);
}

macro @default_unmapped(DFieldConfig $config) @local @const {
  $switch $config.tagged.unmapped.as:
    $case ERROR:
      return "default: return UNMAPPED_UNION_VARIANT~;";
    $case EMPTY_STRUCT:
      return "default: (void) deserializer.next_field_name()!; (void) deserialize_value{Object*}(deserializer, {})!;";
    $case NULL:
      return "default: (void) deserializer.next_field_name()!; (void) deserialize_value{Maybe{int}}(deserializer, {})!;";
    $case ZERO:
      return "default: (void) deserializer.next_field_name()!; (void) deserialize_value{int}(deserializer, {})!;";
  $endswitch
}

macro Output? deserialize_value(deserializer, DFieldConfig $config) <Output> @local {
  Output value;
  $switch:
    $case Output::kind == POINTER:
      if (deserializer.next_null()!) {
        return null;
      } else {
        $switch:
          $case Output == Object*:
            return utils::@method_fallback{Deserializer}(deserializer, next_any, UNSUPPORTED_ANY~);

          $case Output::inner.is_generic(List):
            Allocator allocator = utils::@method_fallback{Deserializer}(deserializer, get_allocator, tmem);

            value = alloc::alloc(allocator, Output::inner);
            // value.init(allocator);
            //
            // deserializer.slice_start()!;
            // while(deserializer.has_next_slice_item()!) {
            //   value.push(deserialize{Output::inner.generic_args[0]}(deserializer)!);
            // }
            // deserializer.slice_end()!;
            // return value;
            *value = @deserialize_list{Output::inner.generic_args[0]}(deserializer, allocator)!;
            return value;

          $default:
            Allocator allocator = utils::@method_fallback{Deserializer}(deserializer, get_allocator, tmem);

            value = alloc::alloc(allocator, Output::inner);
            *value = deserialize_value{Output::inner}(deserializer, $config)!;
            return value;
        $endswitch
      }

    $case Output == Object:
      $error "Cannot deserialize to `Object`, only to `Object*`";

    $case Output::kind == CONSTDEF:
      value = (Output) deserialize{Output::inner}(deserializer)!;
      return value;

    $case $defined(value.deserialize) &&& $defined(value.deserialize(deserializer)):
      $if Output != Object &&& Output::kind == STRUCT:
        $if !$config.flatten:
          deserializer.struct_start(Output::name)!;
        $endif
      $endif
      value.deserialize(deserializer)!;
      $if Output != Object &&& Output::kind == STRUCT:
        $if !$config.flatten:
          deserializer.struct_end(Output::name)!;
        $endif
      $endif
      return value;

    $case $defined(value.deserialize) &&& $defined(value.deserialize(deserializer, (DFieldConfig) {})):
      $if Output != Object &&& Output::kind == STRUCT:
        $if !$config.flatten:
          deserializer.struct_start(Output::name)!;
        $endif
      $endif
      value.deserialize(deserializer, $config)!;
      $if Output != Object &&& Output::kind == STRUCT:
        $if !$config.flatten:
          deserializer.struct_end(Output::name)!;
        $endif
      $endif
      return value;

    $case Output::is_generic(HashMap):
      Allocator allocator = utils::@method_fallback{Deserializer}(deserializer, get_allocator, tmem);

      $if $Typeof(value.tkeys()[0]) != String:
        $error "Only a hashmap with string key can be deserialized";
      $endif

      value.init(allocator);
      defer catch value.free();

      $if !$config.flatten:
        deserializer.struct_start(Output::name)!;
      $endif
      while(deserializer.has_next_field()!) {
        String next_key = deserializer.next_field_name()!;
        value.set(next_key, deserialize{$Typeof(value.tvalues()[0])}(deserializer)!);
      }
      $if !$config.flatten:
        deserializer.struct_end(Output::name)!;
      $endif
      return value;

    $case Output::is_generic(List):
      Allocator allocator = utils::@method_fallback{Deserializer}(deserializer, get_allocator, tmem);

      return @deserialize_list{Output::generic_args[0]}(deserializer, allocator)!;

    $case Output::is_generic(Maybe):
      if (deserializer.next_null()!) {
        return (Maybe{$Typeof(value.value)}) {};
      } else {
        return maybe::value{$Typeof(value.value)}(deserialize_value{$Typeof(value.value)}(deserializer, $config)!);
      }

    $case Output::kind == ARRAY: //$defined(value.len) &&& $defined(value[0]) &&& Output != String:
    $case Output::kind == VECTOR:
      Allocator allocator = utils::@method_fallback{Deserializer}(deserializer, get_allocator, tmem);
      return @deserialize_slice{Output::inner}(deserializer, allocator, $config, Output::len);

    $case Output::kind == SLICE: //$defined(value.len) &&& $defined(value[0]) &&& Output != String:
      Allocator allocator = utils::@method_fallback{Deserializer}(deserializer, get_allocator, tmem);

      return @deserialize_slice{Output::inner}(deserializer, allocator, $config);

    $default:
      return @deserialize_primitive_value(Output, deserializer)!;

  $endswitch
}

macro @deserialize_list(#des, #allocator) <Output> @local {
  #des.slice_start()!;

  List{Output} elements;
  elements.init(#allocator);
  while(#des.has_next_slice_item()!) {
    elements.push(deserialize{Output}(#des)!);
  }
  #des.slice_end()!;
  return elements;
}

macro @deserialize_slice(#des, #allocator, #config, int $array_len = -1) <Output> @local {
  #des.slice_start()!;

  $if $array_len != -1:
    Output[$array_len] arr;
    sz i = 0;
    while(#des.has_next_slice_item()!) {
      if (i >= $array_len) {
        if (#config.array.skip_extra) {
          utils::@method_fallback{Deserializer}(#des, skip_next_value, @skip_next_value_fallback(#des))!;
        } else {
          return TOO_MANY_ELEMENTS_IN_ARRAY~;
        }
      } else {
        arr[i] = deserialize{Output}(#des)!;
      }
      i++;
    }
    #des.slice_end()!;
    return arr;

  $else
    List{Output} elements;
    while(#des.has_next_slice_item()!) {
      elements.push(deserialize{Output}(#des)!);
    }
    #des.slice_end()!;
    return elements.to_array(#allocator);
  $endif
}

macro @deserialize_primitive_value($Type, des) @local {
  $switch $Type:
    $case String:
      return des.next_string()!;

    $case char:
      $switch:
        $case $Typeof(des) == Deserializer:
          if (&des.next_char) {
            return des.next_char()!;
          }
          String s = des.next_string()!;
          Allocator allocator = utils::@method_fallback{Deserializer}(des, get_allocator, tmem);
          defer alloc::free(allocator, s);
          return s[0];

        $case $defined(des.next_char):
          return des.next_char();

        $default:
          String s = des.next_string()!;
          Allocator allocator = utils::@method_fallback{Deserializer}(des, get_allocator, tmem);
          defer alloc::free(allocator, s);
          return s[0];
      $endswitch

    $case bool:
      return des.next_bool()!;

    $case ichar:
      return (ichar) utils::@method_fallback_chain{Deserializer}(des, next_ichar, next_long, next_double)!;

    $case short:
      return (short) utils::@method_fallback_chain{Deserializer}(des, next_short, next_long, next_double)!;

    $case int:
      return (int) utils::@method_fallback_chain{Deserializer}(des, next_int, next_long, next_double)!;

    $case long:
      return (long) utils::@method_fallback{Deserializer}(des, next_long, des.next_double())!;

    $case int128:
      return utils::@method_fallback{Deserializer}(des, next_int128, UNSUPPORTED_DATATYPE~)!;

    $case ushort:
      return (ushort) utils::@method_fallback_chain{Deserializer}(des, next_ushort, next_ulong, next_long, next_double)!;

    $case uint:
      return (uint) utils::@method_fallback_chain{Deserializer}(des, next_uint, next_ulong, next_long, next_double)!;

    $case ulong:
      return (ulong) utils::@method_fallback_chain{Deserializer}(des, next_ulong, next_long, next_double)!;

    $case uint128:
      return utils::@method_fallback{Deserializer}(des, next_uint128, UNSUPPORTED_DATATYPE~)!;

    $case float:
      return (float) utils::@method_fallback{Deserializer}(des, next_float, des.next_double())!;

    $case double:
      return des.next_double()!;

    $default:
      $error "The value cannot be deserialize: " +++ $Type::name;
  $endswitch
}
