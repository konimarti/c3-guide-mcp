module c3guide::test::suggest;
import c3guide::tools, c3guide::test::support;
import std::core::string;

// c3_lookup of a name that is not in the library says what it probably is: the first line after "did you mean:", or
// nothing when the library has nothing close ("nothing is better than noise").

struct Miss
{
	String name;
	String first;   // the first suggestion, "" when there must be none
}

const Miss[*] MISSES = {
	{ "String.trepeat", "DString.append_repeat" },
	{ "file::tload", "file::load_temp" },
	{ "io::File.get_length", "File.size" },
	{ "alloc::allocated", "" },
	{ "Arena", "allocators::ArenaAllocator" },
	{ "libc::fstat", "" },
	{ "libc::dup2", "" },
	// three more, from names a person writes after another language
	{ "String.to_upper", "String.convert_to_upper" },
	{ "String.tsplit_x", "String.tsplit" },
	{ "Path.exists", "path::exists" },
	// the names of other languages
	{ "List.append", "List.push" },
	{ "HashMap.put", "HashMap.set" },
};

fn String first_suggestion(String reply) @local
{
	bool next = false;
	foreach (line : reply.tsplit("\n"))
	{
		if (next) return line.trim().tsplit(" ")[0];
		if (line == "did you mean:") next = true;
	}
	return "";
}

fn void a_missing_name_gets_the_right_suggestion_or_none() @test
{
	foreach (m : MISSES)
	{
		String r = tools::c3_lookup(m.name);
		assert(r.contains("does not exist"), "%s: %s", m.name, r);
		String got = first_suggestion(r);
		assert(got == m.first, "%s: wanted '%s', got '%s'\n%s", m.name, m.first, got, r);
	}
}

fn void at_most_three_suggestions_and_none_for_a_field() @test
{
	String r = tools::c3_lookup("String.trepeat");
	int n = 0;
	bool in = false;
	foreach (line : r.tsplit("\n"))
	{
		if (line == "did you mean:") { in = true; continue; }
		if (in && line.starts_with("  ") && !line.starts_with("  std::")) { n++; }
		else if (in) { break; }
	}
	assert(n >= 1 && n <= 3, "%d", n);
	r = tools::c3_lookup("TempAllocator.used");
	assert(r.contains("is a field of") && !r.contains("did you mean") && !r.contains("does not exist"), "%s", r);
}

// libc::fstat: the standard library has no wrapper, and the answer says to declare an extern
fn void a_missing_libc_function_says_to_declare_an_extern() @test
{
	String r = tools::c3_lookup("libc::fstat");
	assert(r.contains("extern fn") && r.contains("@extern(\"fstat\")") && !r.contains("did you mean"), "%s", r);
}

// `String.length` suggested `String.count` (it counts occurrences): the length is the `.len` member
fn void the_length_of_a_string_is_a_member_not_a_method() @test
{
	foreach (n : (String[]){ "String.length", "String.size", "char[].length" })
	{
		String r = tools::c3_lookup(n);
		assert(r.contains("does not exist") && r.contains("`.len` member"), "%s: %s", n, r);
		assert(!r.contains("did you mean") && !r.contains("String.count   ") && !r.contains("String.count_"), "%s: %s", n, r);
	}
}
