module c3guide::test::search_dollar;
import c3guide::tools, c3guide::search, c3guide::corpus, c3guide::test::support;
import std::core::string;

// A `$`, `$$` or `@` word in a question is a name: an entry without it comes after every entry that has it, and the
// compiler's lists are searched for it too.

fn String first_heading(String q) @local
{
	String r = tools::c3_search(q, limit: 1);
	foreach (line : r.tsplit("\n")) if (line.starts_with("### ")) return line;
	return r;
}

struct Case
{
	String ask;
	String want;   // in the first heading
}

const Case[*] CASES = {
	{ "$embed file optional fallback if file does not exist", "compile-time checks" },
	{ "compile time check if a type implements an interface or is assignable ($defined, $assignable, implements)", "$defined" },
	{ "get the type of an expression with $typeof", "$Typeof" },
	{ "allocate temporary memory with @pool", "@pool" },
	{ "loop over values at compile time with $foreach", "$foreach" },
	{ "current line number $$LINE", "$$LINE" },
	{ "turn an expression into a string with $stringify", "$stringify" },
	{ "what is $assignable", "$assignable" },
	{ "conditional compilation per platform with $if and $feat", "compile-time checks" },
};

fn void dollar_questions_find_their_section() @test
{
	foreach (c : CASES)
	{
		String h = first_heading(c.ask);
		assert(h.contains(c.want), "%s: wanted '%s' in the first hit, got: %s", c.ask, c.want, h);
	}
}

fn void a_contract_question_finds_the_contracts() @test
{
	String h = first_heading("add a contract with @require");
	assert(h.to_lower_tcopy().contains("contract"), "%s", h);
}

// Ranking: with a marked word, the entries that have it come first, whatever their score
fn void entries_without_the_marked_word_rank_below_those_with_it() @test
{
	Hit[] hits = search::search("$embed", { "doc", "recipe" }, 5);
	assert(hits.len > 0);
	foreach (h : hits) assert(corpus::entries[h.idx].body.contains("$embed") || corpus::entries[h.idx].title.contains("$embed"), "%s", corpus::entries[h.idx].title);
	// more matched marked words rank higher: `$embed` and `$defined` together are in the recipe, not in a section of one of them
	Hit[] both = search::search("$embed $defined optional", { "doc", "recipe" }, 3);
	assert(both.len > 0 && corpus::entries[both[0].idx].title.contains("compile-time checks"), "%s", corpus::entries[both[0].idx].title);
}

fn void punctuation_around_a_marked_word_is_not_part_of_it() @test
{
	String[] t = search::query_terms("check ($defined, $assignable) and (@require) or $$LINE.");
	bool d = false;
	bool a = false;
	bool r = false;
	bool l = false;
	foreach (x : t) { if (x == "$defined") d = true; if (x == "$assignable") a = true; if (x == "@require") r = true; if (x == "$$line") l = true; }
	assert(d && a && r && l, "%s", t);
}

// The lists of the compiler are searched for the marked word and come first when one has it exactly
fn void the_syntax_lists_answer_an_exact_marked_word() @test
{
	String r = tools::c3_search("what does $defined do");
	assert(r.starts_with("In the compiler's lists (c3_search scope=syntax):\nkeywords: $defined"), "%s", r);
	r = tools::c3_search("$$LINE current line number");
	assert(r.starts_with("In the compiler's lists") && r.contains("builtins: $$LINE"), "%s", r);
	r = tools::c3_search("how to loop over a slice");
	assert(!r.starts_with("In the compiler's lists"), "%s", r);
}
