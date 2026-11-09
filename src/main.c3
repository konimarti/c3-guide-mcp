module c3guide;
import mcp, libc, std::core::string, std::os::env;
import c3guide::compat, c3guide::proc, c3guide::corpus, c3guide::tools, c3guide::check, c3guide::live, c3guide::setup;
import std::io;

// Sent to the model in `initialize`: this is what makes a model use the tools without being told.
const String INSTRUCTIONS = `Your memory of C3 is probably outdated (most training data is C3 0.6/0.7; the language changed a lot in 0.8).
Do not write C3 from memory. Call the tools below directly by name (this server has no resources to list or read, and the tool schemas come with tools/list). To check, test or run code use these tools and not "c3c compile", "c3c test" or "c3c run" typed by hand: they run the real compiler and add what its messages lack. Use c3c directly when you need a shell: "c3c build" for a binary, creating a project, running the built app in its own directory.
- c3_lookup before you use any name: one call for your project, its libraries and the standard library. A name gives the exact signature, docs, location and an example, or says it does not exist and what it became. Describe what you need ("read line from stdin") when you do not know the name. A path alone lists the declarations of a project.
- c3_check on every snippet before you show it, and on a project or file with path. Old 0.7 syntax is rewritten for you; format=true also runs the formatter c3f.
- c3_test runs the @test functions of a project or file and returns the failures (sanitize=address|memory|thread).
- c3_run builds and runs a program (arguments, stdin; sanitize=address|memory|thread).
- c3_refs for where a name is used: before you rename, move or delete one, use it instead of grep and sed (whole identifiers only; comments and strings are not uses); rename_to=NEW returns the exact edits of a rename and writes nothing.
- c3_search for how to do something (manual, recipes); scope=changes when old syntax or an old name fails; scope=syntax for the exact lists of attributes, builtins, keywords and type properties.
Trust the compiler over this documentation when they disagree.`;

const String VERSION = "0.7.0";

const String USAGE = `c3-guide-mcp %s: C3 knowledge for AI assistants (an MCP server on stdin/stdout).
  c3-guide-mcp             serve (this is how an editor starts it)
  c3-guide-mcp --doctor    show the compiler, the docs version and what Claude Code integration is in place
  c3-guide-mcp --setup     install the rules, the hook and the server entry for Claude Code ([--dry-run] shows the plan)
  c3-guide-mcp --version
`;

fn int main(String[] args)
{
	if (args.len > 1)
	{
		switch (args[1])
		{
			case "--version": io::printn(VERSION); return 0;
			case "--doctor": return setup::run_doctor(setup::self_path(args[0]), VERSION);
			case "--setup":
				if (args.len > 3 || (args.len == 3 && args[2] != "--dry-run")) { io::eprintf(USAGE, VERSION); return 2; }   // a typo must not turn a dry run into a real one
				return setup::run_setup(setup::self_path(args[0]), args.len == 3);
			case "--help":
			case "-h": io::printf(USAGE, VERSION); return 0;
			default:
				// an editor may start the server with a flag of its own (`--stdio`): serve. At a terminal it is a typo.
				if (libc::isatty(0) != 0) { io::eprintf(USAGE, VERSION); return 2; }
				io::eprintfn("c3-guide-mcp: ignoring the argument '%s'", args[1]);
		}
	}
	// a program that exits without reading its input must not take the server down with a broken pipe
	$if !env::WIN32:
		libc::signal(libc::SIGPIPE, (SignalFunction)(iptr)1);
	$endif
	corpus::load();
	live::enabled = true;   // the standard library as the installed c3c has it, read on the first symbol lookup
	mcp::Server server = mcp::new_server("c3-guide-mcp", VERSION);
	server.instructions = INSTRUCTIONS;
	defer server.free();
	tools::register(&server);
	check::register(&server);
	compat::serve_stdio(&server);
	proc::cleanup();
	return 0;
}
