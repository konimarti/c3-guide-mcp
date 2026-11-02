module c3guide::test::tools;
import c3guide::tools, c3guide::util, c3guide::search, c3guide::test::support;
import std::core::string, std::time::clock;

const sz MAX_TEXT = 3300;   // reply cap (3200) plus the cut marker

fn void a_huge_query_is_cut_and_stays_fast() @test
{
	DString q = dstring::temp();
	for (int i = 0; i < 20000; i++) q.appendf("word%d ", i);
	Clock t = clock::now();
	String r = tools::c3_search(q.str_view());
	long ms = (long)t.to_now() / 1_000_000;
	assert(ms < 2000, "a 20,000-word query took %d ms", (int)ms);
	assert(r.len > 0);
	assert(search::query_terms(q.str_view()).len <= 16);
}

fn void examples_find_temp_variants_and_skip_prose() @test
{
	String t = tools::c3_examples("String.split");
	assert(t.contains("tsplit"), "%s", t);
	String j = tools::c3_examples("json");
	assert(j.contains("json::parse"), "the JSON recipe: %s", j);
	String none = tools::c3_examples("ZipEntry");
	assert(none.starts_with("no recipe or manual example uses"), "prose and file names are not examples: %s", none);
	String l = tools::c3_examples("file::load");
	assert(l.contains("load_temp") || l.starts_with("no recipe"), "%s", l);
}

fn void old_names_point_to_their_replacement() @test
{
	assert(tools::c3_syntax("$sizeof").contains("T::size"));
	String t = tools::c3_symbol("$typeof");
	assert(t.contains("$Typeof") && t.contains("does not exist"), "%s", t);
	assert(tools::c3_symbol("isz").contains("`sz`"));
}

fn void symbol_finds_names_by_what_they_do() @test
{
	String n = tools::c3_symbol("time now");
	assert(n.contains("::now"), "%s", n);
}

fn void changes_put_renames_before_fixes() @test
{
	String c = tools::c3_changes("faultdef");
	String first = c.tsplit("\n")[0];
	assert(!first.contains("Fixes"), "%s", c);
}

fn void symbol_by_name() @test
{
	assert(tools::c3_symbol("printfn").contains("fn sz? printfn"));
	assert(tools::c3_symbol("io::printfn").contains("fn sz? printfn"), "qualified name");
	assert(tools::c3_symbol("String.split").contains("std::core::string::String.split"));
}

fn void symbol_that_does_not_exist() @test
{
	String t = tools::c3_symbol("tnew_array");
	assert(t.contains("does not exist"), "%s", t);
	assert(!t.tsplit("\n")[0].contains("fn "), "no fake signature in the first line");
	String w = tools::c3_symbol("File.read_line");
	assert(w.starts_with("'File.read_line' does not exist") && w.contains("std::io::readline"), "%s", w);
}

fn void symbol_by_description() @test
{
	String t = tools::c3_symbol("read a line from stdin");
	assert(t.contains("std::io::readline") && t.contains("macro String? readline"), "%s", t);
	assert(t.len <= 3200 + 64, "reply is capped");
	assert(tools::c3_symbol("qzxv wqjk").contains("no symbol matches"));
	assert(tools::c3_symbol("get environment variable").contains("std::os::env::get_var"), "abbreviations (env, var)");
}

fn void symbol_empty_name() @test
{
	assert(tools::c3_symbol("").contains("give a symbol"));
}

fn void symbol_reply_never_cuts_a_utf8_character() @test
{
	// 3190 ASCII bytes, then four 4-byte characters: the cap falls inside the first one
	DString name = dstring::temp();
	for (int i = 0; i < 3190; i++) name.append_char('a');
	for (int i = 0; i < 4; i++) name.append("\U0001F980");
	String t = tools::c3_symbol(name.str_view());
	assert(support::valid_utf8(t), "cut inside a UTF-8 character");
	String s = util::clip("ab\U0001F980", 4);
	assert(support::valid_utf8(s) && s.len < 4 + 16);
}

fn void search_finds_the_manual() @test
{
	assert(tools::c3_search("foreach with index", 3).contains("oreach"));
	assert(tools::c3_search("zzzqqqxx", 3).contains("no match"), "no match is a plain message");
}

fn void search_reply_is_capped() @test
{
	assert(tools::c3_search("defer", 99).len <= MAX_TEXT, "limit is clamped, reply capped");
}

fn void search_keeps_attribute_and_dollar_tokens() @test
{
	assert(tools::c3_search("@require", 3).contains("@require"));
	assert(!tools::c3_search("$for", 3).contains("no match"), "$for is not dropped as a stopword");
	assert(!tools::c3_search("@nodiscard", 3).contains("no match"));
}

fn void changes_by_topic() @test
{
	String t = tools::c3_changes("faultdef", 3);
	assert(t.contains("0.8") || contains_fault(t), "%s", t);
}

fn bool contains_fault(String t) @local => support::contains_ci(t, "fault");

fn void changes_newest_version_first() @test
{
	String t = tools::c3_changes("type properties", 3);
	int prev = 2147483647;
	int heads = 0;
	foreach (line : t.tsplit("\n"))
	{
		if (!line.starts_with("### ")) continue;
		String[] nums = line[4..].tsplit(" ")[0].tsplit(".");
		int key = 0;
		foreach (n : nums) key = key * 100 + (n.to_int() ?? 0);
		assert(key <= prev, "older release listed before a newer one: %s", line);
		prev = key;
		heads++;
	}
	assert(heads >= 2, "need two release sections to check the order");
}

fn void syntax_lists_and_word_search() @test
{
	String t = tools::c3_syntax("type-properties");
	assert(t.contains("::") || t.contains("len"), "%s", t);
	assert(tools::c3_syntax("@noreturn").contains("@noreturn"));
	assert(tools::c3_syntax("zzzqqqxx").contains("no such list"));
}

fn void examples_show_working_code() @test
{
	String t = tools::c3_examples("HashMap");
	assert(t.contains("HashMap{String, int}") && t.len <= 3200 + 64, "%s", t);
	assert(tools::c3_examples("String.split").contains("split"), "qualified name uses its last segment");
	assert(tools::c3_examples("qzxvwqjk").contains("no recipe or manual example"));
	assert(!tools::c3_examples("readline").contains("readline_all"), "whole identifiers only");
}

fn void syntax_without_a_topic_lists_the_topics() @test
{
	assert(tools::c3_syntax("").contains("type-properties"));
}

fn void enum_count_is_found() @test
{
	String t = tools::c3_search("number of enum values count", 2);
	assert(t.contains("Status::len"), "%s", t);
}

fn void renamed_names_point_to_the_release_note() @test
{
	String t = tools::c3_symbol("printfln");
	assert(t.contains("does not exist") && t.contains("Release notes") && t.contains("printfn"), "%s", t);
}

fn void a_name_in_the_wrong_module_finds_the_right_one() @test
{
	String t = tools::c3_symbol("allocator::free");
	assert(t.contains("std::core::mem::alloc::free"), "%s", t);
	assert(!t.contains("libc::free") || t.index_of("std::core::mem::alloc::free") ?? 0 < t.index_of("libc::free") ?? 0, "the module that resembles the asked one comes first: %s", t);
}

fn void optional_interface_methods_are_found() @test
{
	String t = tools::c3_search("call optional interface method that may not be implemented", 2);
	assert(t.contains("Recipe: optional interface method"), "%s", t);
}
