module c3guide::tools;
import mcp, std::core::string;
import c3guide::corpus, c3guide::search;
import std::sort;

// Every reply is capped: a docs server that dumps pages into the context is worse than none.
const sz MAX_REPLY = 3200;
const sz MAX_SNIPPET = 900;
const String[*] SYMBOL_KINDS = { "fn", "macro", "method", "mmethod", "type", "var" };

// Cut at a line boundary below `max` bytes.
fn String clip(String s, sz max)
{
	if (s.len <= max) return s;
	String head = s[:max];
	sz cut = head.rindex_of("\n") ?? max;
	return string::tformat("%s\n[...cut]", head[:cut]);
}

fn String hit_text(Entry* e, sz snippet)
{
	String loc = e.loc.len > 0 ? string::tformat("  (%s)", e.loc) : "";
	return string::tformat("### %s%s\n%s\n", e.title, loc, clip(e.body, snippet));
}

fn String format_hits(Hit[] hits, sz snippet)
{
	DString out = dstring::temp();
	foreach (h : hits) out.append(hit_text(&corpus::entries[h.idx], snippet));
	return clip(out.str_view(), MAX_REPLY);
}

// "C3C Release Notes > 0.8.5 Change list > Fixes" -> 800005 (0.8.5), so newer versions sort higher.
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
		foreach (t : terms) if (low.contains(t)) hit++;
		if (hit == 0 || (all && hit < terms.len)) continue;
		out.appendf("%s\n", clip(line, 240));
		n++;
	}
	return out.str_view();
}

fn String strip_prefix(String s, String prefix) => s.starts_with(prefix) ? s[prefix.len..] : s;

fn int clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

fn String c3_search(String query @Desc("what you want to know, e.g. 'foreach with index', 'defer catch'"),
	int limit @Desc("number of results (1..5)") = 3)
	@Desc("Search the C3 language manual (the installed compiler's version). Use this before writing C3 you are not sure about.")
	@ReadOnly
{
	Hit[] hits = search::search(query, { "doc" }, clamp(limit, 1, 5));
	if (hits.len == 0) return "no match in the manual; try other words or c3_symbol for a stdlib name";
	return format_hits(hits, MAX_SNIPPET);
}

fn String c3_changes(String topic @Desc("keyword, e.g. 'foreach', 'faultdef', 'type properties'"),
	int limit @Desc("number of release-note sections (1..5)") = 3)
	@Desc("Search the release notes (0.3.0 to the installed version) for what changed or broke, newest first. Use it when old C3 syntax from memory fails.")
	@ReadOnly
{
	String[] terms = search::query_terms(topic);
	Hit[] hits = search::search(topic, { "change" }, 12);
	if (hits.len == 0) return "nothing in the release notes";
	Hit[] sorted = mem::talloc_array(Hit, hits.len);
	foreach (i, h : hits) sorted[i] = h;
	sort::quicksort(sorted, fn int(Hit a, Hit b) => version_key(corpus::entries[b.idx].title) - version_key(corpus::entries[a.idx].title));
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
	return clip(out.str_view(), MAX_REPLY);
}

fn String c3_syntax(String topic @Desc("one of: attributes, builtins, keywords, type-properties, operators, precedence; or a word to find in them"))
	@Desc("Exact lists from the compiler: attributes, builtins, keywords, type properties, operators, precedence.")
	@ReadOnly
{
	DString out = dstring::temp();
	foreach (&e : corpus::entries)
	{
		if (e.kind != "list") continue;
		if (e.title == topic) return clip(e.body, MAX_REPLY);
		foreach (line : e.body.tsplit("\n"))
		{
			if (line.contains(topic)) out.appendf("%s: %s\n", e.title, line);
		}
	}
	if (out.len() == 0) return "no such list or entry; lists: attributes, builtins, keywords, type-properties, operators, precedence";
	return clip(out.str_view(), MAX_REPLY);
}

// "std::io::printfn" -> "printfn", "std::core::string::String.split" -> "split"
fn String last_segment(String uid)
{
	sz a = uid.rindex_of("::") ?? 0;
	String s = a == 0 ? uid : uid[a + 2..];
	sz d = s.rindex_of(".") ?? 0;
	return d == 0 ? s : s[d + 1..];
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

fn String c3_symbol(String name @Desc("stdlib symbol, e.g. 'printfn', 'io::printfn', 'String.split', 'talloc_array'"))
	@Desc("Exact signature, docs and source location of a C3 standard library function, macro, method or type. Never guess a signature, look it up.")
	@ReadOnly
{
	String n = name.trim(" \t\n");
	DString out = dstring::temp();
	int found = 0;
	foreach (&e : corpus::entries)
	{
		if (!is_symbol(e.kind) || !uid_matches(e.title, n)) continue;
		if (found++ < 6) out.append(hit_text(e, MAX_SNIPPET));
	}
	if (found > 0)
	{
		if (found > 6) out.appendf("[%d more matches; qualify the name, e.g. io::%s]\n", found - 6, n);
		return clip(out.str_view(), MAX_REPLY);
	}
	// not found: say so (a model must not assume a guessed API exists), then offer close names
	out.appendf("'%s' does not exist in the standard library of c3c %s.\n", n, corpus::snapshot_version);
	String lower = n.to_lower_tcopy();
	int shown = 0;
	foreach (&e : corpus::entries)
	{
		if (!is_symbol(e.kind)) continue;
		String last = last_segment(e.title).to_lower_tcopy();
		if (last.len >= 3 && (last.starts_with(lower) || lower.starts_with(last)) && shown < 8)
		{
			if (shown++ == 0) out.append("Similar names:\n");
			out.appendf("  %s\n", e.title);
		}
	}
	if (shown == 0)
	{
		Hit[] hits = search::search(n, SYMBOL_KINDS[..], 5);
		if (hits.len > 0) out.append("Related symbols:\n");
		foreach (h : hits) out.appendf("  %s\n", corpus::entries[h.idx].title);
	}
	return clip(out.str_view(), MAX_REPLY);
}

fn void register(mcp::Server* s)
{
	s.@tool(c3_search);
	s.@tool(c3_symbol);
	s.@tool(c3_changes);
	s.@tool(c3_syntax);
}
