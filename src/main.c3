module c3guide;
import mcp;
import c3guide::corpus, c3guide::tools, c3guide::check;

// Sent to the model in `initialize`: this is what makes a model use the tools without being told.
const String INSTRUCTIONS = `Your memory of C3 is probably outdated (most training data is C3 0.6/0.7; the language changed a lot in 0.8).
Do not write C3 from memory:
- c3_symbol before using any stdlib function, macro or method: exact signature or "does not exist". Do not know the name? Describe it ("read line from stdin") and it lists the matching functions.
- c3_search for language rules (the manual); c3_changes when old syntax fails (release notes, newest first).
- c3_check on every snippet before you show it: it runs the real compiler and returns its diagnostics.
- c3_syntax for the exact list of attributes, keywords, builtins and type properties.
Trust the compiler over this documentation when they disagree.`;

fn void main()
{
	corpus::load();
	mcp::Server server = mcp::new_server("c3-guide-mcp", "0.1.0");
	server.instructions = INSTRUCTIONS;
	defer server.free();
	tools::register(&server);
	check::register(&server);
	server.serve_stdio();
}
