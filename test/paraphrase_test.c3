module c3guide::test::paraphrase;
import c3guide::tools, c3guide::test::support;
import std::io;

// How people ask for a function when they do not know its name. Written before the synonym table existed and
// not tuned to it: the table has to earn its place by raising this score. A want may list alternatives with '|'.
struct Case
{
	String ask;
	String want;
}

const Case[*] CASES = {
	{ "convert text to an integer", "String.to_int" },
	{ "get the current time", "::now" },
	{ "read a whole file into memory", "file::load" },
	{ "delete a file", "file::delete" },
	{ "remove a directory", "rmdir|rmtree" },
	{ "make a new directory", "path::mkdir" },
	{ "list the entries of a directory", "path::ls" },
	{ "reverse a list", "List.reverse" },
	{ "make a string uppercase", "to_upper" },
	{ "write a string to a file", "file::save" },
	{ "find the position of a substring", "String.index_of" },
	{ "terminate the program", "os::exit" },
	{ "size of a file in bytes", "get_size|file_size" },
	{ "pause execution for a while", "sleep" },
	{ "check that a string begins with a prefix", "starts_with" },
	{ "generate a random number", "random::" },
	// a second set, written after the table, to see whether it helps beyond the first
	{ "check whether a file exists", "file::exists" },
	{ "join two strings together", "concat" },
	{ "convert a string to lowercase", "to_lower" },
	{ "duplicate a string", "String.copy|String.tcopy" },
	{ "exchange two values", "swap" },
	{ "get an environment variable", "get_var" },
	{ "remove whitespace from both ends", "String.trim" },
	{ "break a string into parts", "split" },
	{ "how many items are in the list", "List.len|len" },
	{ "stop the process after an error", "exit|abort" },
};

const int MIN_FOUND = 19;

fn bool found(String reply, String want)
{
	foreach (alt : want.tsplit("|")) if (support::contains_ci(reply, alt)) return true;
	return false;
}

fn void paraphrases_find_their_function() @test
{
	int hits = 0;
	foreach (c : CASES)
	{
		if (found(tools::c3_symbol(c.ask), c.want)) { hits++; continue; }
		io::printfn("MISS %-44s want '%s'", c.ask, c.want);
	}
	io::printfn("paraphrases found: %d of %d", hits, CASES.len);
	assert(hits >= MIN_FOUND, "%d of %d", hits, CASES.len);
}
