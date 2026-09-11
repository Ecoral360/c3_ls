module dessert::ser;

import std::collections::object;
import std::collections::map;

faultdef UNSUPPORTED_DATA_TYPE;

// fn void? String.serialize(&self, Serializer ser) @dynamic {
//   return ser.serialize_string(*self);
// }
// fn void? ZString.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_zstring) {
//     return ser.serialize_zstring(*self);
//   }
//   return ser.serialize_string(self.str_view());
// }
//
// fn void? bool.serialize(&self, Serializer ser) @dynamic {
//   return ser.serialize_bool(*self);
// }
//
// fn void? char.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_char) {
//     return ser.serialize_char(*self);
//   }
//   return ser.serialize_string({*self});
// }
//
// /// Signed numbers
//
// fn void? ichar.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_ichar) {
//     return ser.serialize_ichar(*self);
//   }
//   return ser.serialize_long((long) *self);
// }
//
// fn void? short.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_short) {
//     return ser.serialize_short(*self);
//   }
//   return ser.serialize_long((long) *self);
// }
//
// fn void? int.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_int) {
//     return ser.serialize_int(*self);
//   }
//   return ser.serialize_long((long) *self);
// }
//
// fn void? long.serialize(&self, Serializer ser) @dynamic {
//   return ser.serialize_long(*self);
// }
//
// fn void? int128.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_int128) {
//     return ser.serialize_int128(*self);
//   }
//   return UNSUPPORTED_DATA_TYPE~;
// }
//
// /// Unsigned numbers
//
// fn void? ushort.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_ushort) {
//     return ser.serialize_ushort(*self);
//   } else if (&ser.serialize_ulong) {
//     return ser.serialize_ulong((ulong) *self);
//   } else {
//     return ser.serialize_long((long) *self);
//   }
// }
//
// fn void? uint.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_uint) {
//     return ser.serialize_uint(*self);
//   } else if (&ser.serialize_ulong) {
//     return ser.serialize_ulong((ulong) *self);
//   } else {
//     return ser.serialize_long((long) *self);
//   }
// }
//
// fn void? ulong.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_ulong) {
//     return ser.serialize_ulong(*self);
//   }
//   return ser.serialize_long((long) *self);
// }
//
// fn void? uint128.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_uint128) {
//     return ser.serialize_uint128(*self);
//   }
//   return UNSUPPORTED_DATA_TYPE~;
// }
//
// /// Floating numbers
//
// // fn void? float16.serialize(&self, Serializer ser) @dynamic @if($defined(float16)) {
// //   if (&ser.serialize_float16) {
// //     return ser.serialize_float16(*self);
// //   }
// //   return ser.serialize_double((double) *self);
// // }
//
// fn void? float.serialize(&self, Serializer ser) @dynamic {
//   if (&ser.serialize_float) {
//     return ser.serialize_float(*self);
//   }
//   return ser.serialize_double((double) *self);
// }
//
// fn void? double.serialize(&self, Serializer ser) @dynamic {
//   return ser.serialize_double(*self);
// }
//
// // fn void? float128.serialize(&self, Serializer ser) @dynamic @if($defined(float128)) {
// //   if (&ser.serialize_float128) {
// //     return ser.serialize_float128(*self);
// //   }
// //   return UNSUPPORTED_DATA_TYPE~;
// // }
//
<*
  Serialize a dynamically-typed `Object*`, the mirror image of `next_any` on the
  deserializer side.

  Unlike the other `serialize` methods, this one emits its own struct and slice
  delimiters: the shape is only known at runtime, so `serialize_value` cannot
  wrap the call in `struct_start`/`struct_end` up front (see the `Object` case
  there).
*>
fn void? Object.serialize(&self, Serializer ser) {
  switch {
    // `new_obj` yields an object of type `void`, i.e. a map with no entry yet.
    case self.is_empty():
      break;

    case self.is_null():
      return ser.serialize_null();

    case self.is_bool():
      return ser.serialize_bool(self.b);

    case self.is_string():
      return ser.serialize_string(self.s);

    case self.is_float():
      return ser.serialize_double(self.f);

    case self.is_int():
      return ser.serialize_long((long) self.i);

    case self.is_enum():
      return ser.serialize_long((long) self.i);

    case self.is_array():
      long len = (long) self.array.len();
      ser.serialize_slice_start(len)!;
      foreach (i, item : self.array) {
        if (&ser.serialize_slice_item_start) ser.serialize_slice_item_start((usz) i)!;
        ser::serialize_value(ser, item, {})!;
        if (&ser.serialize_slice_item_end) ser.serialize_slice_item_end((usz) i)!;
      }
      ser.serialize_slice_end(len)!;

    case self.is_map():
      self.map.@each(; String key, Object* value) {
        ser.serialize_field_start(key, {}, $Typeof(*self))!;
        ser::serialize_value(ser, value, {})!;
        ser.serialize_field_end(key, {}, $Typeof(*self))!;
      };

    default:
      // `void*` other than the shared null object, and any other payload the
      // std `Object` may grow later.
      switch (self.type.kind) {
        case POINTER:
          return ser.serialize_null();
        case SIGNED_INT:
          return ser.serialize_long((long) self.i);
        case UNSIGNED_INT:
          if (&ser.serialize_ulong) return ser.serialize_ulong((ulong) self.i);
          return ser.serialize_long((long) self.i);
        case FLOAT:
          return ser.serialize_double(self.f);
        default:
          return UNSUPPORTED_DATA_TYPE~;
      }
  }
}

fn void? HashMap.serialize(&self, Serializer s) {
  $if @is_serializable((Value){}):
    self.@each(; key, value) {
      String key_s = string::tformat("%s", key);
      s.serialize_field_start(key_s, {}, $Typeof(*self))!;
      serialize_value(s, value, {})!;
      s.serialize_field_end(key_s, {}, $Typeof(*self))!;
    };
  $else
    abort(@sprintf("Value not serializable '%s'", Value::name));
  $endif
}
