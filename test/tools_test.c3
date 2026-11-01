module c3guide::test::tools;
import c3guide::tools, c3guide::util, c3guide::test::support;
import std::core::string;

const sz MAX_TEXT = 3300;   // reply cap (3200) plus the cut marker

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
