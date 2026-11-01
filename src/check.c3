module c3guide::check;
import mcp, std::core::string, std::io, std::io::path, std::io::file, std::os::process, std::os::env, std::time::clock;
import c3guide::util;

// Only the compiler's own diagnostics come back, never a build artifact. The snippet is written to a
// fresh temp dir and compiled with a FIXED command line:
//   --trust=none  no $exec / $include at compile time, whatever the user's c3c config says
//   --no-obj      nothing is emitted or linked, so nothing can run
//   timeout 10    a compile-time loop in the snippet cannot hang the server
// The compiler binary is not a tool argument: C3C env var, else "c3c" from PATH.
//
// `--trust=none` still allows $embed, and $echo prints to stdout, so a snippet could read any file the
// server can read and print it byte by byte. Snippets that mention $embed, $include or $exec are
// rejected before they reach the compiler (the tokens cannot be spelled any other way: $eval only
// builds identifiers). Do not run the server as a user that can read secrets regardless.
const sz MAX_CODE = 32 * 1024;
const sz MAX_OUTPUT = 4 * 1024;
const String[*] FORBIDDEN = { "$embed", "$include", "$exec" };

fn String c3c_binary()
{
	String? v = env::tget_var("C3C");
	if (try v) { if (v.len > 0) return v; }
	return "c3c";
}

// Run argv (no shell), capture stdout+stderr up to MAX_OUTPUT, kill the child past that, always join.
// *code gets the exit status (0 when the child was killed because of the cap).
fn String? run_capped(String[] cmd, int* code)
{
	Process p = process::spawn(cmd, process::SpawnOptions.STDERR_TO_STDOUT | process::SpawnOptions.INHERIT_ENV)!;
	defer (void)p.destroy();
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
	*code = p.join()!;
	String s = out.str_view();
	if (capped)
	{
		*code = 0;
		return string::tformat("%s\n[output cut]", s[:util::utf8_boundary(s, s.len)]);
	}
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
	Path? dir = tmp.tappend(string::tformat("c3guide-%d", (int)(clock::now() % 1000000000)));
	if (catch dir) return "cannot create a temp path";
	if (catch path::mkdir(dir)) return "cannot create a temp directory";
	defer (void)path::rmtree(dir);
	String file = string::tformat("%s/snippet.c3", (String)dir);
	if (catch file::save(file, code)) return "cannot write the snippet";
	String[] argv = { "timeout", "10", c3c_binary(), "--trust=none", "--no-obj", "--no-entry", "-q", "compile-only", file };
	int status = 0;
	String? out = run_capped(argv, &status);
	if (catch out) return "could not start `timeout` or c3c (set the C3C environment variable to the c3c path; `timeout` must be on PATH)";
	if (status == 127) return "c3c not found: set the C3C environment variable to its path or put c3c on PATH";
	String shown = redact(out, (String)dir);
	if (status == 124) shown = string::tformat("%s\n[timeout: the compiler ran longer than 10 s]", shown);
	if (shown.trim().len == 0)
	{
		return status == 0 ? "OK: no errors" : string::tformat("c3c failed (exit code %d) without a message", status);
	}
	return shown;
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_check);
}
