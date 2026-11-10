module c3guide::guard;
import c3guide::util, c3guide::sources;
import std::os::env, std::io::file, std::io::path, std::core::string, std::collections::list, std::collections::object, std::compression::zip, std::encoding::json;

// c3_check promises that nothing is run and nothing is read outside what is being checked. `--trust=none` stops `$exec`,
// but still lets `$embed` read any file the server can read (an `$assert` on one byte of it is enough to read it back).
// So before a project, a file or a `files` entry is compiled, its `$embed`/`$include`/`$exec` are read: one that cannot
// be proven to stay inside the project's tree is refused. A snippet given as `code` may not use them at all (src/check.c3).
//
// A project is read for what c3c compiles, not for what lies in its folder (scratch folders, review fixtures and a copy of
// the standard library in `.work/` are not compiled): the files its `sources` and `test-sources` patterns stand for (the
// project's and every target's, expanded as c3c does: src/sources.c3) and the directory libraries and archives (*.c3l) in
// its `dependency-search-paths`, each with the sources its manifest.json names. Each of those files is read for compile-time
// reads (and its contracts: doc comments are code to c3c), and a link among them that leaves the project or ends nowhere,
// a file that is unreadable or too large to check, or a directory library whose manifest.json is unreadable or names a
// folder outside it is refused. A directory library may be a link only to a directory inside the project.
//
// The scan fails closed: when the project uses something the guard cannot expand exactly like c3c (a pattern form c3c does
// not expand, `${NAME}`, a template, a project.json that is not plain JSON, more files than can be checked), the whole
// tree is read as before (nothing skipped, `.git` included) and the answer says why. The messages name the file, the line
// of an $embed/$include/$exec and the reason ("src/x.c3:12: $embed with a computed path").

const long MAX_SCAN_FILE = 4 * 1024 * 1024;        // a source larger than this is refused (padding is not a way past)
const long MAX_SCAN_TOTAL = 128 * 1024 * 1024;
const int MAX_SCAN_FILES = 5000;
const int MAX_SCAN_DEPTH = 40;
const String[*] COMPILE_TIME_READS = { "$embed", "$include", "$exec" };

// ---- the source text -------------------------------------------------------------------------------------------------
//
// The text is read the way c3c's lexer reads it (src/compiler/lexer.c), not with util::skip_blank, which hints use to
// copy comments as they are. The difference is the doc comment `<* ... *>`: only its description is text. From the first
// line that starts with `@name` (or at once, for `<* @require ...`) c3c lexes the contracts as code, up to `*>`, and
// `@require $embed("...")[0] == 'x'` reads a file. In those lines `//` and `/*` are not comments. And `<<*p` and
// `int[<*>]` hold no doc comment: c3c reads `<<` and `[<` first.

// Past the description of a doc comment whose `<*` ends at `i`: at the first `@name` that starts a line, at `*>`, or at
// the end of the text (c3c's parse_doc_start).
fn sz doc_description(String s, sz i)
{
	bool line_start = true;
	while (i < s.len)
	{
		char c = s[i];
		if (c == '\n') { line_start = true; i++; continue; }
		if (c == ' ' || c == '\t' || c == '\r') { i++; continue; }
		if (c == '*' && i + 1 < s.len && s[i + 1] == '>') return i;
		if (c == '@' && line_start && i + 1 < s.len && s[i + 1] >= 'a' && s[i + 1] <= 'z') return i;
		line_start = false;
		i++;
	}
	return i;
}

// Past whitespace and comments from `i`. A doc comment is skipped up to its contracts, which are code: *contracts says
// that the text from here up to `*>` is contract lines (where nothing is a comment).
fn sz skip_blank_code(String s, sz i, bool* contracts)
{
	while (i < s.len)
	{
		char c = s[i];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { i++; continue; }
		if (*contracts) break;
		if (c == '/' && i + 1 < s.len && s[i + 1] == '/')
		{
			while (i < s.len && s[i] != '\n') i++;
			continue;
		}
		if (c == '/' && i + 1 < s.len && s[i + 1] == '*')
		{
			int depth = 1;
			i += 2;
			while (i < s.len && depth > 0)
			{
				if (s[i] == '/' && i + 1 < s.len && s[i + 1] == '*') { depth++; i += 2; }
				else if (s[i] == '*' && i + 1 < s.len && s[i + 1] == '/') { depth--; i += 2; }
				else { i++; }
			}
			continue;
		}
		if (c == '<' && i + 1 < s.len && s[i + 1] == '*')
		{
			i = doc_description(s, i + 2);
			*contracts = true;   // c3c lexes contracts from here; `*>` (outside a string) ends them
			continue;
		}
		break;
	}
	return i;
}

// One line of a refusal: the file, the line when there is one, the reason.
fn String at(String file, int line, String reason) => line > 0 ? string::tformat("%s:%d: %s", file, line, reason) : string::tformat("%s: %s", file, reason);

fn int line_of(String s, sz at)
{
	int n = 1;
	for (sz i = 0; i < at && i < s.len; i++) if (s[i] == '\n') n++;
	return n;
}

fn String flag(String src, sz at, int* line, String reason)
{
	*line = line_of(src, at);
	return reason;
}

// "" when every compile-time read of `src` (a file in `dir`) is a plain literal path ending inside `root`, else the reason
// the first one that is not is refused (and *line is its line). An empty `root` (a file that belongs to no project, so no
// tree is its own) allows none at all.
fn String escapes(String src, String dir, String root, int* line)
{
	sz i = 0;
	bool contracts = false;
	while (i < src.len)
	{
		i = skip_blank_code(src, i, &contracts);
		if (i >= src.len) break;
		char c = src[i];
		char next = i + 1 < src.len ? src[i + 1] : 0;
		bool plain;
		if (c == '"' || c == '\'' || c == '`') { i = util::skip_literal(src, i, &plain); continue; }
		if (contracts && c == '*' && next == '>') { contracts = false; i += 2; continue; }
		if ((c == '<' || c == '[') && next == '<') { i += 2; continue; }   // `<<` and `[<` are one token: no `<*` in them
		if (c != '$') { i++; continue; }
		sz start = i++;
		while (i < src.len && (src[i].is_alnum() || src[i] == '_')) i++;
		String word = src[start:i - start];
		bool watched = false;
		foreach (w : COMPILE_TIME_READS) if (w == word) watched = true;
		if (!watched) continue;
		if (word == "$exec") return flag(src, start, line, "$exec runs a program");
		if (root.len == 0) return flag(src, start, line, string::tformat("%s in a file that belongs to no project (nothing to stay inside)", word));
		i = skip_blank_code(src, i, &contracts);
		if (i >= src.len || src[i] != '(') return flag(src, start, line, string::tformat("%s without a literal path", word));
		i = skip_blank_code(src, i + 1, &contracts);
		if (i >= src.len || (src[i] != '"' && src[i] != '`')) return flag(src, start, line, string::tformat("%s with a computed path", word));   // the name is computed: it cannot be checked
		sz lit = i;
		i = util::skip_literal(src, i, &plain);
		if (!plain) return flag(src, start, line, string::tformat("%s with a path written with escapes (\\x2e...)", word));   // "\x2e\x2e/..." says something else than it shows
		String arg = src[lit + 1:i - lit - 2];
		i = skip_blank_code(src, i, &contracts);
		if (i >= src.len || (src[i] != ')' && src[i] != ',')) return flag(src, start, line, string::tformat("%s with a path built from parts (+++)", word));   // "a" +++ "b": only a part of the name is seen
		String full = arg.starts_with("/") ? arg : string::tformat("%s/%s", dir, arg);
		String real = util::canonical(full);
		if (real.len == 0) continue;   // it does not exist: the compiler will say so, nothing is read
		if (!util::inside(root, real)) return flag(src, start, line, string::tformat("%s path '%s' leaves the project", word, util::clip(arg, 80)));
	}
	return "";
}

// ---- files and trees -------------------------------------------------------------------------------------------------

// "" or why `f` is refused: it reads outside `root` at compile time, or is too large to read here.
fn String file_escape(String f, String root)
{
	long? size = file::get_size(f);
	if (catch size) return "";
	if (size > MAX_SCAN_FILE) return at(f, 0, "file over 4 MB: too large to check");
	char[]? data = file::load_temp(f);
	if (catch data) return "";
	String dir = f[:f.rindex_of("/") ?? 0];
	String canon_root = root.len > 0 ? util::canonical(root) : "";
	int line = 0;
	String why = escapes((String)data, dir, canon_root, &line);
	if (why.len > 0) return at(f, line, why);
	// c3c resolves a relative path from the folder the file really lies in: for a link, that is the target's folder
	String real = util::canonical(f);
	String real_dir = real[:real.rindex_of("/") ?? 0];
	if (real.len > 0 && real_dir != dir)
	{
		why = escapes((String)data, real_dir, canon_root, &line);
		if (why.len > 0) return at(f, line, string::tformat("%s (a link: read from its target's folder)", why));
	}
	return "";
}

struct Scan
{
	int files;
	long bytes;
}

// The sources of a library archive are compiled with the project: an entry that reads outside the tree is refused too.
fn String archive_escape(String archive, String root, Scan* scan)
{
	long? size = file::get_size(archive);
	if (catch size) return at(archive, 0, "cannot be read");
	if (size > MAX_SCAN_TOTAL) return at(archive, 0, "library archive too large to check");
	ZipArchive? z = zip::open(tmem, archive);
	if (catch z) return at(archive, 0, "library archive is not a zip file");   // nobody can say what c3c does with it
	defer (void)z.close();
	sz entries = z.count();
	for (sz i = 0; i < entries; i++)
	{
		ZipEntry? e = z.stat_at(i);
		if (catch e) return at(archive, 0, "library archive cannot be listed");
		if (e.is_directory || !sources::c3c_source_name(e.name)) continue;
		String shown = string::tformat("%s!/%s", archive, util::sanitize_utf8(e.name));
		if (e.is_encrypted || e.uncompressed_size > MAX_SCAN_FILE) return at(shown, 0, "encrypted or over 4 MB: cannot be checked");
		scan.bytes += e.uncompressed_size;
		if (++scan.files > MAX_SCAN_FILES || scan.bytes > MAX_SCAN_TOTAL) return at(archive, 0, "too many sources to check");
		char[]? data = z.read_file_all(tmem, e.name);
		if (catch data) return at(shown, 0, "cannot be read");
		int line = 0;
		String why = escapes((String)data, root, root, &line);
		if (why.len > 0) return at(shown, line, why);
	}
	return "";
}

// The folder part of a `sources` pattern, before its first wildcard: `src/**` -> `src/`, `**` -> "" (c3c expands only a
// trailing `*` or `**`: `../out*/x` and `dir/e*.c3` are not found by it).
fn String pattern_dir(String n)
{
	sz cut = n.index_of_char('*') ?? n.len;
	cut = min(cut, n.index_of_char('?') ?? n.len);
	cut = min(cut, n.index_of_char('[') ?? n.len);
	return n[:cut];
}

// A directory library (`foo.c3l/`) is compiled from what its manifest.json names, wherever that is: "" when every
// `sources` and `dependency-search-paths` entry stays inside the library's folder, else the manifest (also when it is
// missing, too large or not JSON: nobody can say what c3c would compile).
fn String library_escape(String dir)
{
	String manifest = string::tformat("%s/manifest.json", dir);
	String home = util::canonical(dir);
	if (home.len == 0) return at(dir, 0, "library folder cannot be resolved");
	long? size = file::get_size(manifest);
	if (catch size) return at(manifest, 0, "library without a readable manifest.json (nobody can say what c3c compiles from it)");
	if (size > MAX_SCAN_FILE) return at(manifest, 0, "library manifest over 4 MB: too large to check");
	char[]? data = file::load_temp(manifest);
	if (catch data) return at(manifest, 0, "library manifest cannot be read");
	Object*? o = json::parse(tmem, (String)data);
	if (catch o) return at(manifest, 0, "library manifest is not valid JSON (nobody can say what c3c compiles from it)");
	List{String} names;
	names.init(tmem);
	manifest_paths(o, &names, 0);
	foreach (n : names)
	{
		String prefix = pattern_dir(n);
		if (prefix.len == 0) continue;   // `*` / `**`: the library's own folder
		String full = prefix.starts_with("/") ? prefix : string::tformat("%s/%s", home, prefix);
		String real = util::canonical(full);
		if (real.len == 0) continue;   // c3c cannot open it either: nothing is compiled from it
		if (!util::inside(home, real)) return at(manifest, 0, string::tformat("library manifest names sources outside its library ('%s')", util::clip(n, 80)));
	}
	return "";
}

// The first offender under `dir` (a tree of its own: `root` is `dir`), "" when every source in it is clean. Nothing is
// skipped (not even `.git`): a manifest can name any folder as a source.
fn String tree_escape(String dir, String root, int depth, Scan* scan)
{
	if (depth > MAX_SCAN_DEPTH) return at(dir, 0, "folders nested deeper than 40 levels");
	if (dir.ends_with(".c3l"))   // a directory library: its manifest can add sources from elsewhere
	{
		String bad = library_escape(dir);
		if (bad.len > 0) return bad;
	}
	Path? dp = path::new(tmem, dir);
	if (catch dp) return at(dir, 0, "cannot be read");
	PathList? entries = path::ls(tmem, dp, relative: true);
	if (catch entries) return at(dir, 0, "folder cannot be read");
	foreach (e : entries)
	{
		String name = e.basename();
		Path? full = dp.tappend(name);
		if (catch full) return at(dir, 0, "cannot be read");
		String f = (String)full;
		if (path::is_link(full))
		{
			// c3c follows a link, so it reads whatever the link ends at. Its real path (every link of a chain resolved) must
			// exist and be inside this tree: that place is scanned where it lies, so a directory link is not entered again
			// (no second scan, no loop), and a file link is read below under the link's own name, which c3c goes by.
			$if env::WIN32:
				return at(f, 0, "link that cannot be shown to stay inside the project on this system");
			$endif
			String real = util::canonical(f);
			if (real.len == 0) return at(f, 0, "link that ends nowhere");
			if (!util::inside(root, real)) return at(f, 0, "link leaves the project");
			if (path::is_dir(full))
			{
				// a directory library is told by its name: `x.c3l -> plain` would skip the manifest check of the target
				if (name.ends_with(".c3l") && !real.ends_with(".c3l")) return at(f, 0, "library link to a folder that is not named .c3l (its manifest.json would not be read)");
				continue;
			}
		}
		else if (path::is_dir(full))
		{
			String hit = tree_escape(f, root, depth + 1, scan);
			if (hit.len > 0) return hit;
			continue;
		}
		bool archive = f.ends_with(".c3l");
		if (!archive && !sources::c3c_source_name(name)) continue;
		if (archive)
		{
			String hit = archive_escape(f, root, scan);
			if (hit.len > 0) return hit;
			continue;
		}
		long? size = file::get_size(f);
		if (catch size) return at(f, 0, "cannot be read");
		scan.bytes += size;
		if (++scan.files > MAX_SCAN_FILES || scan.bytes > MAX_SCAN_TOTAL) return at(dir, 0, "too many sources to check (over 5000 files or 128 MB)");
		String hit = file_escape(f, root);
		if (hit.len > 0) return hit;
	}
	return "";
}

// Every string of the arrays `sources` and `dependency-search-paths` in project.json, in the project and in its targets.
fn void manifest_paths(Object* o, List{String}* out, int depth)
{
	if (depth > 4 || !o.is_map()) return;
	o.@each_entry(; String key, Object* value)
	{
		if ((key == "sources" || key == "sources-override" || key == "dependency-search-paths" || key == "dependency-search-paths-override") && value.is_array())
		{
			for (sz i = 0; i < value.get_len(); i++)
			{
				Object* one = value.get_at(i);
				if (one.is_string()) out.push(one.s);
			}
		}
		else { manifest_paths(value, out, depth + 1); }
	};
}

// What the whole tree of the project at `root` holds: every source below it, then the folders its project.json names
// (inside the project they were read above, outside they are trees of their own). "" or the first offender.
fn String whole_tree_escape(String root, Scan* scan)
{
	String hit = tree_escape(root, root, 0, scan);
	if (hit.len > 0) return hit;
	char[]? data = file::load_temp(string::tformat("%s/project.json", root));
	if (catch data) return "";
	Object*? manifest = json::parse(tmem, (String)data);
	if (catch manifest) return at(string::tformat("%s/project.json", root), 0, "not plain JSON: the guard cannot tell what c3c reads");
	List{String} names;
	names.init(tmem);
	manifest_paths(manifest, &names, 0);
	foreach (n : names)
	{
		String prefix = pattern_dir(n);
		if (prefix.len == 0) continue;
		String full = prefix.starts_with("/") ? prefix : string::tformat("%s/%s", root, prefix);
		String real = util::canonical(full);
		if (real.len == 0 || util::inside(root, real)) continue;
		if (file::is_file(real))   // a single source outside the project
		{
			String one = file_escape(real, real[:real.rindex_of("/") ?? 0]);
			if (one.len > 0) return one;
			continue;
		}
		if (!file::is_dir(real)) continue;
		String out = tree_escape(real, real, 0, scan);
		if (out.len > 0) return out;
	}
	return "";
}

// True when a component of the path is `..`.
fn bool has_dotdot(String p)
{
	foreach (part : p.tsplit("/")) if (part == "..") return true;
	return false;
}

fn bool is_symlink(String f)
{
	Path? p = path::new(tmem, f);
	if (catch p) return false;
	return path::is_link(p);
}

// Reads the files the patterns stand for (c3c runs in `cwd`, `home` is the tree whose `$embed`s are allowed; a pattern that
// names a folder outside it makes that folder a tree of its own). "" or the first offender; *unsure is set (and "" returned)
// when a pattern cannot be expanded exactly.
fn String scan_patterns(String cwd, String home, List{String} patterns, Scan* scan, String* unsure)
{
	foreach (pattern : patterns)
	{
		List{String} files;
		files.init(tmem);
		String base;
		List{String} entered;
		entered.init(tmem);
		String why = sources::expand_pattern(cwd, pattern, &files, MAX_SCAN_FILES, &base, &entered);
		if (why.len > 0) { *unsure = why; return ""; }
		String tree = home;
		// a pattern that stays inside by its spelling (not absolute, no `..`) is the project's own: where it really ends must be
		// inside too (a link out is refused, never made a tree of its own). One that is spelled to leave (`../shared/**`, an
		// absolute path) names a tree of its own.
		bool spelled_inside = !pattern.starts_with("/") && !has_dotdot(pattern);
		if (base.len > 0)
		{
			String real_base = util::canonical(base);
			String shown_base = base.ends_with("/") ? base[:base.len - 1] : base;
			if (real_base.len == 0 && is_symlink(shown_base)) return at(shown_base, 0, "link that ends nowhere");
			if (real_base.len > 0 && !util::inside(home, real_base))
			{
				if (spelled_inside) return at(shown_base, 0, "link leaves the project");
				tree = real_base;
			}
		}
		// a link to a folder is followed by c3c: where it ends must be inside the tree, even if only data lies there now
		foreach (d : entered)
		{
			$if env::WIN32:
				if (is_symlink(d)) return at(d, 0, "link that cannot be shown to stay inside the project on this system");   // util::canonical cannot resolve a link here
			$endif
			String real_dir = util::canonical(d);
			if (real_dir.len > 0 && !util::inside(tree, real_dir)) return at(d, 0, "link leaves the project");
		}
		foreach (f : files)
		{
			$if env::WIN32:
				if (is_symlink(f)) return at(f, 0, "link that cannot be shown to stay inside the project on this system");
			$endif
			String real = util::canonical(f);
			String one_tree = tree;
			if (base.len == 0)
			{
				// a file named as it is: one that is spelled to leave the project is a source of its own (read in its own folder)
				if (real.len == 0)
				{
					if (is_symlink(f)) return at(f, 0, "link that ends nowhere");
					continue;   // it does not exist: c3c says so
				}
				if (!util::inside(home, real))
				{
					if (spelled_inside) return at(f, 0, "link leaves the project");
					one_tree = real[:real.rindex_of("/") ?? 0];
				}
			}
			else if (real.len == 0)
			{
				if (is_symlink(f)) return at(f, 0, "link that ends nowhere");
				continue;
			}
			else if (!util::inside(tree, real)) { return at(f, 0, "link leaves the project"); }
			long? size = file::get_size(f);
			if (catch size) continue;
			scan.bytes += size;
			if (++scan.files > MAX_SCAN_FILES || scan.bytes > MAX_SCAN_TOTAL) return at(f, 0, "too many sources to check (over 5000 files or 128 MB)");
			String hit = file_escape(f, one_tree);
			if (hit.len > 0) return hit;
		}
	}
	return "";
}

// The libraries c3c can find in `dirs` (the *.c3l directly in each): a directory with its manifest.json and the sources
// that names, or an archive. Every one is read, not only those `dependencies` names (a library is found by what its manifest
// says it provides, and it may bring others).
fn String scan_libraries(String root, List{String} dirs, Scan* scan, String* unsure)
{
	foreach (d : dirs)
	{
		String full = d.starts_with("/") ? d : string::tformat("%s/%s", root, d);
		String real = util::canonical(full);
		if (real.len == 0 || !file::is_dir(real)) continue;
		String tree = util::inside(root, real) ? root : real;
		Path? dp = path::new(tmem, real);
		if (catch dp) return at(real, 0, "cannot be read");
		PathList? entries = path::ls(tmem, dp, relative: true);
		if (catch entries) return at(real, 0, "folder cannot be read");
		foreach (e : entries)
		{
			String name = e.basename();
			if (name.len < 5 || name[0] == '.' || !name.ends_with(".c3l")) continue;
			String lib = string::tformat("%s/%s", real, name);
			if (is_symlink(lib))
			{
				$if env::WIN32:
					return at(lib, 0, "link that cannot be shown to stay inside the project on this system");
				$endif
				String target = util::canonical(lib);
				if (target.len == 0) return at(lib, 0, "link that ends nowhere");
				if (!util::inside(tree, target)) return at(lib, 0, "link leaves the project");
				if (file::is_dir(target) && !target.ends_with(".c3l")) return at(lib, 0, "library link to a folder that is not named .c3l (its manifest.json would not be read)");
			}
			if (!file::is_dir(lib))
			{
				String hit = archive_escape(lib, tree, scan);
				if (hit.len > 0) return hit;
				continue;
			}
			String bad = library_escape(lib);
			if (bad.len > 0) return bad;
			Object* m = sources::json_of(string::tformat("%s/manifest.json", lib));
			List{String} patterns;
			patterns.init(tmem);
			if (m) sources::strings_everywhere(m, { "sources", "sources-override" }, &patterns, 0);
			patterns.push("*");   // a target without `sources` takes the files of the library's own folder
			String inner_unsure = "";
			String hit = scan_patterns(lib, tree, patterns, scan, &inner_unsure);
			if (hit.len > 0) return hit;
			if (inner_unsure.len > 0)
			{
				*unsure = string::tformat("%s (in library %s)", inner_unsure, name);
				return "";
			}
		}
	}
	return "";
}

// What would make an exact scan impossible: "" or the reason.
fn String inexact_because(Object* manifest, List{String} patterns)
{
	if (!manifest) return "project.json is not plain JSON the guard can read";
	if (sources::has_key(manifest, "template", 0)) return "a target uses a template (a library supplies settings the guard cannot see)";
	foreach (p : patterns) if (p.contains("$")) return string::tformat("pattern '%s' uses $ (c3c fills ${NAME} from the environment)", p);
	return "";
}

// The first file of the project at `root_arg` that cannot be shown to stay inside its tree, as one line ("src/a.c3:12:
// $embed with a computed path"; the file relative to the project when it is inside); "" when everything c3c compiles is
// clean. *note is "" or says that the whole tree was read, and why.
fn String project_escape_note(String root_arg, String* note)
{
	*note = "";
	String root = util::canonical(root_arg);
	if (root.len == 0) return at(root_arg, 0, "cannot be resolved");
	Scan scan;
	String hit = "";
	Object* m = sources::manifest_of(root);
	List{String} patterns;
	patterns.init(tmem);
	List{String} lib_dirs;
	lib_dirs.init(tmem);
	String why = "";
	if (m)
	{
		sources::strings_everywhere(m, { "sources", "sources-override", "test-sources", "test-sources-override" }, &patterns, 0);
		sources::strings_everywhere(m, { "dependency-search-paths", "dependency-search-paths-override" }, &lib_dirs, 0);
		List{String} top;
		top.init(tmem);
		sources::strings_of(m, "sources", &top);
		if (top.len() == 0) patterns.push("src/**");   // what a snippet checked with the project compiles
	}
	why = inexact_because(m, patterns);
	if (why.len == 0) why = inexact_because(m, lib_dirs);
	if (why.len == 0)
	{
		hit = scan_patterns(root, root, patterns, &scan, &why);
		if (hit.len == 0 && why.len == 0)
		{
			// the folders code + path gives c3c (sources::project_libraries: the top level's, else lib and deps) and the project's own folder
			// (any target without search paths of its own searches `.`) are read as well: the key can be in a target, or `-override`n empty
			lib_dirs.push(".");
			lib_dirs.push("lib");
			lib_dirs.push("deps");
			hit = scan_libraries(root, lib_dirs, &scan, &why);
		}
	}
	if (hit.len == 0 && why.len > 0)
	{
		*note = string::tformat("(scanned the whole tree because %s)", why);
		Scan again;
		hit = whole_tree_escape(root, &again);
	}
	if (hit.len > root.len + 1 && hit.starts_with(root) && hit[root.len] == '/') return string::tformat("%s", hit[root.len + 1..]);
	return hit;
}

// The same without the note, for a caller that only needs to know.
fn String project_escape(String root_arg)
{
	String note;
	return project_escape_note(root_arg, &note);
}
