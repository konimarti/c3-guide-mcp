module c3guide::test::context_test;
import c3guide::context, c3guide::tools, c3guide::test::support;
import std::io, std::io::file, std::io::path;

fn void imports_become_context_and_only_the_standard_library() @test
{
	context::clear();
	context::note_source("module m;\n// import std::fake;\nimport std::io, std::io::path @public;\nimport std::net;\nimport mylib::thing;\nfn void f() {}\n");
	assert(context::count == 3, "%d", context::count);
	assert(context::name_at(0) == "std::net" && context::name_at(2) == "std::io", "newest first");
	context::note_module("std::io");
	assert(context::count == 3 && context::name_at(0) == "std::io", "a module seen again moves to the front");
	context::clear();
}

fn void the_context_keeps_only_the_newest_modules() @test
{
	context::clear();
	for (int i = 0; i < 40; i++) context::note_module(string::tformat("std::m%d", i));
	assert(context::count == context::MAX_MODULES && context::name_at(0) == "std::m39", "%d", context::count);
	context::clear();
}

// `is_dir` exists in two modules; the one the code imports comes first.
fn void the_imported_module_wins_a_tie() @test
{
	String ask = "check whether a path is a directory";
	context::clear();
	context::note_source("import std::io::file;");
	String with_file = tools::c3_symbol(ask);
	context::clear();
	context::note_source("import std::io::path;");
	String with_path = tools::c3_symbol(ask);
	context::clear();
	assert((with_file.index_of("std::io::file::is_dir") ?? 99999) < (with_file.index_of("std::io::path::is_dir") ?? 99999), "%s", with_file);
	assert((with_path.index_of("std::io::path::is_dir") ?? 99999) < (with_path.index_of("std::io::file::is_dir") ?? 99999), "%s", with_path);
}

fn void a_checked_file_and_a_looked_up_name_are_context() @test
{
	Path dir = support::make_temp_dir("c3ctx");
	defer (void)path::rmtree(dir);
	String f = string::tformat("%s/a.c3", (String)dir);
	file::save(f, "import std::net;\nfn void main() {}\n")!!;
	context::clear();
	tools::c3_search("defer", 1, f);
	assert(context::count == 1 && context::name_at(0) == "std::net", "the file parameter");
	context::clear();
	tools::c3_symbol("String.split");
	assert(context::count == 1 && context::name_at(0) == "std::core::string", "a name looked up");
	context::clear();
}
