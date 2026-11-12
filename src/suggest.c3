module c3guide::suggest;
import c3guide::corpus, c3guide::util;
import std::collections::list, std::core::ascii, std::sort;

// "does not exist" is not an answer for a name that is nearly right: `String.trepeat` is `DString.append_repeat`,
// `file::tload` is `file::load_temp`. The suggestions come from the names of the standard library by their words (not by
// their spelling: that is `Similar names`): the words of the missing name (`t` in front of a name is the temp-allocator
// variant, `get`, `new`, `is` say nothing) against the words of the names that belong where it was looked for: the type,
// the types that build it, the module of the type, the module that was named. At most 3; below a threshold, nothing.

const int MAX_SUGGESTIONS = 3;
const float MIN_RELATIVE = 0.88f;      // a suggestion must have this share of the best one's score
const float MIN_COVER = 0.6f;          // the share of the missing name's words a suggestion must have
const float SYNONYM_COVER = 0.7f;      // a word the missing name did not use (`size` for `length`) counts for less
const String[*] FILLER = { "get", "set", "new", "is", "to", "as", "try", "from", "of", "the" };
// types that are made of another or build it, where the library keeps what a plain `String` does not have
const String[2][*] BUILDS = { { "String", "DString" }, { "String", "ZString" }, { "String", "WString" }, { "ZString", "String" }, { "DString", "String" } };

// Names other languages (and 0.6/0.7) use for what C3 calls something else, where the words say nothing: `List.append` is
// `List.push`. { owner, missing name, the name in C3 }
const String[3][*] RENAMED_MEMBERS = { { "List", "append", "push" }, { "List", "add", "push" }, { "HashMap", "put", "set" }, { "HashMap", "insert", "set" } };
// the length of a String or a slice is a member, not a method: `s.len`
const String[*] LENGTH_NAMES = { "length", "size", "count", "len" };

struct Cand
{
	Entry* e;
	float score;
}

// `read_line` -> read, line; `ByteReader` -> byte, reader. Lowercase.
fn String[] split_words(String name)
{
	List{String} out;
	out.init(tmem);
	DString cur = dstring::temp();
	foreach (i, c : name)
	{
		bool boundary = c == '_' || (ascii::is_upper(c) && i > 0 && ascii::is_lower(name[i - 1]));
		if (boundary && cur.len() > 0) { out.push(cur.copy_str(tmem)); cur.clear(); }
		if (c != '_') cur.append_char(ascii::to_lower(c));
	}
	if (cur.len() > 0) out.push(cur.copy_str(tmem));
	return out.array_view();
}

fn bool is_filler(String w)
{
	foreach (f : FILLER) if (f == w) return true;
	return w.len < 2;
}

// Both are lowercase words: the same, or one a plural of the other.
fn bool same_word(String a, String b)
{
	if (a == b) return true;
	if (a.len == b.len + 1 && a.ends_with("s") && a[:b.len] == b) return true;
	if (b.len == a.len + 1 && b.ends_with("s") && b[:a.len] == a) return true;
	return false;
}

// Do the two words stand for the same thing in data/synonyms.txt (`length`, `size`, `len`)?
fn bool synonyms(String a, String b)
{
	foreach (line : corpus::synonym_text().tsplit("\n"))
	{
		bool has_a = false;
		bool has_b = false;
		foreach (w : line.tsplit(" "))
		{
			if (same_word(w, a)) has_a = true;
			if (same_word(w, b)) has_b = true;
		}
		if (has_a && has_b) return true;
	}
	return false;
}

struct Missing
{
	String owner;      // `String` of `String.trepeat`, "" when none
	String mod_name;   // `file` of `file::tload`, "" when none
	String name;
	String[] words;    // what the name says: filler left out
	bool temp;         // `tload`: the variant that uses the temp allocator
}

fn Missing parse(String n)
{
	Missing m;
	sz dot = n.rindex_of(".") ?? -1;
	if (dot > 0) { m.owner = util::last_part(n[:dot]); m.name = n[dot + 1..]; }
	else
	{
		sz sep = n.rindex_of("::") ?? -1;
		if (sep > 0) { m.mod_name = n[:sep]; m.mod_name = m.mod_name[(m.mod_name.rindex_of("::") ?? -2) + 2..]; m.name = n[sep + 2..]; }
		else { m.name = n; }
	}
	String lower = m.name.to_lower_tcopy();
	// `tload`, `tsplit`: the temp variant of `load`, `split`
	if (m.name.len >= 5 && m.name[0] == 't' && ascii::is_lower(m.name[1]) && !m.name.contains("_")) { m.temp = true; lower = lower[1..]; }
	List{String} words;
	words.init(tmem);
	foreach (w : split_words(lower)) { if (w == "temp" || w == "tmp") m.temp = true; if (!is_filler(w)) words.push(w); }
	m.words = words.array_view();
	return m;
}

// How much of the missing name's words the candidate says (0..1).
fn float cover(Missing* m, String[] have)
{
	float sum = 0;
	foreach (w : m.words)
	{
		float best = 0;
		foreach (h : have)
		{
			if (same_word(w, h)) { best = 1; }
			else if (best < SYNONYM_COVER && synonyms(w, h)) { best = SYNONYM_COVER; }
		}
		sum += best;
	}
	return m.words.len == 0 ? 0 : sum / (float)m.words.len;
}

fn String module_of(String title) => title[:title.rindex_of("::") ?? 0];
fn String member_of_module(String mod) => mod[((mod.rindex_of("::") ?? -2) + 2)..];
fn String member_of(String title) => title[((title.rindex_of("::") ?? -2) + 2)..];

fn String signature(Entry* e) => util::clip(e.body.tsplit("\n")[0], 140);

// The line to show for a suggestion: `DString.append_repeat` for a method, `file::load_temp` for a function.
fn String shown(Entry* e)
{
	String m = member_of(e.title);
	if (m.contains(".")) return m;
	String mod = module_of(e.title);
	return string::tformat("%s::%s", mod[((mod.rindex_of("::") ?? -2) + 2)..], m);
}

// "" or "did you mean: ..." lines for a name that is not in the library.
fn String did_you_mean(String n)
{
	Missing m = parse(n);
	if (m.name.len < 3) return "";
	String known = known_member(&m);
	if (known.len > 0) return known;
	List{Cand} found;
	found.init(tmem);
	if (m.owner.len == 0 && m.mod_name.len == 0) { type_candidates(&m, &found); }
	else { member_candidates(&m, &found); }
	if (found.len() == 0) return "";
	Cand[] sorted = found.array_view();
	sort::quicksort(sorted, fn int(Cand a, Cand b) => a.score < b.score ? 1 : (a.score > b.score ? -1 : (int)(a.e - b.e)));
	DString out = dstring::temp();
	out.append("did you mean:\n");
	// only what is close to the best: a second suggestion that is much worse is noise
	for (sz i = 0; i < sorted.len && i < MAX_SUGGESTIONS; i++)
	{
		if (sorted[i].score < sorted[0].score * MIN_RELATIVE) break;
		out.appendf("  %s   %s\n", shown(sorted[i].e), signature(sorted[i].e));
	}
	return out.str_view();
}

// A member the table above knows: its answer replaces the suggestions by words (`String.length` would suggest `String.count`,
// which counts occurrences).
fn String known_member(Missing* m)
{
	if (m.owner.len == 0) return "";
	String lower = m.name.to_lower_tcopy();
	if (m.owner == "String" || m.owner.ends_with("[]"))
	{
		foreach (w : LENGTH_NAMES) if (w == lower) return string::tformat("not a method: the length of a %s is its `.len` member (`s.len`, no parentheses), `%s.%s` does not exist.\n", m.owner == "String" ? "String" : "slice", m.owner, m.name);
	}
	foreach (row : RENAMED_MEMBERS)
	{
		if (row[0] != m.owner || row[1] != lower) continue;
		String want = string::tformat("%s.%s", row[0], row[2]);
		foreach (&e : corpus::entries)
		{
			if (e.kind != "method" && e.kind != "mmethod") continue;
			if (member_of(e.title) == want) return string::tformat("did you mean:\n  %s   %s\n", want, signature(e));
		}
	}
	return "";
}

// `Arena` is `ArenaAllocator`: a type whose name starts with the word, or has it as one of its words.
fn void type_candidates(Missing* m, List{Cand}* found)
{
	String want = m.name.to_lower_tcopy();
	if (want.len < 4) return;
	foreach (&e : corpus::entries)
	{
		if (e.kind != "type") continue;
		String last = member_of(e.title);
		if (last.contains(".")) continue;
		String low = last.to_lower_tcopy();
		float score = 0;
		if (low.starts_with(want) && low.len > want.len) { score = 2.0f - 0.01f * (float)(low.len - want.len); }
		else
		{
			foreach (w : split_words(last)) if (w == want) score = 1.0f - 0.01f * (float)low.len;
		}
		if (score > 0) found.push({ e, score });
	}
}

// `String.trepeat`, `file::tload`: names of the owner, of the types that build it, of its module (or the module asked for).
fn void member_candidates(Missing* m, List{Cand}* found)
{
	if (m.words.len == 0) return;
	// the module of the type that was asked for: its functions are the type's too (`file::get_size` for `File.get_length`)
	String owner_module = "";
	if (m.owner.len > 0)
	{
		foreach (&e : corpus::entries)
		{
			if (e.kind != "type" || !corpus::is_symbol_kind(e.kind)) continue;
			if (member_of(e.title) == m.owner) { owner_module = module_of(e.title); break; }
		}
	}
	foreach (&e : corpus::entries)
	{
		if (e.kind != "fn" && e.kind != "macro" && e.kind != "method" && e.kind != "mmethod") continue;
		String member = member_of(e.title);
		String type = "";
		String name = member;
		sz dot = member.index_of(".") ?? -1;
		if (dot > 0) { type = member[:dot]; name = member[dot + 1..]; }
		String mod = module_of(e.title);
		float place = 0;
		if (m.owner.len > 0)
		{
			if (type == m.owner) { place = 0.5f; }
			else if (type.len > 0 && builds(m.owner, type)) { place = 0.35f; }
			else if (type.len == 0 && owner_module.len > 0 && (mod == owner_module || mod.starts_with(string::tformat("%s::", owner_module))))
			{
				// a function of the type's module, most of all of the one that is named like it (`file` for `File`)
				place = member_of_module(mod) == m.owner.to_lower_tcopy() ? 0.4f : (mod == owner_module ? 0.25f : 0.0f);
				if (place == 0) continue;
			}
			else { continue; }
		}
		else
		{
			// a module was named: its functions and the methods of the types in it (and in its submodules)
			String last_mod = mod[((mod.rindex_of("::") ?? -2) + 2)..];
			bool in_module = last_mod == m.mod_name || mod.ends_with(string::tformat("::%s", m.mod_name)) || mod.contains(string::tformat("::%s::", m.mod_name));
			if (!in_module) continue;
			place = type.len == 0 ? 0.4f : 0.2f;
		}
		String[] have = split_words(name);
		float cov = cover(m, have);
		if (cov < MIN_COVER) continue;
		bool has_temp = false;
		foreach (h : have) if (h == "temp" || h == "tmp") has_temp = true;
		float score = cov + place + (m.temp && has_temp ? 0.3f : 0) - 0.04f * (float)have.len;
		found.push({ e, score });
	}
}

fn bool builds(String owner, String type)
{
	foreach (pair : BUILDS) if (pair[0] == owner && pair[1] == type) return true;
	return false;
}

// `libc::fstat`: the library only wraps part of the C library, the rest is declared where it is used.
fn String extern_hint(String n)
{
	String mod = n.contains("::") ? n[:n.rindex_of("::") ?? 0] : "";
	String last = mod[((mod.rindex_of("::") ?? -2) + 2)..];
	if (last != "libc" && last != "posix") return "";
	return string::tformat("The standard library does not wrap '%s'. Declare it where you use it: `extern fn CInt %s(...) @extern(\"%s\");` (C types: CInt, CLong, ZString; the call is `%s(...)`).\n", n, util::last_part(n), util::last_part(n), util::last_part(n));
}
