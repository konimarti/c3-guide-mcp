module c3guide::check;
import mcp, std::core::string, std::io::path, std::io::file;
import c3guide::guard, c3guide::proc, c3guide::compiler, c3guide::format, c3guide::util, c3guide::hints, c3guide::context, c3guide::outline;

// c3_check, c3_test and c3_run: the real compiler's diagnostics (never a build artifact), with hints.
//
// A snippet is written to a fresh temp dir and compiled with a fixed command line (`--trust=none --no-obj`: nothing is
// emitted or linked, so nothing can run). Running c3c, its deadlines and its working directory are src/proc.c3; finding it
// is src/compiler.c3.
//
// `--trust=none` still allows $embed, and a compile error can print what it read, so a snippet could read any file the
// server can read. Snippets that mention $embed, $include or $exec are rejected before they reach the compiler (the tokens
// cannot be spelled any other way: $eval only builds identifiers). Code that reaches the compiler by `path` or `files` is
// read first (src/guard.c3) for the same reason, and a project is only type-checked (`-C`): its cflags, c-sources and
// link-args would run under cc and the linker. Do not run the server as a user that can read secrets regardless.
const sz MAX_CODE = 32 * 1024;
const sz MAX_FIX = 12 * 1024;
const ulong PROJECT_CHECK_MS = 25000;   // c3_check of a project: under the tool's 30 s limit, so our own message is what the caller sees
const ulong RUN_DEADLINE_MS = 120000;   // c3_test / c3_run: the program has to build and run (the most a caller may ask for)

// timeout_s: 0 = the default, else 1..120 seconds
fn ulong deadline_for(int timeout_s) => timeout_s <= 0 || timeout_s > 120 ? RUN_DEADLINE_MS : (ulong)timeout_s * 1000;
const sz MAX_RUN_OUTPUT = 6 * 1024;
const sz MAX_RUN_CAPTURE = 64 * 1024;

// The hints and, when the compile failed and the compilers differ, the note above.
fn String after_compile(String shown)
{
	String note = shown.contains("error:") ? compiler::path_mismatch_note() : "";
	return string::tformat("%s%s", hints::diagnostics(shown), note);
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

faultdef BAD_TARGET;

// A command line under construction (C3 has no varargs-free array literal with conditional members).
struct Args
{
	String[64] items;
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
	if (!file::exists(s) || !util::is_c3_file(s)) return BAD_TARGET~;
	*is_dir = false;
	return s;
}

// The directory a target lives in, with a trailing '/' (the prefix to hide in the compiler's paths).
fn String dir_of(String where, bool is_dir) => is_dir ? string::tformat("%s/", where) : string::tformat("%s", where[:(where.rindex_of("/") ?? 0) + 1]);

// Shown for the faults above, so the model knows what to give.
const String BAD_TARGET_TEXT = "path must be a project directory (containing project.json) or a .c3 or .c3i file that exists";

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

const String NO_C3C = "could not start c3c: set the C3C environment variable to its path or put c3c on PATH";
const String BAD_SANITIZE = "sanitize must be address, memory or thread (or empty for none)";

fn bool valid_sanitize(String x) => x == "" || x == "address" || x == "memory" || x == "thread";

const String BAD_OPT = "opt must be one of O0 O1 O2 O3 O4 O5 Os Oz (or empty for the default)";

fn bool valid_opt(String o)
{
	if (o.len == 0) return true;
	String[*] levels = { "O0", "O1", "O2", "O3", "O4", "O5", "Os", "Oz" };
	foreach (ok : levels) if (o == ok) return true;
	return false;
}

const String BAD_TARGET_NAME = "target must be a build target name (letters, digits, _ . -), not an option";

// Exactly one of code / path. Returns "" when the arguments are fine, else the message to show.
fn String exclusive_args(String code, String path)
{
	if (code.len > 0 && path.len > 0) return "give either code or path, not both";
	if (code.len == 0 && path.len == 0) return "give code (a snippet) or path (a project directory or .c3 file)";
	if (code.len > MAX_CODE) return string::tformat("give 1 to %d bytes of code", (int)MAX_CODE);
	foreach (f : guard::COMPILE_TIME_READS)
	{
		if (code.contains(f)) return string::tformat("rejected: %s reads files or runs programs at compile time and is not allowed here", f);
	}
	return "";
}

// c3c 0.8.5 warns about every key of a library manifest it does not know (`version`, `authors`), on every build, for a
// library the user did not write. Left out, with a count, so the output is about the code.
fn String without_manifest_warnings(String text, int* dropped)
{
	DString kept = dstring::temp();
	foreach (line : text.tsplit("\n"))
	{
		if (line.starts_with("WARNING: Unknown parameter '") || line.starts_with("You can use '--list-manifest-properties'")) { *dropped += line.starts_with("WARNING") ? 1 : 0; continue; }
		kept.appendf("%s\n", line);
	}
	return kept.str_view();
}

// The compiler's text, with the scratch directory (snippet) or the project directory (project) removed
// from the paths, an explanation when it was cut or timed out, and hints for what went wrong.
fn String report(String out, int status, bool timed_out, String hide, String replacement, String ok, ulong deadline_ms)
{
	int dropped = 0;
	String shown = without_manifest_warnings(strip_ansi(util::redact(out, hide, replacement)), &dropped).trim_right();
	if (dropped > 0 && shown.trim().len > 0) shown = string::tformat("%s\n\n(%d warning(s) about unknown keys in a library manifest left out: not your code)", shown, dropped);
	if (timed_out) shown = string::tformat("%s\n[timeout: longer than %d s]", shown, (int)(deadline_ms / 1000));
	if (shown.trim().len == 0 && !timed_out)
	{
		return status == 0 ? ok : string::tformat("c3c failed (exit code %d) without a message", status);
	}
	return shown;
}

// Extra sources compiled together with a snippet or a file (a helper, a library's source): one path per line.
const int MAX_EXTRA_FILES = 8;
const int MAX_PROGRAM_ARGS = 16;
const sz MAX_STDIN = 16 * 1024;

struct FileList
{
	String[MAX_EXTRA_FILES] items;
	int n;
}

fn String[] FileList.list(&self) => self.items[:self.n];

// Fills `out` from the lines of `files`; returns "" or the message to show.
fn String parse_files(String files, FileList* out)
{
	foreach (line : files.tsplit("\n"))
	{
		String t = line.trim(" \t\r");
		if (t.len == 0) continue;
		if (out.n >= MAX_EXTRA_FILES) return string::tformat("files: at most %d files", MAX_EXTRA_FILES);
		if (t.len > 4096 || t[0] == '-' || !util::is_c3_file(t)) return string::tformat("files: '%s' is not a .c3 or .c3i file", util::clip(t, 80));
		Path? p = path::new(tmem, t);
		if (catch p) return "files: invalid path";
		Path? abs = p.absolute(tmem);
		if (catch abs) return "files: invalid path";
		String full = (String)abs;
		if (!file::is_file(full)) return string::tformat("files: '%s' does not exist", util::clip(t, 80));
		if (guard::file_escape(full, project_dir(full)).len > 0) return reads_outside(full);
		out.items[out.n++] = full;
	}
	return "";
}

// The program arguments, one per line (a line is one argument, spaces included).
fn String parse_args(String args, Args* a)
{
	int n = 0;
	foreach (line : args.tsplit("\n"))
	{
		String t = line.trim("\r");
		if (t.len == 0) continue;
		if (n++ >= MAX_PROGRAM_ARGS) return string::tformat("args: at most %d arguments", MAX_PROGRAM_ARGS);
		if (t.len > 1024) return "args: an argument is longer than 1024 bytes";
		a.add(t);
	}
	return "";
}

fn String c3_check(String code @Desc("a C3 snippet or file content; a main function is not required") = "",
	String path @Desc("instead of code: a project directory (with project.json) or a .c3 / .c3i file on disk; a project is built (not run) in a scratch directory, nothing is written to it") = "",
	String files @Desc("with code or a single .c3 / .c3i path: more .c3 or .c3i files compiled together with it, one path per line (a helper, an FFI binding, a library's source)") = "",
	String target @Desc("with a project path: the build target, default the first") = "",
	String platform @Desc("check for another platform without linking, e.g. 'windows-x64', 'macos-aarch64', 'linux-x64' (c3c --list-targets lists them)") = "",
	bool format @Desc("also run the formatter c3f: a snippet comes back formatted, a file or project as a diff of what would change (nothing is written)") = false)
	@Desc("USE THIS TO CHECK CODE instead of `c3c compile`. Compiles a snippet (code) or a real project/file (path) with the installed c3c, nothing is run, and returns the compiler's diagnostics plus hints that point to the right stdlib signature or release note. Code in old 0.6/0.7 syntax that fails is rewritten mechanically (`int.sizeof` -> `int::size`, `isz` -> `sz`...) and the rewritten code is checked too. A project (path) is type-checked, never compiled with cc or linked (its c-sources, cflags and link-args are code); c3_test and c3_run build it. A file that belongs to a project is checked with that project; a snippet or a file outside any project is only type-checked. `platform` checks for another OS without linking. It type-checks only: a clean result says nothing about leaks, double frees or use-after-free; run those with c3_test or c3_run and sanitize=address. Check code before showing it. To get the binary itself, run `c3c build` in the shell.")
	@Timeout(30000)
{
	String reply = check_any(code, path, files, target, platform);
	if (!format || !(reply.starts_with("OK") || reply.contains("error:"))) return reply;   // not after a refused call
	String where = "";
	if (path.len > 0)
	{
		bool is_dir;
		String? w = resolve_target(path, &is_dir);
		if (catch w) return reply;
		where = w;
	}
	return string::tformat("%s%s", reply, format::report(code, where));
}

fn String check_any(String code, String path, String files, String target, String platform)
{
	String bad = exclusive_args(code, path);
	if (bad.len > 0) return bad;
	if (!valid_target(target) || !valid_target(platform)) return BAD_TARGET_NAME;
	FileList extra;
	String err = parse_files(files, &extra);
	if (err.len > 0) return err;
	if (path.len > 0)
	{
		if (util::is_c3_file(path)) { context::note_file(path); }
		else { outline::note_project(path); }
		return check_path(path, target, platform, extra.list());
	}
	context::note_source(code);
	// No @pool here: the result lives in the caller's temp memory (a nested pool would free it on return).
	Path? dir = proc::scratch_dir();
	if (catch dir) return "cannot create a temp directory";
	defer (void)path::rmtree(dir);
	String file = string::tformat("%s/snippet.c3", (String)dir);
	if (catch file::save(file, code)) return "cannot write the snippet";
	String first = compile_only(file, (String)dir, "<code>", platform, extra.list());
	if (!first.contains("error:") || code.len > MAX_FIX) return first;
	// old syntax: apply the mechanical rewrite and check that too, so one call shows what is left
	hints::Rewrite r = hints::rewrite(code);
	if (r.count == 0) return first;
	String fixed = string::tformat("%s/rewritten.c3", (String)dir);
	if (catch file::save(fixed, r.code)) return first;
	String second = compile_only(fixed, (String)dir, "<code>", platform, extra.list());
	return string::tformat("%s\n\n0.7 syntax found: %d mechanical rewrite(s) (%s). The rewritten code:\n--- code ---\n%s\n--- c3_check of the rewritten code ---\n%s", first, r.count, r.notes, r.code, second);
}

// Type-check one file: nothing is emitted or run. `hide` is cut from the paths in the output.
fn String compile_only(String file, String hide, String replacement, String platform = "", String[] extra = {})
{
	Args a;
	a.add(compiler::c3c_binary());
	a.add("--trust=none");
	a.add("--no-obj");
	a.add("--no-entry");
	a.add("-q");
	if (platform.len > 0)
	{
		a.add("--target");
		a.add(platform);
	}
	a.add("compile-only");
	a.add(file);
	foreach (e : extra) a.add(e);
	int status = 0;
	bool timed_out = false;
	String? out = proc::run_capped(a.list(), &status, &timed_out);
	if (catch out) return NO_C3C;
	if (proc::could_not_start(status)) return NO_C3C;
	String shown = report(out, status, timed_out, hide, replacement, "OK: no errors", proc::DEADLINE_MS);
	return string::tformat("%s%s", shown, after_compile(shown));
}

fn String check_path(String target_path, String target, String platform = "", String[] extra = {})
{
	bool is_dir;
	String? where = resolve_target(target_path, &is_dir);
	if (catch where) return BAD_TARGET_TEXT;
	String base = dir_of(where, is_dir);
	if (is_dir)
	{
		if (extra.len > 0) return "files goes with code or a single .c3 path, not with a project directory (the project lists its own sources)";
		String outside = guard::project_escape(where);
		if (outside.len > 0) return reads_outside(outside);
		// `--no-obj` only exists for single files. A project is built (not run) in a scratch directory.
		Path? scratch = proc::scratch_dir();
		if (catch scratch) return "cannot create a temp directory";
		defer (void)path::rmtree(scratch);
		Args m;
		m.add("build");
		if (target.len > 0) m.add(target);
		// another platform cannot be linked here (no SDK), and an edit loop does not need the link: lex, parse and
		// check only (0.2 s where the build takes 2.6 s)
		if (platform.len > 0)
		{
			m.add("--target");
			m.add(platform);
		}
		// type-check only, never `cc` or the linker: a project's cflags, c-sources and link-args are code that would run
		m.add("-C");
		String ok = "OK: no errors (type-checked; c3_test or c3_run builds, links and runs)";
		return run_c3c(m.list(), base, "", scratch, true, where, ok, PROJECT_CHECK_MS);
	}
	// A file checked on its own cannot see the other modules or the dependencies of its project: check the project
	String project = extra.len > 0 ? "" : project_dir(where);
	if (project.len > 0)
	{
		outline::note_project(project);
		return string::tformat("(this file belongs to the project in %s: the whole project is type-checked)\n%s", project, check_path(project, target, platform));
	}
	String outside = guard::file_escape(where, "");   // (a file of a project was checked above, with its project)
	if (outside.len > 0) return reads_outside(outside);
	return compile_only(where, base, "", platform, extra);
}

// $embed, $include and $exec can read any file the server can read, and $echo prints it into the reply: not at check time.
fn String reads_outside(String file)
{
	return string::tformat("rejected: %s cannot be shown to stay inside its project: it reads at compile time ($embed/$include/$exec) with a path that leaves it or one that is computed, or it is a link, an unreadable or oversized file, a tree too large to check, or a library manifest (manifest.json) that is unreadable or names sources outside its library. c3_check does not compile it. If you trust it, build it yourself with `c3c`.", util::clip(file, 200));
}

// The directory of the project.json above a file, "" when the file belongs to no project.
fn String project_dir(String file)
{
	String dir = file[:file.rindex_of("/") ?? 0];
	for (int up = 0; up < 6 && dir.len > 1; up++)
	{
		if (file::exists(string::tformat("%s/project.json", dir))) return dir;
		dir = dir[:dir.rindex_of("/") ?? 0];
	}
	return "";
}

// Build and run the target's tests / the program in a scratch directory: every artifact goes there, the
// user's tree is not written to. `--trust=none` as for check; `input` is the program's stdin (then end of input).
fn String run_c3c(String[] mode_args, String hide, String replacement, Path scratch, bool is_dir_target, String where, String ok, ulong deadline_ms = RUN_DEADLINE_MS, String input = "", bool program = false)
{
	String sd = (String)scratch;
	Args a;
	a.add(compiler::c3c_binary());
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
	String? out = proc::run_capped(argv, &status, &timed_out, { .deadline_ms = deadline_ms, .max_output = MAX_RUN_CAPTURE, .input = input, .cwd = sd, .sweep = sd });
	if (catch out) return NO_C3C;
	if (proc::could_not_start(status)) return NO_C3C;
	// a program's own output is shown as it is, with its exit code; a test run drops the runtime's frames and passing lines
	String shown = report(out, program ? 0 : status, timed_out, hide, replacement, ok, deadline_ms);
	if (program) { if (status != 0 && !timed_out && !shown.contains("error: ")) shown = string::tformat("%s\n[exit code %d]", shown, status); }
	else { shown = drop_runtime_frames(shown); }
	shown = util::clip_keep_tail(shown, MAX_RUN_OUTPUT, 1536);
	// where it ran: a path that was defaulted or relative is the one thing a caller cannot see
	String footer = where.len > 0 ? string::tformat("\n[c3c %s, %s]", compiler::compiler_version(), where) : "";
	return string::tformat("%s%s%s", shown, after_compile(shown), footer);
}

fn String c3_test(String path @Desc("a project directory (with project.json) or a .c3 file with @test functions") = "",
	String filter @Desc("run only the tests whose name matches") = "",
	String platform @Desc("type-check the tests for another platform, e.g. 'windows-x64' (they cannot run here)") = "",
	int timeout_s @Desc("give up after this many seconds (1..120, default 120); a test stuck in a loop is killed") = 0,
	String sanitize @Desc("run under a sanitizer: address (memory errors and leaks), memory or thread; empty for none") = "")
	@Desc("USE THIS INSTEAD OF running `c3c test` yourself. Builds the project or file in a scratch directory, runs its @test functions and returns the failures only, with the failing assertion and file:line, and the summary line; compile errors come with hints. Nothing is written to your tree. 120 s limit.")
	@Timeout(150000)
{
	if (path.len == 0) return "give path: a project directory (with project.json) or a .c3 file with @test functions";
	if (filter.len > 0 && filter[0] == '-') return "filter must be a test name, not an option";
	if (!valid_target(platform)) return BAD_TARGET_NAME;
	if (!valid_sanitize(sanitize)) return BAD_SANITIZE;
	bool is_dir;
	String? where = resolve_target(path, &is_dir);
	if (catch where) return BAD_TARGET_TEXT;
	if (is_dir) { outline::note_project(path); } else { context::note_file(path); }
	Path? scratch = proc::scratch_dir();
	if (catch scratch) return "cannot create a temp directory";
	defer (void)path::rmtree(scratch);
	String base = dir_of(where, is_dir);
	Args m;
	if (sanitize.len > 0) m.add(string::tformat("--sanitize=%s", sanitize));
	if (filter.len > 0)
	{
		m.add("--test-filter");
		m.add(filter);
	}
	m.add(is_dir ? "test" : "compile-test");
	if (!is_dir) m.add(where);
	String ok = "no output (are there @test functions?)";
	if (platform.len > 0)
	{
		m.add("--target");
		m.add(platform);
		m.add("-C");
		ok = "OK: the tests type-check for that platform (not run)";
	}
	return run_c3c(m.list(), base, "", scratch, is_dir, where, ok, deadline_for(timeout_s));
}

fn String c3_run(String code @Desc("a C3 program with a main function") = "",
	String path @Desc("instead of code: a project directory or a .c3 file") = "",
	String args @Desc("the program's command-line arguments, one per line") = "",
	String input @Desc("what the program reads from stdin (up to 16 KB); then it sees end of input") = "",
	String files @Desc("with code or a single .c3 path: more .c3 files compiled into the program, one path per line") = "",
	String target @Desc("with a project path: the target to run") = "",
	String opt @Desc("optimization level: O0 O1 O2 O3 O4 O5 Os Oz; default is the compiler's (use it to compare speed)") = "",
	int timeout_s @Desc("give up after this many seconds (1..120, default 120); a program stuck in a loop is killed") = 0,
	String sanitize @Desc("run under a sanitizer: address (memory errors and leaks), memory or thread; empty for none") = "")
	@Desc("USE THIS INSTEAD OF `c3c compile-run` or `c3c run`. Builds in a scratch directory and runs the program (arguments, stdin and extra source files can be given; 120 s limit), returning its output or the compile errors with hints. A program that needs its own working directory or files next to it: `c3c build` and run it in the shell.")
	@Timeout(150000)
{
	String bad = exclusive_args(code, path);
	if (bad.len > 0) return bad;
	if (!valid_target(target)) return BAD_TARGET_NAME;
	if (!valid_opt(opt)) return BAD_OPT;
	if (!valid_sanitize(sanitize)) return BAD_SANITIZE;
	if (input.len > MAX_STDIN) return string::tformat("input: at most %d bytes", (int)MAX_STDIN);
	FileList extra;
	String err = parse_files(files, &extra);
	if (err.len > 0) return err;
	Args tail;
	err = parse_args(args, &tail);
	if (err.len > 0) return err;
	Path? scratch = proc::scratch_dir();
	if (catch scratch) return "cannot create a temp directory";
	defer (void)path::rmtree(scratch);
	Args m;
	if (opt.len > 0) m.add(string::tformat("-%s", opt));
	if (sanitize.len > 0) m.add(string::tformat("--sanitize=%s", sanitize));
	String hide;
	String replacement = "";
	String where = "";
	bool is_dir = false;
	if (code.len > 0)
	{
		String file = string::tformat("%s/snippet.c3", (String)scratch);
		if (catch file::save(file, code)) return "cannot write the snippet";
		m.add("--run-dir");
		m.add((String)scratch);
		m.add("compile-run");
		m.add(file);
		hide = (String)scratch;
		replacement = "<code>";
	}
	else
	{
		String? resolved = resolve_target(path, &is_dir);
		if (catch resolved) return BAD_TARGET_TEXT;
		where = resolved;
		hide = dir_of(where, is_dir);
		if (is_dir)
		{
			outline::note_project(path);
			if (extra.n > 0) return "files goes with code or a single .c3 path, not with a project directory";
			m.add("run");
			if (target.len > 0) m.add(target);
		}
		else
		{
			context::note_file(path);
			m.add("--run-dir");
			m.add((String)scratch);
			m.add("compile-run");
			m.add(where);
		}
	}
	foreach (e : extra.list()) m.add(e);
	if (tail.n > 0)
	{
		m.add("--");
		foreach (t : tail.list()) m.add(t);
	}
	return run_c3c(m.list(), hide, replacement, scratch, is_dir, where, "(no output)", deadline_for(timeout_s), input, true);
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_check);
	s.@tool(c3_test);
	s.@tool(c3_run);
}
