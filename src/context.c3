module c3guide::context;
import std::core::string, std::io::file;

// What this session is working with: the standard library modules the code it checked imports, and the modules of
// the names it looked up. A search prefers names from those modules (`is_dir` is `std::io::file::is_dir` for code
// that imports std::io::file, `std::io::path::is_dir` for code that imports std::io::path). Nothing is stored on
// disk; the server forgets it when the session ends, and the newest MAX_MODULES modules are all it keeps.

const sz MAX_MODULES = 16;
const sz MAX_NAME = 96;
const sz MAX_SOURCE = 1024 * 1024;
const float BOOST = 1.5f;

struct Slot
{
	char[MAX_NAME] text;
	sz len;
}

Slot[MAX_MODULES] slots;   // newest first
sz count;

fn String name_at(sz i) => (String)slots[i].text[:slots[i].len];

fn void clear() { count = 0; project_len = 0; }

// The project the session works on: the last project directory a tool was given (c3_check, c3_test, c3_run,
// c3_lookup, c3_refs). c3_lookup and c3_refs search it when no path is given.
const sz MAX_PROJECT = 1024;
char[MAX_PROJECT] project_buf;
sz project_len;

fn String project() => (String)project_buf[:project_len];

fn void note_project_dir(String dir)
{
	if (dir.len == 0 || dir.len > MAX_PROJECT) return;
	project_buf[:dir.len] = dir[..];
	project_len = dir.len;
}

// Make the module `name` the newest. Only the standard library matters: the symbols searched are its.
fn void note_module(String name)
{
	name = name.trim(" \t\r;");
	if (!name.starts_with("std::") || name.len > MAX_NAME) return;
	sz at = count;
	for (sz i = 0; i < count; i++) if (name_at(i) == name) { at = i; break; }
	if (at == count)
	{
		if (count == MAX_MODULES) at = --count;
		count++;
	}
	for (sz i = at; i > 0; i--) slots[i] = slots[i - 1];
	slots[0].text[:name.len] = name[..];
	slots[0].len = name.len;
}

// The modules of the `import a::b, c::d;` lines of C3 source.
fn void note_source(String source)
{
	if (source.len > MAX_SOURCE) return;
	foreach (line : source.tsplit("\n"))
	{
		String l = line.trim(" \t\r");
		if (!l.starts_with("import ")) continue;
		l = l["import ".len..];
		l = l[:l.index_of(";") ?? l.len];
		foreach (part : l.tsplit(","))
		{
			String name = part.trim(" \t");
			note_module(name[:name.index_of(" ") ?? name.len]);   // `std::io @public`: the name alone
		}
	}
}

fn void note_file(String path) => @pool()
{
	long? size = file::get_size(path);
	if (catch size) return;
	if (size > MAX_SOURCE) return;
	char[]? data = file::load_temp(path);
	if (try data) note_source((String)data);
}

// The module of a symbol that was looked up: "std::core::string::String.split" -> "std::core::string".
fn void note_symbol(String uid)
{
	sz at = uid.rindex_of("::") ?? -1;
	if (at > 0) note_module(uid[:at]);
}

// How much the context prefers this symbol: those of a module the session works with.
fn float boost(String title)
{
	sz at = title.rindex_of("::") ?? -1;
	if (at <= 0 || count == 0) return 1.0f;
	String owner = title[:at];
	for (sz i = 0; i < count; i++) if (name_at(i) == owner) return BOOST;
	return 1.0f;
}
