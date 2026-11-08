module c3guide::test::telemetry_test;
import c3guide::telemetry;
import std::core::string, std::io, std::io::file, std::io::path, std::os::env, std::time::clock;

fn void outcomes_are_told_from_fixed_words() @test
{
	assert(telemetry::classify("OK: no errors").kind == "ok");
	assert(telemetry::classify("x.c3:3:1: error: Expected ';'").kind == "compile_error");
	assert(telemetry::classify("'frob' does not exist in the standard library").kind == "not_found");
	assert(telemetry::classify("Testing a::b [FAIL]").kind == "test_failed");
	assert(telemetry::classify("the build timed out").kind == "timeout");
	assert(telemetry::classify("error: x\n\nHints:\n  y").hint);
}

fn void a_log_line_holds_no_content() @test
{
	String req = `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"c3_check","arguments":{"code":"SECRET_TOKEN_123","path":"/home/me/secret-project","evil":1}}}`;
	String line = telemetry::line_for(req, `{"result":{"content":[{"type":"text","text":"OK: SECRET_TOKEN_123"}]}}`, 12);
	assert(line.contains("\"tool\":\"c3_check\"") && line.contains("\"args\":[\"path\",\"code\"]"), "%s", line);   // ARG_NAMES order (path before code), only names that were given
	assert(!line.contains("SECRET") && !line.contains("secret-project") && !line.contains("evil"), "%s", line);
}

fn void only_our_own_tool_calls_are_logged() @test
{
	assert(telemetry::line_for(`{"method":"tools/list"}`, "{}", 1) == "");
	assert(telemetry::line_for(`{"method":"tools/call","params":{"name":"rm -rf\n","arguments":{}}}`, "{}", 1) == "");
	assert(telemetry::line_for(`not json at all "tools/call"`, "{}", 1) == "");
}

fn void the_log_can_be_turned_off_and_rotates() @test
{
	Path dir = path::temp_directory(tmem)!!.tappend(string::tformat("c3guide-log-%d", (long)clock::now()))!!;
	path::mkdir(dir, recursive: true)!!;
	defer (void)path::rmtree(dir);
	String log = string::tformat("%s/usage.jsonl", (String)dir);
	String req = `{"method":"tools/call","params":{"name":"c3_check","arguments":{"code":"x"}}}`;
	env::set_var("C3_GUIDE_LOG", "off");
	telemetry::record(req, "{}", 1);
	env::set_var("C3_GUIDE_LOG", log);
	assert(!file::exists(log));   // off wrote nothing
	telemetry::record(req, "{}", 1);
	assert(file::exists(log) && file::load_temp(log)!!.len > 10);
	DString big = dstring::temp();
	for (int i = 0; i < 4000; i++) big.append("0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789\n");
	file::save(log, big.str_view())!!;
	telemetry::record(req, "{}", 1);
	assert(file::exists(string::tformat("%s.1", log)) && file::get_size(log)!! < 1000, "the full log moved to .1 and a new one started");
	(void)env::clear_var("C3_GUIDE_LOG");
}
