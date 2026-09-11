// module dessert::des;
// import std::collections::object;
// import std::collections::map;
// import std::collections::list;
//
//
// fn void? String.deserialize(&self, Deserializer des) @dynamic {
//   *self = des.next_string()!;
// }
//
// fn void? char.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_char) {
//     *self = des.next_char()!;
//   } else {
//     *self = des.next_string()[0]!;
//   }
// }
//
// fn void? bool.deserialize(&self, Deserializer des) @dynamic {
//   *self = des.next_bool()!;
// }
//
// /// Signed numbers
//
// fn void? ichar.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_ichar) {
//     *self = des.next_ichar()!;
//   } else {
//     *self = (ichar) des.next_long()!;
//   }
// }
//
// fn void? short.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_short) {
//     *self = des.next_short()!;
//   } else {
//     *self = (short) des.next_long()!;
//   }
// }
//
// fn void? int.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_int) {
//     *self = des.next_int()!;
//   } else {
//     *self = (int) des.next_long()!;
//   }
// }
// fn void? long.deserialize(&self, Deserializer des) @dynamic {
//   *self = des.next_long()!;
// }
// fn void? int128.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_int128) {
//    *self = des.next_int128()!;
//     return;
//   }
//   return UNSUPPORTED_DATA_TYPE~;
// }
//
// /// Unsigned numbers
//
// fn void? ushort.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_ushort) {
//     *self = des.next_ushort()!;
//   } else if (&des.next_ulong) {
//     *self = (ushort) des.next_ulong()!;
//   } else {
//     *self = (ushort) des.next_long()!;
//   }
// }
//
// fn void? uint.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_uint) {
//     *self = des.next_uint()!;
//   } else if (&des.next_ulong) {
//     *self = (uint) des.next_ulong()!;
//   } else {
//     *self = (uint) des.next_long()!;
//   }
// }
// fn void? ulong.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_ulong) {
//     *self = des.next_ulong()!;
//   } else {
//     *self = (ulong) des.next_long()!;
//   }
// }
//
// fn void? uint128.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_uint128) {
//     *self = des.next_uint128()!;
//     return;
//   }
//   return UNSUPPORTED_DATA_TYPE~;
// }
//
//
// /// Floating numbers
//
// fn void? float.deserialize(&self, Deserializer des) @dynamic {
//   if (&des.next_float) {
//     *self = des.next_float()!;
//   } else {
//     *self = (float) des.next_double()!;
//   }
// }
//
// fn void? double.deserialize(&self, Deserializer des) @dynamic {
//   *self = des.next_double()!;
// }
//
// // fn void? List.deserialize(&self, Deserializer deserializer) {
// //   $if @is_deserializable(Type):
// //       deserializer.slice_start()!;
// //       while(deserializer.has_next_slice_item()!) {
// //         self.push(deserialize{Type}(deserializer)!);
// //       }
// //       deserializer.slice_end()!;
// //   $else
// //     abort(@sprintf("Type not deserializable '%s'", Type));
// //   $endif
// // }
