// Tests for the dotenv deserializer (`dessert::format::dotenv`). Dotenv is
// deserialize-only and reads directly from a file path, so each test writes a
// temporary `.env` under `build/`, loads it, then deletes it.
module dotenv_test @test;
import std;
import std::io::file;
import dessert;
import dessert::format::dotenv;

// ── Test types ───────────────────────────────────────────────────────────────

$expand(dessert::@derive(EnvConfig, deserialize));
struct EnvConfig @DStruct({ .rename_all = UPPER_CASE }) {
  String name;       // unquoted value
  String greeting;   // double-quoted value with an escape
  String raw;        // single-quoted value (no escape processing)
  int    port;
  bool   debug;
}

$expand(dessert::@derive(EnvSmall, deserialize));
struct EnvSmall @DStruct({ .rename_all = UPPER_CASE }) {
  String host;
  int    offset;
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn void test_dotenv_loads_all_types() @test => @pool() {
  const String PATH = "build/dotenv_test_all.env";
  // Raw literal: `\t` / `\n` are written to the file verbatim (backslash + letter).
  const String CONTENT =
`# application config

NAME = dessert
GREETING = "hello\tworld"
RAW = 'a\nb'
PORT=8080
DEBUG=false
`;
  file::save(PATH, (char[]) CONTENT)!!;
  defer (void) file::delete(PATH);

  EnvConfig cfg = dotenv::tload{EnvConfig}(PATH)!!;

  test::eq(cfg.name, "dessert");
  // Double-quoted values process escapes: `\t` becomes a real tab.
  test::eq(cfg.greeting, "hello\tworld");
  // Single-quoted values are literal: the backslash-n stays two characters.
  test::eq(cfg.raw, `a\nb`);
  test::eq(cfg.port, 8080);
  test::eq(cfg.debug, false);
}

fn void test_dotenv_comments_blanks_and_trimming() @test => @pool() {
  const String PATH = "build/dotenv_test_small.env";
  const String CONTENT =
`# a leading comment
HOST =   example.com

# another comment
OFFSET = -5
`;
  file::save(PATH, (char[]) CONTENT)!!;
  defer (void) file::delete(PATH);

  EnvSmall cfg = dotenv::tload{EnvSmall}(PATH)!!;

  // Surrounding whitespace around unquoted values is trimmed.
  test::eq(cfg.host, "example.com");
  test::eq(cfg.offset, -5);
}

fn void test_dotenv_load_with_allocator() @test => @pool() {
  const String PATH = "build/dotenv_test_alloc.env";
  const String CONTENT =
`HOST=localhost
OFFSET=1
`;
  file::save(PATH, (char[]) CONTENT)!!;
  defer (void) file::delete(PATH);

  // The non-`t` entry point takes an explicit allocator for the result.
  EnvSmall cfg = dotenv::load{EnvSmall}(tmem, PATH)!!;
  test::eq(cfg.host, "localhost");
  test::eq(cfg.offset, 1);
}
