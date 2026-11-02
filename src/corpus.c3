module c3guide::corpus;
import std::core::string;

// Embedded snapshot built by scripts/gen_corpus.py. Records end with \x1e, fields split by \x1f:
// kind, title, body, loc. All strings are slices into the embedded blob: nothing is copied.
const char[*] BLOB = $embed("../data/corpus.dat");

// Groups of words that mean the same thing, one group per line (scripts/update_synonyms.py).
const char[*] SYNONYMS = $embed("../data/synonyms.txt");

fn String synonym_text() => (String)SYNONYMS[..];

struct Entry
{
	String kind;
	String title;
	String body;
	String loc;
}

Entry[] entries;
String snapshot_version;      // the c3c release the manual and the release notes belong to
String symbols_version;       // the c3c release the standard library signatures belong to: the same, unless read live
bool symbols_live;
Entry[] snapshot_entries;     // the embedded entries, kept while the symbols are live
Entry[] live_symbols;         // the heap entries read from the compiler

// Parse the blob once at startup (one allocation: the Entry array).
fn void load()
{
	String all = (String)BLOB[..];
	sz count = 0;
	foreach (c : all) if (c == 0x1e) count++;
	entries = mem::new_array(Entry, count - 1);
	sz n = 0;
	bool first = true;
	foreach (rec : all.tsplit("\x1e"))
	{
		if (rec.len == 0) continue;
		String[] f = rec.tsplit("\x1f", 4);
		if (f.len < 4) continue;
		if (first)
		{
			snapshot_version = f[2];
			symbols_version = f[2];
			first = false;
			continue;
		}
		entries[n++] = { f[0], f[1], f[2], f[3] };
	}
	entries = entries[:n];
}

// What stays when the symbols are replaced: everything that is not a standard library symbol, and the `alias`
// variables the snapshot adds (`mem`, `tmem`: docgen does not list them). Alias *types* are docgen's: they are replaced.
fn bool keeps_in_overlay(Entry* e) => !is_symbol_kind(e.kind) || (e.kind == "var" && e.body.starts_with("alias "));

fn bool is_symbol_kind(String kind) => kind == "fn" || kind == "macro" || kind == "method" || kind == "mmethod" || kind == "type" || kind == "var";

// Swap the standard library symbols for ones read from the c3c the user runs (see live.c3). The aliases in the
// snapshot (`mem`, `tmem`...) stay: docgen does not list them. Everything else is untouched.
fn void replace_symbols(Entry[] live, String version)
{
	sz keep = 0;
	foreach (&e : entries) if (keeps_in_overlay(e)) keep++;
	Entry[] merged = mem::new_array(Entry, keep + live.len);
	sz n = 0;
	foreach (&e : entries) if (keeps_in_overlay(e)) merged[n++] = *e;
	foreach (&e : live) merged[n++] = *e;
	if (!symbols_live) snapshot_entries = entries;
	entries = merged;
	live_symbols = live;
	symbols_version = version;
	symbols_live = true;
}

// Entries whose strings were copied to the heap (see live.c3).
fn void free_entries(Entry[] list)
{
	foreach (&e : list) { free(e.kind); free(e.title); free(e.body); free(e.loc); }
	free(list);
}

// Back to the embedded snapshot, releasing what the live read allocated.
fn void restore_snapshot()
{
	if (!symbols_live) return;
	free(entries);
	free_entries(live_symbols);
	entries = snapshot_entries;
	live_symbols = {};
	symbols_version = snapshot_version;
	symbols_live = false;
}
