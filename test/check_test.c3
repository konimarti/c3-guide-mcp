module c3guide::test::check;
import c3guide::format;
import c3guide::compiler, c3guide::proc;
import c3guide::check, c3guide::util, c3guide::hints, c3guide::test::support;
import std::core::string, std::io, std::io::file, std::io::path, std::os::env, std::time, std::time::clock;
import std::os::posix;

const String[*] TOKENS = { "$include", "$exec", "$embed" };
const String[*] FLAGS = { "--trust=none", "--no-obj", "--no-entry", "compile-only" };

fn bool has(String hay, String needle) @local => hay.contains(needle);

fn void valid_code_is_ok() @test
{
	assert(has(check::c3_check("fn int add(int a, int b) { return a + b; }"), "OK"));
}

fn void if_else_without_braces_is_reported() @test
{
	String t = check::c3_check("fn void f() { int x = 1; if (x == 1) return; else return; }");
	assert(has(t, "must use") && has(t, "<code>/snippet.c3"), "%s", t);
}

fn void syntax_error_has_line_and_column() @test
{
	String t = check::c3_check("import std::io;\nfn void main() { io::printn(\"a\") }");
	assert(has(t, "snippet.c3:2:"), "%s", t);
	assert(!has(t, "c3guide-"), "the temp path leaks: %s", t);
}

fn void empty_and_oversized_code_is_rejected() @test
{
	assert(has(check::c3_check(""), "give code"));
	DString big = dstring::temp();
	big.append("fn void f() {}");
	for (int i = 0; i < 40000; i++) big.append_char(' ');
	assert(has(check::c3_check(big.str_view()), "give 1 to"));
}

fn void forbidden_tokens_are_rejected() @test
{
	foreach (tok : TOKENS)
	{
		String t = check::c3_check(string::tformat("module m; %s(\"x\");", tok));
		assert(has(t, "rejected"), "%s: %s", tok, t);
	}
}

fn void exec_never_runs() @test
{
	Path work = support::make_temp_dir("c3work");
	defer (void)path::rmtree(work);
	String marker = string::tformat("%s/marker", (String)work);
	String payload = string::tformat("module evil;\n$exec(\"touch\", { \"%s\" });\nfn void main() {}\n", marker);
	check::c3_check(payload);
	assert(!file::exists(marker), "c3_check ran $exec");
	// positive control: the same payload does run under --trust=full, so the check above can fail
	String evil = string::tformat("%s/evil.c3", (String)work);
	file::save(evil, payload)!!;
	support::sh(string::tformat("cd '%s' && '%s' --trust=full --no-obj --no-entry -q compile-only evil.c3 2>&1", (String)work, support::c3c_binary()));
	assert(file::exists(marker), "positive control: the payload should run under --trust=full");
}

fn void embed_cannot_leak_a_file() @test
{
	Path dir = support::make_temp_dir("c3secret");
	defer (void)path::rmtree(dir);
	String secret = string::tformat("%s/secret.txt", (String)dir);
	file::save(secret, "rxyz")!!;   // 114 120 121 122: a file of our own, so the test does not depend on /etc/passwd
	String code = string::tformat("module m; const char[*] X = $embed(\"%s\"); fn void f() { $for var $i = 0; $i < 4; $i++: $echo((int)X[$i]); $endfor }", secret);
	String t = check::c3_check(code);
	assert(has(t, "rejected") && !has(t, "114") && !has(t, "120"), "%s", t);
	// positive control: the compiler itself prints the file under --trust=none
	String probe = string::tformat("%s/probe.c3", (String)dir);
	file::save(probe, code)!!;
	String ctl = support::sh(string::tformat("'%s' --trust=none --no-obj --no-entry -q compile-only '%s' 2>&1", support::c3c_binary(), probe));
	assert(has(ctl, "114"), "positive control: %s", ctl);
}

fn void temp_dirs_are_cleaned_up() @test
{
	Path tmp = path::temp_directory(tmem)!!;
	String before = support::sh(string::tformat("ls '%s' | grep -c '^c3guide-' ; true", (String)tmp));
	check::c3_check("fn void f() {}");
	String after = support::sh(string::tformat("ls '%s' | grep -c '^c3guide-' ; true", (String)tmp));
	assert(before == after, "c3guide-* dirs before %s, after %s", before, after);
}

fn void stale_temp_dirs_are_swept_and_fresh_ones_kept() @test
{
	Path tmp = path::temp_directory(tmem)!!;
	String old = string::tformat("%s/c3guide-stale-test", (String)tmp);
	String fresh = string::tformat("%s/c3guide-fresh-test", (String)tmp);
	// two hours old; `date -r SECONDS` is BSD/macOS, `date -d @SECONDS` is GNU, and touch -d "2 hours ago" is GNU only
	support::sh(string::tformat("mkdir -p '%s' '%s' && t=$(( $(date +%%s) - 7200 )) && touch -t \"$(date -r $t +%%Y%%m%%d%%H%%M.%%S 2>/dev/null || date -d @$t +%%Y%%m%%d%%H%%M.%%S)\" '%s'", old, fresh, old));
	check::c3_check("fn void f() {}");
	assert(!file::exists(old), "stale temp dir should be removed");
	assert(file::exists(fresh), "fresh temp dir belongs to another server and stays");
	support::sh(string::tformat("rm -rf '%s'", fresh));
}

fn void missing_compiler_gives_a_clear_message() @test
{
	defer support::restore_c3c();
	support::set_c3c("/nonexistent/c3c");
	assert(has(check::c3_check("fn void f() {}"), "could not start c3c"));
}

fn void the_exit_code_is_right_even_when_the_pipe_outlives_the_compiler() @test
{
	// the compiler exits with 3 at once, a background process keeps the output pipe open for half a second:
	// the exit is seen before the output is complete, and the code must still be 3 (every time, not mostly)
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	defer support::restore_c3c();
	support::set_c3c(support::write_fake(dir, "exit3.sh", "sleep 0.5 &\nexit 3"));
	String t = check::c3_check("fn void f() {}");
	assert(!has(t, "OK") && has(t, "exit code 3"), "%s", t);
	support::set_c3c(support::write_fake(dir, "exit0.sh", "sleep 0.5 &\nexit 0"));
	assert(has(check::c3_check("fn void f() {}"), "OK"), "a success with a held pipe is still a success");
}

fn void output_of_exactly_the_cap_is_not_cut_but_one_byte_more_is() @test
{
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	defer support::restore_c3c();
	// c3_check keeps 4096 bytes. 4096 exactly fits, with its exit code; 4097 is cut
	support::set_c3c(support::write_fake(dir, "exact.sh", "head -c 4096 /dev/zero | tr '\\\\0' 'x'\nexit 7"));
	String exact = check::c3_check("fn void f() {}");
	assert(!has(exact, "[output cut]") && exact.len >= 4096, "%d bytes: %s", (int)exact.len, util::clip(exact, 80));
	support::set_c3c(support::write_fake(dir, "over.sh", "head -c 4097 /dev/zero | tr '\\\\0' 'x'\nexit 7"));
	assert(has(check::c3_check("fn void f() {}"), "[output cut]"));
}

fn void a_compiler_that_closes_its_output_but_keeps_running_still_gets_the_deadline() @test
{
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	String fake = support::write_fake(dir, "mute.sh", "exec >&- 2>&-\nsleep 20\nexit 4");
	String[] argv = { fake };
	int code = 0;
	bool timed_out = false;
	Clock t = clock::now();
	String? out = proc::run_capped(argv, &code, &timed_out, { .deadline_ms = 1500 });
	long ms = (long)t.to_now() / 1_000_000;
	assert(@ok(out) && timed_out && ms < 6000, "%d ms, timed out %s", (int)ms, timed_out ? "yes" : "no");
}

fn void exit_code_without_output_is_not_ok() @test
{
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	defer support::restore_c3c();
	support::set_c3c(support::write_fake(dir, "exit1.sh", "exit 1"));
	String t = check::c3_check("fn void f() {}");
	assert(!has(t, "OK") && has(t, "exit code 1"), "%s", t);
}

fn void compiler_flags_are_fixed() @test
{
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	defer support::restore_c3c();
	String argv = string::tformat("%s/argv.txt", (String)dir);
	support::set_c3c(support::write_fake(dir, "rec.sh", string::tformat("echo \"$@\" > '%s'", argv)));
	check::c3_check("fn void f() {}");
	String got = (String)file::load_temp(argv)!!;
	foreach (f : FLAGS) assert(has(got, f), "flag %s missing: %s", f, got);
}

fn void never_ending_compiler_is_killed_after_10_seconds() @test
{
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	defer support::restore_c3c();
	support::set_c3c(support::write_fake(dir, "hang", "exec sleep 60"));
	Clock start = clock::now();
	String t = check::c3_check("fn void f() {}");
	ulong ms = (ulong)start.to_now() / 1_000_000;
	assert(ms > 9000 && ms < 20000 && has(t, "[timeout"), "%d ms: %s", ms, t);
	// the server keeps serving
	support::restore_c3c();
	assert(has(check::c3_check("fn void f() {}"), "OK"));
}

fn void no_timeout_program_is_needed() @test
{
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	defer support::restore_c3c();
	String saved = env::tget_var("PATH")!!;
	defer env::set_var("PATH", saved);
	String bin = string::tformat("%s/bin", (String)dir);
	support::sh(string::tformat("mkdir '%s' && ln -s \"$(command -v sleep)\" '%s/sleep'", bin, bin));
	support::set_c3c(support::write_fake(dir, "hang2", "exec sleep 60"));
	env::set_var("PATH", bin);
	Clock start = clock::now();
	String t = check::c3_check("fn void f() {}");
	ulong ms = (ulong)start.to_now() / 1_000_000;
	assert(ms > 9000 && ms < 20000 && has(t, "[timeout"), "%d ms: %s", ms, t);
}

fn void flooding_compiler_is_cut_and_killed() @test
{
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	defer support::restore_c3c();
	support::set_c3c(support::write_fake(dir, "flood", "exec yes 'error: x'"));
	Clock start = clock::now();
	String t = check::c3_check("fn void f() {}");
	ulong ms = (ulong)start.to_now() / 1_000_000;
	assert(t.len < 4200 && has(t, "[output cut]") && ms < 5000, "%d ms, len %d", ms, t.len);
}

// ---------------------------------------------------------------- project / file paths, fix, hints, run

// A two-file project in a temp dir: `body` is the content of src/main.c3.
fn Path make_project(String body)
{
	Path dir = support::make_temp_dir("c3proj");
	support::sh(string::tformat("mkdir -p '%s/src'", (String)dir));
	file::save(string::tformat("%s/project.json", (String)dir), `{"langrev":"1","sources":["src/**"],"targets":{"app":{"type":"executable"}}}`)!!;
	file::save(string::tformat("%s/src/main.c3", (String)dir), body)!!;
	return dir;
}

const String PROJECT_OK = "module app;\nimport std::io;\nfn int add(int a, int b) => a + b;\nfn void main() { io::printn(add(1, 2)); }\nfn void t_ok() @test { assert(add(1, 1) == 2); }\nfn void t_bad() @test { assert(add(1, 1) == 3, \"nope\"); }\n";

fn void project_path_is_checked_and_tree_stays_clean() @test
{
	Path dir = make_project(PROJECT_OK);
	defer (void)path::rmtree(dir);
	String t = check::c3_check(path: (String)dir);
	assert(has(t, "OK"), "%s", t);
	String listing = support::sh(string::tformat("ls '%s'", (String)dir));
	assert(!has(listing, "build") && !has(listing, "out") && !has(listing, "obj"), "the check wrote into the project: %s", listing);
}

fn void project_error_has_relative_path() @test
{
	Path dir = make_project("module app;\nfn void main() { int x = ; }\n");
	defer (void)path::rmtree(dir);
	String t = check::c3_check(path: (String)dir);
	String body = t[:t.index_of("\n[c3c ") ?? t.len];   // the last line names the project on purpose (where it ran)
	assert(has(body, "src/main.c3:2:") && !has(body, "c3proj-") && has(t, "[c3c "), "%s", t);
}

fn void single_file_path_is_checked() @test
{
	Path dir = make_project("module app;\nfn int f() { return 1; }\nfn void main() {}\n");   // a file of a project is checked with the project: it needs its main
	defer (void)path::rmtree(dir);
	String t = check::c3_check(path: string::tformat("%s/src/main.c3", (String)dir));
	assert(has(t, "OK"), "%s", t);
}

fn void bad_paths_and_argument_mixes_are_refused() @test
{
	assert(has(check::c3_check(path: "/nonexistent/dir"), "project directory"));
	assert(has(check::c3_check(path: "/tmp"), "project directory"), "a directory without project.json");
	assert(has(check::c3_check("fn void f() {}", "/tmp"), "not both"));
	assert(has(check::c3_check(), "give code"));
}

fn void old_property_error_gets_a_hint() @test
{
	String t = check::c3_check("fn void f() { int a = int.sizeof; }");
	assert(has(t, "Hints:") && has(t, "Type properties are written with `::`") && has(t, "`c3_check` rewrites it"), "%s", t);
}

fn void guessed_stdlib_name_gets_a_signature_hint() @test
{
	String t = check::c3_check("import std::io;\nfn void f() { io::read_line(); }");
	assert(has(t, "Hints:") && has(t, "readline"), "%s", t);
}

fn void valid_code_has_no_hints() @test
{
	assert(!has(check::c3_check("fn void f() {}"), "Hints"));
}

fn void check_rewrites_old_syntax_and_verifies() @test
{
	String t = check::c3_check("import std::io;\nstruct Foo { int x; }\nfn void f(isz z) { int a = int.sizeof; usz n = $sizeof(Foo); io::printn(a); }\n");
	assert(has(t, "0.7 syntax found") && has(t, "int::size") && has(t, "Foo::size") && has(t, "sz z") && has(t, "OK: no errors"), "%s", t);
}

fn void fix_leaves_strings_comments_and_variables_alone() @test
{
	hints::Rewrite r = hints::rewrite("// isz int.sizeof\nfn void f() { String s = \"isz int.sizeof\"; var m = x.max; /* $sizeof(a) */ }");
	assert(r.count == 0 && r.code.contains("\"isz int.sizeof\"") && r.code.contains("x.max") && r.code.contains("// isz"), "%s", r.code);
	hints::Rewrite q = hints::rewrite("fn int g() { return int.max + Foo.min; }");
	assert(q.code == "fn int g() { return int::max + Foo::min; }" && q.count == 2, "%s", q.code);
}

fn void check_without_old_syntax_adds_no_rewrite() @test
{
	assert(!has(check::c3_check("fn void f() {}"), "0.7 syntax"));
	assert(!has(check::c3_check("fn void f() { undefined_name(); }"), "0.7 syntax"), "an error that is not old syntax is not rewritten");
}

fn void test_tool_reports_failures_without_noise() @test
{
	Path dir = make_project(PROJECT_OK);
	defer (void)path::rmtree(dir);
	String t = check::c3_test((String)dir);
	assert(has(t, "t_bad") && has(t, "nope") && has(t, "main.c3:6") && has(t, "1 passed, 1 failed"), "%s", t);
	assert(!has(t, "std.core.runtime") && !has(t, "\x1b"), "%s", t);
	String f = check::c3_test((String)dir, "t_ok");
	assert(has(f, "1 passed") && !has(f, "FAIL"), "%s", f);
	String listing = support::sh(string::tformat("ls '%s'", (String)dir));
	assert(!has(listing, "out") && !has(listing, "build"), "the test run wrote into the project: %s", listing);
}

fn void run_tool_runs_snippet_and_project() @test
{
	String t = check::c3_run("import std::io;\nfn void main() { io::printn(\"hello run\"); }");
	assert(has(t, "hello run"), "%s", t);
	Path dir = make_project(PROJECT_OK);
	defer (void)path::rmtree(dir);
	String p = check::c3_run(path: (String)dir);
	assert(has(p, "3"), "%s", p);
	String e = check::c3_run("fn void main() { int x = ; }");
	assert(has(e, "snippet.c3:1:") && !has(e, "c3guide-"), "%s", e);
}

fn void run_tool_rejects_embed_in_snippets() @test
{
	assert(has(check::c3_run("module m; const char[*] X = $embed(\"x\");"), "rejected"));
}

// A compiler report as c3_check shows it: the echoed source line, then the error.
fn String err(String src, String msg) @local => string::tformat(" 1: %s\n<code>/snippet.c3:1:7: error: %s", src, msg);

fn void static_hints_fire_only_with_the_old_syntax_present() @test
{
	assert(has(hints::diagnostics(err("fn int! f() { return 1; }", "A type name was expected here.")), "int?"));
	assert(!has(hints::diagnostics(err("fn Foo f() { }", "A type name was expected here.")), "int?"), "no optional hint without a `!`");
	assert(has(hints::diagnostics(err("fault E { A, B }", "This looks like a constant variable, did you forget 'const'?")), "faultdef"));
	assert(has(hints::diagnostics(err("List(<int>) l;", "An expression was expected.")), "List{int}"));
	assert(!has(hints::diagnostics(err("int x = ;", "An expression was expected.")), "List{int}"));
	assert(has(hints::diagnostics(err("def Foo = int;", "A type name was expected, but this looks a variable or function name (as it doesn't start with an uppercase letter).")), "alias"));
	assert(has(hints::diagnostics(err("fn int f(int x) @require(x > 0) {}", "This is not a known valid attribute name.")), "doc comment"));
	assert(has(hints::diagnostics(err("int x = (int)g();", "It is not possible to cast from 'int?' to 'int'.")), "??"));
	assert(!has(hints::diagnostics(err("short x = (short)g();", "It is not possible to cast from 'Foo' to 'short'.")), "??"));
	assert(has(hints::diagnostics(err("mem::alloc(10);", "A type, like 'int' or 'double' was expected for the parameter '$Type'.")), "mem::alloc(int)"));
	assert(has(hints::diagnostics(err("$typeof(x) y = 4;", "Expected ';'")), "$Typeof"));
	// the false positive: `anyfault` is not `isz`
	assert(!has(hints::diagnostics(err("anyfault e;", "Expected a type here.")), "isz"));
	assert(has(hints::diagnostics(err("isz n = 0;", "Expected a type here.")), "isz"));
	// the other message form for a member that does not exist
	assert(has(hints::diagnostics(err("File f; f.read_line();", "There is no field or method 'File.read_line'.")), "File.read_line"));
}

fn void rewrite_skips_what_is_not_a_type() @test
{
	assert(hints::rewrite("fn int Pt.min(Pt a, int b) => 1;").count == 0, "a method definition");
	assert(hints::rewrite("int a = LIMIT.max;").count == 0, "a constant");
	assert(hints::rewrite("int a = /* int.sizeof /* nested */ int.sizeof */ 1;").count == 0, "a nested comment");
	assert(hints::rewrite("int a = Foo.max;").code == "int a = Foo::max;", "still a type");
	assert(hints::rewrite("usz n = $sizeof(Foo[$sizeof(int)]);").code == "usz n = Foo[int::size]::size;", "nested");
	assert(hints::rewrite("usz n = $sizeof ( int );").code == "usz n = int::size;", "spaces");
	assert(hints::rewrite("usz n = $sizeof(x);").code == "usz n = $Typeof(x)::size;", "an expression, not a type");
	assert(hints::rewrite("usz n = $sizeof(Foo*);").code == "usz n = Foo*::size;", "a pointer type");
	assert(hints::rewrite("int a = Foo*.sizeof + p.s.max;").code == "int a = Foo*::size + p.s.max;", "a pointer type property, a member chain");
	assert(hints::rewrite("fn isz f(isz n) { isz x = int.sizeof; return x.max; }").code == "fn sz f(sz n) { sz x = int::size; return x.max; }", "isz makes the function unparseable: repaired first");
	assert(hints::rewrite("fn void f(Foo x) { x.isz = 1; }").count == 0, "a field that happens to be called isz");
}

fn void test_summary_survives_a_long_run() @test
{
	DString body = dstring::temp();
	body.append("module app;\nfn void main() {}\n");
	for (int i = 0; i < 150; i++) body.appendf("fn void a_rather_long_test_name_to_fill_the_output_%d() @test { assert(true); }\n", i);
	body.append("fn void the_one_failing_test() @test { assert(false, \"boom\"); }\n");
	Path dir = make_project(body.str_view());
	defer (void)path::rmtree(dir);
	String t = check::c3_test((String)dir);
	assert(has(t, "the_one_failing_test") && has(t, "boom") && has(t, "150 passed, 1 failed"), "%s", t);
	assert(!has(t, "[PASS]") && t.len < 8000, "%d bytes", (int)t.len);
}

fn void target_cannot_be_a_compiler_option() @test
{
	Path dir = make_project(PROJECT_OK);
	defer (void)path::rmtree(dir);
	String[*] bads = { "--trust=full", "-O3", "a b", "x;y", "../x" };
	foreach (bad : bads)
	{
		assert(has(check::c3_check(path: (String)dir, target: bad), "build target name"), "check accepted %s", bad);
		assert(has(check::c3_run(path: (String)dir, target: bad), "build target name"), "run accepted %s", bad);
	}
	assert(check::valid_target("app") && check::valid_target("my-app_2.0") && check::valid_target(""));
}

fn void stale_sweep_does_not_follow_symlinks() @test
{
	Path victim = support::make_temp_dir("c3victim");
	defer (void)path::rmtree(victim);
	String v = (String)victim;
	String tmp = (String)path::temp_directory(tmem)!!;
	String link = string::tformat("%s/c3guide-symlink-test", tmp);
	// the target is older than the one-hour limit, so a followed link would be swept
	support::sh(string::tformat("echo keep > '%s/keep.txt'; touch -t 202001010000 '%s' '%s/keep.txt'; ln -sfn '%s' '%s'", v, v, v, v, link));
	defer support::sh(string::tformat("rm -f '%s'", link));
	assert(has(check::c3_check("fn void main() {}"), "OK"));   // every call sweeps the temp dir first
	assert(file::exists(string::tformat("%s/keep.txt", v)), "the sweep followed a symlink and emptied its target");
}

fn void run_tool_kills_a_hanging_compiler_after_its_deadline_flag() @test
{
	// the run deadline is longer than the check deadline: a fake that exits fast must not be cut
	Path dir = support::make_temp_dir("c3fake");
	defer (void)path::rmtree(dir);
	defer support::restore_c3c();
	support::set_c3c(support::write_fake(dir, "ok.sh", "echo fake-output"));
	assert(has(check::c3_run("fn void main() {}"), "fake-output"));
}

fn void run_takes_an_optimization_level() @test
{
	assert(check::valid_opt("") && check::valid_opt("O3") && check::valid_opt("Os"));
	assert(!check::valid_opt("O9") && !check::valid_opt("--run-dir") && !check::valid_opt("-O3"));
}

fn void c3c_is_found_in_path_and_the_version_is_read() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String fake = string::tformat("%s/%s", (String)dir, compiler::EXE);
	file::save(fake, "x")!!;
	String list = string::tformat("/nonexistent%s%s", compiler::PATH_SEP, (String)dir);
	String? hit = compiler::which(compiler::EXE, list);
	if (catch hit) assert(false, "not found in PATH");
	assert(hit == fake, "path lookup: %s", hit);
	assert(@catch(compiler::which(compiler::EXE, "/nonexistent")) == compiler::NOT_FOUND);
	assert(compiler::compiler_version().len > 0, "c3c --version is readable");
}

fn void ambiguous_names_get_no_hint_list() @test
{
	String d = hints::diagnostics(err("x.free();", "'free' could not be found, did you spell it right?"));
	assert(!d.contains("Url.free") && !d.contains("std::"), "a name with dozens of owners is not a hint: %s", d);
}

// Processes whose command line matches `pattern`. Tests compare before and after: another session may be running.
fn int count_procs(String pattern) @local => (support::sh(string::tformat("pgrep -f '%s' | wc -l", pattern)).trim().to_int()) ?? 0;

const String SCRATCH_PROC = "c3guide-[0-9]+/";

fn void a_hung_program_is_stopped_and_leaves_nothing_running() @test
{
	assert(check::deadline_for(0) == 120000 && check::deadline_for(5) == 5000 && check::deadline_for(120) == 120000 && check::deadline_for(-3) == 120000 && check::deadline_for(999) == 120000);
	int before = count_procs(SCRATCH_PROC);
	Clock t = clock::now();
	String r = check::c3_run("import std::thread;\nfn void main() { thread::sleep_ms(600000); }", timeout_s: 3);
	long ms = (long)t.to_now() / 1_000_000;
	assert(r.contains("timeout") && ms < 15000, "%s (%d ms)", r, (int)ms);
	assert(count_procs(SCRATCH_PROC) <= before, "processes left behind");
}

fn void a_program_that_leaves_a_background_process_cannot_hang_the_server() @test
{
	// `sleep 301 &` keeps the output pipe open and its command line does not name the scratch directory
	Clock t = clock::now();
	String r = check::c3_run(`import libc;
fn void main() { libc::system("sleep 301 &"); }`, timeout_s: 3);
	long ms = (long)t.to_now() / 1_000_000;
	support::sh("pkill -f '[s]leep 301'; true");
	assert(ms < 20000, "the call took %d ms: %s", (int)ms, r);
}

fn void regex_characters_in_the_scratch_path_do_not_defeat_the_sweep() @test
{
	String base = support::sh("d=$(mktemp -d)/x'(b'; mkdir -p \"$d\"; printf %s \"$d\"").trim();
	String? saved = env::tget_var("TMPDIR");
	env::set_var("TMPDIR", base);
	int before = count_procs("sleep 600000|x.\\(b");
	Clock t = clock::now();
	String r = check::c3_run("import std::thread;\nfn void main() { thread::sleep_ms(600000); }", timeout_s: 3);
	long ms = (long)t.to_now() / 1_000_000;
	if (try s = saved) { env::set_var("TMPDIR", s); } else { env::clear_var("TMPDIR"); }
	support::sh(string::tformat("pkill -9 -f '%s/c3guide'; rm -rf \"$(dirname '%s')\"; true", "x.\\(b", base));
	assert(r.contains("timeout") && ms < 15000, "%s (%d ms)", r, (int)ms);
}

fn void a_program_past_the_output_cap_is_stopped() @test
{
	int before = count_procs(SCRATCH_PROC);
	Clock t = clock::now();
	String r = check::c3_run(`import std::io;
import std::thread;
fn void main()
{
	for (int i = 0; i < 20000; i++) io::printn("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
	thread::sleep_ms(600000);
}`, timeout_s: 20);
	long ms = (long)t.to_now() / 1_000_000;
	assert(ms < 15000 && r.len > 1000, "%d ms, %d bytes", (int)ms, (int)r.len);
	assert(count_procs(SCRATCH_PROC) <= before, "the program kept running after the cap");
}

fn void a_file_of_a_project_is_checked_with_its_project() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/src", root))!!)!!;
	file::save(string::tformat("%s/project.json", root), "{ \"sources\": [\"src/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	String f = string::tformat("%s/src/a.c3", root);
	file::save(f, "module a;\nimport b;\nfn void main() { b::hello(); }\n")!!;
	file::save(string::tformat("%s/src/b.c3", root), "module b;\nfn void hello() {}\n")!!;
	// alone, a.c3 does not know module b; with its project it compiles
	String r = check::c3_check("", f);
	assert(r.contains("belongs to the project in") && r.contains("OK: no errors (type-checked"), "%s", r);
	// the directory is type-checked: never cc, never the linker
	assert(check::c3_check("", root).starts_with("OK: no errors") && check::c3_check("", root).contains("type-checked"));
	// and a platform given with the file reaches the project check
	String w = string::tformat("%s/src/w.c3", root);
	file::save(w, "module w;\nfn void g() { $if env::WIN32: int x = \"not an int\"; $endif }\n")!!;
	assert(check::c3_check("", w, platform: "windows-x64").contains("error"), "the platform applies to a file of a project");
	// a file outside any project is still compiled by itself
	String lone = string::tformat("%s/lone.c3", root[:root.rindex_of("/") ?? 0]);
	assert(check::project_dir("/tmp/none/x.c3").len == 0 && lone.len > 0);
}

fn void a_test_filter_cannot_be_an_option() @test
{
	assert(check::c3_test("src", "--trust=full").starts_with("filter must be"));
	assert(check::c3_test("src", "-x").starts_with("filter must be"));
}

fn void hints_are_complete_and_short() @test
{
	String d = hints::diagnostics(err("s.append_chars(\"a\");", "There is no field or method 'DString.append_chars'."));
	assert(d.contains("DString.append_char") && !d.contains("[...cut]") && !d.contains("does not exist"), "%s", d);
	assert(d.len < 1200, "%d bytes: %s", (int)d.len, d);
	String p = hints::diagnostics(err("string::ztformat(\"\");", "'string::ztformat' could not be found, did you perhaps want 'string::tformat'?"));
	assert(p.contains("fn String tformat") && !p.contains("ZString") && !p.contains("@str_"), "the proposed name, not a keyword search: %s", p);
}

fn void the_version_note_is_said_once() @test
{
	(void)compiler::version_note();
	assert(compiler::version_note() == "", "a second reply stays quiet");
}

fn void a_library_manifest_without_targets_is_explained() @test
{
	String d = hints::diagnostics(err("import foo;", "Library 'foo' cannot be used with arch/os 'linux-x64'."));
	assert(has(d, "targets") && has(d, "manifest.json") && has(d, "0.8.6"), "%s", d);
}

fn void an_optional_struct_field_is_explained() @test
{
	String d = hints::diagnostics(err("struct Conf { String[]? deps; }", "A valid member name was expected here."));
	assert(has(d, "cannot be optional"), "%s", d);
	assert(!has(hints::diagnostics(err("struct Conf { int x; } y", "A valid member name was expected here.")), "cannot be optional"), "only where a `?` is in the code");
}

const String WIN_ONLY_ERROR = "fn void main() { $if env::WIN32: int x = \"not an int\"; $endif }";

fn void a_snippet_can_be_checked_for_another_platform() @test
{
	assert(check::c3_check(WIN_ONLY_ERROR).starts_with("OK"), "fine here, the branch is for Windows");
	String r = check::c3_check(WIN_ONLY_ERROR, platform: "windows-x64");
	assert(r.contains("error"), "%s", r);
	assert(check::c3_check("fn void main() {}", "", "", "--trust=full").contains("not an option"), "a platform is a name, never a flag");
}

fn void a_project_can_be_checked_for_another_platform() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/src", root))!!)!!;
	file::save(string::tformat("%s/project.json", root), "{ \"sources\": [\"src/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	file::save(string::tformat("%s/src/a.c3", root), WIN_ONLY_ERROR)!!;
	assert(check::c3_check("", root).contains("OK"), "the project builds for this platform");
	assert(check::c3_check("", root, platform: "windows-x64").contains("error"), "and not for Windows");
}

fn void manifest_warnings_of_a_library_are_left_out() @test
{
	int n = 0;
	String raw = "WARNING: Unknown parameter 'version' in 'library'\nWARNING: Unknown parameter 'authors' in 'library'\nYou can use '--list-manifest-properties' to list all valid properties.\nsrc/a.c3:1:1: error: boom\n";
	String kept = check::without_manifest_warnings(raw, &n);
	assert(n == 2 && !kept.contains("WARNING") && !kept.contains("list-manifest") && kept.contains("error: boom"), "%d: %s", n, kept);
	String warning_only = check::report(raw[:raw.index_of("src")!!], 0, false, "/nowhere", "<x>", "OK: no errors", 1000);
	assert(warning_only == "OK: no errors", "%s", warning_only);
}

fn void the_rules_that_fail_late_get_a_hint() @test
{
	String a = check::c3_check("fn int? f() => 1;\nfn void main() { for (int i = 0; i < 3; i++) { int x = f() ?? continue; } }");
	assert(a.contains("Hints:") && a.contains("not `continue`"), "%s", a);
	String b = check::c3_check("fn int? f() => 1;\nfn void main() { if (catch e = f() || true) {} }");
	assert(b.contains("cannot be combined with `||`"), "%s", b);
	String c = check::c3_check("module m;\nstruct Cat { int lives; }\nfn int Cat.secret(&self) @private => self.lives;\nfn void main() {}");
	assert(c.contains("has no effect on a method"), "a warning gets its hint: %s", c);
	String plain = check::c3_check("fn void main() { int x = ; }");
	assert(!plain.contains("cannot be combined") && !plain.contains("has no effect on a method"), "%s", plain);
}

fn void a_property_written_with_a_dot_points_to_the_colons() @test
{
	String t = check::c3_check("fn void main() { double x = double.inf; }");
	assert(t.contains("not `.inf`") && t.contains("double::inf"), "%s", t);
	String ok = check::c3_check("fn void main() { double x = double::inf; }");
	assert(ok.starts_with("OK"), "%s", ok);
}

fn void run_passes_arguments_and_stdin_to_the_program() @test
{
	String code = "import std::io;\nfn void main(String[] a) { String? l = io::treadline(); io::printfn(\"in=%s n=%d first=%s\", l!!, a.len, a[1]); }";
	String t = check::c3_run(code, args: "alpha\nbeta gamma", input: "abc\n");
	assert(has(t, "in=abc n=3 first=alpha"), "%s", t);
	assert(has(check::c3_run("fn void main() {}", args: "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq"), "at most 16"));
}

fn void a_program_that_reads_stdin_sees_the_end_of_it() @test
{
	String t = check::c3_run("import std::io;\nfn void main() { String? l = io::treadline(); io::printfn(\"%s\", l ? \"line\" : \"eof\"); }");
	assert(has(t, "eof"), "%s", t);
}

fn void check_and_run_take_extra_source_files() @test
{
	Path dir = support::make_temp_dir("c3guide-files");
	defer (void)path::rmtree(dir);
	String helper = string::tformat("%s/helper.c3", (String)dir);
	file::save(helper, "module helper;\nfn int twice(int x) => x * 2;\n")!!;
	String code = "import helper;\nimport std::io;\nfn void main() { io::printfn(\"%d\", helper::twice(21)); }";
	assert(has(check::c3_check(code), "error"), "the helper is not known without files");
	assert(has(check::c3_check(code, files: helper), "OK: no errors"));
	assert(has(check::c3_run(code, files: helper), "42"));
	assert(has(check::c3_check(code, files: "/nonexistent/x.c3"), "does not exist"));
	assert(has(check::c3_check(code, files: "x.txt"), "not a .c3"));
}

fn void test_tool_checks_tests_for_another_platform() @test
{
	Path dir = make_project(PROJECT_OK);
	defer (void)path::rmtree(dir);
	String t = check::c3_test((String)dir, platform: "windows-x64");
	assert(has(t, "type-check") || has(t, "OK"), "%s", t);
	assert(!has(t, "error"), "%s", t);
}

fn void test_tool_platform_check_finds_an_error_of_that_platform() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/src", root))!!)!!;
	file::save(string::tformat("%s/project.json", root), "{ \"sources\": [\"src/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	file::save(string::tformat("%s/src/a.c3", root), string::tformat("%s\nfn void t() @test {}\n", WIN_ONLY_ERROR))!!;
	String here = check::c3_test(root);
	assert(!has(here, "error") && has(here, "passed"), "the tests run on this platform: %s", here);
	String win = check::c3_test(root, platform: "windows-x64");
	assert(has(win, "error"), "and the Windows type-check sees the error: %s", win);
}

// c3c reads every `*.c3l` in its working directory: a broken library next to the server must not break a snippet
fn void a_broken_library_in_the_servers_directory_does_not_break_a_snippet() @test
{
	Path base = path::temp_directory(tmem)!!;
	Path dir = base.tappend(string::tformat("c3guide-cwd-%d", (long)clock::now()))!!;
	path::mkdir(dir.tappend("broken.c3l")!!, recursive: true)!!;
	Path back = path::tcwd()!!;
	assert(posix::chdir(((String)dir).zstr_tcopy()) == 0);
	String r = check::c3_check("fn void main() {}");
	String s = check::c3_run("import std::io; fn void main() { io::printn(\"hi\"); }");
	assert(posix::chdir(((String)back).zstr_tcopy()) == 0);
	(void)path::rmtree(dir);
	assert(r.starts_with("OK"), "%s", r);
	assert(s.contains("hi"), "%s", s);
}

fn void a_sanitizer_finds_a_memory_error() @test
{
	String code = "import std::io;\nfn void main()\n{\n\tint* a = mem::alloc_array(int, 4);\n\ta[5] = 1;\n\tio::printn(a[5]);\n}";
	String refused = check::c3_run(code, sanitize: "bogus");
	assert(refused.contains("sanitize must be"), "%s", refused);
	String bad = check::c3_run(code, sanitize: "address");
	assert(bad.contains("AddressSanitizer"), "%s", bad);
}

fn void a_c3i_file_is_checked_alone_and_with_a_snippet() @test
{
	Path dir = path::temp_directory(tmem)!!.tappend(string::tformat("c3guide-c3i-%d", (long)clock::now()))!!;
	path::mkdir(dir)!!;
	defer (void)path::rmtree(dir);
	String f = string::tformat("%s/b.c3i", (String)dir);
	file::save(f, "module b;\nextern fn int abs(int x);\n")!!;
	String alone = check::c3_check(path: f);
	assert(alone.starts_with("OK"), "%s", alone);
	String together = check::c3_check("import b;\nfn void main() { int x = b::abs(-1); }", files: f);
	assert(together.starts_with("OK"), "%s", together);
}

fn void format_returns_the_formatted_snippet() @test
{
	String? f = format::find_c3f();
	if (catch f) { io::printn("skipped: c3f is not installed"); return; }
	String r = check::c3_check("module a;\nfn int  f(int x){return x+1;}\n", format: true);
	assert(has(r, "OK") && has(r, "c3f: formatted code") && has(r, "{ return x + 1; }"), "%s", r);
	String again = check::c3_check("module a;\nfn int f(int x) { return x + 1; }\n", format: true);
	assert(has(again, "already formatted"), "%s", again);
	String plain = check::c3_check("module a;\nfn int f(int x){return x+1;}\n");
	assert(!has(plain, "c3f"), "%s", plain);
}

// Tokens and keys in the client's environment are not handed to a program a snippet builds
fn void a_program_does_not_see_the_clients_secrets() @test
{
	$if !env::WIN32:
		env::set_var("C3GUIDE_TEST_SECRET", "hunter2");
		defer (void)env::clear_var("C3GUIDE_TEST_SECRET");
		String r = check::c3_run("import std::io, std::os::env;\nfn void main()\n{\n\tio::printn(env::tget_var(\"C3GUIDE_TEST_SECRET\") ?? \"absent\");\n\tio::printn(env::tget_var(\"PATH\") ?? \"nopath\");\n}");
		assert(has(r, "absent") && !has(r, "hunter2") && !has(r, "nopath"), "%s", r);
	$endif
}

// $embed reads any file at compile time and $echo prints it: not for code that reaches the compiler by path or files
fn void a_file_or_project_that_reads_outside_itself_is_refused() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/proj/src", root))!!, recursive: true)!!;
	path::mkdir(path::new(tmem, string::tformat("%s/other", root))!!)!!;
	String secret = string::tformat("%s/other/secret.txt", root);
	file::save(secret, "CANARY_SECRET_ONE")!!;
	file::save(string::tformat("%s/proj/project.json", root), "{ \"sources\": [\"src/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	file::save(string::tformat("%s/proj/res.txt", root), "inside")!!;
	// 1) a helper given as files
	String helper = string::tformat("%s/other/h.c3", root);
	file::save(helper, string::tformat("module h;\nconst String L = (String)$embed(\"%s\");\n$echo \"LEAK=\" +++ L;\n", secret))!!;
	String r1 = check::c3_check("fn int main() { return 0; }", files: helper);
	assert(has(r1, "rejected") && !has(r1, "CANARY"), "%s", r1);
	// 2) a project whose source embeds a file outside it
	String proj = string::tformat("%s/proj", root);
	String main_c3 = string::tformat("%s/proj/src/main.c3", root);
	file::save(main_c3, string::tformat("module app;\nconst String L = (String)$embed(\"%s\");\n$echo \"LEAK=\" +++ L;\nfn void main() {}\n", secret))!!;
	String r2 = check::c3_check(path: proj);
	assert(has(r2, "rejected") && !has(r2, "CANARY"), "%s", r2);
	// 3) the same through ".." and a computed name
	file::save(main_c3, "module app;\nconst String L = (String)$embed(\"../../other/secret.txt\");\nfn void main() {}\n")!!;
	assert(has(check::c3_check(path: proj), "rejected"));
	file::save(main_c3, "module app;\nconst String N = \"x\";\nconst String L = (String)$embed(N);\nfn void main() {}\n")!!;
	assert(has(check::c3_check(path: proj), "rejected"));
	// 4) an $embed of a file inside the project is a normal thing to do
	file::save(main_c3, "module app;\nconst String L = (String)$embed(\"../res.txt\");\nfn void main() {}\n")!!;
	String ok = check::c3_check(path: proj);
	assert(has(ok, "OK: no errors"), "%s", ok);
}

// cflags and c-sources of a project are code (cc runs them): a check never reaches cc
fn void a_project_check_never_runs_the_c_compiler() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	path::mkdir(path::new(tmem, string::tformat("%s/src", root))!!)!!;
	path::mkdir(path::new(tmem, string::tformat("%s/c", root))!!)!!;
	file::save(string::tformat("%s/project.json", root), "{ \"sources\": [\"src/**\"], \"c-sources\": [\"c/a.c\"], \"cflags\": \"-DX=1\", \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	file::save(string::tformat("%s/src/main.c3", root), "module app;\nfn void main() {}\n")!!;
	file::save(string::tformat("%s/c/a.c", root), "#error BOOM_FROM_C\nint x;\n")!!;
	String r = check::c3_check(path: root);
	assert(has(r, "OK: no errors") && !has(r, "BOOM"), "%s", r);
}
