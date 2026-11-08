module c3guide::setup;
import c3guide::compiler;
import c3guide::corpus, c3guide::util;
import libc, std::time::clock;
import std::io, std::io::file, std::io::path, std::os::env, std::core::string;

// `c3-guide-mcp --setup` puts the integration in place for Claude Code, `--doctor` says what is and is not in place.
// Both touch only: <config>/CLAUDE.md (one marked block), <config>/hooks/c3-guide-redirect.sh (our own file) and, when
// it does not exist yet, <config>/settings.json. A settings.json that exists is never rewritten (it has the user's
// comments and order): the snippet to merge is printed. A file or directory that is a symlink is refused.

const String CLAUDE_SNIPPET = (String)$embed("../integrations/claude-code/CLAUDE.md");
const String HOOK_SCRIPT = (String)$embed("../integrations/claude-code/redirect-c3c.sh");
const String BEGIN = "<!-- c3-guide:begin (written by c3-guide-mcp --setup; edit outside this block) -->";
const String END = "<!-- c3-guide:end -->";
const String HOOK_NAME = "c3-guide-redirect.sh";
const sz MAX_CONFIG = 1024 * 1024;   // a CLAUDE.md or settings.json larger than this is not ours to rewrite

// ~/.claude, or $CLAUDE_CONFIG_DIR.
fn String config_dir()
{
	String? c = env::tget_var("CLAUDE_CONFIG_DIR");
	if (try c) { if (c.len > 0) return c; }
	String? home = env::tget_var("HOME");
	if (try home) { if (home.len > 0) return string::tformat("%s/.claude", home); }
	return "";
}

// The text of a file: "" when there is none, a fault when it exists but cannot be read or is too large to be ours to edit.
fn String? read_text(String f)
{
	if (!file::is_file(f)) return "";
	long size = file::get_size(f)!;
	if (size > MAX_CONFIG) return UNREADABLE~;
	char[] data = file::load_temp(f)!;
	return (String)data;
}

faultdef UNREADABLE;

fn String read_or_empty(String f) => read_text(f) ?? "";

fn bool is_link(String f)
{
	Path? p = path::new(tmem, f);
	if (catch p) return false;
	return path::is_link(p);
}

// The text of CLAUDE.md with our block set to `block`: replaced in place, else appended. A begin marker without its end
// marker is not ours to guess about: the text is returned unchanged (the caller sees that it did not change).
fn String with_block(String existing, String block)
{
	String body = string::tformat("%s\n%s\n%s", BEGIN, block.trim(), END);
	sz? from = existing.index_of(BEGIN);
	if (try from)
	{
		sz? to = existing[from..].index_of(END);
		if (catch to) return existing;
		return string::tformat("%s%s%s", existing[:from], body, existing[from + to + END.len..]);
	}
	if (existing.trim().len == 0) return string::tformat("%s\n", body);
	return string::tformat("%s\n\n%s\n", existing.trim_right(), body);
}

fn bool block_current(String existing) => existing.contains(BEGIN) && existing == with_block(existing, CLAUDE_SNIPPET);

// `s` as a JSON string literal.
fn String json_string(String s)
{
	DString d = dstring::temp();
	d.append('"');
	foreach (c : s)
	{
		if (c == '"' || c == '\\') { d.append('\\'); d.append(c); }
		else if (c == '\n') { d.append("\\n"); }
		else if (c == '\t') { d.append("\\t"); }
		else if (c < 0x20) { d.appendf("\\u%04x", (int)c); }
		else { d.append(c); }
	}
	d.append('"');
	return d.str_view();
}

// `s` as one shell word: as it is when it is plain, else in single quotes.
fn String shell_word(String s)
{
	bool plain = s.len > 0;
	foreach (c : s) if (!(c.is_alnum() || c == '_' || c == '/' || c == '.' || c == '-' || c == '+' || c == ':')) plain = false;
	if (plain) return s;
	DString d = dstring::temp();
	d.append('\'');
	foreach (c : s)
	{
		if (c == '\'') { d.append("'\\''"); }
		else { d.append(c); }
	}
	d.append('\'');
	return d.str_view();
}

fn String settings_snippet(String hook)
{
	return string::tformat(`{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": %s } ] }
    ]
  }
}
`, json_string(shell_word(hook)));
}

// A new file next to `target`, then a rename over it: a reader never sees half of it.
fn void? save_atomic(String target, String content)
{
	String temp = string::tformat("%s.c3-guide-%d", target, (long)clock::now());
	file::save(temp, content)!;
	if (libc::rename(temp.zstr_tcopy(), target.zstr_tcopy()) != 0)
	{
		(void)file::delete(temp);
		return io::GENERAL_ERROR~;
	}
}

// Writes `content` to `target` unless it is a symlink or equal to what is there. Says what it did.
fn String put(String what, String target, String content, uint mode, bool dry, int* failed)
{
	if (is_link(target)) return string::tformat("  skipped  %s: %s is a symbolic link; edit its target yourself", what, target);
	if (read_or_empty(target) == content && file::is_file(target)) return string::tformat("  ok       %s: already up to date", what);
	if (dry) return string::tformat("  would write %s (%s)", what, target);
	if (catch save_atomic(target, content)) { *failed += 1; return string::tformat("  FAILED   %s: cannot write %s", what, target); }
	util::set_mode(target, mode);
	return string::tformat("  wrote    %s (%s)", what, target);
}

fn String ensure_dir(String dir)
{
	if (is_link(dir)) return string::tformat("%s is a symbolic link", dir);
	if (file::is_dir(dir)) return "";
	Path? p = path::new(tmem, dir);
	if (catch p) return "bad path";
	if (catch path::mkdir(p, recursive: true)) return string::tformat("cannot create %s", dir);
	return "";
}

fn bool registered()
{
	// Claude Code keeps user-scope MCP servers in ~/.claude.json (inside CLAUDE_CONFIG_DIR when that is set)
	String base = env::tget_var("CLAUDE_CONFIG_DIR") ?? "";
	if (base.len == 0) base = env::tget_var("HOME") ?? "";
	String f = string::tformat("%s/.claude.json", base);
	return read_or_empty(f).contains("\"c3-guide\"");
}

fn int run_setup(String exe, bool dry)
{
	String cfg = config_dir();
	if (cfg.len == 0) { io::printn("setup: no HOME and no CLAUDE_CONFIG_DIR; nothing to do"); return 1; }
	io::printfn("%s Claude Code integration in %s", dry ? "Would set up the" : "Setting up the", cfg);
	String bad = dry ? "" : ensure_dir(cfg);
	if (bad.len == 0 && !dry) bad = ensure_dir(string::tformat("%s/hooks", cfg));
	if (bad.len > 0) { io::printfn("setup: %s", bad); return 1; }
	int failed = 0;
	String md_path = string::tformat("%s/CLAUDE.md", cfg);
	String? md = read_text(md_path);
	if (catch md) { io::printfn("  skipped  rules for the assistant: %s is unreadable or larger than 1 MB, left alone", md_path); failed++; }
	else if (md.contains(BEGIN) && !md[md.index_of(BEGIN)!!..].contains(END)) { io::printfn("  skipped  rules for the assistant: %s has the begin marker of our block and no end marker; fix or remove it, then run --setup again", md_path); failed++; }
	else { io::printn(put("rules for the assistant", md_path, with_block(md, CLAUDE_SNIPPET), 0o644, dry, &failed)); }
	String hook = string::tformat("%s/hooks/%s", cfg, HOOK_NAME);
	io::printn(put("hook script", hook, HOOK_SCRIPT, 0o755, dry, &failed));
	String settings = string::tformat("%s/settings.json", cfg);
	if (!file::is_file(settings)) { io::printn(put("hook registration", settings, settings_snippet(hook), 0o644, dry, &failed)); }
	else if (read_or_empty(settings).contains(HOOK_NAME)) { io::printn("  ok       hook registration: settings.json already names the hook"); }
	else { io::printfn("  to do    hook registration: add this to hooks.PreToolUse in %s (it is not rewritten for you):\n%s", settings, settings_snippet(hook)); }
	if (registered()) { io::printn("  ok       MCP server: c3-guide is registered"); }
	else { io::printfn("  to do    MCP server: run  claude mcp add c3-guide --scope user -- %s", shell_word(exe)); }
	io::printn("Restart Claude Code to pick up the changes. `c3-guide-mcp --doctor` shows what is in place.");
	return failed > 0 ? 1 : 0;
}

fn int run_doctor(String exe, String version)
{
	String cfg = config_dir();
	io::printfn("c3-guide-mcp %s  (%s)", version, exe);
	String have = compiler::compiler_version();
	if (have.len == 0) { io::printn("c3c:        NOT FOUND (put c3c on PATH or set C3C)"); }
	else
	{
		io::printfn("c3c:        %s at %s", have, compiler::c3c_binary());
		corpus::load();
		io::printfn("docs:       manual, recipes and release notes from c3c %s%s", corpus::snapshot_version, have != corpus::snapshot_version ? "  (differs from your c3c: replies say so; signatures are read from your c3c)" : "");
	}
	io::printfn("config:     %s", cfg);
	String md = read_or_empty(string::tformat("%s/CLAUDE.md", cfg));
	io::printfn("  rules:    %s", block_current(md) ? "installed" : (md.contains(BEGIN) ? "OUTDATED (run --setup)" : "missing (run --setup)"));
	String script = read_or_empty(string::tformat("%s/hooks/%s", cfg, HOOK_NAME));
	io::printfn("  hook:     %s", script == HOOK_SCRIPT ? "installed" : (script.len > 0 ? "OUTDATED (run --setup)" : "missing (run --setup)"));
	io::printfn("  settings: %s", read_or_empty(string::tformat("%s/settings.json", cfg)).contains(HOOK_NAME) ? "hook registered" : "hook NOT registered (run --setup)");
	io::printfn("  server:   %s", registered() ? "registered with Claude Code" : "NOT registered (claude mcp add c3-guide --scope user -- <this binary>)");
	return 0;
}

// The absolute path of this binary as the user started it.
fn String self_path(String argv0)
{
	if (argv0.contains("/") || argv0.contains("\\"))
	{
		Path? p = path::new(tmem, argv0);
		if (try p) { Path? a = p.absolute(tmem); if (try a) return (String)a; }
		return argv0;
	}
	String? dirs = env::tget_var("PATH");
	if (try dirs) foreach (d : dirs.tsplit(compiler::PATH_SEP)) { String? f = compiler::which(argv0, d); if (try f) return f; }
	return argv0;
}
