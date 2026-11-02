module c3guide::test::outline;
import c3guide::outline, c3guide::check, c3guide::util, c3guide::test::support;
import std::core::string, std::os::env, std::io, std::io::file, std::io::path, std::time::clock;

const String SAMPLE = `module demo::shapes;
import std::io;

<* Area of a circle. @require r >= 0 *>
fn double circle_area(double r) => 3.14159 * r * r;

struct Point { int x; int y; }
enum Color : int { RED, GREEN }
faultdef BAD_INPUT;
macro @twice(#e) { return #e * 2; }
fn int Point.sum(&self) => self.x + self.y;
const int LIMIT = 10;
alias Pt = Point;
fn void main() { int local = 1; io::printn(local); }
`;

fn void lists_top_level_declarations_with_lines() @test
{
	String o = outline::outline_source(SAMPLE);
	assert(o.contains("5    fn double circle_area(double r)"), "line of the declaration, not of its doc comment: %s", o);
	assert(o.contains("-- Area of a circle."), "doc comment: %s", o);
	assert(o.contains("fn int Point.sum(&self)"), "method keeps its receiver: %s", o);
	assert(o.contains("struct Point") && o.contains("enum Color : int") && o.contains("faultdef BAD_INPUT"), "%s", o);
	assert(o.contains("macro @twice(#e)") && o.contains("const int LIMIT") && o.contains("alias Pt = Point"), "%s", o);
	assert(!o.contains("local"), "locals are not top-level: %s", o);
	String g = outline::outline_source("module m <Key, Value>;\nfn int f() => 1;\n");
	assert(g.contains("module m <Key, Value>") && g.contains("fn int f()") && !g.contains("=>"), "%s", g);
	assert(!o.contains("import"), "imports are not listed: %s", o);
}

fn void outlines_a_project_and_a_file() @test
{
	String own = outline::c3_outline("src");
	assert(own.contains("check.c3") && own.contains("fn String c3_check("), "%s", own);
	assert(!own.contains("vendor"), "%s", own);
	String one = outline::c3_outline("src/outline.c3");
	assert(one.contains("fn String c3_outline("), "%s", one);
	String small = outline::c3_outline("src/util.c3");
	assert(small.contains("fn String clip("), "%s", small);
	assert(outline::c3_outline("nope.txt").contains("must be"));
	assert(outline::c3_outline("src").len <= 6 * 1024 + 128, "capped");
}

fn Path project_dir() @local => check::scratch_dir()!!;

fn void a_long_project_is_cut_and_says_so() @test
{
	Path dir = project_dir();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	support::sh(string::tformat("mkdir -p '%s/src'; for i in $(seq 1 60); do for j in $(seq 1 12); do echo \"fn int f${i}_${j}(int value) => value;\"; done > \"%s/src/m$i.c3\"; done", root, root));
	String o = outline::c3_outline(root);
	assert(o.contains("more files not shown") && o.len <= 6 * 1024 + 128, "%d bytes: %s", (int)o.len, util::clip(o, 300));
}

fn void links_and_big_files_cannot_exhaust_the_outline() @test
{
	Path dir = project_dir();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	support::sh(string::tformat("mkdir -p '%s/src/a' && echo 'fn void ok() {}' > '%s/src/a/ok.c3' && ln -s .. '%s/src/a/loop' && ln -s . '%s/src/self' && head -c 1200000 /dev/zero | tr '\\\\0' 'a' > '%s/src/big.c3'", root, root, root, root, root));
	Clock t = clock::now();
	String o = outline::c3_outline(root);
	long ms = (long)t.to_now() / 1_000_000;
	assert(ms < 3000 && !o.contains("loop") && !o.contains("self/"), "%d ms: %s", (int)ms, o);
	assert(o.contains("fn void ok()") && o.contains("big.c3") && o.contains("skipped"), "%s", o);
}

fn void a_file_that_is_not_utf8_gives_a_valid_reply() @test
{
	Path dir = project_dir();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	support::sh(string::tformat("printf 'fn void h\\377\\376() {}\\n<* doc \\342\\202 *>\\nfn void k() {}\\n' > '%s/bad.c3'", root));
	String o = outline::c3_outline(string::tformat("%s/bad.c3", root));
	assert(support::valid_utf8(o) && o.contains("fn void k()"), "%s", o);
	assert(util::sanitize_utf8("a\xFFb\xE2\x82") == "a?b??", "a lone lead and a truncated sequence");
	assert(util::sanitize_utf8("h\xC3\xA9llo \U0001F980") == "h\xC3\xA9llo \U0001F980", "valid text is untouched");
	assert(util::sanitize_utf8("\xC0\x80") == "??" && util::sanitize_utf8("\xED\xA0\x80") == "???", "overlong and surrogate forms");
}

fn void a_very_deep_expression_does_not_crash_c3_fix() @test
{
	DString code = dstring::temp();
	code.append("fn void main() { x = ");
	for (int i = 0; i < 11000; i++) code.append_char('!');
	code.append("a; }");
	String r = check::c3_fix(code.str_view());
	assert(r.len > 0, "survived");
	String n = check::c3_fix("usz n = $sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof(int))))))))))))))))));");
	assert(n.len > 0, "survived deep nesting of the old form");
}

fn void the_grammar_parses_the_stdlib_of_the_c3c_it_targets() @test
{
	// Run with C3_DIR=<the c3c install> (CI sets it). Skipped without it: there is no stdlib to read.
	String? dir = env::tget_var("C3_DIR");
	if (catch dir) return;
	DString names = dstring::temp();
	int bad = outline::unparsed_files(string::tformat("%s/lib/std", dir), &names);
	assert(bad == 0, "%d stdlib files do not parse with the vendored grammar: it has not caught up with this c3c. Keep the old grammar (git checkout vendor/) until it does, or see scripts/update_treesitter.py.\n%s", bad, names.str_view());
}

fn void a_file_the_grammar_rejects_is_marked_incomplete() @test
{
	String o = outline::outline_source("fn void ok() {}\nfn void broken( {{{ ;;; @@@\nfn void after() {}\n");
	assert(o.contains("may be incomplete") && o.contains("fn void ok()"), "%s", o);
	assert(!outline::outline_source("fn void ok() {}\n").contains("incomplete"));
}

fn void libraries_and_a_match_filter() @test
{
	Path dir = project_dir();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	// a .c3l library is a zip file of sources: one entry stored, one deflated
	support::sh(string::tformat("mkdir -p '%s/deps' && python3 -c \"import zipfile; z = zipfile.ZipFile('%s/deps/curl.c3l', 'w'); z.writestr('curl.c3', 'module curl;\\nfn int curl_easy_init() => 1;\\nfn void curl_free() {}\\n', zipfile.ZIP_STORED); z.writestr('sub/util.c3', 'module curl::util;\\nfn int helper(int x) => x;\\n' * 40, zipfile.ZIP_DEFLATED); z.writestr('README.md', 'x'); z.close()\"", root, root));
	String lib = outline::c3_outline(string::tformat("%s/deps/curl.c3l", root));
	assert(lib.contains("curl.c3l!/curl.c3") && lib.contains("fn int curl_easy_init()") && lib.contains("fn int helper(int x)"), "%s", lib);
	assert(!lib.contains("README"), "only sources are listed: %s", lib);
	String found = outline::c3_outline(string::tformat("%s/deps", root), "CURL_EASY");
	assert(found.contains("curl_easy_init") && !found.contains("curl_free") && !found.contains("helper"), "match is case-insensitive and filters: %s", found);
	assert(outline::c3_outline(string::tformat("%s/deps", root), "no_such_function") == "no declarations found");
	String src = outline::c3_outline("src/util.c3", "clip");
	assert(src.contains("fn String clip(") && !src.contains("utf8_boundary"), "%s", src);
}
