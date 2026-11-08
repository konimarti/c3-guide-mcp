module c3guide::tools;
import c3guide::compiler, c3guide::proc;
import mcp, std::core::string;
import c3guide::corpus, c3guide::context, c3guide::search, c3guide::util, c3guide::live, c3guide::outline;
import std::sort, std::math, std::collections::list, std::io::file, libc;

// Every reply is capped: a docs server that dumps pages into the context is worse than none.
const sz MAX_REPLY = 3200;
const sz MAX_SNIPPET = 900;
const sz MAX_RECIPE = 1800;
const String[*] SYMBOL_KINDS = { "fn", "macro", "method", "mmethod", "type", "var" };

fn String hit_text(Entry* e, sz snippet, String tag = "")
{
	String loc = e.loc.len > 0 ? string::tformat("  (%s)", e.loc) : "";
	return string::tformat("### %s%s%s\n%s\n", e.title, loc, tag, util::clip(e.body, snippet));
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
	{ "$sizeof", "`$sizeof(T)` is `T::size` since 0.8 (`$alignof(T)` is `T::alignment`). c3_check rewrites it; c3_search scope=syntax type-properties lists them." },
	{ "$alignof", "`$alignof(T)` is `T::alignment` since 0.8. c3_check rewrites it when it gets the code as `code`." },
	{ "$typeof", "`$typeof(x)` is spelled `$Typeof(x)` where a type is expected (`$Typeof(x) y = 4;`)." },
	{ "$vacount", "`$vacount` is `$vaarg.len` since 0.8. c3_check rewrites it when it gets the code as `code`." },
	{ "$vasplat", "`$vasplat` is `...$vaarg` since 0.8. c3_check rewrites it when it gets the code as `code`." },
	{ "isz", "`isz` is `sz` since 0.8 (`usz` is unchanged). c3_check rewrites it when it gets the code as `code`." },
	{ "fault", "`fault E { A, B }` is `faultdef A, B;` since 0.8. c3_search scope=changes faultdef has the notes." },
	{ "def", "`def Foo = int;` is `alias Foo = int;` since 0.7." },
};

fn String legacy_note(String name)
{
	foreach (pair : LEGACY) if (pair[0] == name) return string::tformat("'%s' is old C3 syntax: %s\n", name, pair[1]);
	return "";
}

fn String strip_prefix(String s, String prefix) => s.starts_with(prefix) ? s[prefix.len..] : s;

fn int clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

const String SEARCH_HELP = "give query: what you want to know ('foreach with index', 'defer catch'). scope=changes searches the release notes (what was renamed or removed), scope=syntax the exact lists (attributes, builtins, keywords, type-properties, operators, precedence).";

fn String c3_search(String query @Desc("what you want to know, e.g. 'foreach with index', 'defer catch'; with scope=syntax a list name or a word to find in the lists") = "",
	String scope @Desc("all (default): manual, recipes and standard library names. changes: the release notes, newest first (use it when old syntax or an old name fails). syntax: the compiler's exact lists of attributes, builtins, keywords, type-properties, operators, precedence") = "",
	int limit @Desc("number of results (1..5)") = 3,
	String file @Desc("the C3 file you are editing, if any: the standard library modules it imports narrow the library names") = "")
	@Desc("Start here for any 'how do I' question about C3: searches the language manual, the verified recipes (small working programs: read a file, HashMap, sort, mkdir, threads...) and the standard library names that fit the words ('tcp server' gives std::net::tcp). scope=changes finds what changed between releases, scope=syntax gives the compiler's exact lists. Use c3_lookup when you already know the name.")
	@ReadOnly
{
	String q = query.trim(" \t\n");
	String sc = scope.trim(" \t\n");
	if (sc == "syntax") return syntax_reply(q);
	if (q.len == 0) return SEARCH_HELP;
	if (sc == "changes") return string::tformat("%s%s", changes_reply(q, limit), manual_note());
	if (sc.len > 0 && sc != "all" && sc != "manual") return "scope must be all, changes or syntax";
	String reply = search_all(q, limit, file);
	// a question about what changed is answered by the release notes too
	if (asks_about_change(q))
	{
		String notes = changes_reply(q, 2);
		if (!notes.starts_with("nothing in the release notes")) reply = string::tformat("%s\nRelease notes:\n%s", reply, notes);
	}
	return string::tformat("%s%s", reply, manual_note());
}

fn bool asks_about_change(String q)
{
	String low = q.to_lower_tcopy();
	String[*] marks = { "renam", "remov", "deprecat", "0.6", "0.7", "migrat", "no longer", "changed", "old syntax", "used to" };
	foreach (m : marks) if (low.contains(m)) return true;
	return false;
}

// The manual, the recipes and the release notes are one release's snapshot: say so when the compiler in use is another.
fn String manual_note()
{
	String have = compiler::compiler_version();
	if (have.len == 0 || have == corpus::snapshot_version) return "";
	return string::tformat("\n(manual, recipes and release notes: c3c %s snapshot; your c3c is %s. Library signatures and the syntax lists come from your compiler, and c3_check has the last word.)\n", corpus::snapshot_version, have);
}

fn String search_all(String query, int limit, String file)
{
	int n = clamp(limit, 1, 5);
	if (file.len > 0) context::note_file(file);
	Hit[] hits = search::search(query, { "recipe", "doc" }, n);
	// pasted code (`main(String[] args)`, `path::ls`, `List{`) has no words until the punctuation is gone
	if (hits.len == 0) hits = search::search(search::words(query, false), { "recipe", "doc" }, n);
	// The library is searched on every question: a task ("tcp server") is often one word in the manual ("accept" in
	// attributes) and a whole module in the library. A name that holds two of the question's words is shown when it has
	// as many of them as the manual's best section, or the section has under half; the one with more goes first.
	live::ensure();
	Hit[] syms = search::search(query, SYMBOL_KINDS[..], 3, true);
	String[] terms = search::query_terms(search::words(query));
	int manual = hits.len > 0 ? words_in(&corpus::entries[hits[0].idx], terms) : 0;
	int library = 0;
	int library_context = 0;   // a name from a module the session works with counts as one more word
	foreach (h : syms)
	{
		int words = words_in(&corpus::entries[h.idx], terms);
		library = math::max(library, words);
		library_context = math::max(library_context, words + (context::boost(corpus::entries[h.idx].title) > 1.0f ? 1 : 0));
	}
	if (hits.len == 0 && syms.len == 0) return "no match in the manual; try other words or c3_lookup for a stdlib name";
	bool show_library = syms.len > 0 && (hits.len == 0 || (library >= 2 && (library_context >= manual || manual * 2 < (int)terms.len)));
	bool library_first = show_library && library_context > manual;
	DString out = dstring::temp();
	if (library_first)
	{
		out.append(hits.len == 0 ? "not in the manual; closest standard library names:\n" : "Standard library (c3_lookup has the full signature):\n");
		foreach (h : syms) out.append(brief(&corpus::entries[h.idx]));
	}
	// A manual section with under half of the words only got in through one of them ("accept" in the attributes):
	// next to a better answer it is noise. A recipe is a program that ran: it stays.
	List{Hit} fitting;
	fitting.init(tmem);
	foreach (h : hits)
	{
		bool few = terms.len >= 3 && corpus::entries[h.idx].kind != "recipe" && words_in(&corpus::entries[h.idx], terms) * 2 < (int)terms.len;
		if (!few) fitting.push(h);
	}
	// when none fits, the manual has nothing on it: say so, unless the library has the answer
	Hit[] manual_hits = fitting.len() > 0 ? fitting.array_view() : (show_library ? (Hit[]){} : hits);
	if (manual_hits.len > 0)
	{
		bool weak = fitting.len() == 0;
		if (library_first) out.append("\nManual:\n");
		if (weak) out.appendf("Weak match: the best manual section has %d of your %d words.\n", manual, (int)terms.len);
		out.append(format_hits(manual_hits, MAX_SNIPPET));
	}
	if (show_library && !library_first)
	{
		out.append("\nStandard library (c3_lookup has the full signature):\n");
		foreach (h : syms) out.append(brief(&corpus::entries[h.idx]));
	}
	return util::clip(out.str_view(), MAX_REPLY);
}

fn String changes_reply(String topic, int limit = 3)
{
	String words = search::words(topic, false);   // `int.sizeof`, `String.split`, `0.8.0`: the punctuation is not part of a word
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

const String[*] SYNTAX_LISTS = { "attributes", "builtins", "keywords", "type-properties", "operators", "precedence" };
const String SYNTAX_TOPICS = "lists: attributes, builtins, keywords, type-properties, operators, precedence; or give a word to find in them";
const sz MAX_LIST = 48 * 1024;

String[6] live_lists;

// A copy that lives as long as the server (not tracked by the allocator: the lists are read once).
fn String keep(String s)
{
	char* p = libc::malloc(s.len + 1);
	mem::copy(p, s.ptr, s.len);
	return (String)p[:s.len];
}
bool live_lists_read;

// The body of one list: from the c3c in use when it is another release than the snapshot, else the snapshot's.
fn String syntax_list(String name)
{
	String have = compiler::compiler_version();
	if (have.len > 0 && have != corpus::snapshot_version)
	{
		if (!live_lists_read)
		{
			live_lists_read = true;
			foreach (i, l : SYNTAX_LISTS)
			{
				String[] argv = { compiler::c3c_binary(), string::tformat("--list-%s", l) };
				int status = 0;
				bool timed_out = false;
				String? out = proc::run_capped(argv, &status, &timed_out, { .deadline_ms = 3000, .max_output = MAX_LIST });
				if (try out) { if (status == 0 && !timed_out && out.len > 0) live_lists[i] = keep(out.trim()); }
			}
		}
		foreach (i, l : SYNTAX_LISTS) if (l == name && live_lists[i].len > 0) return live_lists[i];
	}
	foreach (&e : corpus::entries) if (e.kind == "list" && e.title == name) return e.body;
	return "";
}

fn String syntax_reply(String topic)
{
	String t = topic.trim(" \t\n");
	if (t.len == 0) return SYNTAX_TOPICS;
	foreach (l : SYNTAX_LISTS) if (l == t) return util::clip(syntax_list(l), MAX_REPLY);
	DString out = dstring::temp();
	foreach (l : SYNTAX_LISTS)
	{
		foreach (line : syntax_list(l).tsplit("\n"))
		{
			if (line.contains(t)) out.appendf("%s: %s\n", l, line);
		}
	}
	if (out.len() == 0)
	{
		String old = legacy_note(t);
		if (old.len > 0) return old;
		return "no such list or entry; lists: attributes, builtins, keywords, type-properties, operators, precedence. A standard library name (a macro like @pool) is c3_lookup.";
	}
	return util::clip(out.str_view(), MAX_REPLY);
}

// "std::io::printfn" -> "printfn", "std::core::string::String.split" -> "split"
// Does the symbol uid match the user's name? "printfn", "io::printfn", "String.split" and the full uid all do.
fn bool uid_matches(String uid, String name)
{
	if (uid == name) return true;
	if (uid.len <= name.len) return false;
	char sep = uid[uid.len - name.len - 1];
	return uid.ends_with(name) && (sep == ':' || sep == '.');
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
fn String describe(String query, bool strict = false)
{
	Hit[] hits = search::search(query, SYMBOL_KINDS[..], 5, true);
	if (hits.len == 0) return string::tformat("no symbol matches '%s'; try other words", query);
	DString out = dstring::temp();
	out.appendf("Symbols matching '%s' (c3c %s):\n", query, corpus::symbols_version);
	// Words are all a description search has. When even the best hit has few of them, the nearest names are not an
	// answer: say so, since "the standard library has no such function" is the usual truth (symlinks, mkdtemp...)
	String[] terms = search::query_terms(search::words(query));
	int best = 0;
	foreach (h : hits)
	{
		int n = words_in(&corpus::entries[h.idx], terms);
		if (n > best) best = n;
	}
	// a name that was not found (`outline_source`) is not described by a symbol that has only one of its two words
	if (strict && terms.len == 2 && best < 2) return string::tformat("no symbol matches '%s'; try other words", query);
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
	foreach (&e : corpus::entries) if (corpus::is_symbol_kind(e.kind) && uid_matches(e.title, name)) n++;
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

const String LOOKUP_HELP = "give query: a name (printfn, String.split, HashMap, std::io::path) or what you want to do ('read a line from stdin'). With path (a project directory, a .c3 file, a .c3l library, deps) the project's code and its libraries are searched too; path alone lists its declarations.";

fn String c3_lookup(String query @Desc("a name ('printfn', 'io::printfn', 'String.split', 'HashMap', 'std::io::path') or, when you do not know the name, what it does ('read a line from a file', 'trim whitespace')") = "",
	String path @Desc("where your code is: a project directory (its src and libraries are searched), a .c3 file, a .c3l library or a directory of libraries. Default: the project you last gave to c3_check, c3_test or c3_run. Without a query it lists the declarations there") = "",
	int examples @Desc("working code that calls a library name (0..3, default 1)") = 1,
	bool source @Desc("also show the implementation of a library function or macro") = false)
	@Desc("Look up a name wherever it lives: your project, its libraries (deps) or the C3 standard library. A standard library name gives the exact signature, docs, source location and a working example; a description ('read a line from stdin') gives the functions that do it; a type or module (`List`, `std::io::path`) lists its methods or functions; a name that does not exist says what it became (renamed, a method, a compiler builtin). Never guess a signature, look it up.")
	@ReadOnly
{
	String q = query.trim(" \t\n");
	if (path.len > 0) outline::note_project(path);
	if (q.len == 0)
	{
		if (path.len > 0) return outline::outline_path(path);
		return LOOKUP_HELP;
	}
	// "to_upper_tcopy mem::temp_new_array": several names in one call are looked up one by one
	String[] names = name_list(q);
	if (names.len > 1)
	{
		DString many = dstring::temp();
		foreach (n : names) many.appendf("== %s ==\n%s\n", n, lookup_one(n, path, 0, false));
		String all = many.str_view();
		return string::tformat("%s%s", util::clip(all, 5200), compiler::version_note(all.contains("does not exist")));
	}
	String reply = lookup_one(q, path, examples, source);
	return string::tformat("%s%s", reply, compiler::version_note(reply.contains("does not exist")));
}

// A query of two to six tokens that all look like names (no plain words) and of which at least one is a standard library
// name is a list of names, not a description. Otherwise: empty.
fn String[] name_list(String q)
{
	live::ensure();
	String[] raw = q.tsplit(" ");
	String[] out = mem::talloc_array(String, 6);
	int n = 0;
	int known = 0;
	foreach (r : raw)
	{
		String t = r.trim(" ,;\t\n");
		if (t.len == 0) continue;
		if (n >= 6) return {};
		foreach (c : t) if (!(c.is_alnum() || c == '_' || c == ':' || c == '.' || c == '@' || c == '$')) return {};
		out[n++] = t;
		bool is_known = first_symbol(t) != null;
		if (is_known) known++;
		// a plain word ("lowercase") is a description word, a name has :: . _ @ $ or exists
		if (!is_known && !t.contains("::") && !t.contains(".") && !t.contains("_") && !t.contains("@") && !t.contains("$")) return {};
	}
	return (n >= 2 && known >= 1) ? out[:n] : {};
}

fn String lookup_one(String q, String path, int examples, bool source)
{
	int pcount = 0;
	String pscope = "";
	String proj = outline::project_lookup(path, q, 10, &pcount, &pscope);
	bool found_std = false;
	int exact = 0;
	String std = symbol_reply(q, &found_std, &exact);
	DString out = dstring::temp();
	if (pcount > 0)
	{
		out.appendf("In %s%s (%d match%s):\n%s", pscope, path.len == 0 ? " (the project you last used; give path for another)" : "", pcount, pcount == 1 ? "" : "es", proj);
		if (found_std && exact > 2)
		{
			// your own declaration is the answer; the library has many names that end the same: say so in a line
			out.appendf("\nThe standard library has %d names ending in '%s' (c3_lookup 'module::%s' for one), e.g.", exact, util::clip(q, 40), util::clip(q, 40));
			int shown = 0;
			foreach (&e : corpus::entries)
			{
				if (shown >= 3) break;
				if (corpus::is_symbol_kind(e.kind) && uid_matches(e.title, q)) out.appendf("%s %s", shown++ > 0 ? "," : "", e.title);
			}
			out.append("\n");
		}
		else if (found_std) { out.appendf("\nStandard library:\n%s", std); }
	}
	else
	{
		out.append(std);
		if (!found_std)
		{
			if (pscope.len > 0) { out.appendf("(Also searched %s%s and its libraries: nothing declares '%s'.)\n", pscope, path.len == 0 ? ", the project you last used (give path for another)," : "", util::clip(q, 60)); }
			else { out.append("(No project to search: give path to look in your own code and its libraries.)\n"); }
		}
	}
	if (found_std && exact > 1 && source && !q.contains(" ")) out.appendf("\n(source and examples are shown for one name: %d match this, qualify it, e.g. %s)\n", exact, short_uid(first_symbol(q).title));
	if (found_std && exact == 1 && !q.contains(" "))
	{
		Entry* e = first_symbol(q);
		if (e != null)
		{
			if (source) out.append(source_excerpt(e));
			if (examples > 0) out.append(examples_for(q, clamp(examples, 0, 3), 18));
		}
	}
	return util::clip(out.str_view(), source ? 5200 : 4000);
}

// `std::collections::map::HashMap.init` -> `HashMap.init`; `std::io::printfn` -> `io::printfn`
fn String short_uid(String uid)
{
	if (uid.contains(".")) return uid[((uid.rindex_of("::") ?? -2) + 2)..];
	sz last = uid.rindex_of("::") ?? -1;
	sz prev = last > 0 ? (uid[:last].rindex_of("::") ?? -2) : -2;
	return uid[(prev + 2)..];
}

fn String c3_refs(String query @Desc("the name whose uses you want: an identifier, or Type.name / module::name (the last part is searched)") = "",
	String path @Desc("a project directory or a .c3 file; its libraries (deps) are included. Default: the project you last gave to c3_check, c3_test, c3_run or c3_lookup") = "",
	bool stdlib @Desc("search the C3 standard library of your c3c instead of a project") = false,
	int limit @Desc("number of uses shown (1..100)") = 30,
	String rename_to @Desc("instead of listing uses: the new name. Returns the exact edits (old line and new line, per file) that rename every use; nothing is written") = "")
	@Desc("Where a name is used: file, line and the line itself, with the declaration marked. Read with the C3 grammar, so comments and strings are not uses. Use it instead of grep and sed before you rename, move or delete a function, type or module: it matches whole identifiers only, so `Server` does not match `TcpServerSocket`, and comments and strings are not uses. With rename_to=NEW it returns the edits that rename it (every use, nothing written), so a rename is a plan you apply and then c3_check. With stdlib=true it shows how the standard library itself uses a name.")
	@ReadOnly
{
	if (query.trim().len == 0) return "give query: the name to find, e.g. 'new_server' or 'HashMap.init'";
	if (path.len > 0) outline::note_project(path);
	return util::clip(outline::refs_reply(query, path, stdlib, clamp(limit, 1, 100), rename_to.trim()), 6000);
}

// The first symbol entry whose name is `name`.
fn Entry* first_symbol(String name)
{
	foreach (&e : corpus::entries) if (corpus::is_symbol_kind(e.kind) && uid_matches(e.title, name)) return e;
	return null;
}

// The implementation of a standard library function, macro or type: its lines in the installed library, cut at the end of
// the declaration or after 40 lines.
fn String source_excerpt(Entry* e)
{
	String loc = e.loc;
	sz c1 = loc.rindex_of(":") ?? -1;
	if (c1 <= 0) return "";
	sz c2 = loc[:c1].rindex_of(":") ?? -1;
	if (c2 <= 0) return "";
	int? row = loc[c2 + 1:c1 - c2 - 1].to_int();
	if (catch row) return "";
	String root = compiler::stdlib_root();
	if (root.len == 0 || row < 1) return "";
	char[]? data = file::load_temp(string::tformat("%s/%s", root, loc[:c2]));
	if (catch data) return "";
	String[] lines = ((String)data).tsplit("\n");
	DString out = dstring::temp();
	int depth = 0;
	bool opened = false;
	for (int i = row - 1; i < (int)lines.len && i < row - 1 + 40; i++)
	{
		String l = lines[i];
		out.appendf("%d: %s\n", i + 1, util::clip(util::sanitize_utf8(l), 160));
		String code = l[:l.index_of("//") ?? l.len];
		foreach (c : code)
		{
			if (c == '{') { depth++; opened = true; }
			if (c == '}') depth--;
		}
		if (opened && depth <= 0) break;
		if (!opened && code.trim().ends_with(";")) break;
		if (!opened && code.contains("=>") && code.trim().ends_with(";")) break;
	}
	return string::tformat("\nSource (%s):\n%s", e.loc, out.str_view());
}

// `ctz` is a method of many types: one line with the types that have it, and one signature. `owner`: only the modules whose
// last part is this (empty: any).
fn String method_summary(String word, String owner)
{
	String w = word.to_lower_tcopy();
	DString types = dstring::temp();
	String sample = "";
	String sample_loc = "";
	int count = 0;
	foreach (&e : corpus::entries)
	{
		if (!(e.kind == "method" || e.kind == "mmethod") || util::last_part(e.title).to_lower_tcopy() != w) continue;
		if (owner.len > 0 && !e.title.to_lower_tcopy().contains(string::tformat("::%s::", owner))) continue;
		String receiver = e.title[(e.title.rindex_of("::") ?? -2) + 2..];
		receiver = receiver[:receiver.rindex_of(".") ?? receiver.len];
		if (count++ < 14) types.appendf("%s%s", count > 1 ? ", " : "", receiver);
		if (sample.len == 0) { sample = e.body.tsplit("\n")[0]; sample_loc = e.loc; }
	}
	if (count == 0) return "";
	return string::tformat("'%s' is a method, called on a value (`x.%s(...)`), not a function of a module. It exists on %d type%s: %s%s\n  %s  (%s)\n  c3_lookup 'Type.%s' for one of them.\n", word, word, count, count == 1 ? "" : "s", types.str_view(), count > 14 ? ", ..." : "", util::clip(sample, 160), sample_loc, word);
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
		if (!corpus::is_symbol_kind(e.kind) || !e.title.starts_with(prefix) || e.title.len <= prefix.len + 1) continue;
		String rest = e.title[prefix.len + 1..];
		bool is_method = e.title[prefix.len] == '.';
		if (methods ? !is_method : (e.title[prefix.len] != ':' || rest.contains("::") || rest.contains("."))) continue;
		if (methods ? !(e.kind == "method" || e.kind == "mmethod") : false) continue;
		rest = methods ? rest : rest[(rest.index_of(":") ?? -1) + 1..];
		if (count++ > 0) names.append(", ");
		names.append(rest);
	}
	if (count == 0) return "";
	return string::tformat("%s (%d): %s\n  c3_lookup %s%sNAME for one signature.\n", methods ? "Methods" : "Functions and types", count, util::clip(names.str_view(), 1400), util::last_part(prefix), methods ? "." : "::");
}

// "distinct type TcpSocket = inline std::net::Socket": the methods of Socket are TcpSocket's too.
fn String inherited_methods(String body)
{
	String marker = " = inline ";
	sz at = body.index_of(marker) ?? -1;
	if (at < 0) return "";
	String base = body[at + marker.len..];
	base = base[:base.index_of("\n") ?? base.len];
	base = base[:base.index_of("{") ?? base.len];   // `List{String}`: the methods are listed under `List`
	String methods = members_of(base, true);
	return methods.len == 0 ? "" : string::tformat("Inherited from %s: %s", base, methods);
}

// `std::io::path`, `io::path`, `path`: the module, when it is one. Its functions and macros, names only.
fn String module_listing(String n)
{
	String full = "";
	foreach (&e : corpus::entries)
	{
		if (!corpus::is_symbol_kind(e.kind) || e.title.contains(".")) continue;
		String parent = e.title[:e.title.rindex_of("::") ?? 0];
		if (parent.len > 0 && uid_matches(parent, n)) { full = parent; break; }
	}
	if (full.len == 0) return "";
	return string::tformat("%s\n%s", full, members_of(full, false));
}

fn String symbol_reply(String name, bool* found_out = null, int* exact_out = null)
{
	if (found_out) *found_out = false;
	live::ensure();
	String n = name.trim(" \t\n");
	if (n.len == 0) return "give a symbol name, e.g. printfn or String.split";
	DString out = dstring::temp();
	if (n.contains(" ") || n.contains("\n") || n.contains("\t"))   // several words: a description, not a name
	{
		String d = describe(n);
		if (found_out) *found_out = !d.starts_with("no symbol");
		return d;
	}
	int found = 0;
	foreach (&e : corpus::entries)
	{
		if (!corpus::is_symbol_kind(e.kind) || !uid_matches(e.title, n)) continue;
		if (found++ < 6) out.append(hit_text(e, MAX_SNIPPET, string::tformat("  [c3c %s]", corpus::symbols_version)));   // the version is on every signature: a note said once is missed
		if (found == 1) context::note_symbol(e.title);
	}
	if (found_out && found > 0) *found_out = true;
	if (exact_out) *exact_out = found;
	if (found > 0)
	{
		if (found > 6) out.appendf("[%d more matches; qualify the name, e.g. %s]\n", found - 6, short_uid(first_symbol(n).title));
		foreach (&e : corpus::entries)
		{
			if (e.kind != "type" || !uid_matches(e.title, n)) continue;
			out.append(members_of(e.title, true));
			out.append(inherited_methods(e.body));
		}
		return util::clip(out.str_view(), MAX_REPLY);
	}
	String module_members = module_listing(n);
	if (module_members.len > 0)
	{
		if (found_out) *found_out = true;
		return module_members;
	}
	if (n.starts_with("$$"))
	{
		String inner = n[2..];
		String builtin = string::tformat("'%s' is a compiler builtin (c3_search scope=syntax topic builtins lists them); the standard library wraps many of them as methods.\n", n);
		if (syntax_list("builtins").contains(n))
		{
			if (found_out) *found_out = true;
			String wrapped = inner.len > 1 ? method_summary(inner, "") : "";
			return string::tformat("%s%s", builtin, wrapped);
		}
	}
	// not found: say so (a model must not assume a guessed API exists), then offer close names
	out.append(legacy_note(n));
	out.appendf("'%s' does not exist in the standard library of c3c %s. (Your own or library code: give path.)\n", n, corpus::symbols_version);
	// `allocator::free` is asked for by its old module: the same name in another module is the likely answer
	String q = util::last_part(n).to_lower_tcopy();
	String module_hint = "";
	if (n.contains("::")) { String m = n[:n.rindex_of("::") ?? 0].to_lower_tcopy(); module_hint = m[(m.rindex_of("::") ?? -2) + 2..]; }
	int shown = 0;
	bool qualified = module_hint.len > 0;
	String qkey = name_key(q);
	for (int pass = 0; pass < 5; pass++)
	{
		foreach (&e : corpus::entries)
		{
			if (!corpus::is_symbol_kind(e.kind) || shown >= 8) continue;
			String uid = e.title.to_lower_tcopy();
			String last = util::last_part(e.title).to_lower_tcopy();
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
	// `bits::ctz`: the module has it, but as a method of a type (`x.ctz()`), not as a function of the module
	bool as_method = false;
	if (n.contains("::"))
	{
		String owner = n[:n.rindex_of("::") ?? 0].to_lower_tcopy();
		owner = owner[(owner.rindex_of("::") ?? -2) + 2..];
		String summary = method_summary(util::last_part(n), owner);
		if (summary.len > 0)
		{
			as_method = true;
			if (found_out) *found_out = false;
			out.append(summary);
		}
	}
	out.append(rename_notes(util::last_part(n)));
	// a wrong name usually has the right words in it (`File.read_line`, `tnew_array`)
	String words = as_method ? "" : describe(n, true);
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

// Working code that calls the library name `n`: the verified recipes first, then the manual's examples, each cut to
// `max_lines` lines. "" when nothing uses it.
fn String examples_for(String n, int limit, sz max_lines)
{
	String word = util::last_part(n);
	if (word.len < 2) return "";
	int max = clamp(limit, 0, 5);
	if (max == 0) return "";
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
				bool whole = e.kind == "recipe" && lines.len <= max_lines;
				sz from = whole ? 0 : (i > 3 ? i - 3 : 0);
				sz to = whole ? lines.len : (i + 6 < lines.len ? i + 6 : lines.len);
				if (to - from > max_lines) to = from + max_lines;
				out.appendf("### Example: %s\n", util::clip(e.title, 100));
				foreach (l : lines[from:to - from]) out.appendf("%s\n", util::clip(l, 160));
				shown++;
				break;
			}
		}
	}
	if (shown == 0) return "";
	return string::tformat("\n%s", out.str_view());
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_lookup);
	s.@tool(c3_search);
	s.@tool(c3_refs);
}
