module c3guide::check;
import mcp, std::thread, std::core::string, std::io, std::io::path, std::io::file, std::os::process, std::os::env, std::time::clock;
import c3guide::util, std::time;

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
const sz MAX_OUTPUT = 4 * 1024;
const ulong DEADLINE_MS = 10000;
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
		long left = (long)DEADLINE_MS - (long)(start.to_now() / 1_000_000);
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
fn String? run_capped(String[] cmd, int* code, bool* timed_out)
{
	Process p = process::spawn(cmd, process::SpawnOptions.STDERR_TO_STDOUT | process::SpawnOptions.INHERIT_ENV)!;
	defer (void)p.destroy();
	Watchdog w = { .proc = &p };
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
		sz room = MAX_OUTPUT - out.len();
		out.append((String)buf[:n > room ? room : n]);
		if (out.len() >= MAX_OUTPUT)
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

// Replace every `needle` in `s` by "<code>". (std String.replace returned corrupted bytes for a 4 KB
// string without a match in c3c 0.8.5, hence the small loop.)
fn String redact(String s, String needle)
{
	DString out = dstring::temp();
	while (true)
	{
		sz? at = s.index_of(needle);
		if (catch at) break;
		out.append(s[:at]);
		out.append("<code>");
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
		Time? mt = file::last_modified((String)full);
		if (catch mt) continue;
		if ((long)time::now() - (long)mt > 3600L * (long)time::SEC) (void)path::rmtree(full);
	}
}

fn String c3_check(String code @Desc("a C3 snippet or file content; a main function is not required"))
	@Desc("Compile C3 code with the installed c3c (type-check only, nothing is linked or run) and return the compiler's diagnostics. Use it to verify code before showing it.")
	@Timeout(30000)
{
	if (code.len == 0 || code.len > MAX_CODE) return "give 1 to 32768 bytes of code";
	foreach (f : FORBIDDEN)
	{
		if (code.contains(f)) return string::tformat("rejected: %s reads files or runs programs at compile time and is not allowed here", f);
	}
	// No @pool here: the result lives in the caller's temp memory (a nested pool would free it on return).
	Path? tmp = path::temp_directory(tmem);
	if (catch tmp) return "no temp directory available";
	sweep_stale(tmp);
	// nanosecond clock: two servers (or two calls) never share a directory
	Path? dir = tmp.tappend(string::tformat("c3guide-%d", (long)clock::now()));
	if (catch dir) return "cannot create a temp path";
	if (catch path::mkdir(dir)) return "cannot create a temp directory";
	defer (void)path::rmtree(dir);
	String file = string::tformat("%s/snippet.c3", (String)dir);
	if (catch file::save(file, code)) return "cannot write the snippet";
	String[] argv = { c3c_binary(), "--trust=none", "--no-obj", "--no-entry", "-q", "compile-only", file };
	int status = 0;
	bool timed_out = false;
	String? out = run_capped(argv, &status, &timed_out);
	if (catch out) return "could not start c3c: set the C3C environment variable to its path or put c3c on PATH";
	String shown = redact(out, (String)dir);
	if (timed_out) shown = string::tformat("%s\n[timeout: the compiler ran longer than 10 s]", shown);
	if (shown.trim().len == 0 && !timed_out)
	{
		return status == 0 ? "OK: no errors" : string::tformat("c3c failed (exit code %d) without a message", status);
	}
	return shown;
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_check);
}
