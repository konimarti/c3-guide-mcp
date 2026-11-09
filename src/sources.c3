module c3guide::sources;
import c3guide::util;
import std::sort, std::core::string, std::io::file, std::io::path, std::collections::list, std::collections::object, std::encoding::json;

// What project.json says a project is made of: the files its `sources` patterns stand for and the libraries it depends on.
// c3c expands only a trailing `*` (the files of one folder) or `**` (the folder and everything below it); anything else is
// a file. `./*` is the project's own folder, `**` all of it.

const int MAX_SOURCES = 600;   // a command line must stay within what a process can be started with
const int MAX_DEPTH = 40;

// The strings of the array `key` at the top level of a manifest.
fn void strings_of(Object* m, String key, List{String}* out)
{
	Object*? arr = m.get(key);
	if (catch arr) return;
	if (!arr.is_array()) return;
	for (sz i = 0; i < arr.get_len(); i++)
	{
		Object* one = arr.get_at(i);
		if (one.is_string() && one.s.len > 0) out.push(one.s);
	}
}

// The manifest of the project in `root`, or null (missing, too large, not JSON).
fn Object* manifest_of(String root)
{
	String file = string::tformat("%s/project.json", root);
	long? size = file::get_size(file);
	if (catch size) return null;
	if (size > 4 * 1024 * 1024) return null;
	char[]? data = file::load_temp(file);
	if (catch data) return null;
	Object*? m = json::parse(tmem, (String)data);
	if (catch m) return null;
	return m.is_map() ? m : null;
}

fn void add_file(String f, List{String}* out)
{
	foreach (x : out) if (x == f) return;   // `src/**` and `src/test/**` name the same file once
	out.push(string::tformat("%s", f));
}

fn void add_dir(String dir, bool deep, int depth, List{String}* out)
{
	if (depth > MAX_DEPTH || out.len() >= MAX_SOURCES) return;
	Path? dp = path::new(tmem, dir);
	if (catch dp) return;
	PathList? entries = path::ls(tmem, dp, no_dirs: false, relative: true);
	if (catch entries) return;
	String[] names = mem::talloc_array(String, entries.len());
	foreach (i, e : entries) names[i] = e.basename();
	// a stable order: the same project reads the same on every system
	sort::quicksort(names, fn int(String a, String b) => a.compare_to(b));
	foreach (name : names)
	{
		if (out.len() >= MAX_SOURCES) return;
		String full = string::tformat("%s/%s", dir, name);
		if (file::is_dir(full))
		{
			if (deep && !path::is_link(path::new(tmem, full)!!)) add_dir(full, true, depth + 1, out);
		}
		else if (util::is_c3_file(name))
		{
			add_file(full, out);
		}
	}
}

// The files the project-level `sources` of the project in `root` stand for (absolute, in the order of the patterns, each
// once). `src/**` when the manifest names none. Patterns outside the project (`../shared/**`) count as well.
fn void project_files(String root, List{String}* out)
{
	Object* m = manifest_of(root);
	List{String} patterns;
	patterns.init(tmem);
	if (m) strings_of(m, "sources", &patterns);
	if (patterns.len() == 0) patterns.push("src/**");
	foreach (p : patterns)
	{
		bool deep = p.ends_with("**");
		bool shallow = !deep && p.ends_with("*");
		String base = deep ? p[:p.len - 2] : (shallow ? p[:p.len - 1] : p);
		String full = base.starts_with("/") ? base : string::tformat("%s/%s", root, base);
		if (deep || shallow)
		{
			String dir = util::canonical(full);
			if (dir.len > 0 && file::is_dir(dir)) add_dir(dir, deep, 0, out);
		}
		else
		{
			String f = util::canonical(full);
			if (f.len > 0 && file::is_file(f) && util::is_c3_file(f)) add_file(f, out);
		}
	}
}

// The library folders to give c3c (`--libdir`) and the library names (`--lib`) of the project in `root`: its
// `dependency-search-paths` (else lib and deps, when they exist) that exist, and its `dependencies`.
fn void project_libraries(String root, List{String}* dirs, List{String}* names)
{
	Object* m = manifest_of(root);
	List{String} paths;
	paths.init(tmem);
	if (m) strings_of(m, "dependency-search-paths", &paths);
	if (paths.len() == 0)
	{
		paths.push("lib");
		paths.push("deps");
	}
	foreach (p : paths)
	{
		String full = p.starts_with("/") ? p : string::tformat("%s/%s", root, p);
		String real = util::canonical(full);
		if (real.len > 0 && file::is_dir(real)) dirs.push(real);
	}
	if (m) strings_of(m, "dependencies", names);
}

// True when the text defines a function called `main`: `fn void main(`, `fn int? main (String[] args)`, also with the return
// type and the name on different lines. Comments (line, block, doc) and string literals are not code.
fn bool defines_main(String src)
{
	sz i = 0;
	while (i < src.len)
	{
		i = util::skip_blank(src, i);
		if (i >= src.len) break;
		char c = src[i];
		if (c == '"' || c == '\'' || c == '`')
		{
			bool plain;
			i = util::skip_literal(src, i, &plain);
			continue;
		}
		if (!util::ident_char(c)) { i++; continue; }
		sz start = i;
		while (i < src.len && util::ident_char(src[i])) i++;
		if (src[start:i - start] != "fn" || (start > 0 && src[start - 1] == '.')) continue;
		// the declaration: up to its `(`, the last name before it is the function's
		String last = "";
		int depth = 0;
		sz j = i;
		while (j < src.len)
		{
			j = util::skip_blank(src, j);
			if (j >= src.len) break;
			char d = src[j];
			if (d == '"') break;
			if (d == '{') depth++;
			if (d == '}') { if (--depth < 0) break; }
			if (d == '(' && depth == 0) { if (last == "main") return true; break; }
			if ((d == ';' || d == '=') && depth == 0) break;
			if (util::ident_char(d) || d == '.' || d == ':')
			{
				sz w = j;
				while (j < src.len && (util::ident_char(src[j]) || src[j] == '.' || src[j] == ':')) j++;
				last = src[w:j - w];
				continue;
			}
			j++;
		}
	}
	return false;
}

// The source files of the project that hold a `main`.
fn bool file_defines_main(String f)
{
	long? size = file::get_size(f);
	if (catch size) return false;
	if (size > 4 * 1024 * 1024) return false;
	char[]? data = file::load_temp(f);
	if (catch data) return false;
	return defines_main((String)data);
}
