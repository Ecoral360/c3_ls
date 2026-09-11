module example @feat(DESSERT_EXAMPLE);
import std;
import dessert;
import json;
import derive;
import std::collections::object;
import dessert::format::dotenv;

$expand(dessert::@derive(Loglevel));
enum Loglevel @DEnum({ .rename_all = LOWER_CASE }) {
  VERBOSE,
  DEBUG,
  INFO,
  WARN,
  ERROR,
}

faultdef INVALID_EMAIL;

typedef Email = String;
macro void? Email.serialize(&self, ser) => ser.serialize_string((String) *self)!;
macro void? Email.deserialize(&self, des) {
  String s = des.next_string()!;
  if (!s.contains("@")) {
    return INVALID_EMAIL~;
  }
  *self = (Email) s;
}

$expand(dessert::@derive(Settings));
struct Settings @DStruct({ .rename_all = UPPER_CASE }) {
  Maybe{SecretString} api_key;

  long version;
  bool debug;

  Validated{String} url @DField({ .fmt = { `min_length=5` } });

  Loglevel log_level @DField({ .rename = "LOG" });

  Email email @DField({ .required = true });
  String other_email;

  NumberGt{int, 0} age;
}

$expand(dessert::@derive(FixedArrayWrap));
struct FixedArrayWrap {
    int[3] data @DField({ .array.skip_extra = true });
}


fn void? Settings.serialize_other_email(&self, Serializer ser) {
  ser.serialize_string(string::tformat("custom: %s", self.other_email))!;
}

fn void? Settings.deserialize_other_email(&self, Deserializer des) {
  String s = des.next_string()!;
  if (!s.contains("@")) {
    return INVALID_EMAIL~;
  }
  self.other_email = s;
}

$expand(dessert::@derive(Animal));
struct Animal {
    String name;
    String specie;
}

fn void main() {
  Settings settings = dotenv::tload{Settings}()!!;

  Animal sharpie = { .specie = "Cat", .name = "Sharpie" };
  String json = json::to_tstring(sharpie)!!;
  io::printn(json);

  FixedArrayWrap f = json::tdeserialize{FixedArrayWrap}(`{"data": [10, 20, 30, 40]}`)!!;
  io::printn(json::tserialize(f).to_pretty_string())!!;

  String json_str = "{\"name\": \"Sharpie\", \"specie\": \"Cat\"}";
  Animal animal = json::tfrom_string{Animal}(json_str)!!;
  io::printn(json::to_tstring(animal))!!;

  io::printn(json::tserialize(settings).to_pretty_string())!!;
}
