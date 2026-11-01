module c3guide::hints;
import std::core::string;
import c3guide::tools, c3guide::util;

// Two things the compiler's message alone does not give a model:
//  - hints:   what the error means in C3 0.8 and where the answer is (a stdlib signature, a release note)
//  - rewrite: the mechanical 0.7 -> 0.8 syntax changes, applied to the code

const sz MAX_ERRORS_HINTED = 3;

struct StaticHint
{
	String needle;
	String hint;
}

const StaticHint[*] STATIC_HINTS = {
	{ "must use '{ }'", "C3 0.8: an `if` with an `else` needs braces on both branches: `if (c) { a(); } else { b(); }`." },
	{ "This doesn't seem to be a valid literal", "C3 0.8 removed the `i64`/`u8` style literal suffixes: use `5L`, `5UL` or a cast, `(long)5`." },
	{ "Expected a type here", "If you wrote `isz`: it is `sz` since 0.8 (`usz` is unchanged). `c3_fix` applies this." },
	{ "'$sizeof' could not be found", "`$sizeof(T)` is gone: write `T::size`. `c3_fix` applies this." },
	{ "'$vacount' could not be found", "`$vacount` is `$vaarg.len` and `$vasplat` is `...$vaarg` since 0.8. `c3_fix` applies this." },
	{ "'$vasplat' could not be found", "`$vasplat` is `...$vaarg` since 0.8. `c3_fix` applies this." },
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

fn String hint_for(String msg)
{
	foreach (h : STATIC_HINTS) if (msg.contains(h.needle)) return string::tformat("  %s\n", h.hint);
	String name = quoted(msg);
	if (msg.contains("Did you mean")) return "";   // the compiler already names the fix
	String marker = "member or method '";
	sz m = msg.index_of(marker) ?? msg.len;
	if (m < msg.len)
	{
		name = quoted(msg[m + marker.len - 1..]);   // the member, not the type before it
		foreach (p : OLD_PROPERTIES)
		{
			if (name != p) continue;
			return string::tformat("  Type properties are written with `::` since 0.8 (`int::size`, `Foo::name`, `int::max`), not `.%s`. `c3_fix` rewrites this; c3_syntax type-properties lists them.\n", p);
		}
	}
	// 'x' could not be found / has no member 'x': the name is often a guessed stdlib function
	if (!is_name(name) || !(msg.contains("could not be found") || msg.contains("member or method") || msg.contains("is not a function")))
	{
		return "";
	}
	foreach (t : BUILTIN_TYPES) if (t == name) return "";
	String s = tools::c3_symbol(name);
	// a name that is not in the stdlib and has no close name is the user's own: say nothing
	if (s.contains("does not exist") && !s.contains("Similar names") && !s.contains("Symbols matching")) return "";
	return string::tformat("  c3_symbol '%s':\n%s\n", name, util::clip(s, 700));
}

<*
 Hints for the first few `error:` lines of the compiler output, "" when there are none.
*>
fn String diagnostics(String compiler_output)
{
	DString out = dstring::temp();
	String[3] seen;
	int n = 0;
	foreach (line : compiler_output.tsplit("\n"))
	{
		sz at = line.index_of(": error: ") ?? line.len;
		if (at >= line.len || n >= MAX_ERRORS_HINTED) continue;
		String msg = line[at + 9..];
		bool dup = false;
		for (int i = 0; i < n; i++) if (seen[i] == msg) dup = true;
		if (dup) continue;
		seen[n++] = msg;
		String h = hint_for(msg);
		if (h.len > 0) out.append(h);
	}
	if (out.len() == 0) return "";
	return util::clip(string::tformat("\nHints:\n%s", out.str_view()), 1500);
}

// ---------------------------------------------------------------- 0.7 -> 0.8 rewrites

const String[*] BUILTIN_TYPES = { "bool", "char", "ichar", "short", "ushort", "int", "uint", "long", "ulong", "int128", "uint128", "sz", "usz", "iptr", "uptr", "float", "double", "float16", "bfloat16", "typeid", "String" };
const String[2][*] PROPERTY_RENAMES = { { "sizeof", "size" }, { "alignof", "alignment" }, { "nameof", "name" }, { "max", "max" }, { "min", "min" } };

fn bool ident_char(char c) @inline => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';

// A type-looking name: a builtin type or something capitalised (`Foo`, `Bar{int}`-less). `x.max` on a variable stays.
fn bool type_like(String id)
{
	if (id.len == 0) return false;
	foreach (t : BUILTIN_TYPES) if (t == id) return true;
	return id[0] >= 'A' && id[0] <= 'Z';
}

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

<*
 Apply the mechanical C3 0.7 -> 0.8 changes outside strings and comments:
 `T.sizeof` -> `T::size` (also alignof, nameof, max, min), `$sizeof(T)` -> `T::size`, `$alignof(T)`,
 `isz` -> `sz`, `$vacount` -> `$vaarg.len`, `$vasplat` -> `...$vaarg`.
*>
fn Rewrite rewrite(String code)
{
	DString out = dstring::temp();
	DString notes = dstring::temp();
	int count = 0;
	sz i = 0;
	while (i < code.len)
	{
		char c = code[i];
		// string, raw string, char literal, comments: copied untouched
		if (c == '"' || c == '\'')
		{
			sz j = i + 1;
			while (j < code.len && code[j] != c) { if (code[j] == '\\') j++; j++; }
			j = j < code.len ? j + 1 : code.len;
			out.append(code[i:j - i]);
			i = j;
			continue;
		}
		if (c == '`')
		{
			sz j = i + 1;
			while (j < code.len && code[j] != '`') j++;
			j = j < code.len ? j + 1 : code.len;
			out.append(code[i:j - i]);
			i = j;
			continue;
		}
		if (c == '/' && i + 1 < code.len && (code[i + 1] == '/' || code[i + 1] == '*'))
		{
			bool line = code[i + 1] == '/';
			sz j = i + 2;
			while (j < code.len && (line ? code[j] != '\n' : !(code[j] == '*' && j + 1 < code.len && code[j + 1] == '/'))) j++;
			if (!line) j = j + 2 < code.len ? j + 2 : code.len;
			out.append(code[i:j - i]);
			i = j;
			continue;
		}
		if (c == '$' || ident_char(c))
		{
			sz j = i + 1;
			while (j < code.len && ident_char(code[j])) j++;
			String word = code[i:j - i];
			bool after_dot = i > 0 && code[i - 1] == '.';
			if (word == "isz" && !after_dot)
			{
				out.append("sz");
				note(&notes, "isz -> sz");
				count++;
				i = j;
				continue;
			}
			if (word == "$vacount") { out.append("$vaarg.len"); note(&notes, "$vacount -> $vaarg.len"); count++; i = j; continue; }
			if (word == "$vasplat") { out.append("...$vaarg"); note(&notes, "$vasplat -> ...$vaarg"); count++; i = j; continue; }
			if ((word == "$sizeof" || word == "$alignof") && j < code.len && code[j] == '(')
			{
				sz k = j + 1;
				int depth = 1;
				while (k < code.len && depth > 0) { if (code[k] == '(') depth++; if (code[k] == ')') depth--; k++; }
				if (depth == 0)
				{
					String arg = code[j + 1:k - j - 2].trim();
					String prop = word == "$sizeof" ? "size" : "alignment";
					out.appendf("%s::%s", arg, prop);
					note(&notes, string::tformat("%s(T) -> T::%s", word, prop));
					count++;
					i = k;
					continue;
				}
			}
			// Type.sizeof -> Type::size
			if (!after_dot && type_like(word) && j < code.len && code[j] == '.')
			{
				bool done = false;
				foreach (pair : PROPERTY_RENAMES)
				{
					sz end = j + 1 + pair[0].len;
					if (end <= code.len && code[j + 1:pair[0].len] == pair[0] && (end == code.len || !ident_char(code[end])))
					{
						out.appendf("%s::%s", word, pair[1]);
						note(&notes, string::tformat(".%s -> ::%s", pair[0], pair[1]));
						count++;
						i = end;
						done = true;
						break;
					}
				}
				if (done) continue;
			}
			out.append(word);
			i = j;
			continue;
		}
		out.append_char(c);
		i++;
	}
	return { out.str_view(), count, notes.str_view() };
}
