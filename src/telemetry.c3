module c3guide::telemetry;
import c3guide::util;
import std::io, std::io::file, std::io::path, std::os::env, std::encoding::json, std::collections::object, std::core::string, libc;

// A local usage log for improving the server: one JSON line per tool call, on this machine only, never sent anywhere.
// What is written: the time, the tool, the NAMES of the arguments that were given, the duration, the kind of outcome and
// the size of the reply. What is never written: code, queries, paths, file contents or the reply text (a snippet can hold
// a secret). `scripts/usage_report.py` reads it. Off with C3_GUIDE_LOG=off; C3_GUIDE_LOG=/some/file moves it.

const long MAX_LOG = 1024 * 1024;   // past this size the file moves to <file>.1 (one generation is kept)

// The parameter names of all tools; only these can appear in the log, whatever a client sends.
const String[*] ARG_NAMES = {
	"query", "path", "code", "files", "target", "platform", "scope", "limit", "file", "examples", "source", "filter",
	"args", "input", "opt", "timeout_s", "sanitize", "stdlib", "rename_to", "format"
};

struct Outcome
{
	String kind;      // ok, compile_error, test_failed, not_found, timeout, rejected
	bool hint;        // the reply carried a hint
	bool rewritten;   // old syntax was rewritten
}

// What happened, from the text of the reply. Only fixed words are looked for.
fn Outcome classify(String reply)
{
	Outcome o = { "ok", reply.contains("Hints:"), reply.contains("0.7 syntax found") };
	if (reply.contains("timed out") || reply.contains("deadline")) { o.kind = "timeout"; }
	else if (reply.contains("rejected:") || reply.contains("path must be") || reply.contains("must be one of")) { o.kind = "rejected"; }
	else if (reply.contains("[FAIL]")) { o.kind = "test_failed"; }
	else if (reply.contains("error:")) { o.kind = "compile_error"; }
	else if (reply.contains("does not exist") || reply.contains("no symbol matches") || reply.contains("no declaration")) { o.kind = "not_found"; }
	return o;
}

// Where the log goes, "" when it is off.
fn String log_file()
{
	String? v = env::tget_var("C3_GUIDE_LOG");
	if (try v)
	{
		if (v == "off" || v == "0" || v == "false") return "";
		if (v.len > 0) return v;
	}
	String? state = env::tget_var("XDG_STATE_HOME");
	if (try state) { if (state.len > 0) return string::tformat("%s/c3-guide/usage.jsonl", state); }
	$if env::WIN32:
		String? local = env::tget_var("LOCALAPPDATA");
		if (try local) { if (local.len > 0) return string::tformat("%s/c3-guide/usage.jsonl", local); }
	$endif
	String? home = env::tget_var("HOME");
	if (try home) { if (home.len > 0) return string::tformat("%s/.local/state/c3-guide/usage.jsonl", home); }
	return "";
}

// One line for a `tools/call` request and its response; anything else is not logged. Never fails the caller.
fn void record(String request, String response, long ms)
{
	String file = log_file();
	if (file.len == 0) return;
	String line = line_for(request, response, ms);
	if (line.len == 0) return;
	write_line(file, line);
}

fn String line_for(String request, String response, long ms)
{
	if (!request.contains("\"tools/call\"")) return "";
	Object*? root = json::parse(tmem, request);
	if (catch root) return "";
	Object*? params = root.get("params");
	if (catch params) return "";
	String? tool = params.get_string("name");
	if (catch tool) return "";
	if (tool.len > 40 || !tool.starts_with("c3_")) return "";   // a name a client made up is not logged
	DString d = dstring::temp();
	d.appendf("{\"t\":%d,\"tool\":\"%s\",\"args\":[", (long)libc::time(null), tool);
	Object*? args = params.get("arguments");
	bool first = true;
	if (try args)
	{
		foreach (n : ARG_NAMES)
		{
			if (!args.has_key(n)) continue;
			d.appendf("%s\"%s\"", first ? "" : ",", n);
			first = false;
		}
	}
	Outcome o = classify(response);
	d.appendf("],\"ms\":%d,\"out\":\"%s\",\"hint\":%s,\"rewrite\":%s,\"len\":%d,\"err\":%s}", ms, o.kind, o.hint, o.rewritten, response.len, response.contains("\"isError\":true"));
	return d.str_view();
}

fn void write_line(String file, String line)
{
	String dir = file[:file.rindex_of("/") ?? 0];
	if (dir.len > 0 && !file::is_dir(dir))
	{
		Path? p = path::new(tmem, dir);
		if (catch p) return;
		if (catch path::mkdir(p, recursive: true)) return;
	}
	long? size = file::get_size(file);
	bool created = false;
	if (try size)
	{
		if (size > MAX_LOG)
		{
			String older = string::tformat("%s.1", file);
			(void)file::delete(older);
			libc::rename(file.zstr_tcopy(), older.zstr_tcopy());
			created = true;
		}
	}
	else { created = true; }
	File? f = file::open(file, "a");
	if (catch f) return;
	defer (void)f.close();
	// the log says when and how the tools were used: private to the user, before the first line goes in
	if (created) util::set_mode(file, 0o600);
	(void)f.write(string::tformat("%s\n", line));
}
