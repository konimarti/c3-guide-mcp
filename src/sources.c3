module c3guide::sources;
import c3guide::util;
import std::sort, std::core::string, std::io::file, std::io::path, std::collections::list, std::collections::object, std::encoding::json;

// What project.json says a project is made of: the files its `sources` patterns stand for and the libraries it depends on.
// The patterns are expanded the way c3c 0.8.6 expands them (target_expand_source_names and file_add_wildcard_files in
// its src/utils/file_utils.c; the probes are in docs/MAINTAINING.md): this is also what the guard (src/guard.c3) reads, so
// a file c3c compiles is a file the guard sees.
//  - a name that ends in `/*` (or is `*`) stands for the files of that folder, one ending in `/**` (or `**`) for the folder
//    and everything below it; the folder part is used as it is (`./`, `..`, an absolute path, `//` all work)
//  - a name that ends in .c3, .c3t or .c3i (case matters) is a file; a name that is a folder (`src`, `src/`) is a folder
//    with everything below it; anything else (`src/*.c3`, `src/a*`, `src/**/`) c3c refuses: nothing is compiled
//  - in a folder, names that start with `.` are skipped (files and folders), links are followed (`stat`), a folder whose
//    name ends in .c3 is not entered, and only names ending in .c3, .c3t or .c3i are sources
//  - `${NAME}` in a string of project.json is replaced by the environment before it is used: not expanded here

const int MAX_SOURCES = 600;   // a command line must stay within what a process can be started with
const int MAX_DEPTH = 40;
const String[*] C3C_SUFFIXES = { ".c3", ".c3t", ".c3i" };

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

// The strings of every array called one of `keys` anywhere in the manifest (the project and each of its targets: c3c adds a
// target's to the project's, or lets it replace them with `-override`, so all of them together are a superset).
fn void strings_everywhere(Object* o, String[] keys, List{String}* out, int depth)
{
	if (depth > 5 || !o.is_map()) return;
	o.@each_entry(; String key, Object* value)
	{
		bool wanted = false;
		foreach (k : keys) if (k == key) wanted = true;
		if (wanted && value.is_array())
		{
			for (sz i = 0; i < value.get_len(); i++)
			{
				Object* one = value.get_at(i);
				if (one.is_string() && one.s.len > 0) out.push(one.s);
			}
		}
		else { strings_everywhere(value, keys, out, depth + 1); }
	};
}

// True when a key called `key` is in the manifest, at any depth.
fn bool has_key(Object* o, String key, int depth)
{
	if (depth > 5 || !o.is_map()) return false;
	bool found = false;
	o.@each_entry(; String k, Object* value)
	{
		if (k == key || has_key(value, key, depth + 1)) found = true;
	};
	return found;
}

// The JSON object in `file`, or null (missing, too large, not JSON).
fn Object* json_of(String file)
{
	long? size = file::get_size(file);
	if (catch size) return null;
	if (size > 4 * 1024 * 1024) return null;
	char[]? data = file::load_temp(file);
	if (catch data) return null;
	Object*? m = json::parse(tmem, (String)data);
	if (catch m) return null;
	return m.is_map() ? m : null;
}

// The manifest of the project in `root`, or null (missing, too large, not JSON).
fn Object* manifest_of(String root) => json_of(string::tformat("%s/project.json", root));

fn void add_file(String f, List{String}* out)
{
	foreach (x : out) if (x == f) return;   // `src/**` and `src/test/**` name the same file once
	out.push(string::tformat("%s", f));
}

// What c3c takes for a source by its name: .c3, .c3t or .c3i after at least one more character.
fn bool c3c_source_name(String name)
{
	foreach (s : C3C_SUFFIXES) if (name.len >= s.len + 1 && name.ends_with(s)) return true;
	return false;
}

// Adds the sources in `dir` (and below it when `deep`) the way c3c finds them, at most `limit` in all; every folder entered
// goes to `seen` (when given). A link to a folder that holds the walk (a loop) is not entered again: c3c would read its files
// a second time under other names, which adds nothing. `above` is the real paths of the folders being walked. Returns "" or
// why the answer is not exact (more than `limit` files, folders nested too deep).
fn String walk(String dir, bool deep, int depth, List{String}* out, int limit, List{String}* seen, List{String}* above)
{
	if (depth > MAX_DEPTH) return "folders nested deeper than 40 levels";
	Path? dp = path::new(tmem, dir);
	if (catch dp) return "";
	PathList? entries = path::ls(tmem, dp, no_dirs: false, relative: true);
	if (catch entries) return "";   // c3c cannot open it either
	String[] names = mem::talloc_array(String, entries.len());
	foreach (i, e : entries) names[i] = e.basename();
	// a stable order: the same project reads the same on every system
	sort::quicksort(names, fn int(String a, String b) => a.compare_to(b));
	foreach (name : names)
	{
		if (name.len == 0 || name[0] == '.') continue;
		String full = dir.ends_with("/") ? string::tformat("%s%s", dir, name) : string::tformat("%s/%s", dir, name);
		if (c3c_source_name(name))
		{
			if (file::is_dir(full)) continue;   // a folder called x.c3 is not entered
			if (out.len() >= limit) return string::tformat("more than %d sources", limit);
			add_file(full, out);
		}
		else if (deep && file::is_dir(full))
		{
			String real = util::canonical(full);
			bool loop = false;
			foreach (x : above) if (x == real) loop = true;
			if (loop) continue;
			if (seen) seen.push(full);
			above.push(real);
			String why = walk(full, true, depth + 1, out, limit, seen, above);
			above.pop()!!;
			if (why.len > 0) return why;
		}
	}
	return "";
}

// Adds the files one `sources` pattern stands for, for a c3c that runs in `root`. *base is the folder it walks from ("" for a
// file named as it is); `seen` collects the folders below it that were entered. Returns "" or why the guard cannot give the exact files: a form c3c does not expand (it refuses
// the build), `${` (c3c fills it from the environment), too many files. A file or folder that does not exist adds nothing
// (c3c says so).
fn String expand_pattern(String root, String pattern, List{String}* out, int limit, String* base, List{String}* seen = null)
{
	*base = "";
	if (pattern.len == 0) return "an empty pattern";
	if (pattern.contains("$")) return string::tformat("sources pattern '%s' uses $ (c3c fills ${NAME} from the environment)", pattern);
	if (pattern.ends_with(".o") || pattern.ends_with(".obj") || pattern.ends_with(".ll") || pattern.ends_with(".bc")) return "";   // linked, not compiled from text
	sz len = pattern.len;
	String folder = "";
	bool deep = false;
	bool folder_form = false;
	if (pattern[len - 1] == '*')
	{
		if (len == 1 || pattern[len - 2] == '/') { folder = pattern[:len - 1]; folder_form = true; }
		else if (pattern[len - 2] == '*' && (len == 2 || pattern[len - 3] == '/')) { folder = pattern[:len - 2]; deep = true; folder_form = true; }
	}
	else if (c3c_source_name(pattern))
	{
		add_file(pattern.starts_with("/") ? pattern : string::tformat("%s/%s", root, pattern), out);
		return "";
	}
	if (!folder_form)
	{
		String as_is = pattern.starts_with("/") ? pattern : string::tformat("%s/%s", root, pattern);
		if (!file::is_dir(as_is)) return string::tformat("sources pattern '%s' is not a form the guard can expand like c3c (c3c refuses it)", pattern);
		folder = pattern;
		deep = true;
	}
	String full = folder.starts_with("/") ? folder : string::tformat("%s/%s", root, folder);
	*base = full;
	if (!file::is_dir(full)) return "";
	List{String} above;
	above.init(tmem);
	above.push(util::canonical(full));
	return walk(full, deep, 0, out, limit, seen, &above);
}

// The files the project-level `sources` of the project in `root` stand for (absolute, in the order of the patterns, each
// once). `src/**` when the manifest names none. Patterns outside the project (`../shared/**`) count as well. At most
// MAX_SOURCES: a pattern the guard could not expand (see expand_pattern) adds nothing.
fn void project_files(String root, List{String}* out)
{
	Object* m = manifest_of(root);
	List{String} patterns;
	patterns.init(tmem);
	if (m) strings_of(m, "sources", &patterns);
	if (patterns.len() == 0) patterns.push("src/**");
	foreach (p : patterns)
	{
		String base;
		(void)expand_pattern(root, p, out, MAX_SOURCES, &base);
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
