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
String snapshot_version;

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
			first = false;
			continue;
		}
		entries[n++] = { f[0], f[1], f[2], f[3] };
	}
	entries = entries[:n];
}
