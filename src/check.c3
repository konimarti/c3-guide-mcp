module c3guide::check;
import mcp, std::core::string, std::io::path, std::io::file, std::collections::list, std::collections::object, std::encoding::json;
import c3guide::guard, c3guide::sources, c3guide::proc, c3guide::compiler, c3guide::format, c3guide::util, c3guide::hints, c3guide::context, c3guide::outline;

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
fn String after_compile(String shown, bool platform_given = false)
{
	String note = shown.contains("error:") ? compiler::path_mismatch_note() : "";
	return string::tformat("%s%s%s", hints::diagnostics(shown), note, platform_given ? "" : platform_note(shown));
}

// An error in code that names an operating system (`env::WIN32`, `std::os::posix`, `$if env::DARWIN`) may be an error of this
// platform only: one line says how to type-check the other ones.
fn String platform_note(String shown)
{
	if (!shown.contains("error:")) return "";
	String[*] marks = { "WIN32", "win32", "Win32", "POSIX", "posix", "DARWIN", "darwin", "MACOS", "macos", "LINUX", "linux", "ANDROID", "WASI" };
	foreach (m : marks)
	{
		if (shown.contains(m)) return "\nThis error may be specific to this platform (the code or the message names another): c3_check with platform=windows-x64 (or macos-aarch64, linux-x64) type-checks for it, c3_test takes platform too.\n";
	}
	return "";
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
// With `keep_passes` (output=true) the passing lines stay: what a test printed sits on them, in the order it happened.
fn String drop_runtime_frames(String s, bool keep_passes = false)
{
	DString out = dstring::temp();
	foreach (line : s.tsplit("\n"))
	{
		if (line.contains("std.core.runtime.") || line.contains("[inline]")) continue;
		// a passing test is one line of noise; the failures and the summary line are what matter
		// (and what the output cap must not cut)
		if (!keep_passes && line.starts_with("Testing ") && line.contains("[PASS]")) continue;
		out.appendf("%s\n", line);
	}
	return out.str_view();
}

faultdef BAD_TARGET;

// A command line under construction (C3 has no varargs-free array literal with conditional members).
struct Args
{
	String[800] items;   // a command line with a project's sources (sources::MAX_SOURCES) and its libraries
	int n;
}

fn void Args.add(&self, String s)
{
	if (self.n < self.items.len) self.items[self.n++] = s;   // callers that can be given many (a project's libraries) check first
}
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
const String NO_PATH_TEXT = "give path: a project directory (with project.json) or a .c3 file. No project to default to: none was given to an earlier call, and the server's working directory holds no project.json";
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

const String CODE_AND_PATH = "give either code or path, not both, unless path is a project directory (with project.json): then the snippet is compiled with the project's sources and libraries. To use other files with a snippet, give them in files";

// code or path, or both when path is a project directory (the snippet is compiled with the project's sources and
// libraries). Returns "" when the arguments are fine, else the message to show.
fn String exclusive_args(String code, String path)
{
	if (code.len > 0 && path.len > 0)
	{
		bool is_dir;
		String? w = resolve_target(path, &is_dir);
		if (catch w) return CODE_AND_PATH;
		if (!is_dir) return CODE_AND_PATH;
	}
	if (code.len == 0 && path.len == 0) return "give code (a snippet) or path (a project directory or .c3 file)";
	if (code.len > MAX_CODE) return string::tformat("give 1 to %d bytes of code", (int)MAX_CODE);
	foreach (f : guard::COMPILE_TIME_READS)
	{
		if (code.contains(f)) return string::tformat("rejected: %s reads files or runs programs at compile time and is not allowed in a snippet\nWay out: put the code in a file of a project and c3_check path=<project> (the project's own files may $embed files inside it), or c3_test / c3_run it.", f);
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
fn String report(String out, int status, bool timed_out, String hide, String replacement, String ok, ulong deadline_ms, String also_hide = "")
{
	int dropped = 0;
	String shown = without_manifest_warnings(strip_ansi(util::redact(util::redact(out, hide, replacement), also_hide, "")), &dropped).trim_right();
	if (dropped > 0 && shown.trim().len > 0) shown = string::tformat("%s\n\n(%d warning(s) about unknown keys in a library manifest left out: not your code)", shown, dropped);
	if (timed_out) shown = string::tformat("%s\n[timeout: longer than %d s]", shown, (int)(deadline_ms / 1000));
	if (shown.trim().len == 0 && !timed_out)
	{
		return status == 0 ? ok : string::tformat("c3c failed (exit code %d) without a message", status);
	}
	return shown;
}

// Extra sources compiled together with a snippet or a file (a helper, a library's source): one path per line.
const int MAX_EXTRA_FILES = 32;
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
		String escaped = guard::file_escape(full, project_dir(full));
		if (escaped.len > 0) return reads_outside(escaped);
		out.items[out.n++] = full;
	}
	return "";
}

// A snippet that is checked or run together with a project (code and path): the project's own sources and libraries are
// added to the command line, and nothing is written to its tree. The project is read by the guard first, exactly as in
// path mode. The project's `main` would clash with the snippet's: when the snippet defines one, the sources that define
// theirs are left out (a project that keeps its `main` in a file with other code loses that code; give such code as
// `files` or move it). The project-level `sources` are used, not a target's; the project's c-sources, cflags and
// link-args are not (they are code that cc and the linker would run). Returns "" or the message to show.
fn String project_for_snippet(String path, String code, Args* out, String* root_out, String* note)
{
	bool is_dir;
	String? where = resolve_target(path, &is_dir);
	if (catch where) return BAD_TARGET_TEXT;
	if (!is_dir) return CODE_AND_PATH;
	String outside = guard::project_escape_note(where, note);
	if (outside.len > 0) return reads_outside(outside);
	outline::note_project(path);
	List{String} found;
	found.init(tmem);
	sources::project_files(where, &found);
	bool own_main = sources::defines_main(code);
	foreach (f : found)
	{
		if (own_main && sources::file_defines_main(f)) continue;
		if (out.n >= out.items.len - 100) return string::tformat("the project has more than %d sources: too many to compile with a snippet", sources::MAX_SOURCES);
		out.add(f);
	}
	List{String} dirs;
	List{String} names;
	dirs.init(tmem);
	names.init(tmem);
	sources::project_libraries(where, &dirs, &names);
	if ((long)out.n + 2 * (long)(dirs.len() + names.len()) >= (long)out.items.len - 100) return "the project names too many libraries (dependencies and dependency-search-paths) to compile with a snippet";
	foreach (d : dirs) { out.add("--libdir"); out.add(d); }
	foreach (n : names) { out.add("--lib"); out.add(n); }
	*root_out = string::tformat("%s/", where);
	return "";
}

// The program arguments: a JSON array of strings (`["-v", "a b"]`) or one argument per line (a line is one argument,
// spaces included). A text that starts with `[` and parses as a JSON array is the first form.
fn String parse_args(String args, Args* a)
{
	int n = 0;
	String trimmed = args.trim(" \t\r\n");
	if (trimmed.starts_with("["))
	{
		Object*? arr = json::parse(tmem, trimmed);
		if (try arr)
		{
			if (arr.is_array())
			{
				for (sz i = 0; i < arr.get_len(); i++)
				{
					Object* one = arr.get_at(i);
					if (!one.is_string()) return "args: a JSON array must hold strings only";
					if (n++ >= MAX_PROGRAM_ARGS) return string::tformat("args: at most %d arguments", MAX_PROGRAM_ARGS);
					if (one.s.len > 1024) return "args: an argument is longer than 1024 bytes";
					a.add(one.s);
				}
				return "";
			}
		}
	}
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
	String path @Desc("a project directory (with project.json) or a .c3 / .c3i file on disk to check instead of code; a project is built (not run) in a scratch directory, nothing is written to it. WITH code and a project directory: the snippet is checked together with the project's sources and libraries, so `import yourmodule;` works (if the snippet defines main, the project source files that define theirs are left out)") = "",
	String files @Desc("with code or a single .c3 / .c3i path: more .c3 or .c3i files compiled together with it, one path per line (a helper, an FFI binding, a library's source)") = "",
	String target @Desc("with a project path: the build target, default the first") = "",
	String platform @Desc("check for another platform without linking, e.g. 'windows-x64', 'macos-aarch64', 'linux-x64' (c3c --list-targets lists them)") = "",
	bool format @Desc("also run the formatter c3f: a snippet comes back formatted, a file or project as a diff of what would change (nothing is written)") = false)
	@Desc("USE THIS TO CHECK CODE instead of `c3c compile`. Compiles a snippet (code) or a real project/file (path) with the installed c3c, nothing is run, and returns the compiler's diagnostics plus hints that point to the right stdlib signature or release note. Code in old 0.6/0.7 syntax that fails is rewritten mechanically (`int.sizeof` -> `int::size`, `isz` -> `sz`...) and the rewritten code is checked too. A project (path) is type-checked, never compiled with cc or linked (its c-sources, cflags and link-args are code); c3_test and c3_run build it. A project is first read for compile-time reads ($embed, $include, $exec) in the files c3c compiles (what its sources, test-sources and dependency libraries stand for; scratch and fixture folders are not read) and refused in one line (file:line and reason) when one can leave it. A file that belongs to a project is checked with that project; a snippet or a file outside any project is only type-checked. To check a usage snippet against your own library, give both code and path=<project directory>. `platform` checks for another OS without linking. It type-checks only: a clean result says nothing about leaks, double frees or use-after-free; run those with c3_test or c3_run and sanitize=address. Check code before showing it. To get the binary itself, run `c3c build` in the shell.")
	@Timeout(30000)
{
	String reply = check_any(code, path, files, target, platform);
	if (!format || !(reply.starts_with("OK") || reply.contains("error:"))) return reply;   // not after a refused call
	String where = "";
	if (path.len > 0 && code.len == 0)
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
	if (path.len > 0 && code.len == 0)
	{
		if (util::is_c3_file(path)) { context::note_file(path); }
		else { outline::note_project(path); }
		return check_path(path, target, platform, extra.list());
	}
	context::note_source(code);
	// code with a project directory as path: the project's sources and libraries go on the command line after the files
	Args project;
	String hide_project = "";
	String note = "";
	if (path.len > 0)
	{
		String refused = project_for_snippet(path, code, &project, &hide_project, &note);
		if (refused.len > 0) return refused;
		foreach (x : extra.list()) project.add(x);
	}
	String[] with = path.len > 0 ? project.list() : extra.list();
	return with_note(note, check_snippet(code, platform, with, hide_project));
}

// The snippet checked with `with` (the files and the project's sources and libraries on the command line).
fn String check_snippet(String code, String platform, String[] with, String hide_project)
{
	// No @pool here: the result lives in the caller's temp memory (a nested pool would free it on return).
	Path? dir = proc::scratch_dir();
	if (catch dir) return "cannot create a temp directory";
	defer (void)path::rmtree(dir);
	String file = string::tformat("%s/snippet.c3", (String)dir);
	if (catch file::save(file, code)) return "cannot write the snippet";
	String first = compile_only(file, (String)dir, "<code>", platform, with, hide_project);
	if (!first.contains("error:") || code.len > MAX_FIX) return first;
	// old syntax: apply the mechanical rewrite and check that too, so one call shows what is left
	hints::Rewrite r = hints::rewrite(code);
	if (r.count == 0) return first;
	String fixed = string::tformat("%s/rewritten.c3", (String)dir);
	if (catch file::save(fixed, r.code)) return first;
	String second = compile_only(fixed, (String)dir, "<code>", platform, with, hide_project);
	return string::tformat("%s\n\n0.7 syntax found: %d mechanical rewrite(s) (%s). The rewritten code:\n--- code ---\n%s\n--- c3_check of the rewritten code ---\n%s", first, r.count, r.notes, r.code, second);
}

// Type-check one file: nothing is emitted or run. `hide` is cut from the paths in the output.
fn String compile_only(String file, String hide, String replacement, String platform = "", String[] extra = {}, String also_hide = "")
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
	String shown = report(out, status, timed_out, hide, replacement, "OK: no errors", proc::DEADLINE_MS, also_hide);
	return string::tformat("%s%s", shown, after_compile(shown, platform.len > 0));
}

fn String check_path(String target_path, String target, String platform = "", String[] extra = {})
{
	bool is_dir;
	String inside = "";
	String? first = resolve_target(target_path, &is_dir);
	// a folder inside a project means that project
	if (catch first)
	{
		Path? tp = path::new(tmem, target_path);
		if (catch tp) return BAD_TARGET_TEXT;
		if (!path::is_dir(tp)) return BAD_TARGET_TEXT;
		first = resolve_project_aware(target_path, &is_dir, &inside);
	}
	if (catch first) return BAD_TARGET_TEXT;
	String where = first;
	String base = dir_of(where, is_dir);
	if (is_dir)
	{
		if (extra.len > 0) return "files goes with code or a single .c3 path, not with a project directory (the project lists its own sources)";
		String note;
		String outside = guard::project_escape_note(where, &note);
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
		if (sources::has_no_targets(where)) return with_note(inside, with_note(note, check_library_sources(where, scratch, base)));
		String reply = run_c3c(m.list(), base, "", scratch, true, where, ok, PROJECT_CHECK_MS);
		return with_note(inside, with_note(note, which_source_entry(reply, where)));
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

// A project without targets (a library scaffold) has nothing for `c3c build`: its `sources` and `test-sources` are
// type-checked together, with its libraries, as one compilation (nothing is linked).
fn String check_library_sources(String root, Path scratch, String base)
{
	List{String} found;
	found.init(tmem);
	sources::project_files(root, &found);
	sources::project_test_files(root, &found);
	if (found.len() == 0) return "this project has no targets and its sources and test-sources name no files: nothing to check";
	Args m;
	m.add("compile-only");
	m.add("--no-obj");
	foreach (f : found)
	{
		if (m.n >= m.items.len - 100) return string::tformat("the project has more than %d sources: too many to check without a target", sources::MAX_SOURCES);
		m.add(f);
	}
	List{String} dirs;
	List{String} names;
	dirs.init(tmem);
	names.init(tmem);
	sources::project_libraries(root, &dirs, &names);
	if ((long)m.n + 2 * (long)(dirs.len() + names.len()) >= (long)m.items.len - 100) return "the project names too many libraries to check without a target";
	foreach (d : dirs) { m.add("--libdir"); m.add(d); }
	foreach (n : names) { m.add("--lib"); m.add(n); }
	String ok = string::tformat("OK: no errors (the project has no targets: its %d source files, tests included, were type-checked)", (int)found.len());
	String reply = run_c3c(m.list(), base, "", scratch, false, root, ok, PROJECT_CHECK_MS);
	return which_source_entry(reply, root);
}

// c3c's "Can't open the directory 'x'" does not say which entry of project.json asked for it.
fn String which_source_entry(String reply, String root)
{
	String key = "Can't open the directory '";
	sz at = reply.index_of(key) ?? -1;
	if (at < 0) return reply;
	String rest = reply[at + key.len..];
	sz end = rest.index_of("'") ?? -1;
	if (end <= 0) return reply;
	String line = sources::pattern_naming(root, rest[:end]);
	return line.len > 0 ? string::tformat("%s\n(%s)", reply, line) : reply;
}

// $embed, $include and $exec can read any file the server can read, and $echo prints it into the reply: not at check time.
// `why` is the guard's one line (file, line, reason).
fn String reads_outside(String why)
{
	return string::tformat("rejected: %s\nIf you trust it: c3_test builds and runs the project, or build it yourself with `c3c build`.", util::clip(why, 300));
}

// A reply with the guard's note in front of it (the note is "" when the guard read what c3c compiles).
fn String with_note(String note, String reply) => note.len > 0 ? string::tformat("%s\n%s", note, reply) : reply;

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
fn String run_c3c(String[] mode_args, String hide, String replacement, Path scratch, bool is_dir_target, String where, String ok, ulong deadline_ms = RUN_DEADLINE_MS, String input = "", bool program = false, String also_hide = "", String[] env = {}, bool show_output = false)
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
	bool sanitized = false;
	foreach (arg : mode_args) if (arg.starts_with("--sanitize=")) sanitized = true;
	// capture more than is shown: the [PASS] lines are dropped below, and they must not push the
	// failures and the summary line past the cap
	String? out = proc::run_capped(argv, &status, &timed_out, { .deadline_ms = deadline_ms, .max_output = MAX_RUN_CAPTURE, .input = input, .cwd = sd, .sweep = sd, .raise_limits = sanitized, .env = env });
	if (catch out) return NO_C3C;
	if (proc::could_not_start(status)) return NO_C3C;
	if (sanitized && out.contains("ReserveShadowMemoryRange failed")) return sanitizer_blocked(out);
	// a program's own output is shown as it is, with its exit code; a test run drops the runtime's frames and passing lines
	String shown = report(out, program ? 0 : status, timed_out, hide, replacement, ok, deadline_ms, also_hide);
	if (program) { if (status != 0 && !timed_out && !shown.contains("error: ")) shown = string::tformat("%s\n[exit code %d]", shown, status); }
	else
	{
		shown = drop_runtime_frames(shown, show_output);
	}
	shown = util::clip_keep_tail(shown, MAX_RUN_OUTPUT, 1536);
	// where it ran: a path that was defaulted or relative is the one thing a caller cannot see
	String footer = where.len > 0 ? string::tformat("\n[c3c %s, %s]", compiler::compiler_version(), where) : "";
	bool platform_given = false;
	foreach (arg : mode_args) if (arg == "--target") platform_given = true;
	return string::tformat("%s%s%s", shown, after_compile(shown, platform_given), footer);
}

// The sanitizer could not reserve its shadow memory even with the soft limits raised: say which limit is in the way, in one line
// (the raw report is neither short nor a result).
fn String sanitizer_blocked(String out)
{
	String limits = "";
	bool unlimited = false;
	$if !env::WIN32:
		int code = 0;
		bool timed_out = false;
		String? h = proc::run_capped({ "/bin/sh", "-c", "echo \"$(ulimit -H -d) $(ulimit -H -v)\"" }, &code, &timed_out);
		if (try h) unlimited = h.trim() == "unlimited unlimited";
		String? l = proc::run_capped({ "/bin/sh", "-c", "echo \"data $(ulimit -S -d) soft, $(ulimit -H -d) hard; address space $(ulimit -S -v) soft, $(ulimit -H -v) hard\"" }, &code, &timed_out);
		if (try l) limits = string::tformat(" (%s)", l.trim());
	$endif
	// a c3c that is a shell script setting `ulimit` itself lowers the limits again after we raised them
	bool wrapper = false;
	char[]? loaded = file::load_temp(compiler::c3c_binary());
	if (try loaded) { String head = (String)loaded; wrapper = head.starts_with("#!") && head.contains("ulimit"); }
	String tail = " The tests did not run.";
	// the hard limits are not set: they are not what is in the way, and "run it where the limit is unlimited" would be false
	if (unlimited)
	{
		return string::tformat("The sanitizer could not reserve its shadow memory%s, though ulimit sets no hard limit here; %s.%s", limits, wrapper ? "the c3c in use is a script that may set ulimit itself" : "another limit (a container or cgroup setting) may be in the way", tail);
	}
	String which = out.contains("ulimit -v or ulimit -d") ? "the data or address-space limit (ulimit -d/-v)" : "an address-space limit";
	return string::tformat("The sanitizer could not start: %s is too small for its shadow memory%s.%s%s Run them where the limit is higher.", which, limits, tail, wrapper ? " The c3c in use is a script that may set ulimit itself." : "");
}

// Names a caller may not set: they change what c3c and the C toolchain load or run, not what the program sees.
fn bool env_name_refused(String n)
{
	foreach (p : (String[]){ "C3C", "LD_", "DYLD_", "ASAN_", "UBSAN_", "MSAN_", "TSAN_" }) if (n.starts_with(p)) return true;
	foreach (x : (String[]){ "PATH", "CC", "AR", "SDKROOT", "DEVELOPER_DIR", "HOME", "TMPDIR", "IFS", "SHELL" }) if (n == x) return true;
	return false;
}

// `NAME=value` lines for the child's environment. Returns "" or the message to show.
fn String parse_env(String env, String[]* out)
{
	String[] items = mem::talloc_array(String, 16);
	int n = 0;
	foreach (line : env.tsplit("\n"))
	{
		String t = line.trim(" \t\r");
		if (t.len == 0) continue;
		sz eq = t.index_of("=") ?? -1;
		if (eq <= 0) return string::tformat("env: '%s' is not NAME=value", util::clip(t, 60));
		String name = t[:eq];
		foreach (i, c : name)
		{
			bool ok = c == '_' || c.is_alpha() || (i > 0 && c.is_digit());
			if (!ok) return string::tformat("env: '%s' is not a valid variable name (letters, digits, _)", util::clip(name, 40));
		}
		if (env_name_refused(name)) return string::tformat("env: %s cannot be set (it would change the compiler or the loader, not the program)", name);
		if (t.len > 4096) return "env: an entry is longer than 4096 bytes";
		if (n >= 16) return "env: at most 16 variables";
		items[n++] = t;
	}
	*out = items[:n];
	return "";
}

// What `path` names for c3_test and c3_run: no path is the project of the session (see context::default_project); a folder or
// a .c3 file inside a project means that project (*note says so in one line).
fn String? resolve_project_aware(String path_in, bool* is_dir, String* note)
{
	String path = path_in;
	if (path.len == 0)
	{
		path = context::default_project();
		if (path.len == 0) return BAD_TARGET~;
		*note = string::tformat("(no path: using the project %s)", path);
	}
	if (path.len > 4096) return BAD_TARGET~;
	Path? p = path::new(tmem, path);
	if (catch p) return BAD_TARGET~;
	Path? abs = p.absolute(tmem);
	if (catch abs) return BAD_TARGET~;
	String s = (String)abs;
	String inner = "";
	if (path::is_dir(abs))
	{
		if (!file::exists(string::tformat("%s/project.json", s))) inner = project_dir(string::tformat("%s/x", s));
	}
	else if (util::is_c3_file(s) && file::exists(s))
	{
		inner = project_dir(s);
	}
	if (inner.len > 0)
	{
		*is_dir = true;
		*note = string::tformat("(%s is inside the project in %s: that project is used)", util::clip(path, 100), inner);
		return inner;
	}
	return resolve_target(path, is_dir);
}

fn String c3_test(String path @Desc("a project directory (with project.json) or a .c3 file with @test functions. A folder or file inside a project means that project. Default: the project you last gave to a tool, else the server's working directory when it holds a project.json") = "",
	String filter @Desc("run only the tests whose name matches") = "",
	String platform @Desc("type-check the tests for another platform, e.g. 'windows-x64' (they cannot run here)") = "",
	int timeout_s @Desc("give up after this many seconds (1..120, default 120); a test stuck in a loop is killed") = 0,
	String sanitize @Desc("run under a sanitizer: address (memory errors and leaks), memory or thread; empty for none") = "",
	bool output @Desc("also show what the tests printed (stdout and stderr, in the order of the run, on the lines of the tests that printed it; passing tests are listed then; capped, the summary line is kept)") = false,
	String env @Desc("environment variables for the tests, one NAME=value per line (not for c3c; C3C*, PATH, LD_*, DYLD_*, CC, AR and similar names are refused)") = "")
	@Desc("USE THIS INSTEAD OF running `c3c test` yourself. Builds the project or file in a scratch directory, runs its @test functions and returns the failures only, with the failing assertion and file:line, and the summary line; compile errors come with hints. Nothing is written to your tree. 120 s limit.")
	@Timeout(150000)
{
	if (filter.len > 0 && filter[0] == '-') return "filter must be a test name, not an option";
	if (!valid_target(platform)) return BAD_TARGET_NAME;
	if (!valid_sanitize(sanitize)) return BAD_SANITIZE;
	String[] env_list;
	String env_err = parse_env(env, &env_list);
	if (env_err.len > 0) return env_err;
	bool is_dir;
	String note = "";
	String? where = resolve_project_aware(path, &is_dir, &note);
	if (catch where) return path.len == 0 ? NO_PATH_TEXT : BAD_TARGET_TEXT;
	if (is_dir) { outline::note_project(where); } else { context::note_file(where); }
	Path? scratch = proc::scratch_dir();
	if (catch scratch) return "cannot create a temp directory";
	defer (void)path::rmtree(scratch);
	String base = dir_of(where, is_dir);
	Args m;
	if (sanitize.len > 0) m.add(string::tformat("--sanitize=%s", sanitize));
	if (output) m.add("--test-show-output");
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
	return with_note(note, run_c3c(m.list(), base, "", scratch, is_dir, where, ok, deadline_for(timeout_s), "", false, "", env_list, output));
}

fn String c3_run(String code @Desc("a C3 program with a main function") = "",
	String path @Desc("instead of code: a project directory or a .c3 file (a folder or file inside a project means that project; default: the project you last gave to a tool, else the server's working directory when it holds a project.json). With code and a project directory the snippet is built with the project's sources and libraries and its main runs, not the project's (the project source files that define a main are left out); its c-sources, cflags and link-args are not used") = "",
	String args @Desc("the program's command-line arguments: a JSON array of strings (e.g. [\"-v\", \"a b\"]) or one argument per line; both are accepted (up to 16)") = "",
	String env @Desc("environment variables for the program, one NAME=value per line (not for c3c; C3C*, PATH, LD_*, DYLD_*, CC, AR and similar names are refused)") = "",
	bool output @Desc("accepted for symmetry with c3_test: a program's output is always shown") = false,
	String input @Desc("what the program reads from stdin (up to 16 KB); then it sees end of input") = "",
	String files @Desc("with code or a single .c3 path: more .c3 files compiled into the program, one path per line") = "",
	String target @Desc("with a project path: the target to run") = "",
	String opt @Desc("optimization level: O0 O1 O2 O3 O4 O5 Os Oz; default is the compiler's (use it to compare speed)") = "",
	int timeout_s @Desc("give up after this many seconds (1..120, default 120); a program stuck in a loop is killed") = 0,
	String sanitize @Desc("run under a sanitizer: address (memory errors and leaks), memory or thread; empty for none") = "")
	@Desc("USE THIS INSTEAD OF `c3c compile-run` or `c3c run`. Builds in a scratch directory and runs the program (arguments, stdin and extra source files can be given; 120 s limit), returning its output or the compile errors with hints. A program that needs its own working directory or files next to it: `c3c build` and run it in the shell.")
	@Timeout(150000)
{
	// no code and no path: the project of the session (resolve_project_aware)
	String bad = code.len == 0 && path.len == 0 ? "" : exclusive_args(code, path);
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
	String[] env_list;
	err = parse_env(env, &env_list);
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
	String also_hide = "";
	String note = "";
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
		if (path.len > 0)   // code with a project directory as path: the project's sources and libraries are compiled in
		{
			String refused = project_for_snippet(path, code, &m, &also_hide, &note);
			if (refused.len > 0) return refused;
		}
	}
	else
	{
		String? resolved = resolve_project_aware(path, &is_dir, &note);
		if (catch resolved) return path.len == 0 ? NO_PATH_TEXT : BAD_TARGET_TEXT;
		where = resolved;
		hide = dir_of(where, is_dir);
		if (is_dir)
		{
			outline::note_project(where);
			if (extra.n > 0) return "files goes with code or a single .c3 path, not with a project directory";
			m.add("run");
			if (target.len > 0) m.add(target);
		}
		else
		{
			context::note_file(where);
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
	return with_note(note, run_c3c(m.list(), hide, replacement, scratch, is_dir, where, "(no output)", deadline_for(timeout_s), input, true, also_hide, env_list));
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_check);
	s.@tool(c3_test);
	s.@tool(c3_run);
}
