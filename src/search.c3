module c3guide::search;
import c3guide::corpus, c3guide::util, c3guide::context;
import std::core::ascii;
import std::collections::list;
import std::sort, std::math;

// No prebuilt index: a query scans the ~2 MB snapshot (BM25 over case-insensitive word matches,
// title hits weighted x3). Costs a few ms per query and keeps startup at zero.

const float RECIPE_BOOST = 1.4f;
const sz MAX_QUERY_BYTES = 256;
const sz MAX_TERMS = 16;
const float SYNONYM_WEIGHT = 0.5f;   // a word the person did not type counts for less than one they did
const sz MAX_SYNONYMS = 24;

struct Hit
{
	float score;
	int idx;
}

<*
 Count words in `text` equal to one of `terms` (lowercase). tf[i] += 1 per match of terms[i].
 Returns the word count.
*>
fn int count_terms(String text, String[] terms, int[] tf, bool split_us = false)
{
	int words = 0;
	sz i = 0;
	while (i < text.len)
	{
		if (!is_word(text[i], split_us)) { i++; continue; }
		sz s = i;
		while (i < text.len && is_word(text[i], split_us)) i++;
		words++;
		sz full = s;
		while (s < i && (text[s] == '@' || text[s] == '$')) s++;   // `@require` in the manual also counts as `require`
		String w = text[s:i - s];
		String wf = text[full:i - full];
		foreach (k, t : terms)
		{
			bool marked = t[0] == '@' || t[0] == '$';
			if (matches_term(marked ? wf : w, t, split_us && !marked)) tf[k]++;
		}
	}
	return words;
}

// split_us: symbol search, where `read_line` is the two words a person would type
fn bool is_word(char c, bool split_us = false) @inline => ascii::is_alnum(c) || (c == '_' && !split_us) || c == '$' || c == '@';

// A word matches a term if equal (case-insensitive) or a plural of it ("vaargs" for "vaarg").
// With abbrev (symbol search) the names stdlib authors shorten also match the long word people type
// (`env` for "environment"). A generic prefix rule was worse: `str` would match every "string".
const String[2][*] ABBREVIATIONS = { { "env", "environment" }, { "dir", "directory" }, { "var", "variable" }, { "arg", "argument" }, { "buf", "buffer" }, { "mem", "memory" }, { "cmp", "compare" }, { "num", "number" }, { "len", "length" }, { "func", "function" }, { "init", "initialize" } };

fn bool matches_term(String w, String t, bool abbrev = false)
{
	if (abbrev) foreach (pair : ABBREVIATIONS) if (w.len == pair[0].len && t == pair[1] && matches_ci(w, pair[0])) return true;   // length first: matches_ci indexes the term by w
	if (w.len == t.len) return matches_ci(w, t);
	if (w.len == t.len + 1 && (w[t.len] == 's' || w[t.len] == 'S')) return matches_ci(w[:t.len], t);
	return false;
}

fn bool matches_ci(String w, String lower_term)
{
	foreach (i, c : w) if (ascii::to_lower(c) != lower_term[i]) return false;
	return true;
}

// Filler words of natural-language questions ("how to define a fault") only add noise.
const String[*] STOPWORDS = { "how", "to", "a", "an", "the", "of", "in", "is", "do", "does", "i", "with", "for", "what", "use", "using", "can", "from", "and", "into" };

// Spellings people use that differ from the manual's ("vararg" vs "vaargs").
fn String canonical(String t)
{
	return t == "vararg" || t == "varargs" || t == "vaargs" ? "vaarg" : t;
}

// Split a query into lowercase terms (leading @ and $ are dropped, so `@catch` matches `catch`).
fn String[] query_terms(String query)
{
	List{String} out;
	out.init(tmem);
	// the scan costs terms x entries: a 20,000-word query blocked the server for over a minute
	query = query[:util::utf8_boundary(query, MAX_QUERY_BYTES)];
	foreach (w : query.tsplit(" "))
	{
		if (out.len() >= MAX_TERMS) break;
		String t = w.trim(" \t\n,.?!");
		bool marked = t.starts_with("@") || t.starts_with("$");   // `$for`, `@require`: a name, not filler
		String bare = t.trim("@$");
		if (bare.len == 0) continue;
		// a marked term keeps its marker and then only matches the same marked word in the text
		String low = marked ? string::tformat("%c%s", t[0], canonical(bare.to_lower_tcopy())) : canonical(bare.to_lower_tcopy());
		bool stop = false;
		if (!marked) foreach (sw : STOPWORDS) if (sw == low) stop = true;
		if (!stop) out.push(low);
	}
	return out.array_view();
}

// Add the other words of every synonym group that holds one of the query's own terms.
fn String[] with_synonyms(String[] terms)
{
	List{String} out;
	out.init(tmem);
	foreach (t : terms) out.push(t);
	foreach (line : corpus::synonym_text().tsplit("\n"))
	{
		String[] group = line.tsplit(" ");
		bool hit = false;
		foreach (t : terms) foreach (w : group) if (t == w) hit = true;
		if (!hit) continue;
		foreach (w : group)
		{
			if (w.len == 0 || out.len() - terms.len >= MAX_SYNONYMS) continue;
			bool have = false;
			foreach (o : out) if (o == w) have = true;
			if (!have) out.push(w);
		}
	}
	return out.array_view();
}

// "read line" also finds `readline`: add each pair of neighbouring words, glued together, as a term.
fn String[] with_joined_pairs(String[] terms)
{
	List{String} out;
	out.init(tmem);
	foreach (t : terms) out.push(t);
	for (sz i = 0; i + 1 < terms.len; i++)
	{
		if (terms[i][0] == '@' || terms[i][0] == '$' || terms[i + 1][0] == '@' || terms[i + 1][0] == '$') continue;
		out.push(string::tformat("%s%s", terms[i], terms[i + 1]));
	}
	return out.array_view();
}

// "std::io::read_line" -> "std io read line": every character that cannot be part of a word becomes a space.
// With `split_underscore` false `_` stays, as in `read_line`: code the way people paste it (`main(String[] args)`, `path::ls`).
fn String words(String q, bool split_underscore = true)
{
	DString out = dstring::temp();
	foreach (c : q) out.append_char(is_word(c, split_underscore) ? c : ' ');
	return out.str_view();
}

// The manual puts the name of what it defines in backticks (`sz` in the section on integers). Among the best few, a section
// that has one of the typed words that way, as a whole, goes before one that only has the word in a heading or a sample.
fn Hit[] prefer_defining_sections(Hit[] sorted, String[] typed_terms, int limit)
{
	sz top = math::min(sorted.len, (sz)math::max(limit, 3) * 3);
	for (sz i = 0; i < top; i++)
	{
		Entry* e = &corpus::entries[sorted[i].idx];
		if (e.kind != "doc") continue;
		int named = 0;
		foreach (t : typed_terms)
		{
			if (t[0] == '@' || t[0] == '$' || t.len < 2) continue;
			if (e.body.contains(string::tformat("`%s`", t))) named++;
		}
		sorted[i].score *= 1.0f + 0.3f * (float)named;
	}
	sort::quicksort(sorted[:top], fn int(Hit a, Hit b) => a.score < b.score ? 1 : (a.score > b.score ? -1 : a.idx - b.idx));
	return sorted;
}

// Top `limit` entries whose kind is in `kinds` (empty = all), best first.
// symbols: match on words inside identifiers (`read_line`, `std::io::file`) instead of whole identifiers.
fn Hit[] search(String query, String[] kinds, int limit, bool symbols = false)
{
	String[] terms = query_terms(symbols ? words(query) : query);
	if (terms.len == 0) return {};
	if (symbols && terms.len >= 2) terms = with_joined_pairs(terms);
	int typed = (int)terms.len;
	if (symbols) terms = with_synonyms(terms);   // names are short and say little: widen the net
	int nterms = (int)terms.len;
	int[] df = mem::talloc_array(int, nterms);
	int[] tf = mem::talloc_array(int, nterms);
	int[] ttf = mem::talloc_array(int, nterms);
	df[..] = 0;
	int total = (int)corpus::entries.len;

	// pass 1: document frequency per term and average length (cheap second scan avoided by caching)
	float[] len_cache = mem::talloc_array(float, total);
	float[] short_bonus = mem::talloc_array(float, total);   // symbol search: a hit in a short name beats one in a long name
	int[] tf_all = mem::talloc_array(int, (sz)total * nterms);
	int[] ttf_all = mem::talloc_array(int, (sz)total * nterms);
	double sumlen = 0;
	foreach (i, &e : corpus::entries)
	{
		tf[..] = 0;
		ttf[..] = 0;
		int dl = count_terms(e.body, terms, tf, symbols);
		if (symbols)
		{
			// the module and the name (`sort::quicksort`) count as a title hit, the rest of the path only as text
			sz a = e.title.rindex_of("::") ?? 0;
			sz b = a == 0 ? 0 : (e.title[:a].rindex_of("::") ?? 0);
			sz t0 = b == 0 ? 0 : b + 2;
			dl += count_terms(e.title[:t0], terms, tf, true);
			int tw = count_terms(e.title[t0..], terms, ttf, true);
			short_bonus[i] = 4.0f / (2.0f + (float)tw);
		}
		else
		{
			count_terms(e.title, terms, ttf);
		}
		len_cache[i] = (float)dl + 1;
		if (!symbols) short_bonus[i] = 1.0f;
		sumlen += (double)dl + 1;
		for (int k = 0; k < nterms; k++)
		{
			tf_all[i * nterms + k] = tf[k];
			ttf_all[i * nterms + k] = ttf[k];
			if (tf[k] + ttf[k] > 0) df[k]++;
		}
	}
	float avg = (float)(sumlen / total);
	List{Hit} hits;
	hits.init(tmem);
	foreach (i, &e : corpus::entries)
	{
		if (kinds.len > 0)
		{
			bool ok = false;
			foreach (k : kinds) if (k == e.kind) { ok = true; break; }
			if (!ok) continue;
		}
		float s = 0;
		int covered = 0;   // how many of the words the person typed this entry has
		for (int k = 0; k < nterms; k++)
		{
			int f = tf_all[i * nterms + k];
			int tt = ttf_all[i * nterms + k];
			if (f + tt == 0) continue;
			if (k < typed) covered++;
			float idf = math::ln(1.0f + ((float)(total - df[k]) + 0.5f) / ((float)df[k] + 0.5f));
			float norm = f * 2.2f / (f + 1.2f * (0.25f + 0.75f * len_cache[i] / avg));
			float weight = k < typed ? 1.0f : SYNONYM_WEIGHT;
				s += weight * idf * (norm + 3.0f * short_bonus[i] * (tt > 0 ? 1.0f : 0.0f));
		}
		// A section about the question has its words; one that repeats a common word ("type") does not. BM25 saturates
		// the repeated word, so say it once more: the share of the typed words an entry has counts (squared) in a question.
		if (!symbols && typed >= 2) { float share = (float)covered / (float)typed; s *= share * share; }
		if (symbols) s *= context::boost(e.title);   // a name from a module the session works with
		if (e.kind == "recipe") s *= RECIPE_BOOST;   // a program that was compiled and run beats prose that says the same
		if (s > 0) hits.push({ s, (int)i });
	}
	Hit[] sorted = hits.array_view();
	sort::quicksort(sorted, fn int(Hit a, Hit b) => a.score < b.score ? 1 : (a.score > b.score ? -1 : a.idx - b.idx));   // equal scores: the entry that comes first, so a ranking never depends on the sort
	if (!symbols && typed >= 2) sorted = prefer_defining_sections(sorted, terms[:typed], limit);
	return sorted[:(sz)(sorted.len < limit ? sorted.len : limit)];
}
