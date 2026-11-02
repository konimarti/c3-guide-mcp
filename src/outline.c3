module c3guide::outline;
import mcp, std::core::string, std::io, std::io::file, std::io::path, std::collections::list, std::sort;
import c3guide::ts, c3guide::util;

const sz MAX_OUTLINE = 6 * 1024;

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

fn String node_type(TSNode n) => ts::ts_node_type(n).str_view();

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
fn String outline_source(String source)
{
	TSParser* parser = ts::ts_parser_new();
	defer ts::ts_parser_delete(parser);
	if (!ts::ts_parser_set_language(parser, ts::tree_sitter_c3())) return "  (tree-sitter: language version mismatch)\n";
	TSTree* tree = ts::ts_parser_parse_string(parser, null, source.ptr, (uint)source.len);
	defer ts::ts_tree_delete(tree);
	TSNode root = ts::ts_tree_root_node(tree);
	DString out = dstring::temp();
	uint count = ts::ts_node_named_child_count(root);
	for (uint i = 0; i < count; i++)
	{
		TSNode d = ts::ts_node_named_child(root, i);
		String type = node_type(d);
		if (!is_declaration(type)) continue;
		uint start = ts::ts_node_start_byte(d);
		uint row = ts::ts_node_start_point(d).row + 1;
		String doc = "";
		if (ts::ts_node_named_child_count(d) > 0)
		{
			TSNode first = ts::ts_node_named_child(d, 0);
			if (node_type(first) == "doc_comment")
			{
				doc = doc_line(source[ts::ts_node_start_byte(first):ts::ts_node_end_byte(first) - ts::ts_node_start_byte(first)]);
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
		String shown = line.str_view();
		// a constant's value is rarely what you are looking for, and can be a page long
		if (type == "const_declaration" || type == "global_declaration") shown = shown[:shown.index_of(" = ") ?? shown.len];
		if (shown.len > 160) shown = string::tformat("%s...", shown[:util::utf8_boundary(shown, 160)]);
		out.appendf("  %-4d %s", row, shown);
		if (doc.len > 0) out.appendf("  -- %s", doc);
		out.append("\n");
	}
	return out.str_view();
}

fn bool is_c3_file(String name) => name.ends_with(".c3") || name.ends_with(".c3i");

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
		if (path::is_dir(full))
		{
			if (!skipped_dir(name)) collect(full, files, depth + 1);
		}
		else if (is_c3_file(name))
		{
			files.push(string::tformat("%s", (String)full));
		}
	}
}

fn String c3_outline(String path @Desc("a project directory (its src/ is read, or the directory itself) or one .c3 file"))
	@Desc("The declarations of the project's own code, one line each with file and line: functions and methods with their signatures, structs, enums, macros, faults, constants, and the first line of each doc comment. Use it to see what a project contains before reading files. Parsed with the C3 tree-sitter grammar; nothing is compiled or run.")
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
		if (!is_c3_file(root) || !file::exists(root)) return "path must be a project directory or an existing .c3 file";
		String one = c3_outline_file(root, root);
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
	int total = 0;
	int listed = 0;
	foreach (f : sorted)
	{
		String shown = f.starts_with(root) && f.len > root.len + 1 ? f[root.len + 1..] : f;
		String part = c3_outline_file(f, shown);
		if (part.len == 0) continue;
		total++;
		if (out.len() + part.len > MAX_OUTLINE) continue;
		out.append(part);
		listed++;
	}
	if (listed < total) out.appendf("[%d more files with declarations; give a subdirectory or a file to see them]\n", total - listed);
	return out.len() == 0 ? "no declarations found" : out.str_view();
}

fn String c3_outline_file(String file_path, String shown)
{
	char[]? data = file::load_temp(file_path);
	if (catch data) return "";
	String body = outline_source((String)data);
	if (body.len == 0) return "";
	return string::tformat("%s\n%s", shown, body);
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_outline);
}
