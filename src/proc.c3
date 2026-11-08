module c3guide::proc;
import c3guide::util;
import libc, std::os::posix, std::thread, std::core::string, std::io, std::io::path, std::io::file, std::os::process, std::os::env, std::time::clock, std::time;

// Running a program (c3c, c3f, pkill) with a deadline and capped output, and the scratch directories it works in.

const ulong DEADLINE_MS = 10000;
const sz MAX_OUTPUT = 4 * 1024;

faultdef WATCHDOG_FAILED, NO_CWD;

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

// What c3c and the C toolchain it calls read (c3c's own getenv calls, plus the loader, locale and sanitizer settings).
// Everything else of the client's environment (tokens, API keys) is not handed to a compiler or to a program a snippet builds.
const String[*] KEEP_ENV = {
	"PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "TMP", "TEMP", "TEMPDIR", "XDG_CACHE_HOME", "LANG", "LC_ALL", "LC_CTYPE",
	"C3C_LIB", "C3C_CC", "C3C_AR", "CC", "AR", "SDKROOT", "DEVELOPER_DIR", "LD_LIBRARY_PATH", "ANDROID_NDK",
	"ASAN_OPTIONS", "UBSAN_OPTIONS", "MSAN_OPTIONS", "TSAN_OPTIONS"
};

fn Process? spawn_clean(String[] cmd)
{
	$if env::WIN32:
		return process::spawn(cmd, process::SpawnOptions.STDERR_TO_STDOUT | process::SpawnOptions.INHERIT_ENV);   // the loader needs SystemRoot and more
	$else
		String[] kept = mem::talloc_array(String, KEEP_ENV.len);
		int n = 0;
		foreach (k : KEEP_ENV)
		{
			String? v = env::tget_var(k);
			if (try v) kept[n++] = string::tformat("%s=%s", k, v);
		}
		return process::spawn(cmd, process::SpawnOptions.STDERR_TO_STDOUT, kept[:n]);
	$endif
}

// What a run needs beyond the command; a field left at zero or "" takes the default.
struct RunOpts
{
	ulong deadline_ms;   // default DEADLINE_MS
	sz max_output;       // default MAX_OUTPUT
	String input;        // the child's stdin, then end of input (default: end of input at once)
	String cwd;          // the child's working directory (default: an empty directory of ours, see neutral_cwd)
	String sweep;        // a scratch directory whose processes are killed too when the run is cut short
}

// Run argv, capture stdout+stderr up to max_output, kill the child past that or past the deadline.
// *code gets the exit status (0 when we killed it ourselves), *timed_out says whether the deadline fired. A reader
// thread does the blocking read, so this call always returns: with the output so far if something keeps the pipe open.
// `cwd`: the directory the child runs in (Linux and macOS: through `sh -c 'cd "$1" && exec "$@"'`; argv is still never
// parsed by a shell; on Windows the child keeps our directory). c3c treats every `*.c3l` in its working directory as a library, so a snippet
// must not run in the directory the client was started in (a library being synced there breaks every call).
fn String? run_capped(String[] cmd_in, int* code, bool* timed_out, RunOpts opts = {})
{
	ulong deadline_ms = opts.deadline_ms > 0 ? opts.deadline_ms : DEADLINE_MS;
	sz max_output = opts.max_output > 0 ? opts.max_output : MAX_OUTPUT;
	String input = opts.input;
	String sweep = opts.sweep;
	String cwd = opts.cwd.len > 0 ? opts.cwd : neutral_cwd();
	if (cwd.len == 0) return NO_CWD~;   // never fall back to our own directory: c3c reads every *.c3l in it
	String[] cmd = cmd_in;
	$if !env::WIN32:
		if (cwd.len > 0)
		{
			String[] wrapped = mem::talloc_array(String, cmd_in.len + 5);
			wrapped[0] = "/bin/sh";
			wrapped[1] = "-c";
			wrapped[2] = "cd \"$1\" || exit 253; shift; command -v \"$1\" >/dev/null 2>&1 || exit 252; exec \"$@\"";
			wrapped[3] = "sh";
			wrapped[4] = cwd;
			foreach (i, c : cmd_in) wrapped[5 + i] = c;
			cmd = wrapped;
		}
	$endif
	Process spawned = spawn_clean(cmd)!;
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

// A killed server cannot run its `defer`, so it leaves c3guide-* behind: remove those older than an hour.
// c3guide-<digits>: the names scratch_dir makes (anything else in the temp directory is not ours to remove)
fn bool ours(String name)
{
	if (!name.starts_with("c3guide-") || name.len == 8) return false;
	foreach (c : name[8..]) if (!c.is_digit()) return false;
	return true;
}

fn void sweep_stale(Path tmp)
{
	PathList? list = path::ls(tmem, tmp, no_dirs: false, relative: true);
	if (catch list) return;
	foreach (entry : list)
	{
		String name = entry.basename();
		if (!ours(name)) continue;
		Path? full = tmp.tappend(name);
		if (catch full) continue;
		if (path::is_link(full)) continue;   // never follow a planted symlink into someone else's files
		Time? mt = file::last_modified((String)full);
		if (catch mt) continue;
		if ((long)time::now() - (long)mt > 3600L * (long)time::SEC) (void)path::rmtree(full);
	}
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

// An empty directory to run c3c in when it needs no files of its own (c3c reads every `*.c3l` in its working directory).
// One per process, made on first use and made again if the stale-directory sweep removed it.
char[1024] cwd_buf;
String neutral_cwd_path;

fn String neutral_cwd()
{
	if (neutral_cwd_path.len > 0 && file::is_dir(neutral_cwd_path)) return neutral_cwd_path;
	Path? p = scratch_dir();
	if (catch p) return "";
	String s = (String)p;
	if (s.len >= cwd_buf.len) return "";
	cwd_buf[:s.len] = s[..];
	neutral_cwd_path = (String)cwd_buf[:s.len];
	return neutral_cwd_path;
}

// The exit codes of the shell that sets the working directory: 253 it could not go there, 252 the program is not there. A
// program that exits 126 or 127 itself (a c3_run) is not "could not start".
fn bool could_not_start(int status) => status == 252 || status == 253;

// The directory made by neutral_cwd, removed when the server stops.
fn void cleanup()
{
	if (neutral_cwd_path.len > 0) (void)path::rmtree(path::new(tmem, neutral_cwd_path)!!);
}
