module c3guide::test::search_tasks;
import c3guide::tools, c3guide::context, c3guide::test::support;
import std::io;

// c3_search for a task in words, not a name. Written before the ranking was touched, from queries that were not used
// to diagnose it (4 of 18 found then, 1 of 10 for the second set), so a change has to earn its place by raising TASKS
// without lowering MANUAL. The first case is the
// one that was reported: "tcp server socket listen accept" returned attributes and inline assembly.
struct Case
{
	String ask;
	String want;   // '|' separates alternatives
}

const Case[*] TASKS = {
	{ "tcp server socket listen accept", "tcp::listen|tcp::accept" },
	{ "connect to a server over tcp and send a message", "tcp::connect" },
	{ "compute an md5 digest", "md5" },
	{ "compute a sha1 digest", "sha1" },
	{ "parse a url", "url::parse" },
	{ "check whether a path is a directory", "is_dir" },
	{ "compress data with deflate", "deflate::compress" },
	{ "compare two strings ignoring case", "compare_to_ignore_case" },
	{ "get the home directory of the user", "get_home_dir" },
	{ "check whether a string contains a substring", "String.contains" },
	{ "write bytes to a socket", "Socket.write" },
	{ "read an xml document", "xml::" },
	{ "copy memory from one buffer to another", "mem::copy" },
	{ "decode a utf8 string into code points", "utf8_codepoints" },
	// a second set, written after the first rule was tried and not run until the second was fixed
	{ "encode bytes as hex", "hex::encode" },
	{ "sleep for a number of milliseconds", "sleep_ms" },
	{ "open a zip archive", "zip::open" },
	{ "get the length of a linked list", "LinkedList.len" },
	{ "split a string at a delimiter", "String.split" },
	{ "bind a udp socket to a port", "udp" },
	{ "convert a string to lower case", "to_lower|convert_to_lower" },
	{ "create a hash set of integers", "HashSet" },
	{ "check whether a character is a digit", "is_digit" },
	{ "run a shell command and get its output", "Recipe: run an external command" },
	// already answered by a recipe: these must stay answered
	{ "lock a mutex around shared data", "Recipe: threads" },
	{ "start a thread and wait for it to finish", "Recipe: threads" },
	{ "measure how long something takes", "Recipe: time" },
	{ "read the bytes of a binary file", "file::load" },
};

// Questions about the language: the manual answers, and no library names are added to the reply.
const Case[*] MANUAL = {
	{ "what does defer do at scope exit", "defer" },
	{ "how are optionals unwrapped", "ptional" },
	{ "difference between a struct and a union", "union" },
	{ "compile time conditions with $if", "$if" },
	{ "what is a distinct type", "distinct" },
	{ "how do slices work", "lice" },
	{ "break and continue with labels", "label" },
	{ "contract on a parameter with require", "@require" },
	{ "how to write a unit test function", "@test" },
	{ "enum with explicit values", "enum" },
};

const int MIN_TASKS = 24;

fn bool found(String reply, String want)
{
	foreach (alt : want.tsplit("|")) if (support::contains_ci(reply, alt)) return true;
	return false;
}

fn void tasks_find_their_answer() @test
{
	context::clear();
	int hits = 0;
	foreach (c : TASKS)
	{
		if (found(tools::c3_search(c.ask, 3), c.want)) { hits++; continue; }
		io::printfn("MISS %-52s want '%s'", c.ask, c.want);
	}
	io::printfn("tasks found: %d of %d", hits, TASKS.len);
	assert(hits >= MIN_TASKS, "too few task queries are answered");
}

fn void manual_questions_stay_in_the_manual() @test
{
	context::clear();
	int hits = 0;
	foreach (c : MANUAL)
	{
		String reply = tools::c3_search(c.ask, 3);
		if (found(reply, c.want) && !support::contains_ci(reply, "Standard library (")) { hits++; continue; }
		io::printfn("MISS %-52s want '%s' and no library names", c.ask, c.want);
	}
	io::printfn("manual questions found: %d of %d", hits, MANUAL.len);
	assert(hits >= MANUAL.len - 1, "a manual question lost its answer or got library names");
}
