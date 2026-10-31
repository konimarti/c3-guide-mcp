module c3guide;
import mcp;
import c3guide::corpus, c3guide::tools, c3guide::check;

fn void main()
{
	corpus::load();
	mcp::Server server = mcp::new_server("c3-guide-mcp", "0.1.0");
	defer server.free();
	tools::register(&server);
	check::register(&server);
	server.serve_stdio();
}
