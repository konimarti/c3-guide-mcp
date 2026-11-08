module c3guide::guard;
import c3guide::outline, c3guide::util;
import std::io, std::io::file, std::io::path, std::core::string, std::collections::list, std::compression::zip, std::os::env;

// c3_check promises that nothing is run and nothing is read outside what is being checked. `--trust=none` stops `$exec`,
// but still lets `$embed` read any file the server can read, and `$echo` print it into the reply. So before a file of a
// project (or a `files` entry) is compiled, its `$embed`/`$include`/`$exec` are read: one that can reach outside the
// project's own tree is refused. A snippet given as `code` may not use them at all (src/check.c3).

const long MAX_SCAN_FILE = 4 * 1024 * 1024;   // a source larger than this is not read for $embed: it is refused (padding is not a way past)
const long MAX_SCAN_ARCHIVE = 64 * 1024 * 1024;
const String[*] COMPILE_TIME_READS = { "$embed", "$include", "$exec" };

// True when `src` (a file in `dir`) has a compile-time read that can reach outside `root`: a name that is not a literal,
// or a literal that, taken from `dir`, ends outside `root` (an absolute path, `..`, a link that points out).
// An empty `root` (a file that belongs to no project, so no tree is its own) allows none at all.
fn bool escapes(String src, String dir, String root)
{
	foreach (word : COMPILE_TIME_READS)
	{
		sz from = 0;
		while (from < src.len)
		{
			sz at = (src[from..].index_of(word) ?? -1);
			if (at < 0) break;
			sz i = from + at + word.len;
			from = i;
			while (i < src.len && (src[i] == ' ' || src[i] == '\t')) i++;
			if (i >= src.len || src[i] != '(') continue;   // the word in a comment or a name
			if (root.len == 0) return true;
			i++;
			while (i < src.len && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r')) i++;
			if (i >= src.len || src[i] != '"') return true;   // the name is computed: it cannot be checked
			sz end = i + 1;
			while (end < src.len && src[end] != '"' && src[end] != '\n') end++;
			String arg = src[i + 1:end - i - 1];
			if (word == "$exec") return true;
			String full = arg.starts_with("/") ? arg : string::tformat("%s/%s", dir, arg);
			String real = util::canonical(full);
			if (real.len == 0) continue;   // it does not exist: the compiler will say so, nothing is read
			if (!util::inside(root, real)) return true;
		}
	}
	return false;
}

// The first file of the project at `root` (its sources, its libraries, the sources inside library archives) that
// reads outside the project, as a path relative to `root`; "" when none does.
fn String project_escape(String root_arg)
{
	String root = util::canonical(root_arg);
	if (root.len == 0) return "";
	List{String} bases;
	bases.init(tmem);
	outline::scan_roots(root, &bases);
	List{String} files;
	files.init(tmem);
	foreach (b : bases)
	{
		Path? bp = path::new(tmem, b);
		if (catch bp) continue;
		if (!file::is_dir(b)) { files.push(b); continue; }
		outline::collect(bp, &files, 0);
	}
	foreach (f : files)
	{
		String hit = outline::is_archive(f) ? archive_escape(f, root) : file_escape(f, root);
		if (hit.len > 0) return hit.starts_with(root) && hit.len > root.len + 1 ? string::tformat("%s", hit[root.len + 1..]) : hit;
	}
	return "";
}

// "" or the path of `f` when it reads outside `root`. Unreadable and oversized files are left to the compiler's own limits.
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

// The sources inside a library archive are compiled with the project: an entry that reads outside is refused too. The
// archive is the root of its own entries, so only a literal that ends inside the project tree is allowed.
fn String archive_escape(String archive, String root) => @pool()
{
	long? size = file::get_size(archive);
	if (catch size) return "";
	if (size > MAX_SCAN_ARCHIVE) return archive;
	ZipArchive? z = zip::open(tmem, archive);
	if (catch z) return "";
	defer (void)z.close();
	sz entries = z.count();
	long used = 0;
	for (sz i = 0; i < entries; i++)
	{
		ZipEntry? e = z.stat_at(i);
		if (catch e) continue;
		if (e.is_directory || !util::is_c3_file(e.name)) continue;
		if (e.is_encrypted || e.uncompressed_size > MAX_SCAN_FILE) return string::tformat("%s!/%s", archive, util::sanitize_utf8(e.name));
		used += e.uncompressed_size;
		if (used > MAX_SCAN_ARCHIVE) return archive;
		char[]? data = z.read_file_all(tmem, e.name);
		if (catch data) continue;
		// an entry's own directory does not exist on disk: a relative literal is read from the project dir at worst
		if (escapes((String)data, root, root)) return string::tformat("%s!/%s", archive, util::sanitize_utf8(e.name));
	}
	return "";
}
