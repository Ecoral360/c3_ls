module derive;

macro derive(String $typename, ...) @const @builtin @deprecated("Use `dessert::@derive(Type)` instead") {
  var $out = "";
  $for int $i = 0; $i < $vaarg.len; $i++:
    $out +++= $eval($stringify($vaarg[$i]))($typename);
  $endfor
  return $out;
}

module derive::dessert;

macro serialize(String $typename) @const {
  return @sprintf("macro void? %s.serialize(&self, ser) => dessert::ser::impl_serialize{%s*, $Typeof(ser)}(self, ser);\n", $typename, $typename);
}
macro deserialize(String $typename) @const {
  return @sprintf("macro void? %s.deserialize(&self, des) => dessert::des::impl_deserialize(self, des);\n", $typename);
}

module derive;

macro dessert(String $typename) @const {
  return @sprintf("%s\n%s", dessert::serialize($typename), dessert::deserialize($typename));
}

module dessert;

macro serialize(String $typename) @const @local {
  return @sprintf("macro void? %s.serialize(&self, ser) => dessert::ser::impl_serialize{%s*, $Typeof(ser)}(self, ser);\n", $typename, $typename);
}
macro deserialize(String $typename) @const {
  return @sprintf("macro void? %s.deserialize(&self, des) => dessert::des::impl_deserialize(self, des);\n", $typename);
}
macro @derive($Type, #what = ...) @const {
  $if $defined(#what):
    var $what = $stringify(#what);
    $switch $what:
      $case "serialize":
        return serialize($Type::name);
      $case "deserialize":
        return deserialize($Type::name);
      $default:
        $error @sprintf("Invalid values for `dessert::@derive`. Expected 'serialize' or 'deserialize', found '%s'.", $what);
    $endswitch
  $else
    return @sprintf("%s\n%s", serialize($Type::name), deserialize($Type::name));
  $endif
}
