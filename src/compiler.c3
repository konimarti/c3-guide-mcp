module c3guide::compiler;
import std::core::string, std::io::file, std::io::path, std::os::env;
import c3guide::proc, c3guide::corpus;

// Finding the installed c3c and what it is: where it is, its version, its standard library, and the notes that say
// when the docs and the compiler differ.

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

// A relative path to a program (`C3C=bin/c3c`, a relative PATH entry) is made absolute here: the program is started from
// another directory (proc::run_capped), where it would not be found.
fn String absolute(String binary)
{
	if (!binary.contains("/") || binary.starts_with("/")) return binary;
	Path? p = path::new(tmem, binary);
	if (catch p) return binary;
	Path? a = p.absolute(tmem);
	if (catch a) return binary;
	return (String)a;
}

fn String c3c_binary()
{
	String? v = env::tget_var("C3C");
	if (try v) { if (v.len > 0) return absolute(v); }
	if (found_c3c.len > 0) return found_c3c;
	String? f = find_c3c();
	if (catch f) return EXE;   // not found: let the spawn fail with the usual message (and look again next time)
	String a = absolute(f);
	if (a.len >= c3c_buf.len) return a;
	c3c_buf[:a.len] = a[..];
	found_c3c = (String)c3c_buf[:a.len];
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
	String? out = proc::run_capped(argv, &status, &timed_out, { .deadline_ms = VERSION_MS });
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
