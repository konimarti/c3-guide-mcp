module c3guide::hints;
import std::core::string;
import c3guide::tools, c3guide::util;

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

fn String hint_for(String msg, String output)
{
	foreach (h : STATIC_HINTS)
	{
		if (!msg.contains(h.needle)) continue;
		if (h.require.len > 0 && !output.contains(h.require)) continue;
		return string::tformat("  %s\n", h.hint);
	}
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
			return string::tformat("  Type properties are written with `::` since 0.8 (`int::size`, `Foo::name`, `int::max`), not `.%s`. `c3_fix` rewrites this; c3_syntax type-properties lists them.\n", p);
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
	String[5] seen;
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
		String h = hint_for(msg, compiler_output);
		if (h.len > 0) out.append(h);
	}
	if (out.len() == 0) return "";
	return util::clip(string::tformat("\nHints:\n%s", out.str_view()), 2400);
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
	if (!(id[0] >= 'A' && id[0] <= 'Z')) return false;
	foreach (c : id) if (c >= 'a' && c <= 'z') return true;
	return false;   // ALL CAPS is a constant (`LIMIT.max`), not a type
}

// Is `at` inside the head of a `fn` / `macro` line, before its '('? There `Type.min` names a method being
// defined (`fn int Foo.min(...)`), which has no 0.8 rewrite.
fn bool in_definition_head(String code, sz at)
{
	sz start = at;
	while (start > 0 && code[start - 1] != '\n') start--;
	String head = code[start:at - start];
	String t = head.trim();
	if (!t.starts_with("fn ") && !t.starts_with("macro ")) return false;
	return !head.contains("(");
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
		if (c == '/' && i + 1 < code.len && code[i + 1] == '+')
		{
			// `/+ ... +/` comments nest
			sz j = i + 2;
			int depth = 1;
			while (j < code.len && depth > 0)
			{
				if (code[j] == '/' && j + 1 < code.len && code[j + 1] == '+') { depth++; j += 2; continue; }
				if (code[j] == '+' && j + 1 < code.len && code[j + 1] == '/') { depth--; j += 2; continue; }
				j++;
			}
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
			if (word == "$sizeof" || word == "$alignof")
			{
				sz open = j;
				while (open < code.len && (code[open] == ' ' || code[open] == '\t')) open++;
				if (open < code.len && code[open] == '(')
				{
					sz k = open + 1;
					int depth = 1;
					while (k < code.len && depth > 0) { if (code[k] == '(') depth++; if (code[k] == ')') depth--; k++; }
					if (depth == 0)
					{
						String arg = rewrite(code[open + 1:k - open - 2]).code.trim();   // nested $sizeof first
						String prop = word == "$sizeof" ? "size" : "alignment";
						// `$sizeof(x)` took a type or an expression; `T::size` needs a type
						bool is_type = arg.len > 0 && (type_like(arg) || arg.contains("*") || arg.contains("[") || arg.contains("::") || arg.contains("{"));
						if (is_type) { out.appendf("%s::%s", arg, prop); } else { out.appendf("$Typeof(%s)::%s", arg, prop); }
						note(&notes, string::tformat("%s(T) -> T::%s", word, prop));
						count++;
						i = k;
						continue;
					}
				}
			}
			// Type.sizeof -> Type::size
			if (!after_dot && type_like(word) && j < code.len && code[j] == '.' && !in_definition_head(code, i))
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
