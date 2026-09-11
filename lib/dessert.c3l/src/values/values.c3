module dessert::values;

import dessert::ser;
import dessert::des;

faultdef OUTSIDE_RANGE, VALIDATION_ERROR;

typedef Email = String;
macro void? Email.serialize(&self, ser) => ser.serialize_string((String) *self)!;
macro void? Email.deserialize(&self, des) {
  String s = des.next_string()!;
  if (!s.contains("@")) {
    return INVALID_EMAIL~;
  }
  *self = (Email) s;
}

typedef SecretString = String;
macro void? SecretString.serialize(&self, ser) => ser::serialize_value(ser, "*****", {})!;
macro void? SecretString.deserialize(&self, des) {
  *self = (SecretString) des.next_string()!;
}

typedef Validated<Type> = Type;
macro void? Validated.serialize(&self, ser) => ser::serialize_value(ser, (Type) *self, {})!;
macro void? Validated.deserialize(&self, des, DFieldConfig $config) {
  Type s = des::deserialize{Type}(des)!;
  var $fmt = $config.fmt;
  $switch:
    $case Type == String:
      @validate_string(des, s, $fmt)!;
      *self = ($Typeof(*self)) s;
  $endswitch
}


macro void? @validate_string(des, String s, FieldAttrs $fmt) @local {
  $fmt.@get_then("min_length"; $min_length) {
    var $value = values::@expand($min_length);
    if (s.len < $value) return des::errorf(des, VALIDATION_ERROR, "The length must be greater than %s. Was %s", $value, s.len);
  };

  $fmt.@get_then("max_length"; $max_length) {
    var $value = values::@expand($max_length);
    if (s.len > $value) return des::errorf(des, VALIDATION_ERROR, "The length must be less than %s. Was %s", $value, s.len);
  };
}


typedef Number<Backing, MIN, MAX> = Backing;
alias NumberLt<Backing, MAX> = Number{Backing, Backing::min, MAX};
alias NumberGt<Backing, MIN> = Number{Backing, MIN, Backing::max};

macro void? Number.serialize(&self, ser) => ser::serialize_value(ser, (Backing) *self, {})!;
macro void? Number.deserialize(&self, des) {
  Backing s = des::deserialize{Backing}(des)!;
  if (s > MAX || s < MIN) return OUTSIDE_RANGE~;
  *self = ($Typeof(*self)) s;
}
