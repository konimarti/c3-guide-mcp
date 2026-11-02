module c3guide::live;
import std::core::string, std::collections::list, std::collections::object, std::encoding::json, std::io::file, std::io::path;
import c3guide::corpus, c3guide::check;

// The standard library part of the docs, read from the c3c the user actually runs. The snapshot in the binary
// belongs to one release; when the compiler is another one, the signatures are what would differ, so they are
// taken from `c3c docgen` (about 0.2 s, once at startup). The manual and the release notes stay as they are.
// This is a port of `symbols()` in scripts/gen_corpus.py: for the pinned compiler the two must give the same text
// (test/live_test.c3 checks it).

faultdef NO_STDLIB;

const sz MAX_DOCGEN = 24 * 1024 * 1024;
const ulong DOCGEN_MS = 20000;

struct Kind
{
	String key;
	String code;
}

const Kind[*] KINDS = {
	{ "functions", "fn" }, { "methods", "method" }, { "macros", "macro" },
	{ "macro_methods", "mmethod" }, { "types", "type" }, { "variables", "var" },
};

// Runs of whitespace become one space; nothing at either end.
fn String collapse(String s)
{
	DString out = dstring::temp();
	bool space = false;
	foreach (c : s)
	{
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { space = true; continue; }
		if (space && out.len() > 0) out.append_char(' ');
		space = false;
		out.append_char(c);
	}
	return out.str_view();
}

// A string, number or boolean of the JSON object as text; "" when it is absent or something else.
fn String scalar(Object* o)
{
	if (o.is_string()) return o.s;
	if (o.is_int()) return string::tformat("%d", (long)o.i);
	if (o.is_float()) return string::tformat("%g", o.f);
	if (o.is_bool()) return o.b ? "true" : "false";
	return "";
}

fn String text(Object* o, String key)
{
	if (!o.is_map()) return "";   // the contracts of Object.get are off in a release build: a wrong shape must not reach it
	Object*? v = o.get(key);
	if (catch v) return "";
	return scalar(v);
}

// The object under `key`, or the empty object when there is none (JSON `null` included).
fn Object* child(Object* o, String key)
{
	if (!o.is_map()) return object::new_obj(tmem);
	Object*? v = o.get(key);
	if (catch v) return object::new_obj(tmem);
	return v.is_map() ? v : object::new_obj(tmem);
}

// The value under `key` of any kind, or the empty object when absent. Only a map has keys.
fn Object* child_any(Object* o, String key)
{
	if (!o.is_map()) return object::new_obj(tmem);
	Object*? v = o.get(key);
	if (catch v) return object::new_obj(tmem);
	return v;
}

// "fn String tformat(String fmt, any... args)": the signature line of a function, macro, constant or type.
fn String signature(Object* it)
{
	String kind = text(it, "kind");
	String name = text(it, "name");
	String gen = "";
	Object* gp = child_any(it, "generic_parameters");
	if (gp.is_array() && gp.get_len() > 0)
	{
		DString g = dstring::temp();
		g.append_char('{');
		for (sz i = 0; i < gp.get_len(); i++)
		{
			Object* p = gp.get_at(i);
			if (i > 0) g.append(", ");
			String n = p.is_string() ? p.s : text(p, "name");
			g.append(n.len > 0 ? n : "?");
		}
		g.append_char('}');
		gen = g.str_view();
	}
	String ret = text(child(it, "return_type"), "name");
	DString params = dstring::temp();
	Object* members = child_any(it, "members");
	if (members.is_array())
	{
		for (sz i = 0; i < members.get_len(); i++)
		{
			Object* m = members.get_at(i);
			String t = text(child(m, "type"), "name");
			String n = text(m, "name");
			DString one = dstring::temp();
			if (m.has_key("is_ref") && text(m, "is_ref") == "true") one.append("&");
			String joined = t.len > 0 && n.len > 0 ? string::tformat("%s %s", t, n) : (t.len > 0 ? t : n);
			one.append(joined);
			if (m.has_key("default_value")) one.appendf(" = %s", text(m, "default_value"));
			if (i > 0) params.append(", ");
			params.append(one.str_view());
		}
	}
	if (kind == "function" || kind == "method") return collapse_double(string::tformat("fn %s %s%s(%s)", ret, name, gen, params.str_view()));
	if (kind == "macro" || kind == "macro_method") return collapse_double(string::tformat("macro %s %s%s(%s)", ret, name, gen, params.str_view()));
	if (kind == "constant" || kind == "variable")
	{
		String v = it.has_key("value") ? string::tformat(" = %s", text(it, "value")) : "";
		return string::tformat("%s %s%s", text(child(it, "type"), "name"), name, v).trim();
	}
	String mem = params.str_view();
	return string::tformat("%s %s%s%s", kind, name, gen, (mem.len > 0 && mem.len < 300) ? string::tformat(" { %s }", mem) : "");
}

// The generator writes `fn  name` when the return type is empty and then replaces the doubled space.
fn String collapse_double(String s)
{
	DString out = dstring::temp();
	bool prev_space = false;
	foreach (c : s)
	{
		if (c == ' ' && prev_space) continue;
		prev_space = c == ' ';
		out.append_char(c);
	}
	return out.str_view();
}

// The doc comment of a symbol as one line, with its @param and @return parts.
fn String doc_text(Object* it)
{
	Object* d = child(it, "docs");
	DString doc = dstring::temp();
	doc.append(collapse(text(d, "text")));
	Object* params = child_any(d, "params");
	if (params.is_array())
	{
		for (sz i = 0; i < params.get_len(); i++)
		{
			Object* p = params.get_at(i);
			String desc = collapse(text(p, "description"));
			if (desc.len > 0) doc.appendf(" @param %s: %s", text(p, "name"), desc);
		}
	}
	String ret = text(d, "return");
	if (ret.len > 0) doc.appendf(" @return %s", collapse(ret));
	String dep = text(d, "deprecated");
	if (dep.len > 0) doc.appendf(" DEPRECATED: %s", dep);
	return collapse(doc.str_view());
}

// Heap copies: these entries live as long as the server does.
fn Entry make_entry(String kind, String title, String body, String loc)
{
	return { kind.copy(mem), title.copy(mem), body.copy(mem), loc.copy(mem) };
}

// The public symbols of one module of the docgen output, appended to `out`.
fn void add_module(Object* mod, String root, String cwd, List{Entry}* out)
{
	foreach (k : KINDS)
	{
		Object* items = child_any(mod, k.key);
		if (!items.is_array()) continue;
		for (sz i = 0; i < items.get_len(); i++)
		{
			Object* it = items.get_at(i);
			if (!it.is_map()) continue;
			String vis = text(it, "visibility");
			if (vis == "private" || vis == "local") continue;
			String doc = doc_text(it);
			String body = doc.len > 0 ? string::tformat("%s\n%s", signature(it), doc) : signature(it);
			// `env::PROJECT_PATH` evaluates to the directory docgen ran in: keep that machine's path out of the answers
			if (cwd.len > 1) body = check::redact(body, cwd, "<project>");
			String file = text(it, "file");
			if (root.len > 0 && file.starts_with(root)) file = file[root.len..];
			out.push(make_entry(k.code, text(it, "uid"), body, file));
		}
	}
}

// The symbol entries of a docgen JSON text. `root` is the install directory with a trailing '/', cut from file paths.
fn Entry[]? entries_from_json(String json_text, String root)
{
	Object* dg = json::parse(tmem, json_text)!;
	Object* modules = child(dg, "modules");
	List{Entry} out;
	out.init(mem);
	String cwd = "";
	if (try here = path::tcwd()) cwd = (String)here;
	modules.@each_entry(; String key, Object* mod)
	{
		add_module(mod, root, cwd, &out);
	};
	return out.array_view();
}

// Where the standard library sources are: <install>/lib/std, or <install>/../lib/std for a build tree. "" if neither.
fn String stdlib_dir(String install)
{
	String a = string::tformat("%s/lib/std", install);
	if (file::exists(a)) return a;
	String b = string::tformat("%s/../lib/std", install);
	return file::exists(b) ? b : "";
}

// Replace the snapshot's standard library symbols with the ones of the c3c in use, when that is another release.
// Returns true when it did. Any failure leaves the snapshot as it was.
fn bool overlay()
{
	String have = check::compiler_version();
	if (have.len == 0 || have == corpus::snapshot_version) return false;
	return overlay_from(check::c3c_binary(), have);
}

extern fn CInt malloc_trim(usz pad) @if(env::LINUX);   // glibc: give the memory freed after parsing 2.8 MB of JSON back to the system

fn bool overlay_from(String binary, String version)
{
	Entry[]? live = read_live(binary);
	if (catch live) return false;
	corpus::replace_symbols(live, version);
	$if env::LINUX:
		malloc_trim(0);
	$endif
	return true;
}

// The symbols of the standard library of the compiler at `binary`, as read by `c3c docgen`.
fn Entry[]? read_live(String binary) => @pool()
{
	String install = check::install_dir(binary);
	if (install.len == 0) return NO_STDLIB~;
	String libstd = stdlib_dir(install);
	if (libstd.len == 0) return NO_STDLIB~;
	String[] argv = { binary, "--trust=none", "docgen", libstd, "--json" };
	int status = 0;
	bool timed_out = false;
	String? out = check::run_capped(argv, &status, &timed_out, DOCGEN_MS, MAX_DOCGEN);
	if (catch out) return NO_STDLIB~;
	if (timed_out || status != 0 || out.len == 0) return NO_STDLIB~;
	String root = libstd[:libstd.len - 7];   // "<install>/" : cut from file paths, as the snapshot's are relative
	Entry[] live = entries_from_json(out, root)!;
	if (live.len < 1000) return NO_STDLIB~;   // an empty or partial answer is not a standard library
	return live;
}
