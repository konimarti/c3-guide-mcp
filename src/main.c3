module c3guide;
import mcp, std::core::string;
import c3guide::corpus, c3guide::tools, c3guide::check, c3guide::outline, c3guide::live;

// Sent to the model in `initialize`: this is what makes a model use the tools without being told.
const String INSTRUCTIONS = `Your memory of C3 is probably outdated (most training data is C3 0.6/0.7; the language changed a lot in 0.8).
Do not write C3 from memory. To check, test or run code, use these tools and not "c3c compile", "c3c test" or "c3c run" typed by hand: they run the real compiler and add what its messages lack. Use c3c directly when you need a shell: "c3c build" for a binary, creating a project, running the built app with its own input or working directory.
- c3_symbol before using any stdlib function, macro or method: exact signature or "does not exist". Do not know the name? Describe it ("read line from stdin") and it lists the matching functions.
- c3_outline to see what a project contains (its declarations with file:line) before reading its files.
- c3_examples for working code that calls a stdlib function or type.
- c3_search for language rules (the manual); c3_changes when old syntax or an old stdlib name fails (renames and removals, release notes newest first); c3_fix rewrites 0.7 syntax to 0.8.
- c3_check to check code (instead of "c3c compile"): give code for a snippet, or path for a project or file on disk. Run it on every snippet before you show it.
- c3_syntax for the exact list of attributes, keywords, builtins and type properties.
Trust the compiler over this documentation when they disagree.`;

const String RUN_INSTRUCTIONS = `
- c3_test instead of "c3c test", c3_run instead of "c3c compile-run" or "c3c run": they build in a scratch directory and return only what matters.`;

fn void main()
{
	corpus::load();
	live::enabled = true;   // the standard library as the installed c3c has it, read on the first symbol lookup
	mcp::Server server = mcp::new_server("c3-guide-mcp", "0.5.2");
	server.instructions = check::run_allowed() ? string::format(mem, "%s%s", INSTRUCTIONS, RUN_INSTRUCTIONS) : INSTRUCTIONS;
	defer server.free();
	tools::register(&server);
	check::register(&server);
	outline::register(&server);
	server.serve_stdio();
}
