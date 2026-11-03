module c3guide::test::live;
import c3guide::live, c3guide::corpus, c3guide::check, c3guide::search, c3guide::test::support;
import std::io::path;
import std::core::string, std::collections::map, std::os::env, std::io;

// Run with C3_DIR=<the c3c install the snapshot belongs to> (CI sets it). The port in src/live.c3 must give the
// same text as scripts/gen_corpus.py for every symbol, or the server would answer differently depending on
// whether the docs were read live. docgen documents the platform it runs on (the snapshot was made on Linux), so
// another platform lists symbols the snapshot does not have (allowed), defines a few under another file (allowed,
// up to 5%), and must still return nearly all of the snapshot's symbols.
fn void live_reading_reproduces_the_snapshot() @test
{
	String? dir = env::tget_var("C3_DIR");
	if (catch dir) { io::printn("skipped: C3_DIR is not set"); return; }
	Entry[] live = live::read_live(string::tformat("%s/c3c", dir))!!;
	defer free_live(live);
	HashMap{String, Entry*} by_title;
	by_title.tinit();
	sz snapshot_symbols = 0;
	foreach (&e : corpus::entries) if (corpus::is_symbol_kind(e.kind)) { by_title.set(e.title, e); snapshot_symbols++; }
	int common = 0;
	int differ = 0;
	DString shown = dstring::temp();
	foreach (&l : live)
	{
		Entry*? s = by_title.get(l.title);
		if (catch s) continue;   // only on this platform
		common++;
		if (s.kind != l.kind || s.body != l.body || s.loc != l.loc)
		{
			if (differ++ < 4) shown.appendf("differs: %s\n  snapshot: %s | %s | %s\n  live:     %s | %s | %s\n", l.title, s.kind, util_first(s.body), s.loc, l.kind, util_first(l.body), l.loc);
		}
	}
	// exact where the snapshot was made; elsewhere the platform-specific libc and os bindings are other symbols
	// under the same name (tcgetattr is in linux.c3 for the snapshot and darwin.c3 on macOS): a few percent may differ
	int allowed = env::LINUX ? 0 : common / 20;
	assert(differ <= allowed, "%d of %d common symbols differ (%d allowed)\n%s", differ, common, allowed, shown.str_view());
	assert(common * 100 >= (int)snapshot_symbols * 90, "only %d of the snapshot's %d symbols came back", common, (int)snapshot_symbols);
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
// same ranking for every query (search breaks ties by position). Only meaningful where docgen lists exactly the
// snapshot's symbols (the platform the snapshot was made on).
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
	bool ok = corpus::symbols_live && corpus::symbols_version == "9.9";
	bool same_library = corpus::entries.len == snapshot.len;
	bool same_order = same_library;
	if (same_library) foreach (i, &e : corpus::entries) if (e.title != snapshot[i].title) same_order = false;
	DString after = dstring::temp();
	foreach (q : queries) after.appendf("%s => %s\n", q, top5(q));
	Entry[] merged = corpus::entries;   // put the snapshot back first, so a failed assert cannot leave the overlay on
	corpus::entries = snapshot;
	corpus::symbols_version = version;
	corpus::symbols_live = false;
	free(merged);
	free_live(live);
	assert(ok);
	if (!same_library) { io::printn("skipped: this platform's docgen lists other symbols than the snapshot"); return; }
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
		Entry[]? r = live::entries_from_json(bad);
		if (try r) { assert(r.len == 0, "'%s' gave %d entries", bad, (int)r.len); free(r); }
	}
	// wrong shapes inside: nothing may crash, whatever comes out
	Entry[]? odd = live::entries_from_json("{\"modules\": {\"std::x\": {\"functions\": [5, \"s\", null, {\"name\": 3}], \"types\": 7}}}");
	if (try odd) free_live(odd);
}

fn void standard_library_paths_are_kept_from_lib_std() @test
{
	Entry[] got = live::entries_from_json(`{"modules": {"std::x": {"functions": [
		{"name": "a", "kind": "function", "uid": "std::x::a", "file": "/home/someone/c3/lib/std/core/a.c3:1:2"},
		{"name": "b", "kind": "function", "uid": "std::x::b", "file": "c3c-install/c3/lib/std/b.c3:3:4"},
		{"name": "c", "kind": "function", "uid": "std::x::c", "file": "lib/std/c.c3:5:6"},
		{"name": "d", "kind": "function", "uid": "std::x::d", "file": "/opt/lib/std/tools/c3/lib/std/d.c3:7:8"}]}}}`)!!;
	defer free_live(got);
	String[*] want = { "lib/std/core/a.c3:1:2", "lib/std/b.c3:3:4", "lib/std/c.c3:5:6", "lib/std/d.c3:7:8" };
	assert(got.len == 4, "%d entries", (int)got.len);
	foreach (w : want)
	{
		bool found = false;
		foreach (&e : got) if (e.loc == w) found = true;
		assert(found, "no entry located at %s", w);
	}
}

// A build tree of c3c has the library twice: <install>/lib/std (a copy that docgen rejects, because the compiler also
// loads the real one) and <install>/../lib/std. The fake compiler below behaves like that.
fn void a_build_tree_with_two_copies_of_the_library_still_works() @test
{
	Path dir = support::make_temp_dir("c3tree");
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	support::sh(string::tformat("mkdir -p '%s/build/lib/std' '%s/lib/std' && python3 -c \"import json; json.dump({'modules': {'std::x': {'functions': [{'name': 'f%%d' %% i, 'kind': 'function', 'uid': 'std::x::f%%d' %% i, 'file': 'lib/std/x.c3:1:1'} for i in range(1200)]}}}, open('%s/dg.json', 'w'))\"", root, root, root));
	String fake = support::write_fake(dir, "c3c", string::tformat("if [ \"$1\" = --version ]; then echo 'C3 Compiler Version: 9.9.9'; echo 'Installed directory: %s/build'; exit 0; fi\ncase \"$3\" in */build/lib/std) echo \"error: 'CShake' would shadow a previous declaration.\" >&2; exit 1;; esac\ncat '%s/dg.json'", root, root));
	Entry[] live = live::read_live(fake)!!;
	defer free_live(live);
	assert(live.len == 1200, "%d entries", (int)live.len);
}
