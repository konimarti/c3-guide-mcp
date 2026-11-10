module c3guide::test::next_step;
import c3guide::tools, c3guide::check, c3guide::test::support;
import std::core::string;

// The answers name the next tool or parameter: a refusal says the way out, an error that depends on the platform says how
// to check another one, and `source=true` shows the whole implementation (so nobody reads lib/std with sed).

fn void a_snippet_refusal_says_the_way_out() @test
{
	String r = check::c3_check("fn void f() { char[*] d = $embed(\"/etc/passwd\"); }");
	assert(r.starts_with("rejected:") && r.contains("Way out:") && r.contains("c3_check path="), "%s", r);
}

fn void an_error_that_names_another_platform_says_how_to_check_it() @test
{
	String r = check::c3_check("import std::os::win32;\nfn void f() { win32::no_such_thing(); }");
	assert(r.contains("error:") && r.contains("platform=windows-x64"), "%s", r);
	// asked for a platform already: no advice to ask for one
	String plain = check::c3_check("fn void f() { int x = ; }");
	assert(plain.contains("error:") && !plain.contains("platform="), "%s", plain);
}

fn void source_shows_the_whole_function_not_a_few_lines() @test
{
	String r = tools::c3_lookup("std::io::Formatter.vprintf", examples: 0, source: true);
	int lines = 0;
	foreach (l : r.tsplit("\n")) if (l.len > 2 && l[0] >= '0' && l[0] <= '9' && l.contains(": ")) lines++;
	assert(lines > 45, "a long function was cut at 40 lines: %d lines\n%s", lines, r);
	assert(r.contains("\n}\n") || r.contains(": }\n"), "%s", r);
	assert(!r.contains("[cut after"), "%s", r);
}
