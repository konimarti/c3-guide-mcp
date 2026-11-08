module c3guide::outline;
import std::core::string, std::io, std::io::file, std::io::path, std::collections::list, std::sort, std::compression::zip;
import std::encoding::json, std::collections::object;
import c3guide::ts, c3guide::util, c3guide::context, c3guide::check;

const sz MAX_OUTLINE = 6 * 1024;
const sz MAX_SOURCE = 1024 * 1024;   // a bigger .c3 file is generated or hostile: parsing it costs memory in proportion
const sz MAX_FILES = 400;
const sz MAX_CONTEXT_FILES = 60;   // a project's imports are in its first files; reading all of a big one is not worth it
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
		else if (util::is_c3_file(name) || is_archive(name))
		{
			files.push(string::tformat("%s", (String)full));
		}
	}
}

// The declarations of a project directory, a .c3 file, a .c3l library or a directory of libraries (what c3_lookup shows
// for a path without a query).
fn String outline_path(String path, String match = "")
{
	if (path.len == 0 || path.len > 4096) return "give a path: a project directory, a .c3 file or a .c3l library";
	Path? p = path::new(tmem, path);
	if (catch p) return "invalid path";
	Path? abs = p.absolute(tmem);
	if (catch abs) return "invalid path";
	String root = (String)abs;
	DString out = dstring::temp();
	if (!path::is_dir(abs))
	{
		if (!(util::is_c3_file(root) || is_archive(root)) || !file::exists(root)) return "path must be a project directory, a .c3 file or a .c3l library";
		if (util::is_c3_file(root)) context::note_file(root);
		String one = is_archive(root) ? archive_outline(root, root, match) : outline_file(root, root, match);
		return one.len > 0 ? util::clip(one, MAX_OUTLINE) : "no declarations found";
	}
	note_project(root);
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

// The standard library modules a project's own sources import, as context for the searches (a directory with a
// project.json only: a `deps` or library directory is not what the session works on).
fn void note_project(String root) => @pool()
{
	if (!file::exists(string::tformat("%s/project.json", root))) return;
	Path? p = path::new(tmem, root);
	if (catch p) return;
	Path? abs = p.absolute(tmem);
	if (try a = abs) context::note_project_dir((String)a);
	Path base = p;
	if (try src = p.tappend("src")) { if (path::is_dir(src)) base = src; }
	List{String} files;
	files.init(tmem);
	collect(base, &files, 0);
	foreach (i, f : files) { if (i >= MAX_CONTEXT_FILES) break; context::note_file(f); }
}

// The outline of one file or archive appended to `out` (a heap string), false when it does not fit any more.
fn bool append_outline(String f, String shown, String match, DString* out) => @pool()
{
	String part = is_archive(f) ? archive_outline(f, shown, match) : outline_file(f, shown, match);
	if (out.len() + part.len > MAX_OUTLINE) return false;
	out.append(part);
	return true;
}


fn String outline_file(String file_path, String shown, String match = "")
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
		if (e.is_directory || e.is_encrypted || !util::is_c3_file(e.name) || e.uncompressed_size > (long)MAX_SOURCE) continue;
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


// ---------------------------------------------------------------------------------------------------------------
// Looking a name up in the project's own code and its libraries (c3_lookup), and where a name is used (c3_refs).

struct Found
{
	int rank;      // 0: the declared name is the query, 1: it contains it, 2: the query is elsewhere in the declaration
	int seq;
	String file;
	String row;
	String text;
}

// The name a declaration line declares: `HashMap.init` for a method, `Entry` for a struct, `A, B` for faultdef.
// `header` is the declaration as the outline prints it (without the row number and the doc part).
fn String declared_name(String header)
{
	String h = header.trim();
	String[] words = h.tsplit(" ", 3);
	if (words.len < 2) return "";
	String kw = words[0];
	if (kw == "module") return "";
	if (kw == "fn" || kw == "macro")
	{
		sz paren = -1;
		int depth = 0;
		foreach (i, c : h)
		{
			if (c == '{') depth++;
			if (c == '}') depth--;
			if (c == '(' && depth == 0) { paren = i; break; }
		}
		if (paren < 0) return "";
		sz end = paren;
		sz start = end;
		int back = 0;
		while (start > 0)
		{
			char c = h[start - 1];
			if (c == '}') back++;
			if (c == '{') back--;
			if (back == 0 && (c == ' ' || c == '\t')) break;
			start--;
		}
		return h[start:end - start];
	}
	if (kw == "faultdef") return h["faultdef".len..].trim(" ;");
	if (kw == "struct" || kw == "enum" || kw == "bitstruct" || kw == "union" || kw == "alias" || kw == "interface" || kw == "typedef" || kw == "distinct" || kw == "attrdef" || kw == "constdef")
	{
		String rest = h[kw.len..].trim();
		sz stop = rest.len;
		foreach (i, c : rest) if (c == ' ' || c == '{' || c == ':' || c == '(' || c == '=') { stop = i; break; }
		return rest[:stop];
	}
	// const / extern / a global: "const int MAX", "int counter"
	String last = words[0];
	foreach (w : h.tsplit(" ")) if (w.len > 0) last = w;
	return last.trim(" ;");
}

fn String last_part(String name)
{
	String s = name[((name.rindex_of("::") ?? -2) + 2)..];
	return s[((s.rindex_of(".") ?? -1) + 1)..];
}

// 0 = exact, 1 = contained in the declared name, 2 = elsewhere in the line
fn int name_rank(String header, String query)
{
	String q = last_part(query).to_lower_tcopy();
	String full = query[((query.rindex_of("::") ?? -2) + 2)..].to_lower_tcopy();
	foreach (nm : declared_name(header).tsplit(","))
	{
		String n = nm.trim().to_lower_tcopy();
		if (n.len == 0) continue;
		String l = last_part(n);
		bool qualified = full.contains(".");
		if (n == full || (l == q && (!qualified || n.ends_with(full)))) return 0;
	}
	foreach (nm : declared_name(header).tsplit(","))
	{
		if (nm.trim().to_lower_tcopy().contains(q)) return 1;
	}
	return 2;
}

// Collect the declaration lines of an outline text into `acc`. `terms` set: a description (words), else a name.
fn void rank_into(String text, String query, String[] terms, List{Found}* acc)
{
	String file = "";
	foreach (line : text.tsplit("\n"))
	{
		if (line.len == 0) continue;
		if (line[0] != ' ') { file = line; continue; }
		String t = line.trim();
		if (t.len == 0 || t[0] == '(' || t[0] == '[') continue;
		sz sp = t.index_of(" ") ?? t.len;
		String row = t[:sp];
		String rest = t[sp..].trim();
		if (row.len == 0 || row[0] < '0' || row[0] > '9') continue;
		sz doc_at = rest.index_of("  -- ") ?? rest.len;
		String header = rest[:doc_at];
		int rank;
		if (terms.len > 0)
		{
			String low = rest.to_lower_tcopy();
			int hit = 0;
			foreach (w : terms) if (low.contains(w)) hit++;
			int need = terms.len <= 2 ? terms.len : (terms.len * 2 + 2) / 3;
			if (hit < need) continue;
			rank = (int)terms.len - hit;
		}
		else
		{
			rank = name_rank(header, query);
		}
		acc.push({ rank, (int)acc.len(), file, row, rest });
	}
}

// The directories a path stands for: a project is its src/ plus its libraries (dependency-search-paths of project.json,
// else deps/); anything else is the path itself.
fn void scan_roots(String root, List{String}* bases)
{
	String manifest = string::tformat("%s/project.json", root);
	if (!file::exists(manifest))
	{
		bases.push(root);
		return;
	}
	String src = string::tformat("%s/src", root);
	bases.push(file::is_dir(src) ? src : root);
	bool has_deps = false;
	char[]? data = file::load_temp(manifest);
	if (try data)
	{
		Object*? m = json::parse(tmem, (String)data);
		if (try m)
		{
			Object*? paths = m.get("dependency-search-paths");
			if (try paths)
			{
				if (paths.is_array())
				{
					for (sz i = 0; i < paths.get_len(); i++)
					{
						Object* one = paths.get_at(i);
						if (!one.is_string()) continue;
						String d = one.s;
						if (d.len == 0) continue;
						String full = d[0] == '/' ? d : string::tformat("%s/%s", root, d);
						// a project.json can name any directory: read only the project and its sibling folders (libraries next to it)
						String real = util::canonical(full);
						String home = util::canonical(root);
						String parent = home[:home.rindex_of("/") ?? 0];
						if (real.len == 0 || !(util::inside(home, real) || (parent.len > 1 && util::inside(parent, real) && real != "/"))) continue;
						if (file::is_dir(full)) { bases.push(full); has_deps = true; }
					}
				}
			}
		}
	}
	if (!has_deps)
	{
		foreach (name : (String[]){ "deps", "lib" })
		{
			String dir = string::tformat("%s/%s", root, name);
			if (file::is_dir(dir)) bases.push(dir);
		}
	}
}

const int MAX_FOUND = 200;

// Declarations in the project at `root` (a project directory, or any path) that match `query`: a name or a description.
// Best matches first, at most `max` lines of the form "file:row  declaration -- doc". *count gets how many matched.
fn String project_lookup(String root_arg, String query, int max, int* count, String* scope)
{
	String root = root_arg.len > 0 ? root_arg : context::project();
	*count = 0;
	if (root.len == 0) return "";
	Path? p = path::new(tmem, root);
	if (catch p) return "";
	Path? abs = p.absolute(tmem);
	if (catch abs) return "";
	String r = (String)abs;
	if (!file::exists(r)) return "";
	*scope = r;
	String[] terms = {};
	if (query.contains(" "))
	{
		List{String} w;
		w.init(tmem);
		foreach (x : query.to_lower_tcopy().tsplit(" ")) if (x.len >= 3) w.push(x);
		terms = w.array_view();
	}
	String needle = terms.len > 0 ? "" : last_part(query);
	List{Found} acc;
	acc.init(tmem);
	if (!path::is_dir(abs))
	{
		String text = is_archive(r) ? archive_outline(r, r, needle) : outline_file(r, r, needle);
		rank_into(text, query, terms, &acc);
	}
	else
	{
		List{String} bases;
		bases.init(tmem);
		scan_roots(r, &bases);
		int scanned = 0;
		foreach (b : bases)
		{
			List{String} files;
			files.init(tmem);
			Path? bp = path::new(tmem, b);
			if (catch bp) continue;
			collect(bp, &files, 0);
			foreach (f : files)
			{
				if (scanned++ >= (int)MAX_FILES || acc.len() >= MAX_FOUND) break;
				String shown = f.starts_with(r) && f.len > r.len + 1 ? f[r.len + 1..] : f;
				String text = is_archive(f) ? archive_outline(f, shown, needle) : outline_file(f, shown, needle);
				rank_into(text, query, terms, &acc);
			}
		}
	}
	if (acc.len() == 0) return "";
	Found[] sorted = acc.array_view();
	sort::quicksort(sorted, fn int(Found a, Found b) => a.rank != b.rank ? a.rank - b.rank : a.seq - b.seq);
	int best = sorted[0].rank;
	// declarations that merely mention the name in their parameters are shown only when nothing declares it
	DString out = dstring::temp();
	foreach (f : sorted)
	{
		if (terms.len == 0 && best < 2 && f.rank == 2) break;
		(*count)++;
		if (*count <= max) out.appendf("  %s:%s  %s\n", f.file, f.row, util::clip(f.text, 200));
	}
	if (*count > max) out.appendf("  [%d more; give a path to narrow it]\n", *count - max);
	return out.str_view();
}

struct Ref
{
	uint row;
	uint col;   // byte offset in the line
	bool decl;
}

fn bool declares(String parent_type) => parent_type.contains("declaration") || parent_type.contains("definition") || parent_type.contains("header") || parent_type == "enumerator" || parent_type == "struct_member_declaration";

fn void walk_idents(TSNode n, String src, String name, List{Ref}* out, int depth, String parent_type)
{
	String type = ts::type_of(n);
	uint children = ts::ts_node_child_count(n);
	if (children == 0)
	{
		if (type.ends_with("ident") && ts::node_text(src, n) == name)
		{
			TSPoint at = ts::ts_node_start_point(n);
			out.push({ at.row, at.column, declares(parent_type) });
		}
		return;
	}
	if (depth > 300) return;
	for (uint i = 0; i < children; i++) walk_idents(ts::ts_node_child(n, i), src, name, out, depth + 1, type);
}

// The uses of `name` in one source: row, whether it is a declaration.
fn void refs_in(String src, String name, List{Ref}* out)
{
	if (!src.contains(name)) return;
	TSParser* parser = ts::ts_parser_new();
	defer ts::ts_parser_delete(parser);
	if (!ts::ts_parser_set_language(parser, ts::tree_sitter_c3())) return;
	TSTree* tree = ts::ts_parser_parse_string(parser, null, src.ptr, (uint)src.len);
	defer ts::ts_tree_delete(tree);
	walk_idents(ts::ts_tree_root_node(tree), src, name, out, 0, "");
}

struct RefState
{
	DString* out;
	int limit;
	int total;
	int shown;
	int files;
	String rename_to;   // set: the output is the edits that rename the name, nothing is written
	int collisions;     // uses of rename_to that already exist in the files read
	int lines;          // rename: how many lines change
}

// The uses of `name` in one source, appended to the reply as "file (n)" and one line per line that uses it.
fn void refs_emit(RefState* st, String shown_name, String src, String name)
{
	List{Ref} hits;
	hits.init(tmem);
	refs_in(src, name, &hits);
	if (hits.len() == 0) return;
	st.files++;
	String[] lines = src.tsplit("\n");
	if (st.rename_to.len > 0)
	{
		List{Ref} existing;
		existing.init(tmem);
		refs_in(src, st.rename_to, &existing);
		st.collisions += (int)existing.len();
		rename_lines(st, shown_name, lines, &hits, name);
		return;
	}
	int rows = 0;
	foreach (i, h : hits) if (i == 0 || hits[i - 1].row != h.row) rows++;
	if (st.shown < st.limit) st.out.appendf("%s (%d)\n", shown_name, rows);
	uint prev = uint::max;
	foreach (h : hits)
	{
		if (h.row == prev) continue;
		prev = h.row;
		st.total++;
		if (st.shown >= st.limit) continue;
		st.shown++;
		String text = h.row < lines.len ? lines[h.row].trim() : "";
		st.out.appendf("  %d: %s%s\n", (int)h.row + 1, util::clip(util::sanitize_utf8(text), 150), h.decl ? "   [declaration]" : "");
	}
}

// One "- old line / + new line" pair for each line that uses the name; every use on the line is renamed.
fn void rename_lines(RefState* st, String shown_name, String[] lines, List{Ref}* hits, String name)
{
	if (st.shown < st.limit) st.out.appendf("%s\n", shown_name);
	sz i = 0;
	while (i < hits.len())
	{
		uint row = (*hits)[i].row;
		DString fresh = dstring::temp();
		sz at = 0;
		String old = row < lines.len ? lines[row] : "";
		for (; i < hits.len() && (*hits)[i].row == row; i++)
		{
			sz col = (*hits)[i].col;
			if (col < at || col + name.len > old.len || old[col:name.len] != name) continue;
			fresh.append(old[at:col - at]);
			fresh.append(st.rename_to);
			at = col + name.len;
			st.total++;
		}
		fresh.append(old[at..]);
		st.lines++;
		if (st.shown >= st.limit) continue;
		st.shown++;
		st.out.appendf("  %d:\n    - %s\n    + %s\n", (int)row + 1, util::clip(util::sanitize_utf8(old.trim_right()), 160), util::clip(util::sanitize_utf8(fresh.str_view().trim_right()), 160));
	}
}

// The sources inside a library archive, each in its own memory pool.
fn void refs_in_archive(String archive, String shown, String name, RefState* st) => @pool()
{
	long? size = file::get_size(archive);
	if (catch size) return;
	if (size > MAX_ARCHIVE) return;
	ZipArchive? z = zip::open(tmem, archive);
	if (catch z) return;
	defer (void)z.close();
	long used = 0;
	sz entries = z.count();
	for (sz i = 0; i < entries; i++)
	{
		ZipEntry? e = z.stat_at(i);
		if (catch e) continue;
		if (e.is_directory || e.is_encrypted || !util::is_c3_file(e.name) || e.uncompressed_size > (long)MAX_SOURCE) continue;
		used += e.uncompressed_size;
		if (used > MAX_ARCHIVE_BYTES) return;
		refs_entry(&z, &e, shown, name, st);
	}
}

fn void refs_entry(ZipArchive* z, ZipEntry* e, String shown, String name, RefState* st) => @pool()
{
	char[]? data = z.read_file_all(tmem, e.name);
	if (catch data) return;
	refs_emit(st, string::tformat("%s!/%s", shown, util::sanitize_utf8(e.name)), (String)data, name);
}

// Where `query` (an identifier, `Type.name` and `mod::name` search the last part) is used, as the grammar sees it: strings
// and comments are not uses. `root_arg`: the project (default the session's); stdlib: the installed standard library.
fn String refs_reply(String query, String root_arg, bool stdlib, int limit, String rename_to = "")
{
	String name = last_part(query.trim());
	if (name.len == 0) return "give query: the name to find, e.g. 'new_server' or 'HashMap.init'";
	foreach (c : name) if (!util::ident_char(c)) return "query must be one identifier (a name, or Type.name / module::name)";
	if (rename_to.len > 0)
	{
		if (stdlib) return "rename_to edits your own code; stdlib=true only reads the standard library";
		if (rename_to == name) return "rename_to is the name it already has";
		foreach (k, c : rename_to) if (!util::ident_char(c) || (k == 0 && c.is_digit())) return "rename_to must be one identifier";
	}
	List{String} files;
	files.init(tmem);
	String base;
	String label;
	if (stdlib)
	{
		String root = check::stdlib_root();
		if (root.len == 0) return "cannot find the standard library sources of the installed c3c";
		base = string::tformat("%s/lib/std", root);
		label = "the standard library";
	}
	else
	{
		String root = root_arg.len > 0 ? root_arg : context::project();
		if (root.len == 0) return "give path (a project directory), or check one first; stdlib=true searches the standard library";
		Path? p = path::new(tmem, root);
		if (catch p) return "invalid path";
		Path? abs = p.absolute(tmem);
		if (catch abs) return "invalid path";
		base = (String)abs;
		if (!file::exists(base)) return string::tformat("'%s' does not exist", util::clip(root, 100));
		label = base;
	}
	List{String} bases;
	bases.init(tmem);
	if (stdlib || !file::is_dir(base)) { bases.push(base); }
	else { scan_roots(base, &bases); }
	DString out = dstring::temp();
	foreach (b : bases)
	{
		if (!stdlib && !file::is_dir(b))
		{
			files.push(b);
			continue;
		}
		Path? bp = path::new(tmem, b);
		if (catch bp) continue;
		collect(bp, &files, 0);
	}
	RefState st = { .out = &out, .limit = limit, .rename_to = rename_to };
	int archives = 0;
	foreach (f : files)
	{
		String shown_name = f.starts_with(base) && f.len > base.len + 1 ? f[base.len + 1..] : f;
		if (is_archive(f))
		{
			archives++;
			refs_in_archive(f, shown_name, name, &st);
			continue;
		}
		long? size = file::get_size(f);
		if (catch size) continue;
		if (size > (long)MAX_SOURCE) continue;
		char[]? data = file::load_temp(f);
		if (catch data) continue;
		refs_emit(&st, shown_name, (String)data, name);
	}
	int total = st.total;
	int shown = st.shown;
	int file_count = st.files;
	if (total == 0) return string::tformat("'%s' is not used in %s (%d files%s read). It may be spelled differently there: c3_lookup lists declarations that contain it.", name, label, (int)files.len(), archives > 0 ? string::tformat(", %d library archive(s)", archives) : "");
	if (rename_to.len > 0)
	{
		String warn = st.collisions > 0 ? string::tformat("WARNING: '%s' already occurs %d time(s) in these files; check for a clash first.\n", rename_to, st.collisions) : "";
		String archive_note = archives > 0 ? "Uses inside library archives are not editable and are not in this plan.\n" : "";
		String cut = st.lines > shown ? string::tformat("INCOMPLETE: %d of %d changed lines are shown; raise limit (at most 100) or give a narrower path.\n", shown, st.lines) : "";
		return string::tformat("Rename '%s' to '%s': %d edit(s) on %d line(s) in %d file(s) of %s. Nothing is written; make these edits, then c3_check.\n%s%s%s%s", name, rename_to, total, st.lines, file_count, label, cut, warn, archive_note, out.str_view());
	}
	if (total > shown) out.appendf("[%d more uses in this search; raise limit or give a narrower path]\n", total - shown);
	return string::tformat("%d use(s) of '%s' in %d file(s) of %s:\n%s", total, name, file_count, label, out.str_view());
}
