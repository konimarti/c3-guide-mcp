module c3guide::check;
import mcp, libc, std::os::posix, std::thread, std::core::string, std::io, std::io::path, std::io::file, std::os::process, std::os::env, std::time::clock;
import c3guide::util, c3guide::hints, c3guide::corpus, c3guide::context, c3guide::outline, std::time;

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
const ulong PROJECT_CHECK_MS = 25000;   // c3_check of a project: under the tool's 30 s limit, so our own message is what the caller sees
const ulong RUN_DEADLINE_MS = 120000;   // c3_test / c3_run: the program has to build and run (the most a caller may ask for)

// timeout_s: 0 = the default, else 1..120 seconds
fn ulong deadline_for(int timeout_s) => timeout_s <= 0 || timeout_s > 120 ? RUN_DEADLINE_MS : (ulong)timeout_s * 1000;
const sz MAX_RUN_OUTPUT = 6 * 1024;
const sz MAX_RUN_CAPTURE = 64 * 1024;
const String[*] FORBIDDEN = { "$embed", "$include", "$exec" };

faultdef NOT_FOUND;

const String EXE = env::WIN32 ? "c3c.exe" : "c3c";   // CreateProcess finds a program on PATH only with its extension
const String PATH_SEP = env::WIN32 ? ";" : ":";

// The first `name` found in the directories of `path_var`.
fn String? which(String name, String path_var)
{
	foreach (dir : path_var.tsplit(PATH_SEP))
	{
		if (dir.len == 0) continue;
		String p = string::tformat("%s/%s", dir, name);
		if (file::is_file(p)) return p;
	}
	return NOT_FOUND~;
}

// Editors start the server with a thin environment (a GUI launcher on macOS has no /opt/homebrew/bin in PATH),
// so after $C3C and PATH, look where c3c is usually installed.
fn String? find_c3c()
{
	String? p = env::tget_var("PATH");
	if (try p) { String? f = which(EXE, p); if (try f) return f; }
	String home = env::tget_var("HOME") ?? env::tget_var("USERPROFILE") ?? "";
	String local = env::tget_var("LOCALAPPDATA") ?? "";
	String[*] common = { "/usr/local/bin", "/opt/homebrew/bin", "/opt/c3" };
	foreach (d : common) { String? f = which(EXE, d); if (try f) return f; }
	String[*] under_home = { ".local/bin", "bin", "c3" };
	if (home.len > 0) foreach (d : under_home) { String? f = which(EXE, string::tformat("%s/%s", home, d)); if (try f) return f; }
	if (local.len > 0) { String? f = which(EXE, string::tformat("%s/c3", local)); if (try f) return f; }
	return NOT_FOUND~;
}

char[1024] c3c_buf;   // the cached answer lives here: temp memory is reset between calls
String found_c3c;

fn String c3c_binary()
{
	String? v = env::tget_var("C3C");
	if (try v) { if (v.len > 0) return v; }
	if (found_c3c.len > 0) return found_c3c;
	String? f = find_c3c();
	if (catch f) return EXE;   // not found: let the spawn fail with the usual message (and look again next time)
	if (f.len >= c3c_buf.len) return f;
	c3c_buf[:f.len] = f[..];
	found_c3c = (String)c3c_buf[:f.len];
	return found_c3c;
}

const ulong VERSION_MS = 3000;   // `c3c --version` answers at once; one that does not is not worth waiting for

// The text after the colon of the `c3c --version` line holding `label`, "" when absent or c3c cannot run.
// Temp memory: copy it to keep it.
fn String version_field(String binary, String label)
{
	String[] argv = { binary, "--version" };
	int status = 0;
	bool timed_out = false;
	String? out = run_capped(argv, &status, &timed_out, VERSION_MS);
	if (catch out) return "";
	foreach (line : out.tsplit("\n"))
	{
		if (!line.contains(label)) continue;
		sz colon = line.index_of(":") ?? 0;
		return line[colon..].trim(" :\t\r");
	}
	return "";
}

// The release a compiler reports: "0.8.5_1", or "0.8.6" for "0.8.6 (Pre-release, Nov  2 2026 15:21:29)".
fn String version_of(String binary)
{
	String v = version_field(binary, "Compiler Version:");
	return v[:v.index_of(" ") ?? v.len];
}

// The directory the compiler is installed in, "" when unknown.
fn String install_dir(String binary) => version_field(binary, "Installed directory:");

// The directory the standard library sources are under (lib/std/... inside it), "" when it cannot be found. A release
// keeps lib/ in the install directory; a build tree keeps the real one next to it.
char[1024] stdlib_buf;
String stdlib_dir_found;

fn String stdlib_root()
{
	if (stdlib_dir_found.len > 0) return stdlib_dir_found;
	String install = install_dir(c3c_binary());
	if (install.len == 0) return "";
	String[2] candidates = { string::tformat("%s", install), string::tformat("%s/..", install) };
	foreach (c : candidates)
	{
		if (!file::exists(string::tformat("%s/lib/std", c)) || c.len >= stdlib_buf.len) continue;
		stdlib_buf[:c.len] = c[..];
		stdlib_dir_found = (String)stdlib_buf[:c.len];
		return stdlib_dir_found;
	}
	return "";
}

// The version of the compiler the tools run, asked once. Kept in a fixed buffer: temp memory is reset between calls.
char[64] version_buf;
String installed_version;
bool version_asked;

fn String compiler_version()
{
	if (installed_version.len > 0 || version_asked) return installed_version;
	version_asked = true;   // a c3c that cannot run is asked once, not on every reply
	String v = version_of(c3c_binary());
	if (v.len == 0 || v.len >= version_buf.len) return "";
	version_buf[:v.len] = v[..];
	installed_version = (String)version_buf[:v.len];
	return installed_version;
}

// The version of the `c3c` a developer gets by typing `c3c`, when that is a different program than the one
// the tools run (C3C points elsewhere). "" when they are the same program or none is on PATH.
char[64] path_version_buf;
String path_version;
bool path_version_asked;

fn String path_c3c_version()
{
	if (path_version_asked) return path_version;
	String? p = env::tget_var("PATH");
	if (catch p) return "";
	String? f = which(EXE, p);
	if (catch f) return "";
	path_version_asked = true;
	if (f == c3c_binary()) return "";
	String v = version_of(f);
	if (v.len == 0 || v.len >= path_version_buf.len) return "";
	path_version_buf[:v.len] = v[..];
	path_version = (String)path_version_buf[:v.len];
	return path_version;
}

// The docs are a snapshot of one c3c release. When the installed compiler is another one, say so: a signature
// may have changed, and the compiler is right.
// Said on every failing compile: the code may behave differently under the compiler a developer types as `c3c`.
// "" when the tools run that same compiler (or the other one cannot be found).
fn String path_mismatch_note()
{
	String have = compiler_version();
	String other = path_c3c_version();
	if (have.len == 0 || other.len == 0 || other == have) return "";
	return string::tformat("\nnote: the tools run c3c %s (%s), but `c3c` on your PATH is %s. The same code can compile differently there (a stricter or looser check): set C3C to the compiler you build with.\n", have, c3c_binary(), other);
}

// The hints and, when the compile failed and the compilers differ, the note above.
fn String after_compile(String shown)
{
	String note = shown.contains("error:") ? path_mismatch_note() : "";
	return string::tformat("%s%s", hints::diagnostics(shown), note);
}

bool version_noted;

// Said once per session, and again when a name was not found (that is when a version difference matters).
fn String version_note(bool relevant = false)
{
	String have = compiler_version();
	if (have.len == 0 || (version_noted && !relevant)) return "";
	if (corpus::symbols_live)
	{
		// the signatures were read from this compiler: only the manual and the release notes come from the snapshot
		if (version_noted) return "";
		version_noted = true;
		return string::tformat("\nnote: standard library signatures are read from your c3c %s. The manual and release notes describe c3c %s.\n", have, corpus::snapshot_version);
	}
	if (have != corpus::symbols_version)
	{
		version_noted = true;
		return string::tformat("\nnote: these docs describe c3c %s, but the tools run c3c %s. A signature that fails to compile may have changed: trust the compiler, and c3_search scope=changes lists renames.\n", corpus::symbols_version, have);
	}
	String other = path_c3c_version();
	if (other.len > 0 && other != have && !version_noted)
	{
		version_noted = true;
		return string::tformat("\nnote: the tools run c3c %s (%s), but `c3c` on your PATH is %s. These docs describe %s; if you build with %s, a signature may differ (c3_search scope=changes lists renames). Set C3C to the one you mean.\n", have, c3c_binary(), other, have, other);
	}
	return "";
}
faultdef WATCHDOG_FAILED;

// Everything the reader thread shares with the caller. It is allocated with libc and, if the reader cannot be
// stopped (something outside our reach holds the pipe open), deliberately left behind: a stuck thread is a
// smaller harm than a server that never answers again.
struct Capture
{
	Mutex mutex;
	ConditionVariable cond;
	Process* proc;
	char* buf;
	sz max;
	sz len;
	bool finished;
	bool capped;
}

// The input of a program, written to its stdin by a detached thread that owns the pipe and everything it uses. If the
// child is killed the write fails and the thread ends.
struct Feed
{
	CFile file;
	char* data;
	sz len;
}

fn int write_input(void* arg) @private
{
	Feed* f = (Feed*)arg;
	libc::fwrite(f.data, 1, (usz)f.len, f.file);
	libc::fflush(f.file);
	libc::fclose(f.file);
	libc::free(f.data);
	libc::free(f);
	return 0;
}

fn int read_pipe(void* arg) @private
{
	Capture* c = (Capture*)arg;
	char[2048] tmp;
	while (true)
	{
		sz? n = c.proc.read_stdout(&tmp, tmp.len);
		if (catch n) break;
		if (n == 0) break;
		(void)c.mutex.lock();
		sz room = c.max + 1 - c.len;   // one byte more than the cap: output of exactly `max` bytes is not cut
		sz take = n > room ? room : n;
		if (take > 0)
		{
			mem::copy(c.buf + c.len, &tmp, take);
			c.len += take;
		}
		bool stop = c.len > c.max;
		if (stop) c.capped = true;
		c.mutex.unlock();
		if (stop) break;
	}
	(void)c.mutex.lock();
	c.finished = true;
	c.cond.signal();
	c.mutex.unlock();
	return 0;
}

// Killing c3c leaves the program it started running, and that program holds the output pipe open. Everything
// c3_test and c3_run start lives under the scratch directory, whose name is unique, so a pattern kill on that
// name reaches those processes. pkill is on Linux and macOS and reads an extended regex: the path is escaped and
// anchored on the '/' that follows the directory name, so `c3guide-12` never matches `c3guide-123`.
fn void kill_matching(String dir)
{
	$if !env::WIN32:
		DString pattern = dstring::temp();
		foreach (c : dir)
		{
			if (c == '.' || c == '^' || c == '$' || c == '*' || c == '+' || c == '?' || c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}' || c == '|' || c == '\\') pattern.append_char('\\');
			pattern.append_char(c);
		}
		pattern.append("/");
		String[] argv = { "pkill", "-9", "-f", "--", pattern.str_view() };
		Process? p = process::spawn(argv, process::SpawnOptions.INHERIT_ENV);
		if (catch p) return;
		(void)p.join();
		(void)p.destroy();
	$endif
}

const ulong DRAIN_MS = 1000;     // c3c has exited but the pipe is still open: wait this long for the output, then move on
const ulong REAP_MS = 2000;      // after a kill: wait this long for the reader to see the pipe close

// Has the child exited? If so, *status is its exit code. Process.is_running() cannot be used for this: it reaps the
// child and then calls join(), which has no status left to read, so the code it keeps is garbage.
fn bool child_exited(Process* p, int* status)
{
	$if env::WIN32:
		bool? alive = p.is_running();
		if (catch alive) return false;
		if (alive) return false;
		CInt? code = p.join();   // the exit code is read from the handle, which stays valid after the process ended
		*status = code ?? 1;
		return true;
	$else
		CInt raw = 0;
		CInt reaped = posix::waitpid(p.child, &raw, posix::WNOHANG);
		if (reaped == 0) return false;
		*status = (reaped < 0 || !posix::wIFEXITED(raw)) ? 1 : posix::wEXITSTATUS(raw);
		p.child = 0;   // reaped: nothing left to wait for or to signal
		return true;
	$endif
}

fn long ms_since(Clock t) => (long)(t.to_now() / 1_000_000);

// Run argv (no shell), capture stdout+stderr up to max_output, kill the child past that or past the deadline.
// *code gets the exit status (0 when we killed it ourselves), *timed_out says whether the deadline fired. A reader
// thread does the blocking read, so this call always returns: with the output so far if something keeps the pipe open.
fn String? run_capped(String[] cmd, int* code, bool* timed_out, ulong deadline_ms = DEADLINE_MS, sz max_output = MAX_OUTPUT, String sweep = "", String input = "")
{
	Process spawned = process::spawn(cmd, process::SpawnOptions.STDERR_TO_STDOUT | process::SpawnOptions.INHERIT_ENV)!;
	Process* proc = libc::calloc(1, Process::size);
	*proc = spawned;
	// What the program reads from stdin, then end of input: a program that reads stdin must see EOF, not wait for the
	// deadline. The input is written from a thread of its own: c3c compiles for seconds before the program reads, and a
	// write larger than the pipe buffer must not stop the deadline below from being watched.
	if (proc.stdin_file)
	{
		CFile in = proc.stdin_file;
		proc.stdin_file = null;   // the writer owns the pipe now
		if (input.len == 0)
		{
			libc::fclose(in);
		}
		else
		{
			Feed* f = libc::calloc(1, Feed::size);
			f.file = in;
			f.len = input.len;
			f.data = libc::malloc(input.len);
			mem::copy(f.data, input.ptr, input.len);
			Thread writer;
			if (catch writer.create(&write_input, f))
			{
				libc::fclose(in);
				libc::free(f.data);
				libc::free(f);
			}
			else
			{
				(void)writer.detach();
			}
		}
	}
	Capture* c = libc::calloc(1, Capture::size);
	c.proc = proc;
	c.max = max_output;
	c.buf = libc::malloc((usz)max_output + 1);
	(void)c.mutex.init();
	(void)c.cond.init();
	Thread th;
	if (catch th.create(&read_pipe, c))
	{
		(void)proc.terminate();
		(void)proc.join();
		(void)proc.destroy();
		libc::free(c.buf);
		libc::free(c);
		libc::free(proc);
		return WATCHDOG_FAILED~;
	}

	Clock start = clock::now();
	bool fired = false;
	bool exited = false;
	int exit_status = 0;
	long exited_at = 0;
	(void)c.mutex.lock();
	while (!c.finished)
	{
		long now = ms_since(start);
		if (now >= (long)deadline_ms) { fired = true; break; }
		if (!exited)
		{
			if (child_exited(proc, &exit_status)) { exited = true; exited_at = now; }
		}
		else if (now - exited_at > (long)DRAIN_MS)
		{
			break;   // a descendant outlived c3c and holds the pipe
		}
		long left = (long)deadline_ms - now;
		(void)c.cond.wait_timeout(&c.mutex, (ulong)(left < 100 ? left : 100));
	}
	bool capped = c.capped;
	bool stray = !c.finished;
	c.mutex.unlock();

	// the pipe closed but c3c may still be running (it closed its output and went on): the deadline still applies
	while (!exited && !fired && !capped && !child_exited(proc, &exit_status))
	{
		if (ms_since(start) >= (long)deadline_ms) { fired = true; break; }
		thread::sleep_ms(10);
	}
	if (!fired && !capped) exited = true;
	if ((fired || capped) && !exited) (void)proc.terminate();
	bool killed = fired || capped || (sweep.len > 0 && stray);
	if (sweep.len > 0 && (fired || capped || stray)) kill_matching(sweep);

	// after a kill the pipe should close: let the reader see it
	Clock reap = clock::now();
	(void)c.mutex.lock();
	while (killed && !c.finished && ms_since(reap) < (long)REAP_MS) (void)c.cond.wait_timeout(&c.mutex, 100);
	bool finished = c.finished;
	DString out = dstring::temp();
	out.append((String)c.buf[:(c.len > c.max ? c.max : c.len)]);
	c.mutex.unlock();

	int status = 0;
	if (exited) { status = exit_status; }
	else { CInt? j = proc.join(); status = j ?? 1; }
	*timed_out = fired;
	*code = (fired || capped) ? 0 : status;

	if (finished)
	{
		(void)th.join();
		(void)proc.destroy();
		(void)c.mutex.destroy();
		(void)c.cond.destroy();
		libc::free(c.buf);
		libc::free(c);
		libc::free(proc);
	}
	else
	{
		(void)th.detach();   // still blocked on a pipe we cannot close: leave it (and what it uses) alone
	}
	String s = out.str_view();
	if (capped) return string::tformat("%s\n[output cut]", s[:util::cut_utf8(s)]);
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
	if (!file::exists(s) || !s.ends_with(".c3")) return BAD_TARGET~;
	*is_dir = false;
	return s;
}

// The directory a target lives in, with a trailing '/' (the prefix to hide in the compiler's paths).
fn String dir_of(String where, bool is_dir) => is_dir ? string::tformat("%s/", where) : string::tformat("%s", where[:(where.rindex_of("/") ?? 0) + 1]);

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

const String NO_C3C = "could not start c3c: set the C3C environment variable to its path or put c3c on PATH";
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

fn String report(String out, int status, bool timed_out, String hide, String replacement, String ok, ulong deadline_ms)
{
	int dropped = 0;
	String shown = without_manifest_warnings(strip_ansi(redact(out, hide, replacement)), &dropped).trim_right();
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
	String[8] items;
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
		if (out.n >= MAX_EXTRA_FILES) return "files: at most 8 files";
		if (t.len > 4096 || t[0] == '-' || !t.ends_with(".c3")) return string::tformat("files: '%s' is not a .c3 file", util::clip(t, 80));
		Path? p = path::new(tmem, t);
		if (catch p) return "files: invalid path";
		Path? abs = p.absolute(tmem);
		if (catch abs) return "files: invalid path";
		String full = (String)abs;
		if (!file::is_file(full)) return string::tformat("files: '%s' does not exist", util::clip(t, 80));
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
		if (n++ >= MAX_PROGRAM_ARGS) return "args: at most 16 arguments";
		if (t.len > 1024) return "args: an argument is longer than 1024 bytes";
		a.add(t);
	}
	return "";
}

fn String c3_check(String code @Desc("a C3 snippet or file content; a main function is not required") = "",
	String path @Desc("instead of code: a project directory (with project.json) or a .c3 file on disk; a project is built (not run) in a scratch directory, nothing is written to it") = "",
	String files @Desc("with code or a single .c3 path: more .c3 files compiled together with it, one path per line (a helper, a library's source)") = "",
	String target @Desc("with a project path: the build target, default the first") = "",
	String platform @Desc("check for another platform without linking, e.g. 'windows-x64', 'macos-aarch64', 'linux-x64' (c3c --list-targets lists them)") = "")
	@Desc("USE THIS TO CHECK CODE instead of `c3c compile`. Compiles a snippet (code) or a real project/file (path) with the installed c3c, nothing is run, and returns the compiler's diagnostics plus hints that point to the right stdlib signature or release note. Code in old 0.6/0.7 syntax that fails is rewritten mechanically (`int.sizeof` -> `int::size`, `isz` -> `sz`...) and the rewritten code is checked too. A project (path) is built through the link; a file that belongs to a project is checked with that project; a snippet or a file outside any project is only type-checked. `platform` checks for another OS without linking. Check code before showing it. To get the binary itself, run `c3c build` in the shell.")
	@Timeout(30000)
{
	String bad = exclusive_args(code, path);
	if (bad.len > 0) return bad;
	if (!valid_target(target) || !valid_target(platform)) return BAD_TARGET_NAME;
	FileList extra;
	String err = parse_files(files, &extra);
	if (err.len > 0) return err;
	if (path.len > 0)
	{
		if (path.ends_with(".c3")) { context::note_file(path); }
		else { outline::note_project(path); }
		return check_path(path, target, platform, true, extra.list());
	}
	context::note_source(code);
	// No @pool here: the result lives in the caller's temp memory (a nested pool would free it on return).
	Path? dir = scratch_dir();
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
	a.add(c3c_binary());
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
	String? out = run_capped(a.list(), &status, &timed_out);
	if (catch out) return NO_C3C;
	String shown = report(out, status, timed_out, hide, replacement, "OK: no errors", DEADLINE_MS);
	return string::tformat("%s%s", shown, after_compile(shown));
}

fn String check_path(String target_path, String target, String platform = "", bool linked = true, String[] extra = {})
{
	bool is_dir;
	String? where = resolve_target(target_path, &is_dir);
	if (catch where) return BAD_TARGET_TEXT;
	String base = dir_of(where, is_dir);
	if (is_dir)
	{
		if (extra.len > 0) return "files goes with code or a single .c3 path, not with a project directory (the project lists its own sources)";
		// `--no-obj` only exists for single files. A project is built (not run) in a scratch directory.
		Path? scratch = scratch_dir();
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
		if (platform.len > 0 || !linked) m.add("-C");
		String ok = platform.len > 0 || !linked ? "OK: no errors (type-checked, not linked)" : "OK: no errors";
		return run_c3c(m.list(), base, "", scratch, true, where, ok, PROJECT_CHECK_MS);
	}
	// A file checked on its own cannot see the other modules or the dependencies of its project: check the project
	String project = extra.len > 0 ? "" : project_dir(where);
	if (project.len > 0)
	{
		outline::note_project(project);
		return string::tformat("(this file belongs to the project in %s: the whole project is type-checked; give the directory to build and link it)\n%s", project, check_path(project, target, platform, false));
	}
	return compile_only(where, base, "", platform, extra);
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
fn String run_c3c(String[] mode_args, String hide, String replacement, Path scratch, bool is_dir_target, String where, String ok, ulong deadline_ms = RUN_DEADLINE_MS, String input = "")
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
	String? out = run_capped(argv, &status, &timed_out, deadline_ms, MAX_RUN_CAPTURE, sd, input);
	if (catch out) return NO_C3C;
	String shown = drop_runtime_frames(report(out, status, timed_out, hide, replacement, ok, deadline_ms));
	shown = util::clip_keep_tail(shown, MAX_RUN_OUTPUT, 1536);
	return string::tformat("%s%s", shown, after_compile(shown));
}

fn String c3_test(String path @Desc("a project directory (with project.json) or a .c3 file with @test functions") = "",
	String filter @Desc("run only the tests whose name matches") = "",
	String platform @Desc("type-check the tests for another platform, e.g. 'windows-x64' (they cannot run here)") = "",
	int timeout_s @Desc("give up after this many seconds (1..120, default 120); a test stuck in a loop is killed") = 0)
	@Desc("USE THIS INSTEAD OF running `c3c test` yourself. Builds the project or file in a scratch directory, runs its @test functions and returns the failures only, with the failing assertion and file:line, and the summary line; compile errors come with hints. Nothing is written to your tree. 120 s limit.")
	@Timeout(150000)
{
	if (path.len == 0) return "give path: a project directory (with project.json) or a .c3 file with @test functions";
	if (filter.len > 0 && filter[0] == '-') return "filter must be a test name, not an option";
	if (!valid_target(platform)) return BAD_TARGET_NAME;
	bool is_dir;
	String? where = resolve_target(path, &is_dir);
	if (catch where) return BAD_TARGET_TEXT;
	if (is_dir) { outline::note_project(path); } else { context::note_file(path); }
	Path? scratch = scratch_dir();
	if (catch scratch) return "cannot create a temp directory";
	defer (void)path::rmtree(scratch);
	String base = dir_of(where, is_dir);
	Args m;
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
	int timeout_s @Desc("give up after this many seconds (1..120, default 120); a program stuck in a loop is killed") = 0)
	@Desc("USE THIS INSTEAD OF `c3c compile-run` or `c3c run`. Builds in a scratch directory and runs the program (arguments, stdin and extra source files can be given; 120 s limit), returning its output or the compile errors with hints. A program that needs its own working directory or files next to it: `c3c build` and run it in the shell.")
	@Timeout(150000)
{
	String bad = exclusive_args(code, path);
	if (bad.len > 0) return bad;
	if (!valid_target(target)) return BAD_TARGET_NAME;
	if (!valid_opt(opt)) return BAD_OPT;
	if (input.len > MAX_STDIN) return "input: at most 16384 bytes";
	FileList extra;
	String err = parse_files(files, &extra);
	if (err.len > 0) return err;
	Args tail;
	err = parse_args(args, &tail);
	if (err.len > 0) return err;
	Path? scratch = scratch_dir();
	if (catch scratch) return "cannot create a temp directory";
	defer (void)path::rmtree(scratch);
	Args m;
	if (opt.len > 0) m.add(string::tformat("-%s", opt));
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
	return run_c3c(m.list(), hide, replacement, scratch, is_dir, where, "(no output)", deadline_for(timeout_s), input);
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_check);
	s.@tool(c3_test);
	s.@tool(c3_run);
}
