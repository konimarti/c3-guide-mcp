module c3guide::tools;
import mcp, std::core::string;
import c3guide::corpus, c3guide::search, c3guide::util, c3guide::hints, c3guide::check, c3guide::live;
import std::sort, std::math;

// Every reply is capped: a docs server that dumps pages into the context is worse than none.
const sz MAX_REPLY = 3200;
const sz MAX_SNIPPET = 900;
const sz MAX_RECIPE = 1800;
const String[*] SYMBOL_KINDS = { "fn", "macro", "method", "mmethod", "type", "var" };

fn String hit_text(Entry* e, sz snippet)
{
	String loc = e.loc.len > 0 ? string::tformat("  (%s)", e.loc) : "";
	return string::tformat("### %s%s\n%s\n", e.title, loc, util::clip(e.body, snippet));
}

fn String format_hits(Hit[] hits, sz snippet)
{
	DString out = dstring::temp();
	foreach (h : hits)
	{
		Entry* e = &corpus::entries[h.idx];
		out.append(hit_text(e, e.kind == "recipe" ? MAX_RECIPE : snippet));   // a recipe is useless cut in half
	}
	return util::clip(out.str_view(), MAX_REPLY);
}

// "C3C Release Notes > 0.8.5 Change list > Fixes" -> 805 (0.8.5), so newer versions sort higher.
fn int version_key(String title)
{
	String[] parts = title.tsplit(" > ");
	if (parts.len < 2) return 0;
	String[] nums = parts[1].tsplit(" ")[0].tsplit(".");
	int key = 0;
	foreach (n : nums)
	{
		int? v = n.to_int();
		key = key * 100 + (v ?? 0);
	}
	return key;
}

// Release-note chunks are long bullet lists: show only the bullets that mention ALL query terms
// (or any term, when no bullet has all of them).
fn String matching_lines(String body, String[] terms, bool all)
{
	DString out = dstring::temp();
	int n = 0;
	foreach (line : body.tsplit("\n"))
	{
		if (!line.starts_with("-") || n >= 6) continue;
		String low = line.to_lower_tcopy();
		int hit = 0;
		foreach (t : terms) if (has_word(low, t) || has_word(low, string::tformat("%ss", t))) hit++;
		if (hit == 0 || (all && hit < terms.len)) continue;
		out.appendf("%s\n", util::clip(line, 240));
		n++;
	}
	return out.str_view();
}

// Names from C3 0.6/0.7 that a model still writes. They are not in the standard library or the keyword
// lists of 0.8, so a plain "does not exist" would send it searching; say what replaced them.
const String[2][*] LEGACY = {
	{ "$sizeof", "`$sizeof(T)` is `T::size` since 0.8 (`$alignof(T)` is `T::alignment`). c3_fix rewrites it; c3_syntax type-properties lists the properties." },
	{ "$alignof", "`$alignof(T)` is `T::alignment` since 0.8. c3_fix rewrites it." },
	{ "$typeof", "`$typeof(x)` is spelled `$Typeof(x)` where a type is expected (`$Typeof(x) y = 4;`)." },
	{ "$vacount", "`$vacount` is `$vaarg.len` since 0.8. c3_fix rewrites it." },
	{ "$vasplat", "`$vasplat` is `...$vaarg` since 0.8. c3_fix rewrites it." },
	{ "isz", "`isz` is `sz` since 0.8 (`usz` is unchanged). c3_fix rewrites it." },
	{ "fault", "`fault E { A, B }` is `faultdef A, B;` since 0.8. c3_changes faultdef has the notes." },
	{ "def", "`def Foo = int;` is `alias Foo = int;` since 0.7." },
};

fn String legacy_note(String name)
{
	foreach (pair : LEGACY) if (pair[0] == name) return string::tformat("'%s' is old C3 syntax: %s\n", name, pair[1]);
	return "";
}

fn String strip_prefix(String s, String prefix) => s.starts_with(prefix) ? s[prefix.len..] : s;

fn int clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

fn String c3_search(String query @Desc("what you want to know, e.g. 'foreach with index', 'defer catch'"),
	int limit @Desc("number of results (1..5)") = 3)
	@Desc("Start here for any 'how do I' question about C3: searches the language manual (the snapshot embedded in this server, see c3_symbol for its version), the verified recipes (small working programs: read a file, HashMap, sort, mkdir, threads...) and the standard library names that fit the words ('tcp server' gives std::net::tcp). Use c3_symbol when you already know the name.")
	@ReadOnly
{
	int n = clamp(limit, 1, 5);
	Hit[] hits = search::search(query, { "recipe", "doc" }, n);
	// pasted code (`main(String[] args)`, `path::ls`, `List{`) has no words until the punctuation is gone
	if (hits.len == 0) hits = search::search(search::code_words(query), { "recipe", "doc" }, n);
	// The library is searched on every question: a task ("tcp server") is often one word in the manual ("accept" in
	// attributes) and a whole module in the library. A name that holds two of the question's words is shown when it has
	// more of them than the manual's best section, or the section has under half; the one with more goes first.
	live::ensure();
	Hit[] syms = search::search(query, SYMBOL_KINDS[..], 3, true);
	String[] terms = search::query_terms(search::words_only(query));
	int manual = hits.len > 0 ? words_in(&corpus::entries[hits[0].idx], terms) : 0;
	int library = 0;
	foreach (h : syms) library = math::max(library, words_in(&corpus::entries[h.idx], terms));
	if (hits.len == 0 && syms.len == 0) return "no match in the manual; try other words or c3_symbol for a stdlib name";
	bool show_library = syms.len > 0 && (hits.len == 0 || (library >= 2 && (library > manual || manual * 2 < (int)terms.len)));
	bool library_first = show_library && library >= manual;
	DString out = dstring::temp();
	if (library_first)
	{
		out.append(hits.len == 0 ? "not in the manual; closest standard library names:\n" : "Standard library (c3_symbol has the full signature):\n");
		foreach (h : syms) out.append(brief(&corpus::entries[h.idx]));
	}
	// a manual section with under half of the words only got in through one of them: after a library name it is noise
	// (a recipe is a program that ran: it stays)
	bool noise = library_first && hits.len > 0 && manual * 2 < (int)terms.len && corpus::entries[hits[0].idx].kind != "recipe";
	if (hits.len > 0 && !noise)
	{
		bool weak = terms.len >= 3 && manual * 2 < (int)terms.len && !show_library;
		if (library_first) out.append("\nManual:\n");
		if (weak) out.appendf("Weak match: the best manual section has %d of your %d words.\n", manual, (int)terms.len);
		out.append(format_hits(hits, MAX_SNIPPET));
	}
	if (show_library && !library_first)
	{
		out.append("\nStandard library (c3_symbol has the full signature):\n");
		foreach (h : syms) out.append(brief(&corpus::entries[h.idx]));
	}
	return util::clip(out.str_view(), MAX_REPLY);
}

fn String c3_changes(String topic @Desc("keyword, e.g. 'foreach', 'faultdef', 'type properties'"),
	int limit @Desc("number of release-note sections (1..5)") = 3)
	@Desc("Search the release notes (0.3.0 to the snapshot's version) for what changed or broke, newest first. Use it when old C3 syntax from memory fails.")
	@ReadOnly
{
	String words = search::code_words(topic);   // `int.sizeof`, `String.split`, `0.8.0`: the punctuation is not part of a word
	String[] terms = search::query_terms(words);
	Hit[] hits = search::search(words, { "change" }, 24);
	if (hits.len == 0) return "nothing in the release notes";
	Hit[] sorted = mem::talloc_array(Hit, hits.len);
	foreach (i, h : hits) sorted[i] = h;
	// "Fixes" sections list crashes; a rename or removal is under the change list and is what breaks old code
	sort::quicksort(sorted, fn int(Hit a, Hit b) {
		String ta = corpus::entries[a.idx].title;
		String tb = corpus::entries[b.idx].title;
		int fa = ta.contains("> Fixes") ? 1 : 0;
		int fb = tb.contains("> Fixes") ? 1 : 0;
		if (fa != fb) return fa - fb;
		return version_key(tb) - version_key(ta);
	});
	DString out = dstring::temp();
	int shown = 0;
	for (int pass = 0; pass < 2; pass++)
	{
		foreach (h : sorted)
		{
			if (shown >= clamp(limit, 1, 5)) break;
			Entry* e = &corpus::entries[h.idx];
			String lines = matching_lines(e.body, terms, pass == 0);
			if (lines.len == 0) continue;
			out.appendf("### %s\n%s", strip_prefix(e.title, "C3C Release Notes > "), lines);
			shown++;
		}
		if (shown > 0) break;
	}
	if (out.len() == 0) return "nothing in the release notes";
	return util::clip(out.str_view(), MAX_REPLY);
}

const String SYNTAX_TOPICS = "lists: attributes, builtins, keywords, type-properties, operators, precedence; or give a word to find in them";

fn String c3_syntax(String topic @Desc("one of: attributes, builtins, keywords, type-properties, operators, precedence; or a word to find in them") = "")
	@Desc("Exact lists from the compiler: attributes, builtins, keywords, type properties, operators, precedence.")
	@ReadOnly
{
	if (topic.trim(" \t\n").len == 0) return SYNTAX_TOPICS;
	DString out = dstring::temp();
	foreach (&e : corpus::entries)
	{
		if (e.kind != "list") continue;
		if (e.title == topic) return util::clip(e.body, MAX_REPLY);
		foreach (line : e.body.tsplit("\n"))
		{
			if (line.contains(topic)) out.appendf("%s: %s\n", e.title, line);
		}
	}
	if (out.len() == 0)
	{
		String old = legacy_note(topic.trim(" \t\n"));
		if (old.len > 0) return old;
	}
	if (out.len() == 0) return "no such list or entry; lists: attributes, builtins, keywords, type-properties, operators, precedence";
	return util::clip(out.str_view(), MAX_REPLY);
}

// "std::io::printfn" -> "printfn", "std::core::string::String.split" -> "split"
fn String last_segment(String uid)
{
	String s = uid[((uid.rindex_of("::") ?? -2) + 2)..];
	return s[((s.rindex_of(".") ?? -1) + 1)..];
}

// Does the symbol uid match the user's name? "printfn", "io::printfn", "String.split" and the full uid all do.
fn bool uid_matches(String uid, String name)
{
	if (uid == name) return true;
	if (uid.len <= name.len) return false;
	char sep = uid[uid.len - name.len - 1];
	return uid.ends_with(name) && (sep == ':' || sep == '.');
}

fn bool is_symbol(String kind)
{
	foreach (k : SYMBOL_KINDS) if (k == kind) return true;
	return false;
}

// Signature line plus the first sentence of the doc: enough to choose, short enough for five hits.
fn String brief(Entry* e)
{
	String[] lines = e.body.tsplit("\n", 2);
	String doc = lines.len > 1 ? lines[1] : "";
	sz cut = doc.index_of(" @param") ?? doc.len;
	cut = (doc.index_of(" @return") ?? doc.len) < cut ? (doc.index_of(" @return") ?? doc.len) : cut;
	String loc = e.loc.len > 0 ? string::tformat("  (%s)", e.loc) : "";
	return string::tformat("%s%s\n  %s\n  %s\n", e.title, loc, util::clip(lines[0], 200), util::clip(doc[:cut].trim(" "), 220));
}

// Words instead of a name: rank symbols by their name and doc comment.
fn String describe(String query)
{
	Hit[] hits = search::search(query, SYMBOL_KINDS[..], 5, true);
	if (hits.len == 0) return string::tformat("no symbol matches '%s'; try other words", query);
	DString out = dstring::temp();
	out.appendf("Symbols matching '%s' (c3c %s):\n", query, corpus::symbols_version);
	// Words are all a description search has. When even the best hit has few of them, the nearest names are not an
	// answer: say so, since "the standard library has no such function" is the usual truth (symlinks, mkdtemp...)
	String[] terms = search::query_terms(search::words_only(query));
	int best = 0;
	foreach (h : hits)
	{
		int n = words_in(&corpus::entries[h.idx], terms);
		if (n > best) best = n;
	}
	if (terms.len >= 3 && best * 2 < (int)terms.len)
	{
		out.appendf("Weak matches: no symbol below has more than %d of your %d words. The standard library may not have this; libc:: and os::posix:: hold the raw system calls, or declare an extern.\n", best, (int)terms.len);
	}
	foreach (h : hits) out.append(brief(&corpus::entries[h.idx]));
	return util::clip(out.str_view(), MAX_REPLY);
}

// How many of the query words the name and doc of this symbol contain, a word counting when it or one of its
// synonyms is there (the answer to "pause" is `sleep`: a hit found through the table is not a weak one).
fn int words_in(Entry* e, String[] terms)
{
	String text = string::tformat("%s %s", e.title, e.body);
	int n = 0;
	foreach (t : terms)
	{
		String[1] one = { t };
		String[] closure = search::with_synonyms(one[..]);
		int[] tf = mem::talloc_array(int, closure.len);
		tf[..] = 0;
		search::count_terms(text, closure, tf, true);
		foreach (c : tf) if (c > 0) { n++; break; }
	}
	return n;
}

// How many stdlib symbols this name stands for (`free` is a dozen of them: too many to be a useful hint).
fn int exact_matches(String name)
{
	live::ensure();
	int n = 0;
	foreach (&e : corpus::entries) if (is_symbol(e.kind) && uid_matches(e.title, name)) n++;
	return n;
}

// Release-note lines that say `word` was renamed, replaced or removed, newest release first (at most two).
// A name that "does not exist" is most often a name that moved.
fn String rename_notes(String word)
{
	if (word.len < 4) return "";   // `foo`, `x`, `any` appear in a hundred unrelated lines
	Hit[] hits = search::search(word, { "change" }, 12);
	int best_key = -1;
	int second_key = -1;
	String best = "";
	String second = "";
	foreach (h : hits)
	{
		Entry* e = &corpus::entries[h.idx];
		if (e.title.contains("> Fixes")) continue;
		foreach (line : e.body.tsplit("\n"))
		{
			if (!line.starts_with("-")) continue;
			String l = line.to_lower_tcopy();
			if (!line.contains(string::tformat("`%s`", word)) || !(l.contains("renam") || l.contains("replace") || l.contains("remov") || l.contains("moved"))) continue;
			int key = version_key(e.title);
			String text = string::tformat("  %s: %s\n", strip_prefix(e.title, "C3C Release Notes > ").tsplit(" ")[0], util::clip(line, 240));
			if (key > best_key) { second_key = best_key; second = best; best_key = key; best = text; }
			else if (key > second_key) { second_key = key; second = text; }
		}
	}
	if (best.len == 0) return "";
	return string::tformat("Release notes:\n%s%s", best, second);
}

fn String c3_symbol(String name @Desc("a stdlib name ('printfn', 'io::printfn', 'String.split', 'talloc_array') or, when you do not know the name, what it does ('read a line from a file', 'trim whitespace')"))
	@Desc("Exact signature, docs and source location of a C3 standard library function, macro, method or type; or, given a description, the functions that do it. A type name or a module (`List`, `std::io::path`) lists its methods or functions. Standard library only: for project or dependency code use c3_outline. Never guess a signature, look it up.")
	@ReadOnly
{
	String reply = symbol_reply(name);
	return string::tformat("%s%s", reply, check::version_note(reply.contains("does not exist")));
}

// A name without its underscores, in lowercase: `readLine`, `read_line` and `readline` are one key.
fn String name_key(String lowercase)
{
	DString out = dstring::temp();
	foreach (c : lowercase) if (c != '_') out.append_char(c);
	return out.str_view();
}

// Do the two names share most of their beginning? `printfln` and `printfn` do, `read` and `read_line` do not.
fn bool alike(String a, String b)
{
	sz common = 0;
	while (common < a.len && common < b.len && a[common] == b[common]) common++;
	sz longer = a.len > b.len ? a.len : b.len;
	return common >= 3 && common * 10 >= longer * 7;
}

// The names a type has as methods (`prefix.name`) or a module has as functions and macros (`prefix::name`), as one line.
fn String members_of(String prefix, bool methods)
{
	DString names = dstring::temp();
	int count = 0;
	foreach (&e : corpus::entries)
	{
		if (!is_symbol(e.kind) || !e.title.starts_with(prefix) || e.title.len <= prefix.len + 1) continue;
		String rest = e.title[prefix.len + 1..];
		bool is_method = e.title[prefix.len] == '.';
		if (methods ? !is_method : (e.title[prefix.len] != ':' || rest.contains("::") || rest.contains("."))) continue;
		if (methods ? !(e.kind == "method" || e.kind == "mmethod") : false) continue;
		rest = methods ? rest : rest[(rest.index_of(":") ?? -1) + 1..];
		if (count++ > 0) names.append(", ");
		names.append(rest);
	}
	if (count == 0) return "";
	return string::tformat("%s (%d): %s\n  c3_symbol %s%sNAME for one signature.\n", methods ? "Methods" : "Functions and types", count, util::clip(names.str_view(), 1400), last_segment(prefix), methods ? "." : "::");
}

// `std::io::path`, `io::path`, `path`: the module, when it is one. Its functions and macros, names only.
fn String module_listing(String n)
{
	String full = "";
	foreach (&e : corpus::entries)
	{
		if (!is_symbol(e.kind) || e.title.contains(".")) continue;
		String parent = e.title[:e.title.rindex_of("::") ?? 0];
		if (parent.len > 0 && uid_matches(parent, n)) { full = parent; break; }
	}
	if (full.len == 0) return "";
	return string::tformat("%s\n%s", full, members_of(full, false));
}

fn String symbol_reply(String name)
{
	live::ensure();
	String n = name.trim(" \t\n");
	if (n.len == 0) return "give a symbol name, e.g. printfn or String.split";
	DString out = dstring::temp();
	if (n.contains(" ") || n.contains("\n") || n.contains("\t")) return describe(n);   // several words: a description, not a name
	int found = 0;
	foreach (&e : corpus::entries)
	{
		if (!is_symbol(e.kind) || !uid_matches(e.title, n)) continue;
		if (found++ < 6) out.append(hit_text(e, MAX_SNIPPET));
	}
	if (found > 0)
	{
		if (found > 6) out.appendf("[%d more matches; qualify the name, e.g. io::%s]\n", found - 6, n);
		foreach (&e : corpus::entries) if (e.kind == "type" && uid_matches(e.title, n)) out.append(members_of(e.title, true));
		return util::clip(out.str_view(), MAX_REPLY);
	}
	String module_members = module_listing(n);
	if (module_members.len > 0) return module_members;
	// not found: say so (a model must not assume a guessed API exists), then offer close names
	out.append(legacy_note(n));
	out.appendf("'%s' does not exist in the standard library of c3c %s. (Project or library code: c3_outline with a path and match.)\n", n, corpus::symbols_version);
	// `allocator::free` is asked for by its old module: the same name in another module is the likely answer
	String q = last_segment(n).to_lower_tcopy();
	String module_hint = "";
	if (n.contains("::")) { String m = n[:n.rindex_of("::") ?? 0].to_lower_tcopy(); module_hint = m[(m.rindex_of("::") ?? -2) + 2..]; }
	int shown = 0;
	bool qualified = module_hint.len > 0;
	String qkey = name_key(q);
	for (int pass = 0; pass < 5; pass++)
	{
		foreach (&e : corpus::entries)
		{
			if (!is_symbol(e.kind) || shown >= 8) continue;
			String uid = e.title.to_lower_tcopy();
			String last = last_segment(e.title).to_lower_tcopy();
			bool same = last == q;
			bool near = module_hint.len >= 3 && uid.contains(module_hint[:module_hint.len < 4 ? module_hint.len : 4]);
			bool plain = !e.title[(e.title.rindex_of("::") ?? 0)..].contains(".");
			bool take;
			switch (pass)
			{
				case 0: take = same && plain && near;          // the same function in a module that resembles the asked one
				case 1: take = same && plain;                  // the same function anywhere
				case 2: take = same && !plain && !qualified;   // methods of that name, when no module was named
				case 3: take = !same && name_key(last) == qkey;   // the same name in another spelling: `toInt` for `to_int`
				default: take = !same && alike(last, q);       // names that start alike
			}
			if (!take || out.str_view().contains(string::tformat("  %s\n", e.title))) continue;
			if (shown++ == 0) out.append("Similar names:\n");
			out.appendf("  %s\n", e.title);
		}
	}
	out.append(rename_notes(last_segment(n)));
	// a wrong name usually has the right words in it (`File.read_line`, `tnew_array`)
	String words = describe(n);
	if (!words.starts_with("no symbol")) out.append(words);
	return util::clip(out.str_view(), MAX_REPLY);
}

// Is `word` in `line` as a whole identifier (not inside `readline_all`)? With variants, a leading `t` or a
// trailing `_suffix` is let through: a recipe uses `tsplit` for split and `load_temp` for load.
fn bool has_word(String line, String word, bool variants = false)
{
	sz from = 0;
	while (from < line.len)
	{
		sz? at = line[from..].index_of(word);
		if (catch at) return false;
		sz a = from + at;
		sz b = a + word.len;
		bool left = a == 0 || !util::ident_char(line[a - 1]) || (variants && line[a - 1] == 't' && (a == 1 || !util::ident_char(line[a - 2])));
		bool right = b >= line.len || !util::ident_char(line[b]) || (variants && line[b] == '_');
		if (left && right) return true;
		from = a + 1;
	}
	return false;
}

// In the manual only a use that looks like code counts: `word(` or `::word` (not `project.json`).
fn bool looks_like_use(String line, String word)
{
	if (!has_word(line, word)) return false;
	return line.contains(string::tformat("%s(", word)) || line.contains(string::tformat("::%s", word));
}

fn String c3_examples(String symbol @Desc("a stdlib name, e.g. 'readline', 'HashMap', 'String.split', 'sort::quicksort'"),
	int limit @Desc("number of examples (1..5)") = 3)
	@Desc("Working code that uses a standard library function or type: the verified recipes and the manual's examples, with the lines around each use. Use it after c3_symbol when the signature is not enough to see how it is called.")
	@ReadOnly
{
	String n = symbol.trim(" \t\n");
	if (n.len == 0) return "give a stdlib name, e.g. HashMap or readline";
	String word = last_segment(n);
	if (word.len < 2) return "give a stdlib name with at least two letters, e.g. HashMap or readline";
	int max = clamp(limit, 1, 5);
	DString out = dstring::temp();
	int shown = 0;
	for (int pass = 0; pass < 2 && shown < max; pass++)
	{
		foreach (&e : corpus::entries)
		{
			if (shown >= max) break;
			if (e.kind != (pass == 0 ? "recipe" : "doc")) continue;
			String[] lines = e.body.tsplit("\n");
			foreach (i, line : lines)
			{
				if (line.trim(" \t").starts_with("//")) continue;   // a comment that mentions the word is not a use of it
				if (!(e.kind == "recipe" ? has_word(line, word, true) : looks_like_use(line, word))) continue;
				// a few lines before and after the first use; a recipe is short, so show it all when it is
				sz from = e.kind == "recipe" && lines.len <= 24 ? 0 : (i > 3 ? i - 3 : 0);
				sz to = e.kind == "recipe" && lines.len <= 24 ? lines.len : (i + 6 < lines.len ? i + 6 : lines.len);
				out.appendf("### %s\n", util::clip(e.title, 100));
				foreach (l : lines[from:to - from]) out.appendf("%s\n", util::clip(l, 160));
				shown++;
				break;
			}
		}
	}
	if (shown == 0) return string::tformat("no recipe or manual example uses '%s'. c3_symbol '%s' gives the signature.", util::clip(word, 80), util::clip(n, 80));
	return util::clip(out.str_view(), MAX_REPLY);
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_examples);
	s.@tool(c3_search);
	s.@tool(c3_symbol);
	s.@tool(c3_changes);
	s.@tool(c3_syntax);
}
