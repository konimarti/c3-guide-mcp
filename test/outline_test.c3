module c3guide::test::outline;
import c3guide::outline, c3guide::tools, c3guide::check, c3guide::util, c3guide::test::support;
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
	String own = outline::outline_path("src");
	assert(own.contains("check.c3") && own.contains("fn String c3_check("), "%s", own);
	assert(!own.contains("vendor"), "%s", own);
	String one = outline::outline_path("src/outline.c3");
	assert(one.contains("fn String outline_path("), "%s", one);
	String small = outline::outline_path("src/util.c3");
	assert(small.contains("fn String clip("), "%s", small);
	assert(outline::outline_path("nope.txt").contains("must be"));
	assert(outline::outline_path("src").len <= 6 * 1024 + 128, "capped");
}

fn Path project_dir() @local => check::scratch_dir()!!;

fn void a_long_project_is_cut_and_says_so() @test
{
	Path dir = project_dir();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	support::sh(string::tformat("mkdir -p '%s/src'; for i in $(seq 1 60); do for j in $(seq 1 12); do echo \"fn int f${i}_${j}(int value) => value;\"; done > \"%s/src/m$i.c3\"; done", root, root));
	String o = outline::outline_path(root);
	assert(o.contains("more files not shown") && o.len <= 6 * 1024 + 128, "%d bytes: %s", (int)o.len, util::clip(o, 300));
}

fn void links_and_big_files_cannot_exhaust_the_outline() @test
{
	Path dir = project_dir();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	support::sh(string::tformat("mkdir -p '%s/src/a' && echo 'fn void ok() {}' > '%s/src/a/ok.c3' && ln -s .. '%s/src/a/loop' && ln -s . '%s/src/self' && head -c 1200000 /dev/zero | tr '\\\\0' 'a' > '%s/src/big.c3'", root, root, root, root, root));
	Clock t = clock::now();
	String o = outline::outline_path(root);
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
	String o = outline::outline_path(string::tformat("%s/bad.c3", root));
	assert(support::valid_utf8(o) && o.contains("fn void k()"), "%s", o);
	assert(util::sanitize_utf8("a\xFFb\xE2\x82") == "a?b??", "a lone lead and a truncated sequence");
	assert(util::sanitize_utf8("h\xC3\xA9llo \U0001F980") == "h\xC3\xA9llo \U0001F980", "valid text is untouched");
	assert(util::sanitize_utf8("\xC0\x80") == "??" && util::sanitize_utf8("\xED\xA0\x80") == "???", "overlong and surrogate forms");
}

fn void a_very_deep_expression_does_not_crash_the_rewrite() @test
{
	DString code = dstring::temp();
	code.append("fn void main() { x = ");
	for (int i = 0; i < 11000; i++) code.append_char('!');
	code.append("a; }");
	String r = check::c3_check(code.str_view());
	assert(r.len > 0, "survived");
	String n = check::c3_check("usz n = $sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof($sizeof(int))))))))))))))))));");
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
	String lib = outline::outline_path(string::tformat("%s/deps/curl.c3l", root));
	assert(lib.contains("curl.c3l!/curl.c3") && lib.contains("fn int curl_easy_init()") && lib.contains("fn int helper(int x)"), "%s", lib);
	assert(!lib.contains("README"), "only sources are listed: %s", lib);
	String found = outline::outline_path(string::tformat("%s/deps", root), "CURL_EASY");
	assert(found.contains("curl_easy_init") && !found.contains("curl_free") && !found.contains("helper"), "match is case-insensitive and filters: %s", found);
	assert(outline::outline_path(string::tformat("%s/deps", root), "no_such_function") == "no declarations found");
	String src = outline::outline_path("src/util.c3", "clip");
	assert(src.contains("fn String clip(") && !src.contains("utf8_boundary"), "%s", src);
}

const String ARCHIVE_SCRIPT = `
import sys, zipfile
root = sys.argv[1]
body = "fn void f() {}\n" * 60000                       # about 0.9 MB inflated, a few KB deflated
with zipfile.ZipFile(root + "/big.c3l", "w", zipfile.ZIP_DEFLATED) as z:
    for i in range(40):
        z.writestr("m%d.c3" % i, "module m%d;\n" % i + body)
with zipfile.ZipFile(root + "/dup.c3l", "w") as z:
    z.writestr("dup.c3", "module first;\nfn void one() {}\n")
    z.writestr("dup.c3", "module second;\nfn void two() {}\n")
with zipfile.ZipFile(root + "/many.c3l", "w") as z:
    for i in range(450):
        z.writestr("f%d.c3" % i, "fn void g%d() {}\n" % i)
`;

fn void archives_have_a_budget_and_say_what_they_skip() @test
{
	Path dir = project_dir();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	file::save(string::tformat("%s/make.py", root), ARCHIVE_SCRIPT)!!;
	support::sh(string::tformat("python3 '%s/make.py' '%s'", root, root));
	Clock t = clock::now();
	String big = outline::outline_path(string::tformat("%s/big.c3l", root), "no_such_declaration");   // nothing matches, so every entry is read
	long ms = (long)t.to_now() / 1_000_000;
	assert(big.contains("[stopped: the sources in this archive are over 8 MB]") && ms < 8000, "%d ms: %s", (int)ms, util::clip(big, 200));
	String dup = outline::outline_path(string::tformat("%s/dup.c3l", root));
	assert(dup.contains("fn void one()") && !dup.contains("fn void two()"), "the first of two entries with one name, once: %s", dup);
	String many = outline::outline_path(string::tformat("%s/many.c3l", root), "g449");
	assert(many.contains("more entries not read"), "a cut is announced: %s", many);
	String shown = outline::outline_path(string::tformat("%s/big.c3l", root));
	assert(shown.len <= 6 * 1024 + 128 && shown.contains("m0.c3"), "an archive's output is capped too: %d bytes", (int)shown.len);
}

fn void a_filter_does_not_hide_that_a_file_was_not_fully_read() @test
{
	String o = outline::outline_source("fn void alpha() {}\nfn void broken( {{{ ;;; @@@\n", "no_such_name");
	assert(o.contains("may be incomplete"), "%s", o);
	assert(outline::outline_source("fn void alpha() {}\n", "no_such_name") == "", "a clean file with no match is just empty");
}

const String LOOKUP_SRC = `module demo;
import std::io;

<* Add two numbers. *>
fn int add(int a, int b) => a + b;

struct Counter { int n; }
fn void Counter.bump(&self) { self.n = add(self.n, 1); }
fn int use_it(Counter* c, int add_me) { c.bump(); return add(add_me, 1); } // add in a comment
const int MAX_ADD = 10;
faultdef BAD_ADD, WORSE_ADD;
fn void main() { io::printn("add"); }
`;

fn Path lookup_project()
{
	Path dir = check::scratch_dir()!!;
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/src", root))!!)!!;
	file::save(string::tformat("%s/project.json", root), "{ \"sources\": [\"src/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	file::save(string::tformat("%s/src/a.c3", root), LOOKUP_SRC)!!;
	return dir;
}

fn void a_declared_name_is_what_the_declaration_declares() @test
{
	assert(outline::declared_name("fn int add(int a, int b)") == "add");
	assert(outline::declared_name("fn void Counter.bump(&self)") == "Counter.bump");
	assert(outline::declared_name("fn List{Type}* List{Type}.push(&self, Type v)") == "List{Type}.push");
	assert(outline::declared_name("struct Counter") == "Counter");
	assert(outline::declared_name("enum Status : int") == "Status");
	assert(outline::declared_name("const int MAX_ADD") == "MAX_ADD");
	assert(outline::declared_name("faultdef BAD_ADD, WORSE_ADD;").contains("WORSE_ADD"));
	assert(outline::name_rank("fn int add(int a, int b)", "add") == 0);
	assert(outline::name_rank("fn int Counter.bump(&self)", "bump") == 0);
	assert(outline::name_rank("fn int Counter.bump(&self)", "Counter.bump") == 0);
	assert(outline::name_rank("const int MAX_ADD", "add") == 1);
	assert(outline::name_rank("fn int use_it(Counter* c, int add_me)", "add") == 2);
}

fn void lookup_finds_declarations_by_name_best_first() @test
{
	Path dir = lookup_project();
	defer (void)path::rmtree(dir);
	int count;
	String scope;
	String r = outline::project_lookup((String)dir, "add", 10, &count, &scope);
	assert(count >= 1 && r.contains("src/a.c3:5  fn int add(int a, int b)") && r.contains("Add two numbers"), "%s", r);
	assert(!r.contains("use_it"), "a declaration that only has the name in a parameter is left out when the name is declared: %s", r);
	String m = outline::project_lookup((String)dir, "bump", 10, &count, &scope);
	assert(count == 1 && m.contains("Counter.bump"), "%s", m);
	String f = outline::project_lookup((String)dir, "worse_add", 10, &count, &scope);
	assert(count == 1 && f.contains("faultdef"), "%s", f);
	String none = outline::project_lookup((String)dir, "nothing_here", 10, &count, &scope);
	assert(count == 0 && none == "", "%s", none);
	assert(scope.contains("c3guide-"), "the scope is reported");
}

fn void lookup_by_description_needs_most_of_the_words() @test
{
	Path dir = lookup_project();
	defer (void)path::rmtree(dir);
	int count;
	String scope;
	String r = outline::project_lookup((String)dir, "add two numbers", 10, &count, &scope);
	assert(count >= 1 && r.contains("fn int add"), "%s", r);
	String no = outline::project_lookup((String)dir, "launch the rocket", 10, &count, &scope);
	assert(count == 0, "%s", no);
}

fn void lookup_reads_the_libraries_of_a_project() @test
{
	Path dir = lookup_project();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/deps/inner", root))!!, recursive: true)!!;
	file::save(string::tformat("%s/deps/inner/lib.c3", root), "module inner;\nfn int curl_easy_perform(int h) => h;\n")!!;
	int count;
	String scope;
	String r = outline::project_lookup(root, "curl_easy_perform", 10, &count, &scope);
	assert(count == 1 && r.contains("deps/inner/lib.c3"), "%s", r);
}

fn void refs_are_uses_in_code_not_in_strings_or_comments() @test
{
	Path dir = lookup_project();
	defer (void)path::rmtree(dir);
	String r = outline::refs_reply("add", (String)dir, false, 30);
	assert(r.contains("3 use(s)") || r.contains("4 use(s)"), "%s", r);
	assert(r.contains("[declaration]"), "%s", r);
	assert(!r.contains("io::printn(\"add\")"), "a string is not a use: %s", r);
	assert(!r.contains("// add in a comment") || r.contains("add(add_me, 1)"), "%s", r);
	String q = outline::refs_reply("Counter.bump", (String)dir, false, 30);
	assert(q.contains("2 use(s)"), "the last part of the name is searched: %s", q);
	assert(outline::refs_reply("zzz_unused", (String)dir, false, 30).contains("is not used"));
	assert(outline::refs_reply("two words", (String)dir, false, 30).contains("one identifier"));
}

fn void refs_search_the_installed_standard_library() @test
{
	if (check::stdlib_root().len == 0) return;
	String r = outline::refs_reply("is_dir", "", true, 5);
	assert(r.contains("use(s) of 'is_dir'") && r.contains("io/path.c3"), "%s", r);
}

fn void refs_search_the_library_archives_too() @test
{
	Path dir = lookup_project();
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/deps", root))!!)!!;
	String script = "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w') as z:\n    z.writestr('src/lib.c3', 'module inner;\\nfn int curl_easy_perform(int h) => h;\\nfn int again() => curl_easy_perform(2);\\n')\n";
	file::save(string::tformat("%s/zip.py", root), script)!!;
	support::sh(string::tformat("python3 '%s/zip.py' '%s/deps/inner.c3l'", root, root));
	String r = outline::refs_reply("curl_easy_perform", root, false, 30);
	assert(r.contains("inner.c3l!/src/lib.c3") && r.contains("2 use(s)"), "%s", r);
}

fn void a_rename_is_a_plan_of_exact_edits_and_writes_nothing() @test
{
	Path dir = check::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/src", root))!!)!!;
	file::save(string::tformat("%s/project.json", root), "{ \"sources\": [\"src/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	String src = "module app;\nstruct Server { int fd; }\nstruct TcpServerSocket { Server s; }\n// Server in a comment\nfn Server make() { Server s = {}; return s; }\n";
	String file = string::tformat("%s/src/a.c3", root);
	file::save(file, src)!!;
	String r = tools::c3_refs("Server", root, false, 30, "Srv");
	assert(r.contains("Rename 'Server' to 'Srv'") && r.contains("- struct Server { int fd; }") && r.contains("+ struct Srv { int fd; }"), "%s", r);
	assert(r.contains("+ fn Srv make() { Srv s = {}; return s; }"), "%s", r);   // two uses on one line
	assert(!r.contains("TcpSrvSocket") && !r.contains("comment"), "%s", r);   // a longer name and a comment are not touched
	assert(file::load_temp(file)!! == src);   // nothing was written
	assert(tools::c3_refs("Server", root, false, 30, "bad name").contains("one identifier"));
	assert(tools::c3_refs("Server", root, true, 30, "Srv").contains("your own code"));
	assert(tools::c3_refs("Server", root, false, 30, "TcpServerSocket").contains("WARNING"));
}

fn void a_search_path_that_leaves_the_project_and_its_parent_is_not_read() @test
{
	Path dir = check::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/a/proj/src", root))!!, recursive: true)!!;
	path::mkdir(path::new(tmem, string::tformat("%s/a/sibling", root))!!)!!;
	path::mkdir(path::new(tmem, string::tformat("%s/elsewhere", root))!!)!!;
	file::save(string::tformat("%s/a/sibling/s.c3", root), "module s;\nconst int SIBLING_THING = 1;\n")!!;
	file::save(string::tformat("%s/elsewhere/e.c3", root), "module e;\nconst int ELSEWHERE_THING = 1;\n")!!;
	file::save(string::tformat("%s/a/proj/src/main.c3", root), "module app;\nfn void main() {}\n")!!;
	file::save(string::tformat("%s/a/proj/project.json", root), string::tformat("{ \"sources\": [\"src/**\"], \"dependency-search-paths\": [\"../sibling\", \"%s/elsewhere\", \"../../elsewhere\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }", root))!!;
	String proj = string::tformat("%s/a/proj", root);
	assert(tools::c3_lookup("SIBLING_THING", proj).contains("SIBLING_THING"));   // a folder next to the project is read
	assert(!tools::c3_lookup("ELSEWHERE_THING", proj).contains("e.c3"));   // one that leaves it is not
}
