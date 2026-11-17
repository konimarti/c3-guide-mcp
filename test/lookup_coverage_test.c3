module c3guide::test::lookup_coverage;
import c3guide::tools, c3guide::suggest, c3guide::live, c3guide::corpus, c3guide::test::support;
import std::io::file, std::io::path, std::os::env;

fn bool has(String hay, String needle) @local => hay.contains(needle);

// ---- a right name in the wrong module: the symbol, and one line saying where it is ----

fn void a_name_in_a_neighbouring_module_is_answered_with_where_it_is() @test
{
	String d = tools::symbol_reply("std::core::string::DString");
	assert(has(d, "std::core::dstring::DString") && has(d, "is in std::core::dstring, not in std::core::string") && !has(d, "does not exist"), "%s", d);
	String h = tools::symbol_reply("std::collections::list::HashMap");
	assert(has(h, "std::collections::map::HashMap") && has(h, "not in std::collections::list") && !has(h, "does not exist"), "%s", h);
	String f = tools::symbol_reply("std::io::file::File");
	assert(has(f, "std::io::File") && has(f, "not in std::io::file"), "%s", f);
}

fn void a_wrong_module_before_type_dot_member_is_answered() @test
{
	String r = tools::symbol_reply("std::collections::hashmap::HashMap.get");
	assert(has(r, "HashMap.get") && has(r, "not in std::collections::hashmap") && !has(r, "does not exist"), "%s", r);
}

fn void several_modules_with_the_name_are_listed_not_guessed() @test
{
	String r = tools::symbol_reply("std::os::time::now");
	assert(has(r, "exists in 3 other modules") && has(r, "std::time::now") && has(r, "std::time::clock::now"), "%s", r);
	assert(!has(r, "does not exist"), "%s", r);
}

// the same name in a module that has nothing to do with the asked one is not an answer
fn void the_same_name_in_an_unrelated_module_is_not_offered() @test
{
	String r = tools::symbol_reply("file::tload");
	assert(has(r, "does not exist") && has(r, "did you mean:\n  file::load_temp") && !has(r, "is in "), "%s", r);
	String q = tools::symbol_reply("mem::tparse");
	assert(!has(q, "is in "), "%s", q);
}

fn void a_name_that_is_nowhere_still_does_not_exist() @test
{
	String r = tools::symbol_reply("std::io::nowhere::Whatever");
	assert(has(r, "does not exist") && !has(r, "is in "), "%s", r);
	String q = tools::symbol_reply("std::io::File.no_such_method_xyz");
	assert(has(q, "does not exist"), "%s", q);
}

// ---- enum and constset members are names ----

fn void constset_members_are_found_with_their_type_and_value() @test
{
	String r = tools::symbol_reply("EINVAL");
	assert(has(r, "libc::Errno.EINVAL") && has(r, "constset member Errno.EINVAL"), "%s", r);
	$if env::LINUX:
		assert(has(r, "= 22"), "%s", r);
	$endif
	String q = tools::symbol_reply("Errno.ENOENT");
	assert(has(q, "libc::Errno.ENOENT") && has(q, "Errno"), "%s", q);
	String t = tools::symbol_reply("Errno");
	assert(has(t, "Members (") && has(t, "ENOENT"), "%s", t);
}

fn void enum_members_are_found_with_their_ordinal() @test
{
	String r = tools::symbol_reply("ThreadPoolState.STOPPING");
	assert(has(r, "enum member ThreadPoolState.STOPPING (ordinal 2)"), "%s", r);
	String s = tools::symbol_reply("RUNNING");
	assert(has(s, "ThreadPoolState.RUNNING"), "%s", s);
}

fn void a_lookup_of_an_enum_lists_its_members() @test
{
	String r = tools::symbol_reply("ThreadPoolState");
	assert(has(r, "Members (3): NO_INIT, RUNNING, STOPPING"), "%s", r);
}

// the live read of docgen gives the same member records as the snapshot generator
fn void live_docgen_json_gives_enum_and_constset_members() @test
{
	Entry[] got = live::entries_from_json(`{"modules": {"geom": {"types": [
		{"name": "Axis", "kind": "enum", "uid": "geom::Axis", "file": "lib/std/geom.c3:3:6", "base_type": {"name": "int"},
		 "members": [{"name": "X", "type": {"name": "Axis"}}, {"name": "Y", "type": {"name": "Axis"}}]},
		{"name": "Mode", "kind": "constset", "uid": "geom::Mode", "file": "lib/std/geom.c3:9:10", "base_type": {"name": "CInt"},
		 "members": [{"name": "FAST", "type": {"name": "Mode"}, "value": "1"}, {"name": "SLOW", "type": {"name": "Mode"}, "value": "2"}]},
		{"name": "Box", "kind": "struct", "uid": "geom::Box", "file": "lib/std/geom.c3:20:8", "members": [{"name": "w", "type": {"name": "int"}}]}]}}}`)!!;
	defer { foreach (&e : got) { free(e.kind); free(e.title); free(e.body); free(e.loc); } free(got); }
	String all = "";
	foreach (&e : got) all = string::tformat("%s%s|%s|%s\n", all, e.kind, e.title, e.body);
	assert(has(all, "member|geom::Axis.Y|enum member Axis.Y (ordinal 1) of an enum with base type int"), "%s", all);
	assert(has(all, "member|geom::Mode.SLOW|constset member Mode.SLOW = 2 (CInt)"), "%s", all);
	assert(!has(all, "Box.w"), "a struct's members are its fields, not names: %s", all);
	assert(got.len == 3 + 4, "%d entries", (int)got.len);
}

// ---- the language: built-in types, keywords, attributes, builtins, type properties ----

fn void built_in_types_say_what_they_are() @test
{
	String s = tools::symbol_reply("short");
	assert(has(s, "built-in type") && has(s, "2 bytes") && has(s, "-32768 .. 32767") && has(s, "short::max"), "%s", s);
	String d = tools::symbol_reply("double");
	assert(has(d, "built-in type") && has(d, "8 bytes") && has(d, "double::inf"), "%s", d);
	String u = tools::symbol_reply("ushort");
	assert(has(u, "0 .. 65535"), "%s", u);
	assert(!has(s, "does not exist") && !has(d, "does not exist"), "%s", s);
}

fn void type_properties_of_built_in_types_are_answered() @test
{
	assert(has(tools::symbol_reply("ushort::max"), "65535"));
	assert(has(tools::symbol_reply("ichar::min"), "-128"));
	assert(has(tools::symbol_reply("long::size"), "8"));
}

fn void keywords_and_attributes_are_answered_from_the_compiler_lists() @test
{
	String w = tools::symbol_reply("while");
	assert(has(w, "`while` is a statement") && !has(w, "does not exist"), "%s", w);
	String n = tools::symbol_reply("nextcase");
	assert(has(n, "`nextcase` is a statement"), "%s", n);
	String a = tools::symbol_reply("@noreturn");
	assert(has(a, "attribute") && !has(a, "does not exist"), "%s", a);
	String s = tools::symbol_reply("struct");
	assert(has(s, "declaration keyword"), "%s", s);
}

fn void a_builtin_without_its_dollars_says_to_write_them() @test
{
	String r = tools::symbol_reply("prefetch");
	assert(has(r, "$$prefetch") && has(r, "compiler builtin"), "%s", r);
	String t = tools::symbol_reply("reduce_fadd");
	assert(has(t, "$$reduce_fadd"), "%s", t);
}

// ---- a list of names with a path is a list ----

fn Path fixture() @local
{
	Path dir = support::make_temp_dir("c3list");
	String root = (String)dir;
	support::sh(string::tformat("mkdir -p '%s/src'", root));
	file::save(string::tformat("%s/project.json", root), "{ \"sources\": [\"src/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }")!!;
	file::save(string::tformat("%s/src/shape.c3", root), "module geom;\nstruct Shape { int sides; }\nfn int Shape.area(&self) => 1;\nfn int Shape.perimeter(&self) => 2;\nfn bool is_convex(Shape* s) => true;\n")!!;
	return dir;
}

fn void a_list_of_project_names_gets_one_answer_per_name() @test
{
	Path dir = fixture();
	defer (void)path::rmtree(dir);
	String r = tools::c3_lookup("Shape.area, Shape.perimeter", (String)dir);
	assert(has(r, "== Shape.area ==") && has(r, "== Shape.perimeter ==") && has(r, "shape.c3:3") && has(r, "shape.c3:4"), "%s", r);
	String s = tools::c3_lookup("Shape.area Shape.perimeter is_convex", (String)dir);
	assert(has(s, "== is_convex ==") && has(s, "shape.c3:5"), "%s", s);
	String c = tools::c3_lookup("Shape.area,Shape.perimeter", (String)dir);
	assert(has(c, "== Shape.area ==") && has(c, "== Shape.perimeter =="), "%s", c);
}

fn void words_with_a_path_are_still_a_description() @test
{
	Path dir = fixture();
	defer (void)path::rmtree(dir);
	String r = tools::c3_lookup("compute the area of a shape", (String)dir);
	assert(!has(r, "== "), "%s", r);
}

// ---- the exact name comes first in suggestions ----

fn void the_exact_name_is_the_first_suggestion() @test
{
	String g = suggest::did_you_mean("env::get_var");
	assert(g.starts_with("did you mean:\n  env::get_var"), "%s", g);
	String s = suggest::did_you_mean("env::set_var");
	assert(s.starts_with("did you mean:\n  env::set_var"), "%s", s);
	String c = suggest::did_you_mean("env::clear_var");
	assert(c.starts_with("did you mean:\n  env::clear_var"), "%s", c);
}
