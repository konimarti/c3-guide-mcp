module c3guide::test::quality;
import c3guide::tools, c3guide::context, c3guide::test::support;
import std::io;

// Search quality: each question must have the expected text in the reply (top 3 hits for c3_search).
// A regression set: every question must keep working.
struct Case
{
	String tool;
	String arg;
	String want;
}

const Case[*] CASES = {
	{ "c3_search", "foreach with index", "Foreach" },
	{ "c3_search", "defer catch", "defer catch" },
	{ "c3_search", "optional fault catch", "ptional" },
	{ "c3_search", "macro vararg", "Macro vaargs" },
	{ "c3_search", "how to define a fault", "excuse" },
	{ "c3_search", "contracts require ensure", "ontract" },
	{ "c3_search", "temp allocator pool", "pool" },
	{ "c3_search", "enum associated values", "ssociated" },
	{ "c3_search", "bitstruct", "itstruct" },
	{ "c3_search", "generic module type parameters", "eneric" },
	{ "lookup", "String.split", "String.split" },
	{ "lookup", "printfn", "std::io::printfn" },
	{ "lookup", "talloc_array", "talloc_array" },
	{ "lookup", "HashMap", "HashMap" },
	{ "lookup", "tnew_array", "does not exist" },
	{ "c3_search", "create a directory mkdir", "Recipe: create a directory" },
	{ "c3_search", "read a file line by line", "Recipe: read a file line by line" },
	{ "c3_search", "hashmap word count", "Recipe: HashMap" },
	{ "c3_search", "sort array with comparator", "Recipe: sort" },
	{ "c3_search", "faultdef optional return fault", "Recipe: faults" },
	{ "c3_search", "threads mutex", "Recipe: threads" },
	{ "c3_search", "run external command capture output", "Recipe: run an external command" },
	{ "c3_search", "generic struct module Type", "Recipe: generic" },
	{ "c3_search", "main(String[] args)", "Recipe: command line arguments" },
	{ "c3_search", "args[0]", "Recipe: command line arguments" },
	{ "c3_search", "List{", "Recipe: List" },
	{ "c3_search", "coalescing", "Recipe: faults" },
	{ "c3_search", "quicksort cmp", "Recipe: sort" },
	{ "c3_search", "path::ls", "Recipe: list a directory" },
	{ "c3_search", "sort::quicksort", "Recipe: sort" },
	{ "c3_search", "read_line", "readline" },
	{ "c3_search", "sort struct array by field", "Recipe: sort structs" },
	{ "c3_search", "list files matching *.txt", "Recipe: list a directory, only" },
	{ "c3_search", "weekday of a date", "Recipe: calendar date" },
	{ "c3_search", "DateTime day of week", "Recipe: calendar date" },
	{ "c3_search", "read lines from stdin", "Recipe: read lines from standard input" },
	{ "lookup", "tmem", "alias tmem = current_temp" },
	{ "lookup", "mem", "alias mem = thread_allocator" },
	{ "lookup", "read line", "std::io::readline" },
	{ "lookup", "File.read_line", "std::io::readline" },
	{ "lookup", "sort array", "std::sort::quicksort" },
	{ "lookup", "get environment variable", "std::os::env::get_var" },
	{ "lookup", "check if file exists", "std::io::file::exists" },
	{ "lookup", "trim whitespace", "String.trim" },
	{ "lookup", "split string", "String.split" },
	{ "lookup", "concatenate strings", "String.concat" },
	{ "lookup", "string to int", "String.to_int" },
	{ "lookup", "sleep milliseconds", "thread::sleep_ms" },
	{ "lookup", "parse json", "json::parse" },
	{ "lookup", "format string", "string::format" },
	{ "changes", "faultdef", "faultdef" },
	{ "changes", "foreach", "foreach" },
	{ "changes", "type properties", "propert" },
	{ "changes", "void! main", "main" },
	{ "syntax", "attributes", "@noreturn" },
	{ "c3_search", "@require", "@require" },
	{ "c3_search", "$for", "$for" },
};

fn String ask(Case c)
{
	switch (c.tool)
	{
		case "c3_search": return tools::c3_search(c.arg, limit: 3);
		case "lookup": return tools::symbol_reply(c.arg);
		case "changes": return tools::changes_reply(c.arg, 3);
		case "syntax": return tools::syntax_reply(c.arg);
		default: unreachable("unknown tool");
	}
}

fn void every_question_finds_its_answer() @test
{
	context::clear();
	int misses = 0;
	foreach (c : CASES)
	{
		if (support::contains_ci(ask(c), c.want)) continue;
		io::printfn("MISS %-10s %-34s want '%s'", c.tool, c.arg, c.want);
		misses++;
	}
	assert(misses == 0, "%d of %d questions lost their answer", misses, CASES.len);
}
