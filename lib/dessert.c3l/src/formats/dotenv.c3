module dessert::format::dotenv;

import std::io;
import std::io::file;
import std::collections::maybe;
import dessert::des;

faultdef
  UNEXPECTED_CHARACTER,
  INVALID_OBJECT,
  INVALID_FIELD,
  INVALID_ARRAY,
  INVALID_STRING,
  INVALID_ESCAPE,
  INVALID_NUMBER,
  INVALID_BOOLEAN,
  INVALID_NULL,
  INVALID_COMMENT;

macro Type? tload(String filepath = ".env") <Type> => load(tmem, filepath);

fn Type? load(Allocator allocator, String filepath = ".env") <Type> {
  String input = (String) io::read_fully(allocator, &&file::open(filepath, "r"))!;

  DotenvDeserializer des = { .allocator = allocator, .input = input };
  return des::deserialize{Type}(&des);
}



struct DotenvDeserializer (Deserializer) {
  Allocator allocator;
  String input;
  long current;
  Maybe{String} peeked_field;
}

macro bool is_blank(char c) @local {
  switch (c) @jump {
    case ' ':
    case '\t':
    case '\n':
    case '\r':
    case '\v':
    case '\f':
    case 0xA0:   // no-break space
      return true;
    default:
      return false;
  }
}
fn void DotenvDeserializer.skip_whitespace(&self) {
  while (self.has_next()) {
    if (is_blank(self.input[self.current])) {
      self.current++;
    } else if (self.input[self.current] == '#') {
      while (self.has_next() && self.peek()!! != '\n') (void) self.next()!!;
    } else {
      break;
    }
  }
}

fn bool DotenvDeserializer.has_next(&self) {
  return self.current < self.input.len;
}

fn char? DotenvDeserializer.next(&self) @inline {
  if (!self.has_next()) return io::EOF~;
  char c = self.input[self.current++];
  return c;
}

fn char? DotenvDeserializer.peek(&self) @inline {
  if (!self.has_next()) return io::EOF~;
  return self.input[self.current];
}

fn Allocator DotenvDeserializer.get_allocator(&self) @dynamic {
  return self.allocator;
}

fn void? DotenvDeserializer.struct_start(&self, String struct_name) @dynamic {
}

fn void? DotenvDeserializer.struct_end(&self, String struct_name) @dynamic {
}

fn bool? DotenvDeserializer.has_next_field(&self) @dynamic {
  if (self.peeked_field.has_value) return true;

  self.skip_whitespace();
  return self.has_next() && ascii::@is_alpha(self.peek())!;
}

fn String? DotenvDeserializer.next_field_name(&self) @dynamic {
  if (try field_name = self.peeked_field.get()) {
    self.peeked_field.reset();
    return field_name;
  }

  self.skip_whitespace();
  long start = self.current;
  while(self.peek()! != '=') (void) self.next()!;
  self.next()!; // skip the '='

  return self.input[start..self.current-2].trim();
}

fn String? DotenvDeserializer.peek_field_name(&self) @dynamic {
  if (try field_name = self.peeked_field.get()) {
    return field_name;
  }

  String field_name = self.next_field_name()!;
  self.peeked_field = maybe::value(field_name);

  return field_name;
}

fn void? DotenvDeserializer.slice_start(&self) @dynamic {
}

fn void? DotenvDeserializer.slice_end(&self) @dynamic {
}

fn bool? DotenvDeserializer.has_next_slice_item(&self) @dynamic {
  return false;
}

fn bool? DotenvDeserializer.next_null(&self) @dynamic {
  return false;
}

fn bool? DotenvDeserializer.next_bool(&self) @dynamic {
  self.skip_whitespace();
  char next = self.next()!;
  switch (next) {
    case 't':
      $foreach $v : "rue": // skips 'rue'
        self.next()!;
      $endforeach
      return true;
    case 'f':
      $foreach $v : "alse": // skips 'alse'
        self.next()!;
      $endforeach
      return false;
    default:
      return INVALID_BOOLEAN~;
  }
}

fn String? DotenvDeserializer.next_string(&self) @dynamic {
  self.skip_whitespace();

  if ((self.peek() ?? '\0') == '"') {
    self.next()!;
    DString val;
    val.init(self.allocator);
    while (true) {
      char c = self.next()!;
      if (c == '"') break;

      if (c == '\\') {
        char escape = self.next()!;
        switch (escape) {
          case 'n':
            val.append('\n');
          case 'r':
            val.append('\r');
          case 't':
            val.append('\t');
          case '"':
            val.append('\"');
          case '\'':
            val.append('\'');
          case '\\':
            val.append('\\');
          default:
            return INVALID_ESCAPE~;
        }
      } else {
        val.append(c);
      }
    }

    return val.copy_str(self.allocator);

  } else if ((self.peek() ?? '\0') == '\'') {
    self.next()!; // skip the first '
    long start = self.current;
    while(self.has_next() && self.peek()! != '\'') (void) self.next()!;
    self.next()!; // skip the last '
    return self.input[start..self.current-2].copy(self.allocator);

  } else {
    long start = self.current;
    while(self.has_next() && self.peek()! != '\n') (void) self.next()!;
    return self.input[start..self.current-1].trim_right().copy(self.allocator);
  }
}

fn double? DotenvDeserializer.next_double(&self) @dynamic {
  self.skip_whitespace();
  long start = self.current;
  while(self.has_next() && self.peek()! != '\n') (void) self.next()!;
  return self.input[start..self.current-1].trim().to_double();
}
