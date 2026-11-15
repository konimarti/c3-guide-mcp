module c3guide::doctor;
import c3guide::compiler;
import c3guide::corpus;
import std::io, std::io::file, std::os::env, std::io::path, std::core::string;

// `c3-guide-mcp --doctor` says which AI clients are installed (their config folder exists) and, for each, whether the
// config file has a c3-guide server entry and whether the user-level rules file mentions the c3 tools. It only reads.

const sz MAX_FILE = 32 * 1024 * 1024;   // a bigger file is not read (a config file is far smaller)

enum Platform { LINUX, MACOS, WINDOWS }
enum Client { CLAUDE, CODEX, ANTIGRAVITY, CURSOR, VSCODE, DESKTOP }
enum Base { HOME, APPDATA }

const Platform HOST = env::WIN32 ? WINDOWS : (env::DARWIN ? MACOS : LINUX);

struct Where
{
	Base base;
	String rel;   // below the base, with '/' (turned into '\\' on Windows)
}

struct Spec
{
	String id;
	String title;
	String env_var;         // the client's own override of its config folder; "" when the client has none we can confirm
	Where[3] at;            // per Platform: LINUX, MACOS, WINDOWS
	String rules_file;      // the user-level rules file in the folder; "" when the client has none
	String config_file;     // the MCP config file in the folder
}

// EVERY LOCATION IS HERE. Sources: "doc" = the client's documentation, "readme" = this repository's README (written
// from the client's own instructions), "unconfirmed" = from memory or by analogy, not checked against the client.
//  claude       doc: Claude Code reads $CLAUDE_CONFIG_DIR, else ~/.claude (CLAUDE.md in it, same on every platform). User-scope
//               MCP servers live in .claude.json: in $CLAUDE_CONFIG_DIR when that is set, else ~/.claude.json (see config_path).
//  codex        doc: $CODEX_HOME, else ~/.codex; AGENTS.md and config.toml in it (the same on every platform).
//  antigravity  readme: ~/.gemini/config with mcp_config.json and GEMINI.md; UNCONFIRMED (no documented override variable;
//               some installs use ~/.gemini/antigravity, name that folder with --config).
//  cursor       doc: ~/.cursor/mcp.json (Windows: %USERPROFILE%\.cursor\mcp.json); no user-level rules file in a folder.
//  vscode       UNCONFIRMED: the user profile's mcp.json (VS Code "MCP: Open User Configuration"): Linux ~/.config/Code/User,
//               macOS ~/Library/Application Support/Code/User, Windows %APPDATA%\Code\User. Honours no override variable.
//  desktop      doc: Claude Desktop's claude_desktop_config.json: macOS ~/Library/Application Support/Claude, Windows
//               %APPDATA%\Claude; Linux ~/.config/Claude is UNCONFIRMED (no official Linux build).
// Environment variables other than CLAUDE_CONFIG_DIR and CODEX_HOME are not used: none could be confirmed.
const Spec[6] SPECS = {
	{ "claude", "Claude Code", "CLAUDE_CONFIG_DIR",
	  { { HOME, ".claude" }, { HOME, ".claude" }, { HOME, ".claude" } }, "CLAUDE.md", ".claude.json" },
	{ "codex", "Codex", "CODEX_HOME",
	  { { HOME, ".codex" }, { HOME, ".codex" }, { HOME, ".codex" } }, "AGENTS.md", "config.toml" },
	{ "antigravity", "Antigravity", "",
	  { { HOME, ".gemini/config" }, { HOME, ".gemini/config" }, { HOME, ".gemini/config" } }, "GEMINI.md", "mcp_config.json" },
	{ "cursor", "Cursor", "",
	  { { HOME, ".cursor" }, { HOME, ".cursor" }, { HOME, ".cursor" } }, "", "mcp.json" },
	{ "vscode", "VS Code (Copilot)", "",
	  { { HOME, ".config/Code/User" }, { HOME, "Library/Application Support/Code/User" }, { APPDATA, "Code/User" } }, "", "mcp.json" },
	{ "desktop", "Claude Desktop", "",
	  { { HOME, ".config/Claude" }, { HOME, "Library/Application Support/Claude" }, { APPDATA, "Claude" } }, "", "claude_desktop_config.json" },
};

fn Spec spec_of(Client c) => SPECS[(int)c];

// ---- paths (pure: the platform and the environment are inputs, so every platform can be tested anywhere) ----

fn String sep(Platform p) => p == WINDOWS ? "\\" : "/";

fn String native(Platform p, String rel)
{
	if (p != WINDOWS) return rel;
	DString d = dstring::temp();
	foreach (c : rel) d.append(c == '/' ? '\\' : c);
	return d.str_view();
}

fn String join(Platform p, String a, String b) => string::tformat("%s%s%s", a, sep(p), native(p, b));

// The home folder: HOME; on Windows USERPROFILE, then HOME (a shell like MSYS sets only that), then HOMEDRIVE + HOMEPATH. "" when there is none.
fn String home_of(Platform p, String home, String userprofile, String drive, String hpath)
{
	if (p == WINDOWS)
	{
		if (userprofile.len > 0) return userprofile;
		if (home.len > 0) return home;
		if (drive.len > 0 && hpath.len > 0) return string::tformat("%s%s", drive, hpath);
		return "";
	}
	return home;
}

// %APPDATA% on Windows; its default below the home folder when it is not set.
fn String appdata_of(String appdata, String home)
{
	if (appdata.len > 0) return appdata;
	if (home.len > 0) return string::tformat("%s\\AppData\\Roaming", home);
	return "";
}

// The config folder of a client: the client's own variable (`override`), else the default.
fn String client_dir(Client c, Platform p, String home, String appdata, String override)
{
	if (override.len > 0) return override;
	Where w = spec_of(c).at[(int)p];
	String base = w.base == APPDATA ? appdata_of(appdata, home) : home;
	if (base.len == 0) return "";
	return join(p, base, w.rel);
}

// The MCP config file of a client. Claude Code keeps it beside its folder (~/.claude.json) unless the folder is moved.
fn String config_path(Client c, Platform p, String dir, String home, bool moved)
{
	if (c == CLAUDE && !moved) return home.len > 0 ? join(p, home, ".claude.json") : "";
	return join(p, dir, spec_of(c).config_file);
}

fn String getenv(String name) => env::tget_var(name) ?? "";

struct Place
{
	String dir;
	String rules;    // "" when the client has no user-level rules file
	String config;
}

fn Place place_of(Client c, Platform p, String home, String appdata, String override)
{
	Spec s = spec_of(c);
	Place pl;
	pl.dir = client_dir(c, p, home, appdata, override);
	pl.rules = (pl.dir.len > 0 && s.rules_file.len > 0) ? join(p, pl.dir, s.rules_file) : "";
	pl.config = pl.dir.len > 0 ? config_path(c, p, pl.dir, home, override.len > 0) : "";
	return pl;
}

fn Place place_here(Client c)
{
	String home = home_of(HOST, getenv("HOME"), getenv("USERPROFILE"), getenv("HOMEDRIVE"), getenv("HOMEPATH"));
	String override = spec_of(c).env_var.len > 0 ? getenv(spec_of(c).env_var) : "";
	return place_of(c, HOST, home, getenv("APPDATA"), override);
}

// ---- what the files say (plain text checks) ----

// Is a c3-guide server in the config file? It names it as a JSON key or a TOML table.
fn bool mentions_server(String text) => text.contains("\"c3-guide\"") || text.contains("mcp_servers.c3-guide");

// Do the rules tell the model to use the c3 tools?
fn bool mentions_tools(String text) => text.contains("c3_lookup") || text.contains("c3_check");

// The text of a file, "" when there is none or it cannot be read.
fn String read_or_empty(String f)
{
	if (!file::is_file(f)) return "";
	long size = file::get_size(f) ?? MAX_FILE + 1;
	if (size > MAX_FILE) return "";
	char[]? data = file::load_temp(f);
	if (catch data) return "";
	return (String)data;
}

fn void report_client(Client c)
{
	Spec s = spec_of(c);
	Place pl = place_here(c);
	io::printfn("%s  (%s)", s.title, pl.dir);
	String cfg = read_or_empty(pl.config);
	String state = !file::is_file(pl.config) ? "no such file" : (mentions_server(cfg) ? "c3-guide server present" : "c3-guide server MISSING");
	io::printfn("  config:   %s: %s", pl.config, state);
	if (pl.rules.len == 0) { io::printn("  rules:    project file (see README)"); return; }
	io::printfn("  rules:    %s: %s", pl.rules, mentions_tools(read_or_empty(pl.rules)) ? "rules mention the c3 tools" : "no c3 rules");
}

// Returns 2 for a stray argument (the caller prints the usage).
fn int run_doctor(String exe, String version, String[] args)
{
	if (args.len > 0) return 2;
	io::printfn("c3-guide-mcp %s  (%s)", version, exe);
	String have = compiler::compiler_version();
	if (have.len == 0) { io::printn("c3c:        NOT FOUND (put c3c on PATH or set C3C)"); }
	else
	{
		io::printfn("c3c:        %s at %s", have, compiler::c3c_binary());
		corpus::load();
		io::printfn("docs:       manual, recipes and release notes from c3c %s%s", corpus::snapshot_version, have != corpus::snapshot_version ? "  (differs from your c3c: replies say so; signatures are read from your c3c)" : "");
	}
	DString missing = dstring::temp();
	foreach (i, s : SPECS)
	{
		Client c = (Client)i;
		Place pl = place_here(c);
		if (pl.dir.len > 0 && file::is_dir(pl.dir)) { report_client(c); continue; }
		if (missing.len() > 0) missing.append(", ");
		missing.append(s.title);
	}
	if (missing.len() > 0) io::printfn("not found: %s", missing.str_view());
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
