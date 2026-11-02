module c3guide::test::live;
import c3guide::live, c3guide::corpus, c3guide::check;
import std::core::string, std::collections::map, std::os::env, std::io;

// Run with C3_DIR=<the c3c install the snapshot belongs to> (CI sets it). The port in src/live.c3 must give the
// same text as scripts/gen_corpus.py for every symbol, or the server would answer differently depending on
// whether the docs were read live.
fn void live_reading_reproduces_the_snapshot() @test
{
	String? dir = env::tget_var("C3_DIR");
	if (catch dir) return;
	Entry[] live = live::read_live(string::tformat("%s/c3c", dir))!!;
	defer corpus::free_entries(live);
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

fn void a_live_overlay_swaps_the_symbols_and_a_failure_changes_nothing() @test
{
	String? dir = env::tget_var("C3_DIR");
	if (catch dir) return;
	sz before = corpus::entries.len;
	defer corpus::restore_snapshot();

	assert(!live::overlay_from("/nonexistent/c3c", "9.9"), "no compiler: the snapshot stays");
	assert(corpus::entries.len == before && !corpus::symbols_live);

	assert(live::overlay_from(string::tformat("%s/c3c", dir), "9.9"));
	assert(corpus::symbols_live && corpus::symbols_version == "9.9");
	assert(corpus::entries.len == before, "the same number of entries: %d vs %d", (int)corpus::entries.len, (int)before);
	bool alias_kept = false;
	foreach (&e : corpus::entries) if (e.title.ends_with("::tmem") && e.body.starts_with("alias ")) alias_kept = true;
	assert(alias_kept, "aliases are not in docgen's output: they come from the snapshot");
}

fn void odd_docgen_output_is_refused_not_trusted() @test
{
	String[*] cases = { "", "not json", "[]", "{\"modules\": 5}", "{\"modules\": {\"std::x\": {\"functions\": [5, \"s\", null, {\"name\": 3}]}}}" };
	foreach (bad : cases)
	{
		Entry[]? r = live::entries_from_json(bad, "");
		if (try r) corpus::free_entries(r);   // whatever came out, nothing crashed
	}
}
