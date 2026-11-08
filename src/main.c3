module c3guide;
import mcp, libc, std::core::string, std::os::env;
import c3guide::corpus, c3guide::tools, c3guide::check, c3guide::outline, c3guide::live;

// Sent to the model in `initialize`: this is what makes a model use the tools without being told.
const String INSTRUCTIONS = `Your memory of C3 is probably outdated (most training data is C3 0.6/0.7; the language changed a lot in 0.8).
Do not write C3 from memory. To check, test or run code use these tools and not "c3c compile", "c3c test" or "c3c run" typed by hand: they run the real compiler and add what its messages lack. Use c3c directly when you need a shell: "c3c build" for a binary, creating a project, running the built app in its own directory.
- c3_lookup before you use any name: one call for your project, its libraries and the standard library. A name gives the exact signature, docs, location and an example, or says it does not exist and what it became. Describe what you need ("read line from stdin") when you do not know the name. A path alone lists the declarations of a project.
- c3_check on every snippet before you show it, and on a project or file with path. Old 0.7 syntax is rewritten for you.
- c3_test runs the @test functions of a project or file and returns the failures; c3_run builds and runs a program (arguments, stdin). Both take sanitize=address|memory|thread.
- c3_refs for where a name is used: before you rename, move or delete one, use it instead of grep and sed (whole identifiers only; comments and strings are not uses).
- c3_search for how to do something (manual, recipes); scope=changes when old syntax or an old name fails; scope=syntax for the exact lists of attributes, builtins, keywords and type properties.
Trust the compiler over this documentation when they disagree.`;

fn void main()
{
	// a program that exits without reading its input must not take the server down with a broken pipe
	$if !env::WIN32:
		libc::signal(libc::SIGPIPE, (SignalFunction)(iptr)1);
	$endif
	corpus::load();
	live::enabled = true;   // the standard library as the installed c3c has it, read on the first symbol lookup
	mcp::Server server = mcp::new_server("c3-guide-mcp", "0.6.0");
	server.instructions = INSTRUCTIONS;
	defer server.free();
	tools::register(&server);
	check::register(&server);
	server.serve_stdio();
}
