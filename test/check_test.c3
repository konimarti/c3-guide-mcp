module c3guide::test::check;
import c3guide::check, c3guide::test::support;
import std::core::string, std::io, std::io::file, std::io::path, std::os::env, std::time, std::time::clock;

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
	assert(has(check::c3_check(""), "give 1 to"));
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
