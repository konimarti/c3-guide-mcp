module c3guide::hints;
import std::core::string;
import c3guide::tools, c3guide::util, c3guide::ts;
import std::collections::list;

// Two things the compiler's message alone does not give a model:
//  - hints:   what the error means in C3 0.8 and where the answer is (a stdlib signature, a release note)
//  - rewrite: the mechanical 0.7 -> 0.8 syntax changes, applied to the code

const sz MAX_ERRORS_HINTED = 5;

// needle: part of the compiler's message. require: when set, that text must also appear in the compiler's
// output (which echoes the source line), so a generic message only gets the hint when the old syntax is there.
struct StaticHint
{
	String needle;
	String require;
	String hint;
}

const StaticHint[*] STATIC_HINTS = {
	{ "cannot be used with arch/os", "", "A library lists the platforms it supports in a `targets` map of its manifest.json: add this platform, e.g. `\"targets\": { \"linux-x64\": {} }`. c3c 0.8.5 requires the map; 0.8.6 does not, so the same library can pass with one compiler and fail with the other." },
	{ "A valid member name was expected here", "?", "A struct field cannot be optional (`T? name;`). Optionals are for return values and local variables: keep the value and a `bool` for \"is set\" in the struct, or return `T?` from a function." },
	{ "is a keyword and not an expression", "??", "`??` needs a value on its right, not `continue`, `return` or `break`. Give a default, `int x = f() ?? 0;`, or leave before using it: `int? v = f(); if (catch v) continue;` (after that `v` is a plain int), or `if (catch err = f()) { return; }`." },
	{ "Expected ')'", "catch AND ||", "A `catch` cannot be combined with `||` or `&&` in one condition: `if (catch err = f()) { ... }` stands alone. Handle the error in its own `if`, then test the other condition." },
	{ "'@private' modifiers are ignored for method declarations", "", "`@private` has no effect on a method: it is visible wherever its type is. For module-private code use a free function, `fn int helper(Cat* c) @private`." },
	{ "must use '{ }'", "", "C3 0.8: an `if` with an `else` needs braces on both branches: `if (c) { a(); } else { b(); }`." },
	{ "This doesn't seem to be a valid literal", "", "C3 0.8 removed the `i64`/`u8` style literal suffixes: use `5L`, `5UL` or a cast, `(long)5`." },
	{ "Expected a type here", "isz", "`isz` is `sz` since 0.8 (`usz` is unchanged). `c3_fix` applies this." },
	{ "Expected ';'", "$typeof(", "`$typeof(x)` is spelled `$Typeof(x)` where a type is expected (`$Typeof(x) y = 4;`)." },
	{ "A type name was expected here", "!", "Optionals are written `int?` (not `int!`) since 0.8: `fn int? f()`, `int? x = f();`." },
	{ "did you forget 'const'", "fault ", "Fault declarations are `faultdef A, B;` since 0.8 (`fault E { A }` is gone). Use them as `A?` or `return A~;`." },
	{ "An expression was expected", "(<", "Generics use braces since 0.7: `List{int}`, not `List(<int>)`." },
	{ "A type name was expected, but this looks a variable or function name", "def ", "`def` is `alias` since 0.7: `alias Foo = int;`." },
	{ "not a known valid attribute name", "@require(", "Contracts are not attributes: write them in a doc comment above the function, `<* @require x > 0 *>`." },
	{ "not a known valid attribute name", "@ensure(", "Contracts are not attributes: write them in a doc comment above the function, `<* @ensure return > 0 *>`." },
	{ "Expected a ':' before the description", "", "In a contract the description follows a colon: `@param x : \"what it is\"`, `@require x > 0 : \"must be positive\"`." },
	{ "It is not possible to cast from", "?'", "An optional is not a plain value: `x ?? default`, `x!!` (panics), `if (try v = f()) { ... }`, or return `T?` and call `f()!` (rethrow)." },
	{ "was expected for the parameter '$Type'", "", "`mem::alloc(Type)` takes a type, not a size: `mem::alloc(int)`, `mem::alloc_array(int, n)`, or `mem::malloc(bytes)`." },
	{ "You cannot cast 'String' to 'Allocator'", "", "A String is an immutable view. The allocating functions take an allocator first (`s.concat(mem, other)`), the `t`-prefixed ones use the temp allocator (`s.tconcat(other)`); use `DString` to build text." },
};

const String[*] OLD_PROPERTIES = { "sizeof", "alignof", "nameof", "max", "min", "elements", "associated", "lookup", "kindof", "typeid", "qnameof", "extnameof" };

// First 'quoted' word of a compiler message, "" when there is none.
fn String quoted(String msg)
{
	sz a = msg.index_of("'") ?? msg.len;
	if (a >= msg.len) return "";
	String rest = msg[a + 1..];
	sz b = rest.index_of("'") ?? rest.len;
	return b >= rest.len ? "" : rest[:b];
}

fn bool is_name(String s)
{
	if (s.len == 0 || s.len > 80) return false;
	foreach (c : s) if (!(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_' && c != ':' && c != '.') return false;
	return true;
}

fn String static_hint(String msg, String output)
{
	foreach (h : STATIC_HINTS)
	{
		if (!msg.contains(h.needle)) continue;
		bool all = true;
		if (h.require.len > 0) foreach (part : h.require.tsplit(" AND ")) if (!output.contains(part)) all = false;   // every part must be there
		if (!all) continue;
		return string::tformat("  %s\n", h.hint);
	}
	return "";
}

fn String hint_for(String msg, String output)
{
	String fixed = static_hint(msg, output);
	if (fixed.len > 0) return fixed;
	String name = quoted(msg);
	String old = tools::legacy_note(name);   // `$sizeof`, `$vacount`...: the one table of names that were replaced
	if (old.len > 0) return string::tformat("  %s", old);
	if (msg.contains("Did you mean")) return "";   // the compiler already names the fix
	String marker = "member or method '";
	sz m = msg.index_of(marker) ?? msg.len;
	if (m < msg.len)
	{
		name = quoted(msg[m + marker.len - 1..]);   // the member, not the type before it
		foreach (p : OLD_PROPERTIES)
		{
			if (name != p) continue;
			bool fixable = false;
			foreach (pair : PROPERTY_RENAMES) if (pair[0] == p) fixable = true;
			return string::tformat("  Type properties are written with `::` since 0.8 (`int::size`, `Foo::name`, `int::max`), not `.%s`.%s c3_syntax type-properties lists them.\n", p, fixable ? " `c3_fix` rewrites this." : "");
		}
	}
	// 'x' could not be found / has no member 'x': the name is often a guessed stdlib function
	if (!is_name(name) || !(msg.contains("could not be found") || msg.contains("member or method") || msg.contains("field or method") || msg.contains("is not a function")))
	{
		return "";
	}
	foreach (t : BUILTIN_TYPES) if (t == name) return "";
	// `free`, `init`, `len`: dozens of methods of that name say nothing about the one that was meant
	if (!name.contains("::") && tools::exact_matches(name) > 3) return "";
	// when the compiler itself proposes a name, the signature of that name is the useful answer
	String proposed = quoted_after(msg, "perhaps want '");
	String s = tools::symbol_reply(is_name(proposed) ? proposed : name);   // the reply itself, without the notes c3_symbol adds
	// a name that is not in the stdlib and has no close name is the user's own: say nothing
	if (s.contains("does not exist") && !s.contains("Similar names") && !s.contains("Symbols matching")) return "";
	return string::tformat("  c3_symbol '%s':\n%s\n", is_name(proposed) ? proposed : name, compact(s));
}

// The word between the quotes right after `marker`, "" when the marker is absent.
fn String quoted_after(String msg, String marker)
{
	sz at = msg.index_of(marker) ?? msg.len;
	if (at >= msg.len) return "";
	return quoted(msg[at + marker.len - 1..]);
}

const int HINT_ENTRIES = 3;

// What a hint needs from a c3_symbol reply: where the name went (similar names, a rename in the release notes)
// and the first signatures. Not the doc comments, and not the sentence repeating the question.
fn String compact(String reply)
{
	DString out = dstring::temp();
	int entries = 0;
	bool listing = false;      // true once the entries start
	bool exact = false;        // an exact hit: "### title (loc)", then the signature unindented; a list: title, then an indented signature
	bool want_signature = false;
	foreach (line : reply.tsplit("\n"))
	{
		if (line.contains(" does not exist in the standard library")) continue;
		if (line.starts_with("Symbols matching")) { listing = true; continue; }
		if (!listing && line.starts_with("### ")) { listing = true; exact = true; }
		if (!listing)
		{
			if (line.trim().len > 0) out.appendf("  %s\n", line);   // similar names, release notes
			continue;
		}
		if (line.trim().len == 0) continue;
		bool title = exact ? line.starts_with("### ") : !line.starts_with(" ");
		if (title)
		{
			if (entries >= HINT_ENTRIES) break;
			entries++;
			sz loc = line.index_of("  (") ?? line.len;   // the file and line are not needed to pick a name
			out.appendf("  %s\n", exact ? line[4:loc - 4] : line[:loc]);
			want_signature = true;
		}
		else if (want_signature)
		{
			out.appendf("    %s\n", line.trim());
			want_signature = false;
		}
	}
	return util::clip(out.str_view(), 900);
}

<*
 Hints for the first few `error:` lines of the compiler output, "" when there are none.
*>
fn String diagnostics(String compiler_output)
{
	DString out = dstring::temp();
	String[5] seen;
	int n = 0;
	foreach (line : compiler_output.tsplit("\n"))
	{
		sz at = line.index_of(": error: ") ?? line.len;
		bool warning = false;
		if (at >= line.len)
		{
			at = line.index_of(": warning: ") ?? line.len;   // a warning gets a hint only when the table has one for it
			warning = true;
		}
		if (at >= line.len || n >= MAX_ERRORS_HINTED) continue;
		String msg = line[at + (warning ? 11 : 9)..];
		bool dup = false;
		for (int i = 0; i < n; i++) if (seen[i] == msg) dup = true;
		if (dup) continue;
		seen[n++] = msg;
		String h = warning ? static_hint(msg, compiler_output) : hint_for(msg, compiler_output);
		if (h.len > 0) out.append(h);
	}
	if (out.len() == 0) return "";
	return util::clip(string::tformat("\nHints:\n%s", out.str_view()), 2400);
}

// ---------------------------------------------------------------- 0.7 -> 0.8 rewrites

const String[*] BUILTIN_TYPES = { "bool", "char", "ichar", "short", "ushort", "int", "uint", "long", "ulong", "int128", "uint128", "sz", "usz", "iptr", "uptr", "float", "double", "float16", "bfloat16", "typeid", "String" };
const String[2][*] PROPERTY_RENAMES = { { "sizeof", "size" }, { "alignof", "alignment" }, { "nameof", "name" }, { "max", "max" }, { "min", "min" } };

struct Rewrite
{
	String code;
	int count;
	String notes;
}

fn void note(DString* notes, String what)
{
	String s = notes.str_view();
	if (s.contains(what)) return;
	if (notes.len() > 0) notes.append(", ");
	notes.append(what);
}

struct Edit
{
	uint start;
	uint end;
	String text;
}

// Walk the syntax tree and note every 0.7 spelling worth an edit. A node that is edited is not entered again.
// Strings and comments are never identifiers in the tree, and `x.max` (a value) is told from `int.max` (a type)
// by what the grammar made of the left side.
const int MAX_TREE_DEPTH = 200;   // a chain of 12,000 `!` is a tree 12,000 deep; recursing that far overflows a thread stack
const int MAX_REWRITE_NESTING = 16;
int rewrite_nesting;

fn void collect(String src, TSNode n, String parent, List{Edit}* edits, DString* notes, int* count, int depth = 0)
{
	if (depth > MAX_TREE_DEPTH) return;
	String type = ts::type_of(n);
	String text = ts::node_text(src, n);
	uint start = ts::ts_node_start_byte(n);
	uint end = ts::ts_node_end_byte(n);
	if (type == "ident" && text == "isz" && parent != "access_ident")
	{
		edits.push({ start, end, "sz" });
		note(notes, "isz -> sz");
		*count += 1;
		return;
	}
	if (type == "ct_ident" && (text == "$vacount" || text == "$vasplat"))
	{
		edits.push({ start, end, text == "$vacount" ? "$vaarg.len" : "...$vaarg" });
		note(notes, text == "$vacount" ? "$vacount -> $vaarg.len" : "$vasplat -> ...$vaarg");
		*count += 1;
		return;
	}
	if (type == "call_expr")
	{
		TSNode fn_node = ts::field_of(n, "function");
		TSNode args = ts::field_of(n, "arguments");
		String name = ts::ts_node_is_null(fn_node) ? "" : ts::node_text(src, fn_node);
		if ((name == "$sizeof" || name == "$alignof") && !ts::ts_node_is_null(args) && ts::ts_node_named_child_count(args) == 1)
		{
			TSNode arg = ts::ts_node_named_child(args, 0);
			TSNode inner = ts::ts_node_named_child_count(arg) > 0 ? ts::ts_node_named_child(arg, 0) : arg;
			Rewrite nested = rewrite(ts::node_text(src, inner).trim());   // `$sizeof(Foo[$sizeof(int)])`
			String prop = name == "$sizeof" ? "size" : "alignment";
			// `$sizeof(x)` took a type or an expression; `T::size` needs a type
			bool is_type = ts::type_of(inner) == "type";
			edits.push({ start, end, is_type ? string::tformat("%s::%s", nested.code, prop) : string::tformat("$Typeof(%s)::%s", nested.code, prop) });
			note(notes, string::tformat("%s(T) -> T::%s", name, prop));
			*count += 1 + nested.count;
			return;
		}
	}
	if (type == "field_expr")
	{
		TSNode left = ts::field_of(n, "argument");
		TSNode right = ts::field_of(n, "field");
		if (!ts::ts_node_is_null(left) && !ts::ts_node_is_null(right) && ts::type_of(left) == "type")
		{
			String prop = ts::node_text(src, right);
			foreach (pair : PROPERTY_RENAMES)
			{
				if (pair[0] != prop) continue;
				edits.push({ start, end, string::tformat("%s::%s", rewrite(ts::node_text(src, left)).code, pair[1]) });
				note(notes, string::tformat(".%s -> ::%s", pair[0], pair[1]));
				*count += 1;
				return;
			}
		}
	}
	uint kids = ts::ts_node_named_child_count(n);
	for (uint i = 0; i < kids; i++) collect(src, ts::ts_node_named_child(n, i), type, edits, notes, count, depth + 1);
}

fn Rewrite rewrite_once(String code, DString* notes)
{
	TSParser* parser = ts::ts_parser_new();
	defer ts::ts_parser_delete(parser);
	ts::ts_parser_set_language(parser, ts::tree_sitter_c3());
	TSTree* tree = ts::ts_parser_parse_string(parser, null, code.ptr, (uint)code.len);
	defer ts::ts_tree_delete(tree);
	List{Edit} edits;
	edits.init(tmem);
	int count = 0;
	collect(code, ts::ts_tree_root_node(tree), "", &edits, notes, &count);
	DString out = dstring::temp();
	uint at = 0;
	foreach (e : edits)
	{
		out.append(code[at:e.start - at]);
		out.append(e.text);
		at = e.end;
	}
	out.append(code[at..]);
	return { out.str_view(), count, "" };
}

<*
 Apply the mechanical C3 0.7 -> 0.8 changes outside strings and comments:
 `T.sizeof` -> `T::size` (also alignof, nameof, max, min), `$sizeof(T)` -> `T::size`, `$alignof(T)`,
 `isz` -> `sz`, `$vacount` -> `$vaarg.len`, `$vasplat` -> `...$vaarg`.
 `isz` is not a type in 0.8, so code that uses it does not parse as a whole: it goes first, then the rest is
 read from the tree of the repaired code.
*>
fn Rewrite rewrite(String code)
{
	if (rewrite_nesting >= MAX_REWRITE_NESTING) return { code, 0, "" };   // `$sizeof($sizeof($sizeof(...` re-enters this function
	rewrite_nesting++;
	defer rewrite_nesting--;
	DString notes = dstring::temp();
	int total = 0;
	for (int pass = 0; pass < 3; pass++)
	{
		Rewrite r = rewrite_once(code, &notes);
		if (r.count == 0) break;
		code = r.code;
		total += r.count;
	}
	return { code, total, notes.str_view() };
}
