module c3guide::test::live;
import c3guide::live, c3guide::corpus, c3guide::check, c3guide::search;
import std::core::string, std::collections::map, std::os::env, std::io;

// Run with C3_DIR=<the c3c install the snapshot belongs to> (CI sets it). The port in src/live.c3 must give the
// same text as scripts/gen_corpus.py for every symbol, or the server would answer differently depending on
// whether the docs were read live.
fn void live_reading_reproduces_the_snapshot() @test
{
	String? dir = env::tget_var("C3_DIR");
	if (catch dir) { io::printn("skipped: C3_DIR is not set"); return; }
	Entry[] live = live::read_live(string::tformat("%s/c3c", dir))!!;
	defer free_live(live);
	HashMap{String, Entry*} by_title;
	by_title.tinit();
	foreach (&e : corpus::entries) if (corpus::is_symbol_kind(e.kind)) by_title.set(e.title, e);
	int missing = 0;
	int differ = 0;
	DString shown = dstring::temp();
	foreach (&l : live)
	{
		Entry*? s = by_title.get(l.title);
		if (catch s) { if (missing++ < 3) shown.appendf("not in snapshot: %s\n", l.title); continue; }
		if (s.kind != l.kind || s.body != l.body || s.loc != l.loc)
		{
			if (differ++ < 4) shown.appendf("differs: %s\n  snapshot: %s | %s | %s\n  live:     %s | %s | %s\n", l.title, s.kind, util_first(s.body), s.loc, l.kind, util_first(l.body), l.loc);
		}
	}
	assert(missing == 0 && differ == 0, "%d symbols only live, %d differ out of %d\n%s", missing, differ, live.len, shown.str_view());
}

fn String util_first(String body)
{
	String[] lines = body.tsplit("\n");
	return lines.len > 0 ? lines[0] : "";
}

fn void free_live(Entry[] list)
{
	foreach (&e : list) { free(e.kind); free(e.title); free(e.body); free(e.loc); }
	free(list);
}

fn String top5(String query)
{
	DString out = dstring::temp();
	Hit[] hits = search::search(query, { "fn", "macro", "method", "mmethod", "type", "var" }, 5, true);
	foreach (h : hits) out.appendf("%s|", corpus::entries[h.idx].title);
	return out.str_view();
}

// The overlay of an unchanged library must change nothing a user can see: same entries in the same order, so the
// same ranking for every query (search breaks ties by position).
fn void a_live_overlay_of_an_unchanged_library_ranks_the_same() @test
{
	String? dir = env::tget_var("C3_DIR");
	if (catch dir) { io::printn("skipped: C3_DIR is not set"); return; }
	String[*] queries = { "free", "len", "new", "parse", "copy", "init", "add", "read line", "get environment variable" };
	DString before = dstring::temp();
	foreach (q : queries) before.appendf("%s => %s\n", q, top5(q));
	Entry[] snapshot = corpus::entries;
	String version = corpus::symbols_version;
	Entry[] live = live::read_live(string::tformat("%s/c3c", dir))!!;
	corpus::replace_symbols(live, "9.9");
	assert(corpus::symbols_live && corpus::symbols_version == "9.9");
	assert(corpus::entries.len == snapshot.len, "the same number of entries: %d vs %d", (int)corpus::entries.len, (int)snapshot.len);
	bool same_order = true;
	foreach (i, &e : corpus::entries) if (e.title != snapshot[i].title) same_order = false;
	DString after = dstring::temp();
	foreach (q : queries) after.appendf("%s => %s\n", q, top5(q));
	Entry[] merged = corpus::entries;   // put the snapshot back and release what the overlay allocated
	corpus::entries = snapshot;
	corpus::symbols_version = version;
	corpus::symbols_live = false;
	free(merged);
	free_live(live);
	assert(same_order, "the entries moved");
	assert(before.str_view() == after.str_view(), "ranking changed:\n%s\nvs\n%s", before.str_view(), after.str_view());
}

fn void no_compiler_means_the_snapshot_stays() @test
{
	sz n = corpus::entries.len;
	assert(!live::overlay_from("/nonexistent/c3c", "9.9"));
	assert(corpus::entries.len == n && !corpus::symbols_live);
}

fn void odd_docgen_output_is_refused_not_trusted() @test
{
	String[*] garbage = { "", "not json", "[]", "{\"modules\": 5}" };
	foreach (bad : garbage)
	{
		Entry[]? r = live::entries_from_json(bad, "");
		if (try r) { assert(r.len == 0, "'%s' gave %d entries", bad, (int)r.len); free(r); }
	}
	// wrong shapes inside: nothing may crash, whatever comes out
	Entry[]? odd = live::entries_from_json("{\"modules\": {\"std::x\": {\"functions\": [5, \"s\", null, {\"name\": 3}], \"types\": 7}}}", "");
	if (try odd) free_live(odd);
}
