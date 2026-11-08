module c3guide::format;
import std::core::string, std::os::env;
import c3guide::proc, c3guide::compiler, c3guide::util;

// The C3 formatter c3f, run on a snippet or a file to show what it would change. Nothing is written.

const sz MAX_FORMAT_INPUT = 60000;

// c3f, the C3 formatter, when it is installed ($C3F or on PATH).
fn String? find_c3f()
{
	String? v = env::tget_var("C3F");
	if (try v) { if (v.len > 0) return v; }
	String? dirs = env::tget_var("PATH");
	if (catch dirs) return compiler::NOT_FOUND~;
	return compiler::which(env::WIN32 ? "c3f.exe" : "c3f", dirs);
}

// What c3f would change, appended to the check: the formatted snippet, or a diff for a file or project. Writes nothing.
fn String report(String code, String where)
{
	String? bin = find_c3f();
	if (catch bin) return "\n(format: c3f is not installed; put it on PATH or set C3F)";
	return where.len > 0 ? format_path(bin, where) : format_snippet(bin, code);
}

fn String format_path(String bin, String where)
{
	int status = 0;
	bool timed_out = false;
	String? out = proc::run_capped({ bin, "--diff", where }, &status, &timed_out, { .max_output = 8192 });
	if (catch out) return "\n(format: c3f could not run)";
	if (timed_out || proc::could_not_start(status)) return "\n(format: c3f did not finish)";
	return out.trim().len == 0 ? "\n(format: c3f has nothing to change)" : string::tformat("\n--- c3f would change ---\n%s", util::clip(util::redact(out, where, ""), 3000));
}

fn String format_snippet(String bin, String code)
{
	if (code.len > MAX_FORMAT_INPUT) return "\n(format: the snippet is too large for c3f here)";
	int status = 0;
	bool timed_out = false;
	String? out = proc::run_capped({ bin, "--stdin-filename", "snippet.c3", "-" }, &status, &timed_out, { .max_output = MAX_FORMAT_INPUT * 2, .input = code });
	if (catch out) return "\n(format: c3f could not run)";
	if (timed_out || proc::could_not_start(status)) return "\n(format: c3f did not finish)";
	// c3f says what it could not format as "<stdin>:LINE: ..." lines: they are notes, not code
	DString formatted = dstring::temp();
	DString notes = dstring::temp();
	foreach (line : out.tsplit("\n"))
	{
		if (line.starts_with("<stdin>:")) { notes.appendf("%s\n", line); }
		else { formatted.appendf("%s\n", line); }
	}
	String f = formatted.str_view().trim_right();
	String note = notes.len() > 0 ? string::tformat("\n(c3f: %s)", notes.str_view().trim()) : "";
	if (f.trim() == code.trim()) return string::tformat("\n(format: already formatted)%s", note);
	return string::tformat("\n--- c3f: formatted code ---\n%s%s", f, note);
}

