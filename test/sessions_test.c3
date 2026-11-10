module c3guide::test::sessions;
import c3guide::tools, c3guide::check, c3guide::context, c3guide::test::support, c3guide::proc;
import std::core::string, std::io, std::io::file, std::io::path;

// Calls that coders really made in their sessions (the replay lists of the orchestrator), with what the answer must hold.
// A call that was wrong once is here so it stays right: renamed names, the `$` words, fields, aliases, a project and its
// library, a snippet checked with the project. A project the calls need is built in a fresh folder below.

struct Call
{
	String tool;       // search, changes, syntax, lookup, check, run, test
	String a;          // query / code / path (a project's folder is `@P`)
	String b;          // scope-like second argument: path of a lookup, code of a check with a path, filter of a test
	String must;       // '|' separates alternatives: one of them must be in the answer ("" = nothing needed)
	String must_not;   // '|' separates: none may be in the answer
	bool refused;      // the answer is a refusal ("rejected") and that is right
}

const Call[*] CALLS = {
	// --- search
	{ "syntax", "type-properties", "", "alignment", "", false },
	{ "syntax", "assignable", "", "$assignable", "", false },
	{ "changes", "0.8.6", "", "0.8.6", "", false },
	{ "changes", "0.8.5", "", "0.8.5", "", false },
	{ "changes", "multiply by 1.5", "", "", "release 1.5", false },
	{ "changes", "foreach", "", "foreach", "", false },
	{ "search", "what is sz type", "", "Integers", "", false },
	{ "search", "compile time check if a type implements an interface or is assignable ($defined, $assignable, implements)", "", "$defined", "optional interface method", false },
	{ "search", "$embed file optional fallback if file does not exist", "", "compile-time checks|Failure to load", "@optional", false },
	{ "search", "enum names values reflection", "", "Enum", "", false },
	// --- library names, fields, aliases, methods of files and paths
	{ "lookup", "TrackingAllocator", "", "struct TrackingAllocator", "does not exist", false },
	{ "lookup", "Formatter", "", "struct Formatter", "does not exist", false },
	{ "lookup", "std::io::File", "", "struct File", "does not exist", false },
	{ "lookup", "Path", "", "PathPosix", "does not exist", false },
	{ "lookup", "PathPosix", "", "distinct type PathPosix", "does not exist", false },
	{ "lookup", "File.size", "", "fn long? size", "does not exist", false },
	{ "lookup", "String.tsplit", "", "fn String[] tsplit", "does not exist", false },
	{ "lookup", "DString.chop", "", "fn void chop", "does not exist", false },
	{ "lookup", "TempAllocator.used", "", "is a field of", "does not exist", false },
	// --- names that do not exist: what to use instead, or that there is nothing
	{ "lookup", "String.trepeat", "", "did you mean:\n  DString.append_repeat", "", false },
	{ "lookup", "file::tload", "", "did you mean:\n  file::load_temp", "", false },
	{ "lookup", "alloc::allocated", "", "does not exist", "did you mean", false },
	{ "lookup", "libc::fstat", "", "extern fn", "did you mean", false },
	{ "lookup", "libc::dup2", "", "extern fn", "did you mean", false },
	{ "lookup", "$typeof", "", "$Typeof", "", false },
	{ "lookup", "isz", "", "`sz`", "", false },
	// --- what a thing does, in words
	{ "lookup", "convert a hex digit char to its value", "", "hex", "", false },
	{ "lookup", "check whether a string is valid UTF-8", "", "utf8", "", false },
	{ "lookup", "read a line from stdin", "", "readline", "", false },
	{ "lookup", "trim whitespace", "", "String.trim", "", false },
	{ "lookup", "sort an array", "", "sort", "", false },
	{ "lookup", "redirect stderr to a buffer / set stderr stream", "", "Weak matches", "", false },
	// --- checking code
	{ "check", "import std::math, std::io;\nfn void main()\n{\n\tdouble a = double.inf;\n\tio::printn(a);\n}\n", "", "double::inf", "", false },
	{ "check", "fn void f() { char[*] d = $embed(\"/etc/passwd\"); }", "", "rejected", "", true },
	// --- a project, its library and a snippet checked with it (@P is the project's folder)
	{ "check", "@P", "", "OK: no errors", "", false },
	{ "check", "import parser, helper;\nfn int use() => helper::triple(1);", "@P", "OK: no errors", "", false },
	{ "check", "fn void f() { char[*] d = $embed(\"/etc/passwd\"); }", "@P", "rejected", "", true },
	{ "run", "import std::io, helper;\nfn void main() { io::printfn(\"%d\", helper::triple(14)); }", "@P", "42", "the project's main", false },
	{ "lookup", "", "@P", "Parser", "", false },
	{ "lookup", "Parser.next", "@P", "next", "", false },
	{ "test", "@P", "doubles", "", "FAIL", false },
};

fn bool any_of(String text, String alternatives) @local
{
	if (alternatives.len == 0) return true;
	foreach (alt : alternatives.tsplit("|")) if (text.contains(alt)) return true;
	return false;
}

fn String project(String root) @local
{
	String p = string::tformat("%s/proj", root);
	path::mkdir(path::new(tmem, string::tformat("%s/src", p))!!, recursive: true)!!;
	path::mkdir(path::new(tmem, string::tformat("%s/lib/helper.c3l/src", p))!!, recursive: true)!!;
	file::save(string::tformat("%s/project.json", p), "{ \"sources\": [\"src/**\"], \"dependency-search-paths\": [\"lib\"], \"dependencies\": [\"helper\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	file::save(string::tformat("%s/lib/helper.c3l/manifest.json", p), "{ \"provides\": \"helper\", \"sources\": [\"src/**\"], \"targets\": { \"linux-x64\": {}, \"macos-aarch64\": {}, \"macos-x64\": {}, \"windows-x64\": {} } }")!!;
	file::save(string::tformat("%s/lib/helper.c3l/src/helper.c3", p), "module helper;\nfn int triple(int x) => x * 3;\n")!!;
	file::save(string::tformat("%s/src/parser.c3", p), "module parser;\nstruct Parser { int pos; }\nfn int Parser.next(&self) => self.pos++;\nfn void doubles() @test { Parser p; assert(p.next() == 0); }\n")!!;
	file::save(string::tformat("%s/src/main.c3", p), "module app;\nimport std::io;\nfn void main() { io::printn(\"the project's main\"); }\n")!!;
	return p;
}

fn String answer(Call* c, String proj) @local
{
	String a = c.a == "@P" ? proj : c.a;
	String b = c.b == "@P" ? proj : c.b;
	switch (c.tool)
	{
		case "search": return tools::c3_search(a);
		case "changes": return tools::c3_search(a, scope: "changes");
		case "syntax": return tools::c3_search(a, scope: "syntax");
		case "lookup": return tools::c3_lookup(a, path: b);
		case "check": return c.b.len > 0 ? check::c3_check(a, path: b) : (c.a == "@P" ? check::c3_check(path: a) : check::c3_check(a));
		case "run": return check::c3_run(a, path: b);
		case "test": return check::c3_test(a, filter: b);
		default: return "unknown tool";
	}
}

fn void coders_calls_get_the_answers_they_should() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String proj = project((String)dir);
	context::clear();
	defer context::clear();   // the calls note the project and the names they ask for: the other tests start without them
	int bad = 0;
	foreach (&c : CALLS)
	{
		String r = answer(c, proj);
		bool ok = r.len > 0 && any_of(r, c.must) && (c.refused || !r.starts_with("rejected"));
		if (ok && c.must_not.len > 0) foreach (n : c.must_not.tsplit("|")) if (r.contains(n)) ok = false;
		if (!ok)
		{
			bad++;
			io::printfn("SESSION CALL FAILED: %s %s | %s\n  wanted: %s   not: %s\n  got: %s", c.tool, c.a, c.b, c.must, c.must_not, util_clip(r));
		}
	}
	assert(bad == 0, "%d of %d calls", bad, (int)CALLS.len);
}

fn String util_clip(String s) @local => s.len > 400 ? s[:400] : s;
