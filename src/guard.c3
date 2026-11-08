module c3guide::guard;
import c3guide::util;
import std::io::file, std::io::path, std::core::string, std::collections::list, std::collections::object, std::compression::zip, std::encoding::json;

// c3_check promises that nothing is run and nothing is read outside what is being checked. `--trust=none` stops `$exec`,
// but still lets `$embed` read any file the server can read (an `$assert` on one byte of it is enough to read it back).
// So before a project, a file or a `files` entry is compiled, its `$embed`/`$include`/`$exec` are read: one that cannot
// be proven to stay inside the project's tree is refused. A snippet given as `code` may not use them at all (src/check.c3).
//
// The scan fails closed. It reads EVERYTHING under the project (not only what `sources` lists), every directory named in
// project.json as a source or a library path (inside the project or not, each as a tree of its own), and refuses a tree
// with a symbolic link, one it cannot read, or one that is too large to check.

const long MAX_SCAN_FILE = 4 * 1024 * 1024;        // a source larger than this is refused (padding is not a way past)
const long MAX_SCAN_TOTAL = 128 * 1024 * 1024;
const int MAX_SCAN_FILES = 5000;
const int MAX_SCAN_DEPTH = 40;
const String[*] COMPILE_TIME_READS = { "$embed", "$include", "$exec" };

// ---- the source text -------------------------------------------------------------------------------------------------

// True when `src` (a file in `dir`) has a compile-time read that is not a plain literal path ending inside `root`.
// An empty `root` (a file that belongs to no project, so no tree is its own) allows none at all.
fn bool escapes(String src, String dir, String root)
{
	sz i = 0;
	while (i < src.len)
	{
		i = util::skip_blank(src, i);
		if (i >= src.len) break;
		char c = src[i];
		bool plain;
		if (c == '"' || c == '\'' || c == '`') { i = util::skip_literal(src, i, &plain); continue; }
		if (c != '$') { i++; continue; }
		sz start = i++;
		while (i < src.len && (src[i].is_alnum() || src[i] == '_')) i++;
		String word = src[start:i - start];
		bool watched = false;
		foreach (w : COMPILE_TIME_READS) if (w == word) watched = true;
		if (!watched) continue;
		if (root.len == 0 || word == "$exec") return true;
		i = util::skip_blank(src, i);
		if (i >= src.len || src[i] != '(') return true;
		i = util::skip_blank(src, i + 1);
		if (i >= src.len || (src[i] != '"' && src[i] != '`')) return true;   // the name is computed: it cannot be checked
		sz lit = i;
		i = util::skip_literal(src, i, &plain);
		if (!plain) return true;   // "\x2e\x2e/..." says something else than it shows
		String arg = src[lit + 1:i - lit - 2];
		i = util::skip_blank(src, i);
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
	return escapes((String)data, dir, root.len > 0 ? util::canonical(root) : "") ? f : "";
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

// The first offender under `dir` (a tree of its own: `root` is `dir`), "" when every source in it is clean.
fn String tree_escape(String dir, String root, int depth, Scan* scan)
{
	if (depth > MAX_SCAN_DEPTH) return dir;
	Path? dp = path::new(tmem, dir);
	if (catch dp) return dir;
	PathList? entries = path::ls(tmem, dp, relative: true);
	if (catch entries) return dir;
	foreach (e : entries)
	{
		String name = e.basename();
		if (name == ".git") continue;
		Path? full = dp.tappend(name);
		if (catch full) return dir;
		String f = (String)full;
		if (path::is_link(full)) return f;   // c3c would follow it, to a place this scan did not read
		if (path::is_dir(full))
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
		sz cut = n.index_of_char('*') ?? n.len;
		cut = min(cut, n.index_of_char('?') ?? n.len);
		cut = min(cut, n.index_of_char('[') ?? n.len);
		String prefix = n[:cut];
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
