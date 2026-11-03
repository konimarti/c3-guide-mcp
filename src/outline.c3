module c3guide::outline;
import mcp, std::core::string, std::io, std::io::file, std::io::path, std::collections::list, std::sort, std::compression::zip;
import c3guide::ts, c3guide::util, c3guide::context;

const sz MAX_OUTLINE = 6 * 1024;
const sz MAX_SOURCE = 1024 * 1024;   // a bigger .c3 file is generated or hostile: parsing it costs memory in proportion
const sz MAX_FILES = 400;
const long MAX_ARCHIVE = 32 * 1024 * 1024;
const long MAX_ARCHIVE_BYTES = 8 * 1024 * 1024;   // all the sources of one archive once inflated: a small .c3l can hold far more

// A top-level declaration the outline lists, by tree-sitter-c3 node type.
const String[*] DECLARATIONS = {
	"module_declaration", "func_definition", "func_declaration", "macro_declaration", "struct_declaration", "enum_declaration",
	"bitstruct_declaration", "alias_declaration", "typedef_declaration", "faultdef_declaration", "attrdef_declaration",
	"interface_declaration", "constdef_declaration", "const_declaration", "global_declaration",
};

fn bool is_declaration(String type)
{
	foreach (d : DECLARATIONS) if (d == type) return true;
	return false;
}

// The first line of a doc comment, without its `<*` / `*>` markers.
fn String doc_line(String text)
{
	foreach (line : text.tsplit("\n"))
	{
		String t = line.trim(" \t\r*<>");
		sz tag = t.index_of(" @") ?? t.len;   // `@param`, `@require`... are the contract, not the summary
		t = t[:tag].trim(" ");
		if (t.len > 0 && !t.starts_with("@")) return util::clip(t, 100);
	}
	return "";
}

// One line per top-level declaration of `source`: "line  header  -- first line of its doc comment".
fn String outline_source(String source, String match = "")
{
	String needle = match.to_lower_tcopy();
	TSParser* parser = ts::ts_parser_new();
	defer ts::ts_parser_delete(parser);
	if (!ts::ts_parser_set_language(parser, ts::tree_sitter_c3())) return "  (tree-sitter: language version mismatch)\n";
	TSTree* tree = ts::ts_parser_parse_string(parser, null, source.ptr, (uint)source.len);
	defer ts::ts_tree_delete(tree);
	TSNode root = ts::ts_tree_root_node(tree);
	DString out = dstring::temp();
	// the grammar is not always as new as the compiler: say so, instead of listing less without a word
	bool partial = ts::ts_node_has_error(root);
	uint count = ts::ts_node_named_child_count(root);
	for (uint i = 0; i < count; i++)
	{
		TSNode d = ts::ts_node_named_child(root, i);
		String type = ts::type_of(d);
		if (!is_declaration(type)) continue;
		uint start = ts::ts_node_start_byte(d);
		uint row = ts::ts_node_start_point(d).row + 1;
		String doc = "";
		if (ts::ts_node_named_child_count(d) > 0)
		{
			TSNode first = ts::ts_node_named_child(d, 0);
			if (ts::type_of(first) == "doc_comment")
			{
				doc = util::sanitize_utf8(doc_line(ts::node_text(source, first)));
				start = ts::ts_node_end_byte(first);
				if (ts::ts_node_named_child_count(d) > 1) row = ts::ts_node_start_point(ts::ts_node_named_child(d, 1)).row + 1;
			}
		}
		TSNode body = ts::ts_node_child_by_field_name(d, "body", 4);
		uint end = ts::ts_node_is_null(body) ? ts::ts_node_end_byte(d) : ts::ts_node_start_byte(body);
		String header = source[start:end - start].trim(" \t\r\n;{");
		if (header.ends_with("=>")) header = header[:header.len - 2].trim_right();   // an expression body: the header stops before it
		// one line: runs of whitespace become a single space
		DString line = dstring::temp();
		bool space = false;
		foreach (c : header)
		{
			if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { space = true; continue; }
			if (space && line.len() > 0) line.append_char(' ');
			space = false;
			line.append_char(c);
		}
		String shown = util::sanitize_utf8(line.str_view());
		// a constant's value is rarely what you are looking for, and can be a page long
		if (type == "const_declaration" || type == "global_declaration") shown = shown[:shown.index_of(" = ") ?? shown.len];
		if (shown.len > 160) shown = string::tformat("%s...", shown[:util::utf8_boundary(shown, 160)]);
		if (needle.len > 0 && !shown.to_lower_tcopy().contains(needle)) continue;
		out.appendf("  %-4d %s", row, shown);
		if (doc.len > 0) out.appendf("  -- %s", doc);
		out.append("\n");
		if (out.len() >= MAX_OUTLINE)   // a generated file can have a hundred thousand declarations
		{
			out.append("  [more declarations not shown; use match to narrow the list]\n");
			break;
		}
	}
	if (partial) out.append("  (the parser did not accept all of this file: the list may be incomplete)\n");
	return out.str_view();
}

// How many .c3 files under `dir` the vendored grammar does not parse cleanly (and the first few names).
// This is what tells you whether the grammar has caught up with a c3c release.
fn int unparsed_files(String dir, DString* names)
{
	List{String} files;
	files.init(tmem);
	Path? p = path::new(tmem, dir);
	if (catch p) return -1;
	collect(p, &files, 0);
	TSParser* parser = ts::ts_parser_new();
	defer ts::ts_parser_delete(parser);
	ts::ts_parser_set_language(parser, ts::tree_sitter_c3());
	int bad = 0;
	foreach (f : files)
	{
		char[]? data = file::load_temp(f);
		if (catch data) continue;
		TSTree* tree = ts::ts_parser_parse_string(parser, null, data.ptr, (uint)data.len);
		defer ts::ts_tree_delete(tree);
		if (!ts::ts_node_has_error(ts::ts_tree_root_node(tree))) continue;
		if (bad++ < 5) names.appendf("  %s\n", f);
	}
	return bad;
}

fn bool is_c3_file(String name) => name.ends_with(".c3") || name.ends_with(".c3i");
fn bool is_archive(String name) => name.ends_with(".c3l");   // a library: a zip file of .c3 sources

// Directories that hold other people's code or build output, not the project's own.
fn bool skipped_dir(String name) => name == "build" || name == "deps" || name == "lib" || name == "vendor" || name.starts_with(".");

fn void collect(Path dir, List{String}* files, int depth)
{
	if (depth > 8) return;
	PathList? entries = path::ls(tmem, dir, no_dirs: false, relative: true);
	if (catch entries) return;
	foreach (e : entries)
	{
		String name = e.basename();
		Path? full = dir.tappend(name);
		if (catch full) continue;
		if (files.len() >= MAX_FILES) return;
		if (path::is_link(full)) continue;   // a link can point back up the tree: the walk would never end
		if (path::is_dir(full))
		{
			if (!skipped_dir(name)) collect(full, files, depth + 1);
		}
		else if (is_c3_file(name) || is_archive(name))
		{
			files.push(string::tformat("%s", (String)full));
		}
	}
}

fn String c3_outline(String path @Desc("a project directory (its src/ is read, or the directory itself), one .c3 file, a library archive (.c3l), or a directory of libraries such as deps"),
	String match @Desc("only declarations whose line contains this text, case-insensitive: finds a function in a library") = "")
	@Desc("The declarations of the project's own code, one line each with file and line: functions and methods with their signatures, structs, enums, macros, faults, constants, and the first line of each doc comment. Use it to see what a project contains before reading files, and to look up a function in its third-party libraries: c3_outline with path 'deps' and match 'curl_easy'. Parsed with the C3 tree-sitter grammar; nothing is compiled or run.")
	@ReadOnly
{
	if (path.len == 0 || path.len > 4096) return "give a project directory or a .c3 file";
	Path? p = path::new(tmem, path);
	if (catch p) return "invalid path";
	Path? abs = p.absolute(tmem);
	if (catch abs) return "invalid path";
	String root = (String)abs;
	DString out = dstring::temp();
	if (!path::is_dir(abs))
	{
		if (!(is_c3_file(root) || is_archive(root)) || !file::exists(root)) return "path must be a project directory, a .c3 file or a .c3l library";
		if (is_c3_file(root)) context::note_file(root);
		String one = is_archive(root) ? archive_outline(root, root, match) : c3_outline_file(root, root, match);
		return one.len > 0 ? util::clip(one, MAX_OUTLINE) : "no declarations found";
	}
	Path base = abs;
	if (try src = abs.tappend("src")) { if (path::is_dir(src)) base = src; }
	List{String} files;
	files.init(tmem);
	collect(base, &files, 0);
	if (files.len() == 0) return "no .c3 files found (looked in src/, skipping build, deps, lib, vendor)";
	String[] sorted = files.array_view();
	sort::quicksort(sorted, fn int(String a, String b) => a.compare_to(b));
	// each file is read and parsed in its own memory pool: a long list of big files must not add up
	DString acc;
	acc.init(mem);
	defer acc.free();
	int unread = 0;
	foreach (i, f : sorted)
	{
		if (acc.len() >= MAX_OUTLINE) { unread = (int)(sorted.len - i); break; }   // parse only what can be shown
		String shown = f.starts_with(root) && f.len > root.len + 1 ? f[root.len + 1..] : f;
		if (!append_outline(f, shown, match, &acc)) { unread = (int)(sorted.len - i); break; }
	}
	if (unread > 0) acc.appendf("[%d more files not shown; give a subdirectory or a file to see them]\n", unread);
	if (files.len() >= MAX_FILES) acc.appendf("[stopped at %d files]\n", (int)MAX_FILES);
	return acc.len() == 0 ? "no declarations found" : string::tformat("%s", acc.str_view());
}

// The outline of one file or archive appended to `out` (a heap string), false when it does not fit any more.
fn bool append_outline(String f, String shown, String match, DString* out) => @pool()
{
	String part = is_archive(f) ? archive_outline(f, shown, match) : c3_outline_file(f, shown, match);
	if (out.len() + part.len > MAX_OUTLINE) return false;
	out.append(part);
	return true;
}


fn String c3_outline_file(String file_path, String shown, String match = "")
{
	long? size = file::get_size(file_path);
	if (catch size) return "";
	if (size > (long)MAX_SOURCE) return string::tformat("%s\n  (skipped: %d KB is more than the %d KB limit)\n", shown, (int)(size / 1024), (int)(MAX_SOURCE / 1024));
	char[]? data = file::load_temp(file_path);
	if (catch data) return "";
	String body = outline_source((String)data, match);
	if (body.len == 0) return "";
	return string::tformat("%s\n%s", shown, body);
}

// The sources inside a library archive (.c3l is a zip file), listed as "archive!/path/in/it".
fn String archive_outline(String archive, String shown, String match)
{
	long? size = file::get_size(archive);
	if (catch size) return "";
	if (size > MAX_ARCHIVE) return string::tformat("%s\n  (skipped: larger than %d MB)\n", shown, (int)(MAX_ARCHIVE / 1024 / 1024));
	ZipArchive? z = zip::open(tmem, archive);
	if (catch z) return "";
	defer (void)z.close();
	DString acc;
	acc.init(mem);
	defer acc.free();
	List{String} seen;   // an entry name can occur twice in a zip, and reading by name finds the first one every time
	seen.init(tmem);
	long used = 0;
	sz read = 0;
	sz entries = z.count();
	for (sz i = 0; i < entries; i++)
	{
		ZipEntry? e = z.stat_at(i);
		if (catch e) continue;
		if (e.is_directory || e.is_encrypted || !is_c3_file(e.name) || e.uncompressed_size > (long)MAX_SOURCE) continue;
		bool dup = false;
		foreach (name : seen) if (name == e.name) dup = true;
		if (dup) continue;
		if (read >= MAX_FILES || acc.len() >= MAX_OUTLINE) { acc.appendf("[%d more entries not read]\n", (int)(entries - i)); break; }
		if (used + e.uncompressed_size > MAX_ARCHIVE_BYTES)
		{
			acc.appendf("[stopped: the sources in this archive are over %d MB]\n", (int)(MAX_ARCHIVE_BYTES / 1024 / 1024));
			break;
		}
		seen.push(e.name);
		read++;
		used += outline_entry(&z, &e, shown, match, &acc);
	}
	return string::tformat("%s", acc.str_view());
}

// One source file of an archive, read and parsed in its own memory pool. Returns the bytes it inflated to.
fn long outline_entry(ZipArchive* z, ZipEntry* e, String shown, String match, DString* out) => @pool()
{
	char[]? data = z.read_file_all(tmem, e.name);
	if (catch data) return 0;
	String body = outline_source((String)data, match);
	if (body.len > 0) out.appendf("%s!/%s\n%s", shown, util::sanitize_utf8(e.name), body);
	return (long)data.len;
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_outline);
}
