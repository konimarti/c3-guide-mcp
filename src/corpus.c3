module c3guide::corpus;
import std::core::string, std::sort;

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
// snapshot (`mem`, `tmem`...) stay: docgen does not list them. Everything else is untouched. The snapshot keeps its
// symbols as one block sorted by name; the live ones are sorted the same way and take the block's place, so a library
// that did not change ranks exactly as the snapshot does (a search breaks ties by position).
fn void replace_symbols(Entry[] live, String version)
{
	sz others = 0;
	sz aliases = 0;
	foreach (&e : entries)
	{
		if (!is_symbol_kind(e.kind)) { others++; }
		else if (keeps_in_overlay(e)) { aliases++; }
	}
	Entry[] block = mem::new_array(Entry, live.len + aliases);
	sz n = 0;
	foreach (&l : live) block[n++] = *l;
	foreach (&e : entries) if (is_symbol_kind(e.kind) && keeps_in_overlay(e)) block[n++] = *e;
	sort::quicksort(block, fn int(Entry a, Entry b) {
		int c = a.title.compare_to(b.title);
		return c != 0 ? c : a.body.compare_to(b.body);
	});
	Entry[] merged = mem::new_array(Entry, others + block.len);
	n = 0;
	bool placed = false;
	foreach (&e : entries)
	{
		if (!is_symbol_kind(e.kind)) { merged[n++] = *e; continue; }
		if (placed) continue;
		placed = true;
		foreach (&b : block) merged[n++] = *b;
	}
	if (!placed) foreach (&b : block) merged[n++] = *b;
	free(block);
	entries = merged;
	symbols_version = version;
	symbols_live = true;
}
