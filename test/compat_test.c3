module c3guide::test::compat;
import c3guide::compat, c3guide::tools, c3guide::check, c3guide::proc, c3guide::test::support;
import mcp, std::core::string, std::io::file, std::io::path, std::encoding::json, std::collections::object;

// The argument names and tool names of 0.5/0.6, as clients still send them (src/compat.c3).

fn String call(String tool, String arguments) @local
{
	mcp::Server s = mcp::new_server("t", "0");
	tools::register(&s);
	check::register(&s);
	defer s.free();
	String line = string::tformat(`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"%s","arguments":%s}}`, tool, arguments);
	String r = compat::handle(&s, tmem, line);
	// every answer is one JSON-RPC response
	Object*? parsed = json::parse(tmem, r);
	assert(!@catch(parsed), "not JSON: %s", r);
	return r;
}

fn void name_and_symbol_are_query() @test
{
	String a = call("c3_lookup", `{"name":"printfn"}`);
	assert(a.contains("printfn") && !a.contains("give query"), "%s", a);
	String b = call("c3_lookup", `{"symbol":"printfn"}`);
	assert(b.contains("printfn") && !b.contains("give query"), "%s", b);
	String c = call("c3_refs", `{"name":"new_server"}`);
	assert(!c.contains("give query"), "%s", c);
	// the real name wins when both are given, and `name` before `symbol`
	String d = call("c3_lookup", `{"query":"printfn","name":"zzzqqq"}`);
	assert(d.contains("printfn") && !d.contains("zzzqqq"), "%s", d);
	String e = call("c3_lookup", `{"name":"printfn","symbol":"zzzqqq"}`);
	assert(e.contains("printfn") && !e.contains("zzzqqq"), "%s", e);
}

fn void file_is_path_where_a_tool_has_no_file() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String f = string::tformat("%s/one.c3", (String)dir);
	file::save(f, "module one;\nfn int twice_it(int x) => x * 2;\n")!!;
	String a = call("c3_lookup", string::tformat(`{"file":"%s"}`, f));
	assert(a.contains("twice_it"), "%s", a);
	String b = call("c3_check", string::tformat(`{"file":"%s"}`, f));
	assert(b.contains("OK: no errors"), "%s", b);
	// c3_search has a `file` of its own: it is left alone (and is not an unknown argument)
	String c = call("c3_search", string::tformat(`{"query":"foreach","file":"%s"}`, f));
	assert(!c.contains("does not take"), "%s", c);
}

fn void an_unknown_argument_names_the_ones_the_tool_takes() @test
{
	String a = call("c3_lookup", `{"query":"printfn","colour":"red"}`);
	assert(a.contains("c3_lookup does not take 'colour'") && a.contains("query (string)") && a.contains("path (string)"), "%s", a);
	assert(!a.contains("fn sz? printfn"), "nothing is run: %s", a);
	String b = call("c3_check", `{"code":"fn void f() {}","bogus":1,"other":2}`);
	assert(b.contains("'bogus'") && b.contains("'other'") && b.contains("code (string)"), "%s", b);
	// known arguments of every kind pass
	String c = call("c3_search", `{"query":"defer","limit":2,"scope":"all"}`);
	assert(!c.contains("does not take"), "%s", c);
}

fn void the_tools_of_the_old_set_are_forwarded() @test
{
	String a = call("c3_symbol", `{"name":"printfn"}`);
	assert(a.contains("c3_symbol is called c3_lookup") && a.contains("fn sz? printfn"), "%s", a);
	String b = call("c3_examples", `{"symbol":"printfn"}`);
	assert(b.contains("c3_examples is called c3_lookup") && b.contains("printfn"), "%s", b);
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String f = string::tformat("%s/one.c3", (String)dir);
	file::save(f, "module one;\nfn int twice_it(int x) => x * 2;\n")!!;
	String c = call("c3_outline", string::tformat(`{"file":"%s"}`, f));
	assert(c.contains("c3_outline is called c3_lookup") && c.contains("twice_it"), "%s", c);
	String d = call("c3_syntax", `{"name":"attributes"}`);
	assert(d.contains("c3_syntax is called c3_search with scope=syntax") && d.contains("@inline"), "%s", d);
	String e = call("c3_changes", `{"query":"faultdef"}`);
	assert(e.contains("c3_changes is called c3_search with scope=changes") && e.contains("faultdef"), "%s", e);
	String g = call("c3_fix", `{"code":"fn isz f() => 1;"}`);
	assert(g.contains("c3_fix is called c3_check") && g.contains("sz"), "%s", g);
	// a name that never was a tool is still unknown
	String h = call("c3_nothing", `{"name":"x"}`);
	assert(h.contains("unknown tool"), "%s", h);
}

// 0.5.6 gave c3_changes and c3_syntax one argument, `topic`; and a call may leave `arguments` out
fn void topic_is_the_query_of_the_old_tools_and_an_alias() @test
{
	String a = call("c3_changes", `{"topic":"faultdef"}`);
	assert(a.contains("c3_changes is called c3_search") && a.contains("faultdef") && !a.contains("give query"), "%s", a);
	String b = call("c3_syntax", `{"topic":"attributes"}`);
	assert(b.contains("@inline") && !b.contains("lists: attributes"), "%s", b);
	String c = call("c3_search", `{"topic":"foreach with index"}`);
	assert(!c.contains("does not take") && !c.contains("give query"), "%s", c);
	String d = call("c3_lookup", `{"query":"printfn","topic":"zzzqqq"}`);
	assert(d.contains("printfn") && !d.contains("zzzqqq"), "%s", d);
}
