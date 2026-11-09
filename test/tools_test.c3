module c3guide::test::tools;
import c3guide::compiler;
import c3guide::tools, c3guide::util, std::os::env, c3guide::search, c3guide::check, c3guide::test::support;
import std::core::string, std::time::clock;

const sz MAX_TEXT = 3600;   // reply cap (3200) plus the cut marker

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
	String t = tools::examples_for("String.split", 3, 24);
	assert(t.contains("tsplit"), "%s", t);
	String j = tools::examples_for("json", 3, 24);
	assert(j.contains("json::parse"), "the JSON recipe: %s", j);
	String none = tools::examples_for("ZipEntry", 3, 24);
	assert(none == "", "prose and file names are not examples: %s", none);
	String l = tools::examples_for("file::load", 3, 24);
	assert(l.contains("load_temp") || l == "", "%s", l);
}

fn void old_names_point_to_their_replacement() @test
{
	assert(tools::syntax_reply("$sizeof").contains("T::size"));
	String t = tools::symbol_reply("$typeof");
	assert(t.contains("$Typeof") && t.contains("does not exist"), "%s", t);
	assert(tools::symbol_reply("isz").contains("`sz`"));
}

fn void symbol_finds_names_by_what_they_do() @test
{
	String n = tools::symbol_reply("time now");
	assert(n.contains("::now"), "%s", n);
}

fn void changes_put_renames_before_fixes() @test
{
	String c = tools::changes_reply("faultdef");
	String first = c.tsplit("\n")[0];
	assert(!first.contains("Fixes"), "%s", c);
}

fn void symbol_by_name() @test
{
	assert(tools::symbol_reply("printfn").contains("fn sz? printfn"));
	assert(tools::symbol_reply("io::printfn").contains("fn sz? printfn"), "qualified name");
	assert(tools::symbol_reply("String.split").contains("std::core::string::String.split"));
}

fn void symbol_that_does_not_exist() @test
{
	String t = tools::symbol_reply("tnew_array");
	assert(t.contains("does not exist"), "%s", t);
	assert(!t.tsplit("\n")[0].contains("fn "), "no fake signature in the first line");
	String w = tools::symbol_reply("File.read_line");
	assert(w.starts_with("'File.read_line' does not exist") && w.contains("std::io::readline"), "%s", w);
}

fn void symbol_by_description() @test
{
	String t = tools::symbol_reply("read a line from stdin");
	assert(t.contains("std::io::readline") && t.contains("macro String? readline"), "%s", t);
	assert(t.len <= 3200 + 64, "reply is capped");
	assert(tools::symbol_reply("qzxv wqjk").contains("no symbol matches"));
	assert(tools::symbol_reply("get environment variable").contains("std::os::env::get_var"), "abbreviations (env, var)");
}

fn void symbol_empty_name() @test
{
	assert(tools::symbol_reply("").contains("give a symbol"));
}

fn void symbol_reply_never_cuts_a_utf8_character() @test
{
	// 3190 ASCII bytes, then four 4-byte characters: the cap falls inside the first one
	DString name = dstring::temp();
	for (int i = 0; i < 3190; i++) name.append_char('a');
	for (int i = 0; i < 4; i++) name.append("\U0001F980");
	String t = tools::symbol_reply(name.str_view());
	assert(support::valid_utf8(t), "cut inside a UTF-8 character");
	String s = util::clip("ab\U0001F980", 4);
	assert(support::valid_utf8(s) && s.len < 4 + 16);
}

fn void search_finds_the_manual() @test
{
	assert(tools::c3_search("foreach with index", limit: 3).contains("oreach"));
	assert(tools::c3_search("zzzqqqxx", limit: 3).contains("no match"), "no match is a plain message");
}

fn void search_reply_is_capped() @test
{
	assert(tools::c3_search("defer", limit: 99).len <= MAX_TEXT, "limit is clamped, reply capped");
}

fn void search_keeps_attribute_and_dollar_tokens() @test
{
	assert(tools::c3_search("@require", limit: 3).contains("@require"));
	assert(!tools::c3_search("$for", limit: 3).contains("no match"), "$for is not dropped as a stopword");
	assert(!tools::c3_search("@nodiscard", limit: 3).contains("no match"));
}

fn void changes_by_topic() @test
{
	String t = tools::changes_reply("faultdef", 3);
	assert(t.contains("0.8") || contains_fault(t), "%s", t);
}

fn bool contains_fault(String t) @local => support::contains_ci(t, "fault");

fn void changes_newest_version_first() @test
{
	String t = tools::changes_reply("foreach", 3);
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
	String t = tools::syntax_reply("type-properties");
	assert(t.contains("::") || t.contains("len"), "%s", t);
	assert(tools::syntax_reply("@noreturn").contains("@noreturn"));
	assert(tools::syntax_reply("zzzqqqxx").contains("no such list"));
}

fn void examples_show_working_code() @test
{
	String t = tools::examples_for("HashMap", 3, 24);
	assert(t.contains("HashMap{String, int}") && t.len <= 3200 + 64, "%s", t);
	assert(tools::examples_for("String.split", 3, 24).contains("split"), "qualified name uses its last segment");
	assert(tools::examples_for("qzxvwqjk", 3, 24) == "");
	assert(!tools::examples_for("readline", 3, 24).contains("readline_all"), "whole identifiers only");
	assert(tools::examples_for("HashMap", 1, 6).tsplit("\n").len <= 9, "an example is cut to the lines asked for");
}

fn void syntax_without_a_topic_lists_the_topics() @test
{
	assert(tools::syntax_reply("").contains("type-properties"));
}

fn void enum_count_is_found() @test
{
	String t = tools::c3_search("number of enum values count", limit: 2);
	assert(t.contains("Status::len"), "%s", t);
}

fn void renamed_names_point_to_the_release_note() @test
{
	String t = tools::symbol_reply("printfln");
	assert(t.contains("does not exist") && t.contains("Release notes") && t.contains("printfn"), "%s", t);
	assert(t.contains("Similar names:") && t.contains("std::io::printfn"), "a name that differs by one letter is a neighbour: %s", t);
}

fn void a_name_in_the_wrong_module_finds_the_right_one() @test
{
	String t = tools::symbol_reply("allocator::free");
	assert(t.contains("std::core::mem::alloc::free"), "%s", t);
	String first = t.tsplit("\n")[2];
	assert(first.contains("::free") && !first.contains(".free"), "a plain function leads, not a method of some type: %s", t);
}

fn void optional_interface_methods_are_found() @test
{
	String t = tools::c3_search("call optional interface method that may not be implemented", limit: 2);
	assert(t.contains("Recipe: optional interface method"), "%s", t);
}

fn void a_cut_utf8_tail_is_dropped() @test
{
	assert(util::cut_utf8("ab") == 2 && util::cut_utf8("") == 0);
	assert(util::cut_utf8("ab\xF0\x9F\xA6") == 2, "three bytes of a four-byte character");
	assert(util::cut_utf8("a\xC3") == 1);
	assert(util::cut_utf8("a\xC3\xA9") == 3, "a complete character stays");
	assert(util::cut_utf8("ab\U0001F980") == 6);
}

fn void examples_refuse_names_with_nothing_in_them() @test
{
	String[*] bads = { "io::", "String.", ".", "::", "a" };
	foreach (bad : bads)
	{
		String r = tools::examples_for(bad, 3, 24);
		assert(r == "", "%s -> %s", bad, r);
	}
	DString big = dstring::temp();
	for (int i = 0; i < 5000; i++) big.append_char('a');
	assert(tools::examples_for(big.str_view(), 3, 24).len <= MAX_TEXT, "nothing of a long name is echoed");
	assert(util::last_part("::x") == "x" && util::last_part(".x") == "x" && util::last_part("std::io::file::") == "");
}

fn void similar_names_are_not_everything_that_shares_a_prefix() @test
{
	String io = tools::symbol_reply("io::");
	assert(!io.contains("Similar names") && !io.contains("ReflectedParam"), "an empty name has no neighbours: %s", io);
	String r = tools::symbol_reply("File.read_line");
	assert(!r.contains("Socket.read") && !r.contains("zip"), "read and read_line are different words: %s", r);
}

fn void release_note_lines_need_the_whole_name() @test
{
	String[*] words = { "foo", "var", "type", "x", "any" };
	foreach (word : words)
	{
		assert(!tools::symbol_reply(word).contains("Release notes"), "%s", word);
	}
	assert(tools::symbol_reply("printfln").contains("Release notes"));
}

fn void changes_understand_dotted_and_qualified_names() @test
{
	assert(!tools::changes_reply("int.sizeof").starts_with("nothing"), "a property written the old way");
	String f = tools::changes_reply("fault", 5);
	foreach (line : f.tsplit("\n"))
	{
		if (!line.starts_with("-")) continue;
		assert(tools::has_word(line.to_lower_tcopy(), "fault") || tools::has_word(line.to_lower_tcopy(), "faults"), "'default' is not 'fault': %s", line);
	}
}

fn void a_name_in_another_spelling_is_found() @test
{
	String[2][*] cases = { { "readLine", "std::io::readline" }, { "toInt", "String.to_int" }, { "getVar", "get_var" }, { "isEmpty", "is_empty" }, { "read_line", "std::io::readline" } };
	foreach (c : cases) assert(tools::symbol_reply(c[0]).contains(c[1]), "%s: %s", c[0], tools::symbol_reply(c[0]));
}

fn void a_type_or_module_lists_what_it_has() @test
{
	String l = tools::symbol_reply("List");
	assert(l.contains("Methods (") && l.contains("push") && l.contains("pop"), "%s", l);
	String m = tools::symbol_reply("std::io::path");
	assert(m.contains("Functions and types (") && m.contains("chdir") && m.contains("cwd"), "%s", m);
	assert(tools::symbol_reply("io::path").contains("chdir"), "a module can be named by its tail too");
}

fn void a_description_with_nothing_close_says_so_and_a_good_one_does_not() @test
{
	assert(tools::symbol_reply("create symbolic link").contains("Weak matches"));
	assert(tools::symbol_reply("compare semantic version strings").contains("Weak matches"));
	String ok = tools::symbol_reply("sha256 hash of bytes");
	assert(!ok.contains("Weak matches") && ok.contains("sha256::hash"), "%s", ok);
	assert(!tools::symbol_reply("pause execution for a while").contains("Weak matches"), "found through a synonym");
}

fn void a_missing_name_points_to_project_code() @test
{
	assert(tools::symbol_reply("curl_easy_perform").contains("give path"));
}

fn void an_inline_type_lists_the_methods_of_its_base() @test
{
	String reply = tools::symbol_reply("TcpSocket");
	assert(reply.contains("distinct type TcpSocket = inline std::net::Socket"), "%s", reply);
	assert(reply.contains("Inherited from std::net::Socket") && reply.contains("close"), "%s", reply);
	assert(tools::symbol_reply("std::net::Socket").contains("struct Socket (InStream, OutStream)"), "the interfaces are part of the signature");
}

fn void a_lookup_says_whether_the_name_is_real() @test
{
	String real = tools::c3_lookup("tcp::listen_to", "", 3, false);
	assert(real.contains("std::net::tcp::listen_to"), "%s", real);
	String fake = tools::c3_lookup("nosuchfunction", "", 3, false);
	assert(fake.contains("does not exist"), "%s", fake);
	assert(tools::c3_lookup("", "", 1, false).contains("give query"));
}

fn void a_lookup_shows_one_example_and_the_source_on_request() @test
{
	String t = tools::c3_lookup("String.split", "", 1, false);
	assert(t.contains("### Example:") && !t.contains("Source ("), "%s", t);
	String none = tools::c3_lookup("String.split", "", 0, false);
	assert(!none.contains("### Example:"), "%s", none);
	String src = tools::c3_lookup("io::printfn", "", 0, true);
	assert(src.contains("Source (") || compiler::stdlib_root().len == 0, "%s", src);
}

fn void a_name_that_is_a_method_or_a_builtin_says_so() @test
{
	String m = tools::c3_lookup("bits::ctz", "", 0, false);
	assert(m.contains("is a method") && !m.contains("BITS"), "%s", m);
	String b = tools::c3_lookup("$$ctz", "", 0, false);
	assert(b.contains("compiler builtin"), "%s", b);
}

fn void every_signature_names_the_compiler_it_came_from() @test
{
	String r = tools::symbol_reply("String.split");
	assert(r.contains("[c3c "), "%s", r);
}

fn void several_names_in_one_lookup_are_answered_one_by_one() @test
{
	String r = tools::c3_lookup("String.to_upper_tcopy mem::temp_new_array", "", 0, false);
	assert(r.contains("== String.to_upper_tcopy ==") && r.contains("== mem::temp_new_array =="), "%s", r);
	assert(r.contains("to_upper_tcopy(") && !r.contains("Weak matches"), "%s", r);
	String w = tools::c3_lookup("read a line from stdin", "", 0, false);   // plain words stay a description
	assert(!w.contains("== "), "%s", w);
}

// `File` is declared in std::io and its methods in std::io::file: a type lists its methods whatever module declares them.
fn void a_type_lists_methods_declared_in_another_module() @test
{
	String r = tools::symbol_reply("std::io::File");
	assert(r.contains("Methods (") && r.contains("size") && r.contains("read_byte"), "%s", r);
	// a type of the same name in an unrelated module does not take them
	assert(tools::method_of("std::io::file::File.size", "std::io::File", false), "a module inside the other");
	assert(tools::method_of("std::io::File.close", "std::io::File", false), "the same module");
	assert(!tools::method_of("std::net::File.size", "std::io::File", false), "an unrelated module, two types of the name");
	assert(tools::method_of("std::net::File.size", "std::io::File", true), "one type has the name: the methods are its");
	assert(!tools::method_of("std::io::file::FileInfo.size", "std::io::File", true), "another type");
	// a type with its methods in its own module is listed as before
	String h = tools::symbol_reply("HashMap");
	assert(h.contains("Methods (") && h.contains("get_ref"), "%s", h);
}

fn void an_alias_shows_its_target_and_the_methods_of_it() @test
{
	if (compiler::stdlib_root().len == 0) return;   // the source of the library is what says what the alias stands for
	String r = tools::symbol_reply("std::io::path::Path");
	$if env::WIN32:
		assert(r.contains("Alias for PathWin"), "%s", r);
	$else
		assert(r.contains("Alias for PathPosix") && r.contains("this platform"), "%s", r);
		assert(r.contains("Methods (") && r.contains("basename") && r.contains("tappend"), "%s", r);
	$endif
	// and the same by the short name
	assert(tools::symbol_reply("Path").contains("Alias for"), "%s", tools::symbol_reply("Path"));
}

// scope=changes with a version asks for that release (it used to rank 0.8.4 and 0.6.0 first for "0.8.5")
fn void a_version_query_returns_that_releases_notes() @test
{
	foreach (q : (String[]){ "0.8.5", "v0.8.5", "0.8.5_1" })
	{
		String r = tools::changes_reply(q, 3);
		assert(r.starts_with("### 0.8.5 Change list"), "%s: %s", q, r);
		assert(!r.contains("### 0.8.4") && !r.contains("### 0.6.0"), "%s: %s", q, r);
	}
	String one = tools::changes_reply("0.8.5", 1);
	assert(one.starts_with("### 0.8.5 Change list > Changes") && !one.contains("Stdlib changes") && !one.contains("> Fixes"), "the limit applies, changes before fixes: %s", one);
	// a minor version is all its releases, newest first
	String minor = tools::changes_reply("0.8", 5);
	assert(minor.starts_with("### 0.8.5"), "%s", minor);
	// the words filter within the release
	String words = tools::changes_reply("0.8.5 removed", 3);
	assert(words.contains("Removed experimental support") && !words.contains("### 0.8.4"), "%s", words);
	// a word is found by its stem inside a release: renamed, rename and renaming
	foreach (w : (String[]){ "renamed", "rename", "renaming" })
	{
		String ren = tools::changes_reply(string::tformat("0.8.0 %s", w), 3);
		assert(ren.starts_with("### 0.8.0") && ren.contains("renamed `has_equals`") && !ren.contains("### 0.8.1"), "%s: %s", w, ren);
	}
	assert(tools::changes_reply("0.8.5 renamed", 3).starts_with("nothing in the release notes of 0.8.5"), "0.8.5 renames nothing");
	String none = tools::changes_reply("0.8.5 zzzzqq", 3);
	assert(none.starts_with("nothing in the release notes of 0.8.5"), "%s", none);
	// a release the snapshot does not have says so and names the ones it has
	String newer = tools::changes_reply("0.8.6", 3);
	assert(newer.contains("no notes for it") && newer.contains("0.8.5") && newer.contains("newer than the snapshot"), "%s", newer);
	assert(!newer.contains("### 0.8.4"), "%s", newer);
	String older = tools::changes_reply("0.2.0", 3);
	assert(older.contains("no notes for it") && older.contains("0.3.0"), "%s", older);
	// through the tool, and a question that merely holds a version still gets the general answer
	assert(tools::c3_search("0.8.5", "changes").starts_with("### 0.8.5"));
	assert(!tools::c3_search("what was renamed in 0.7 for fault", "all").contains("nothing in the release notes of"));
}

// `TempAllocator.used` is a field: it exists, and its type is known
fn void a_field_looked_up_as_a_member_is_said_to_be_a_field() @test
{
	String r = tools::symbol_reply("TempAllocator.used");
	assert(r.contains("is a field of") && r.contains("of type sz") && !r.contains("does not exist"), "%s", r);
	String h = tools::symbol_reply("HashMap.count");
	assert(h.contains("is a field of") && h.contains("of type int"), "%s", h);
	// a name that is neither a method nor a field still does not exist
	assert(tools::symbol_reply("TempAllocator.nothere_at_all").contains("does not exist"));
	// and a method is still a method
	assert(!tools::symbol_reply("String.split").contains("is a field of"));
}

fn void a_name_in_no_syntax_list_points_to_where_it_is() @test
{
	String r = tools::syntax_reply("assignable");
	assert(r.contains("none of the lists") && r.contains("c3_search") && r.contains("c3_lookup") && r.contains("builtins"), "%s", r);
	assert(tools::syntax_reply("zzzqqqxx").contains("no such list"));
}
