module c3guide::guard;
import c3guide::util;
import std::os::env, std::io::file, std::io::path, std::core::string, std::collections::list, std::collections::object, std::compression::zip, std::encoding::json;

// c3_check promises that nothing is run and nothing is read outside what is being checked. `--trust=none` stops `$exec`,
// but still lets `$embed` read any file the server can read (an `$assert` on one byte of it is enough to read it back).
// So before a project, a file or a `files` entry is compiled, its `$embed`/`$include`/`$exec` are read: one that cannot
// be proven to stay inside the project's tree is refused. A snippet given as `code` may not use them at all (src/check.c3).
//
// The scan fails closed. It reads EVERYTHING under the project (not only what `sources` lists, `.git` included), every
// directory named in project.json as a source or a library path (inside the project or not, each as a tree of its own),
// the contracts of doc comments (code to c3c), and refuses a tree with a symbolic link that leaves the project or ends nowhere (a link whose real path is inside the tree is read where it lies, and a directory link is not entered a second time), one it cannot read, one that is
// too large to check, or a directory library (`*.c3l/`) whose manifest.json is unreadable or names a folder outside it.

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

// True when `src` (a file in `dir`) has a compile-time read that is not a plain literal path ending inside `root`.
// An empty `root` (a file that belongs to no project, so no tree is its own) allows none at all.
fn bool escapes(String src, String dir, String root)
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
		if (root.len == 0 || word == "$exec") return true;
		i = skip_blank_code(src, i, &contracts);
		if (i >= src.len || src[i] != '(') return true;
		i = skip_blank_code(src, i + 1, &contracts);
		if (i >= src.len || (src[i] != '"' && src[i] != '`')) return true;   // the name is computed: it cannot be checked
		sz lit = i;
		i = util::skip_literal(src, i, &plain);
		if (!plain) return true;   // "\x2e\x2e/..." says something else than it shows
		String arg = src[lit + 1:i - lit - 2];
		i = skip_blank_code(src, i, &contracts);
		if (i >= src.len || (src[i] != ')' && src[i] != ',')) return true;   // "a" +++ "b": only a part of the name is seen
		String full = arg.starts_with("/") ? arg : string::tformat("%s/%s", dir, arg);
		String real = util::canonical(full);
		if (real.len == 0) continue;   // it does not exist: the compiler will say so, nothing is read
		if (!util::inside(root, real)) return true;
	}
	return false;
}

// ---- files and trees -------------------------------------------------------------------------------------------------

// "" or the path of `f` when it reads outside `root` (or is too large to read here).
fn String file_escape(String f, String root)
{
	long? size = file::get_size(f);
	if (catch size) return "";
	if (size > MAX_SCAN_FILE) return f;
	char[]? data = file::load_temp(f);
	if (catch data) return "";
	String dir = f[:f.rindex_of("/") ?? 0];
	String canon_root = root.len > 0 ? util::canonical(root) : "";
	if (escapes((String)data, dir, canon_root)) return f;
	// c3c resolves a relative path from the folder the file really lies in: for a link, that is the target's folder
	String real = util::canonical(f);
	String real_dir = real[:real.rindex_of("/") ?? 0];
	if (real.len > 0 && real_dir != dir && escapes((String)data, real_dir, canon_root)) return f;
	return "";
}

struct Scan
{
	int files;
	long bytes;
}

// The sources of a library archive are compiled with the project: an entry that reads outside the tree is refused too.
fn String archive_escape(String archive, String root, Scan* scan) => @pool()
{
	long? size = file::get_size(archive);
	if (catch size) return archive;
	if (size > MAX_SCAN_TOTAL) return archive;
	ZipArchive? z = zip::open(tmem, archive);
	if (catch z) return archive;   // not a zip: nobody can say what c3c does with it
	defer (void)z.close();
	sz entries = z.count();
	for (sz i = 0; i < entries; i++)
	{
		ZipEntry? e = z.stat_at(i);
		if (catch e) return archive;
		if (e.is_directory || !util::is_c3_file(e.name)) continue;
		String shown = string::tformat("%s!/%s", archive, util::sanitize_utf8(e.name));
		if (e.is_encrypted || e.uncompressed_size > MAX_SCAN_FILE) return shown;
		scan.bytes += e.uncompressed_size;
		if (++scan.files > MAX_SCAN_FILES || scan.bytes > MAX_SCAN_TOTAL) return archive;
		char[]? data = z.read_file_all(tmem, e.name);
		if (catch data) return shown;
		if (escapes((String)data, root, root)) return shown;
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
	if (home.len == 0) return dir;
	long? size = file::get_size(manifest);
	if (catch size) return manifest;
	if (size > MAX_SCAN_FILE) return manifest;
	char[]? data = file::load_temp(manifest);
	if (catch data) return manifest;
	Object*? o = json::parse(tmem, (String)data);
	if (catch o) return manifest;
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
		if (!util::inside(home, real)) return manifest;
	}
	return "";
}

// The first offender under `dir` (a tree of its own: `root` is `dir`), "" when every source in it is clean. Nothing is
// skipped (not even `.git`): a manifest can name any folder as a source.
fn String tree_escape(String dir, String root, int depth, Scan* scan)
{
	if (depth > MAX_SCAN_DEPTH) return dir;
	if (dir.ends_with(".c3l"))   // a directory library: its manifest can add sources from elsewhere
	{
		String bad = library_escape(dir);
		if (bad.len > 0) return bad;
	}
	Path? dp = path::new(tmem, dir);
	if (catch dp) return dir;
	PathList? entries = path::ls(tmem, dp, relative: true);
	if (catch entries) return dir;
	foreach (e : entries)
	{
		String name = e.basename();
		Path? full = dp.tappend(name);
		if (catch full) return dir;
		String f = (String)full;
		if (path::is_link(full))
		{
			// c3c follows a link, so it reads whatever the link ends at. Its real path (every link of a chain resolved) must
			// exist and be inside this tree: that place is scanned where it lies, so a directory link is not entered again
			// (no second scan, no loop), and a file link is read below under the link's own name, which c3c goes by.
			$if env::WIN32:
				return f;   // util::canonical cannot resolve a link here, so none can be shown to stay inside
			$endif
			String real = util::canonical(f);
			if (real.len == 0 || !util::inside(root, real)) return f;   // dangling, or it leaves the tree
			if (path::is_dir(full))
			{
				// a directory library is told by its name: `x.c3l -> plain` would skip the manifest check of the target
				if (name.ends_with(".c3l") && !real.ends_with(".c3l")) return f;
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
		if (!archive && !util::is_c3_file(name)) continue;
		if (archive)
		{
			String hit = archive_escape(f, root, scan);
			if (hit.len > 0) return hit;
			continue;
		}
		long? size = file::get_size(f);
		if (catch size) return f;
		scan.bytes += size;
		if (++scan.files > MAX_SCAN_FILES || scan.bytes > MAX_SCAN_TOTAL) return dir;
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
		if ((key == "sources" || key == "dependency-search-paths") && value.is_array())
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

// The first file of the project at `root_arg` that cannot be shown to stay inside its tree, relative to the project when it
// is inside; "" when every source is clean.
fn String project_escape(String root_arg)
{
	String root = util::canonical(root_arg);
	if (root.len == 0) return root_arg;
	Scan scan;
	String hit = tree_escape(root, root, 0, &scan);
	if (hit.len > 0) return hit.starts_with(root) && hit.len > root.len + 1 ? string::tformat("%s", hit[root.len + 1..]) : hit;
	// directories the manifest names: inside the project they were read above, outside they are trees of their own
	char[]? data = file::load_temp(string::tformat("%s/project.json", root));
	if (catch data) return "";
	Object*? manifest = json::parse(tmem, (String)data);
	if (catch manifest) return "project.json";
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
		String out = tree_escape(real, real, 0, &scan);
		if (out.len > 0) return out;
	}
	return "";
}
