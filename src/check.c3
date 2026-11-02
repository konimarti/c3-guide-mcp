module c3guide::check;
import mcp, std::thread, std::core::string, std::io, std::io::path, std::io::file, std::os::process, std::os::env, std::time::clock;
import c3guide::util, c3guide::hints, std::time;

// Only the compiler's own diagnostics come back, never a build artifact. The snippet is written to a
// fresh temp dir and compiled with a FIXED command line:
//   --trust=none  no $exec / $include at compile time, whatever the user's c3c config says
//   --no-obj      nothing is emitted or linked, so nothing can run
//   a 10 s deadline, enforced here (watchdog thread kills the compiler), so no `timeout` program is needed
// The compiler binary is not a tool argument: C3C env var, else "c3c" from PATH.
//
// `--trust=none` still allows $embed, and $echo prints to stdout, so a snippet could read any file the
// server can read and print it byte by byte. Snippets that mention $embed, $include or $exec are
// rejected before they reach the compiler (the tokens cannot be spelled any other way: $eval only
// builds identifiers). Do not run the server as a user that can read secrets regardless.
const sz MAX_CODE = 32 * 1024;
const sz MAX_FIX = 12 * 1024;
const sz MAX_OUTPUT = 4 * 1024;
const ulong DEADLINE_MS = 10000;
const ulong RUN_DEADLINE_MS = 60000;   // c3_test / c3_run: the program has to build and run
const sz MAX_RUN_OUTPUT = 6 * 1024;
const sz MAX_RUN_CAPTURE = 64 * 1024;
const sz MAX_HINTS = 1500;
const String[*] FORBIDDEN = { "$embed", "$include", "$exec" };

fn String c3c_binary()
{
	String? v = env::tget_var("C3C");
	if (try v) { if (v.len > 0) return v; }
	$if env::WIN32:
		return "c3c.exe";   // CreateProcess finds a program on PATH only with its extension
	$else
		return "c3c";
	$endif
}

// Kills the child when the deadline passes. The mutex makes "check done, then kill" atomic against the
// main thread's "set done, then join": the kill can never hit a pid that was already reaped.
faultdef WATCHDOG_FAILED;

struct Watchdog
{
	Mutex mutex;
	ConditionVariable cond;
	Process* proc;
	ulong deadline_ms;
	bool done;
	bool fired;
}

fn int watch(void* arg) @private
{
	Watchdog* w = (Watchdog*)arg;
	Clock start = clock::now();
	(void)w.mutex.lock();
	while (!w.done)
	{
		long left = (long)w.deadline_ms - (long)(start.to_now() / 1_000_000);
		if (left <= 0)
		{
			w.fired = true;
			(void)w.proc.terminate();
			break;
		}
		(void)w.cond.wait_timeout(&w.mutex, (ulong)left);
	}
	w.mutex.unlock();
	return 0;
}

// Run argv (no shell), capture stdout+stderr up to MAX_OUTPUT, kill the child past that or past the
// deadline, always join. *code gets the exit status (0 when we killed it ourselves), *timed_out says
// whether the deadline fired. A killed child closes its pipe, so the blocking read below always ends.
fn String? run_capped(String[] cmd, int* code, bool* timed_out, ulong deadline_ms = DEADLINE_MS, sz max_output = MAX_OUTPUT)
{
	Process p = process::spawn(cmd, process::SpawnOptions.STDERR_TO_STDOUT | process::SpawnOptions.INHERIT_ENV)!;
	defer (void)p.destroy();
	Watchdog w = { .proc = &p, .deadline_ms = deadline_ms };
	(void)w.mutex.init();
	(void)w.cond.init();
	Thread th;
	if (catch th.create(&watch, &w))
	{
		(void)p.terminate();   // no deadline without a watchdog: do not run the compiler at all
		(void)p.join();
		return WATCHDOG_FAILED~;
	}
	DString out = dstring::temp();
	char[2048] buf;
	bool capped = false;
	while (true)
	{
		sz? n = p.read_stdout(&buf, buf.len);
		if (catch n) break;
		if (n == 0) break;
		sz room = max_output - out.len();
		out.append((String)buf[:n > room ? room : n]);
		if (out.len() >= max_output)
		{
			capped = true;
			(void)p.terminate();
			break;
		}
	}
	(void)w.mutex.lock();
	w.done = true;
	w.cond.signal();
	w.mutex.unlock();
	(void)th.join();
	*timed_out = w.fired;
	*code = p.join()!;
	String s = out.str_view();
	if (capped || w.fired) *code = 0;
	if (capped) return string::tformat("%s\n[output cut]", s[:util::utf8_boundary(s, s.len)]);
	return s;
}

// Replace every `needle` in `s` by `replacement`. (std String.replace returned corrupted bytes for a 4 KB
// string without a match in c3c 0.8.5, hence the small loop.)
fn String redact(String s, String needle, String replacement)
{
	DString out = dstring::temp();
	while (true)
	{
		sz? at = s.index_of(needle);
		if (catch at) break;
		out.append(s[:at]);
		out.append(replacement);
		s = s[at + needle.len..];
	}
	out.append(s);
	return out.str_view();
}

// A killed server cannot run its `defer`, so it leaves c3guide-* behind: remove those older than an hour.
fn void sweep_stale(Path tmp)
{
	PathList? list = path::ls(tmem, tmp, no_dirs: false, relative: true);
	if (catch list) return;
	foreach (entry : list)
	{
		String name = entry.basename();
		if (!name.starts_with("c3guide-")) continue;
		Path? full = tmp.tappend(name);
		if (catch full) continue;
		if (path::is_link(full)) continue;   // never follow a planted symlink into someone else's files
		Time? mt = file::last_modified((String)full);
		if (catch mt) continue;
		if ((long)time::now() - (long)mt > 3600L * (long)time::SEC) (void)path::rmtree(full);
	}
}



// c3_test and c3_run execute the code they build. That is a different trust level than c3_check, so
// the operator opts in: C3_GUIDE_ALLOW_RUN=1 in the server's environment.
fn bool run_allowed()
{
	String? v = env::tget_var("C3_GUIDE_ALLOW_RUN");
	if (catch v) return false;
	return v == "1";
}

// c3c prints colour codes for tests; a model reads them as noise.
fn String strip_ansi(String s)
{
	DString out = dstring::temp();
	sz i = 0;
	while (i < s.len)
	{
		if (s[i] == 0x1b && i + 1 < s.len && s[i + 1] == '[')
		{
			i += 2;
			while (i < s.len && !((s[i] >= 'A' && s[i] <= 'Z') || (s[i] >= 'a' && s[i] <= 'z'))) i++;
			i++;
			continue;
		}
		out.append_char(s[i]);
		i++;
	}
	return out.str_view();
}

// The runtime's own stack frames say nothing about the user's code: drop them from test output.
fn String drop_runtime_frames(String s)
{
	DString out = dstring::temp();
	foreach (line : s.tsplit("\n"))
	{
		if (line.contains("std.core.runtime.") || line.contains("[inline]")) continue;
		// a passing test is one line of noise; the failures and the summary line are what matter
		// (and what the output cap must not cut)
		if (line.starts_with("Testing ") && line.contains("[PASS]")) continue;
		out.appendf("%s\n", line);
	}
	return out.str_view();
}

// A scratch directory for the snippet and (with run) every build artifact. Remove it with rmtree.
fn Path? scratch_dir()
{
	Path tmp = path::temp_directory(tmem)!;
	sweep_stale(tmp);
	// nanosecond clock: two servers (or two calls) never share a directory
	Path dir = tmp.tappend(string::tformat("c3guide-%d", (long)clock::now()))!;
	path::mkdir(dir)!;
	return dir;
}

faultdef BAD_TARGET;

// A command line under construction (C3 has no varargs-free array literal with conditional members).
struct Args
{
	String[40] items;
	int n;
}

fn void Args.add(&self, String s) => self.items[self.n++] = s;
fn String[] Args.list(&self) => self.items[:self.n];

// What `path` names: a project directory (has project.json) or one .c3 file. Returns the absolute directory
// or file and sets *is_dir. The user's own files are compiled as they are, so the snippet rules
// (no $embed, ...) do not apply to them; the trust level still does.
fn String? resolve_target(String target, bool* is_dir)
{
	if (target.len == 0 || target.len > 4096) return BAD_TARGET~;
	Path p = path::new(tmem, target)!;
	Path abs = p.absolute(tmem)!;
	String s = (String)abs;
	if (path::is_dir(abs))
	{
		if (!file::exists(string::tformat("%s/project.json", s))) return BAD_TARGET~;
		*is_dir = true;
		return s;
	}
	if (!file::exists(s) || !s.ends_with(".c3")) return BAD_TARGET~;
	*is_dir = false;
	return s;
}

// Shown for the faults above, so the model knows what to give.
const String BAD_TARGET_TEXT = "path must be a project directory (containing project.json) or a .c3 file that exists";

// A build target is a name, never a flag: `build --trust=full` would undo the fixed --trust=none.
fn bool valid_target(String t)
{
	if (t.len == 0) return true;
	if (t.len > 128 || t[0] == '-') return false;
	foreach (c : t)
	{
		bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-';
		if (!ok) return false;
	}
	return true;
}

const String BAD_TARGET_NAME = "target must be a build target name (letters, digits, _ . -), not an option";

// Exactly one of code / path. Returns "" when the arguments are fine, else the message to show.
fn String exclusive_args(String code, String target)
{
	if (code.len > 0 && target.len > 0) return "give either code or path, not both";
	if (code.len == 0 && target.len == 0) return "give code (a snippet) or path (a project directory or .c3 file)";
	if (code.len > MAX_CODE) return "give 1 to 32768 bytes of code";
	foreach (f : FORBIDDEN)
	{
		if (code.contains(f)) return string::tformat("rejected: %s reads files or runs programs at compile time and is not allowed here", f);
	}
	return "";
}

// The compiler's text, with the scratch directory (snippet) or the project directory (project) removed
// from the paths, an explanation when it was cut or timed out, and hints for what went wrong.
fn String report(String out, int status, bool timed_out, String hide, String replacement, String ok, ulong deadline_ms)
{
	String shown = strip_ansi(redact(out, hide, replacement)).trim_right();
	if (timed_out) shown = string::tformat("%s\n[timeout: longer than %d s]", shown, (int)(deadline_ms / 1000));
	if (shown.trim().len == 0 && !timed_out)
	{
		return status == 0 ? ok : string::tformat("c3c failed (exit code %d) without a message", status);
	}
	return shown;
}

fn String c3_check(String code @Desc("a C3 snippet or file content; a main function is not required") = "",
	String path @Desc("instead of code: a project directory (with project.json) or a .c3 file on disk; a project is built (not run) in a scratch directory, nothing is written to it") = "",
	String target @Desc("with a project path: the build target, default the first") = "") 
	@Desc("USE THIS INSTEAD OF running `c3c compile` or `c3c build` yourself. Compiles a snippet (code) or a real project/file (path) with the installed c3c, nothing is run, and returns the compiler's diagnostics plus hints that point to the right stdlib signature or release note. Check code before showing it.")
	@Timeout(30000)
{
	String bad = exclusive_args(code, path);
	if (bad.len > 0) return bad;
	if (!valid_target(target)) return BAD_TARGET_NAME;
	if (path.len > 0) return check_path(path, target);
	// No @pool here: the result lives in the caller's temp memory (a nested pool would free it on return).
	Path? dir = scratch_dir();
	if (catch dir) return "cannot create a temp directory";
	defer (void)path::rmtree(dir);
	String file = string::tformat("%s/snippet.c3", (String)dir);
	if (catch file::save(file, code)) return "cannot write the snippet";
	String[] argv = { c3c_binary(), "--trust=none", "--no-obj", "--no-entry", "-q", "compile-only", file };
	int status = 0;
	bool timed_out = false;
	String? out = run_capped(argv, &status, &timed_out);
	if (catch out) return "could not start c3c: set the C3C environment variable to its path or put c3c on PATH";
	String shown = report(out, status, timed_out, (String)dir, "<code>", "OK: no errors", DEADLINE_MS);
	return string::tformat("%s%s", shown, hints::diagnostics(shown));
}

fn String check_path(String target_path, String target)
{
	bool is_dir;
	String? where = resolve_target(target_path, &is_dir);
	if (catch where) return BAD_TARGET_TEXT;
	String base = is_dir ? string::tformat("%s/", where) : string::tformat("%s", where[:(where.rindex_of("/") ?? 0) + 1]);
	if (is_dir)
	{
		// `--no-obj` only exists for single files. A project is built (not run) in a scratch directory.
		Path? scratch = scratch_dir();
		if (catch scratch) return "cannot create a temp directory";
		defer (void)path::rmtree(scratch);
		Args m;
		m.add("build");
		if (target.len > 0) m.add(target);
		return run_c3c(m.list(), base, "", scratch, true, where, "OK: no errors");
	}
	String[] argv = { c3c_binary(), "--trust=none", "--no-obj", "--no-entry", "-q", "compile-only", where };
	int status = 0;
	bool timed_out = false;
	String? out = run_capped(argv, &status, &timed_out);
	if (catch out) return "could not start c3c: set the C3C environment variable to its path or put c3c on PATH";
	String shown = report(out, status, timed_out, base, "", "OK: no errors", DEADLINE_MS);
	return string::tformat("%s%s", shown, hints::diagnostics(shown));
}

fn String c3_fix(String code @Desc("C3 code written with 0.6/0.7 syntax"))
	@Desc("Rewrite C3 0.6/0.7 syntax to 0.8 mechanically (`int.sizeof` -> `int::size`, `$sizeof(T)`, `isz` -> `sz`, `$vacount`, `$vasplat`), then compile the result and return it with the diagnostics. Use it when old syntax fails; it fixes only what is mechanical, the compiler output shows what is left.")
	@Timeout(30000)
{
	if (code.len == 0 || code.len > MAX_FIX) return "give 1 to 12288 bytes of code";
	hints::Rewrite r = hints::rewrite(code);
	String checked = c3_check(r.code);
	if (r.count == 0) return string::tformat("no mechanical 0.7 -> 0.8 rewrite applies.\n%s", checked);
	return string::tformat("%d rewrite(s): %s\n--- code ---\n%s\n--- c3_check ---\n%s", r.count, r.notes, r.code, checked);
}

// Build and run the target's tests / the program in a scratch directory: every artifact goes there, the
// user's tree is not written to. `--trust=none` as for check; stdin is an empty pipe, so a program that reads it
// waits for the deadline.
fn String run_c3c(String[] mode_args, String hide, String replacement, Path scratch, bool is_dir_target, String where, String ok)
{
	String sd = (String)scratch;
	Args a;
	a.add(c3c_binary());
	a.add("--trust=none");
	a.add("-q");
	a.add("--build-dir");
	a.add(string::tformat("%s/b", sd));
	a.add("--output-dir");
	a.add(string::tformat("%s/o", sd));
	a.add("--obj-out");
	a.add(string::tformat("%s/ob", sd));
	if (is_dir_target)
	{
		a.add("--path");
		a.add(where);
	}
	foreach (m : mode_args) a.add(m);
	String[] argv = a.list();
	int status = 0;
	bool timed_out = false;
	// capture more than is shown: the [PASS] lines are dropped below, and they must not push the
	// failures and the summary line past the cap
	String? out = run_capped(argv, &status, &timed_out, RUN_DEADLINE_MS, MAX_RUN_CAPTURE);
	if (catch out) return "could not start c3c: set the C3C environment variable to its path or put c3c on PATH";
	String shown = drop_runtime_frames(report(out, status, timed_out, hide, replacement, ok, RUN_DEADLINE_MS));
	shown = util::clip_keep_tail(shown, MAX_RUN_OUTPUT, 1536);
	return string::tformat("%s%s", shown, hints::diagnostics(shown));
}

fn String c3_test(String path @Desc("a project directory (with project.json) or a .c3 file with @test functions"),
	String filter @Desc("run only the tests whose name matches") = "")
	@Desc("USE THIS INSTEAD OF running `c3c test` yourself. Builds the project or file in a scratch directory, runs its @test functions and returns pass/fail with the failing assertion and file:line; compile errors come with hints. Nothing is written to your tree. 60 s limit.")
	@Timeout(90000)
{
	bool is_dir;
	String? where = resolve_target(path, &is_dir);
	if (catch where) return BAD_TARGET_TEXT;
	Path? scratch = scratch_dir();
	if (catch scratch) return "cannot create a temp directory";
	defer (void)path::rmtree(scratch);
	String base = is_dir ? string::tformat("%s/", where) : string::tformat("%s", where[:(where.rindex_of("/") ?? 0) + 1]);
	Args m;
	if (filter.len > 0)
	{
		m.add("--test-filter");
		m.add(filter);
	}
	m.add(is_dir ? "test" : "compile-test");
	if (!is_dir) m.add(where);
	return run_c3c(m.list(), base, "", scratch, is_dir, where, "no output (are there @test functions?)");
}

fn String c3_run(String code @Desc("a C3 program with a main function") = "",
	String path @Desc("instead of code: a project directory or a .c3 file") = "",
	String target @Desc("with a project path: the target to run") = "")
	@Desc("USE THIS INSTEAD OF running `c3c compile-run` or `c3c run` yourself. Builds in a scratch directory and runs the program (stdin empty, 60 s limit), returning its output or the compile errors with hints.")
	@Timeout(90000)
{
	String bad = exclusive_args(code, path);
	if (bad.len > 0) return bad;
	if (!valid_target(target)) return BAD_TARGET_NAME;
	Path? scratch = scratch_dir();
	if (catch scratch) return "cannot create a temp directory";
	defer (void)path::rmtree(scratch);
	if (code.len > 0)
	{
		String file = string::tformat("%s/snippet.c3", (String)scratch);
		if (catch file::save(file, code)) return "cannot write the snippet";
		String[] mode = { "--run-dir", (String)scratch, "compile-run", file };
		return run_c3c(mode, (String)scratch, "<code>", scratch, false, "", "(no output)");
	}
	bool is_dir;
	String? where = resolve_target(path, &is_dir);
	if (catch where) return BAD_TARGET_TEXT;
	String base = is_dir ? string::tformat("%s/", where) : string::tformat("%s", where[:(where.rindex_of("/") ?? 0) + 1]);
	Args m;
	if (is_dir)
	{
		m.add("run");
		if (target.len > 0) m.add(target);
	}
	else
	{
		m.add("--run-dir");
		m.add((String)scratch);
		m.add("compile-run");
		m.add(where);
	}
	return run_c3c(m.list(), base, "", scratch, is_dir, where, "(no output)");
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_check);
	s.@tool(c3_fix);
	if (run_allowed())
	{
		s.@tool(c3_test);
		s.@tool(c3_run);
	}
}
