module c3guide::test::lookup_language;
import c3guide::tools;
import std::core::string;

// The table of built-in types in c3_lookup is C3 knowledge, not read from the compiler: the compiler that builds these
// tests says whether it is right.
fn int table_size(String name) @local
{
	foreach (&t : tools::BUILTIN_TYPES) if (t.name == name) return t.bytes;
	return -1;
}

fn void the_sizes_in_the_type_table_are_the_compilers() @test
{
	assert(table_size("bool") == bool::size);
	assert(table_size("char") == char::size);
	assert(table_size("ichar") == ichar::size);
	assert(table_size("short") == short::size);
	assert(table_size("ushort") == ushort::size);
	assert(table_size("int") == int::size);
	assert(table_size("uint") == uint::size);
	assert(table_size("long") == long::size);
	assert(table_size("ulong") == ulong::size);
	assert(table_size("int128") == int128::size);
	assert(table_size("uint128") == uint128::size);
	assert(table_size("float16") == float16::size);
	assert(table_size("bfloat") == bfloat::size);
	assert(table_size("float") == float::size);
	assert(table_size("double") == double::size);
	assert(table_size("float128") == float128::size);
}

fn void the_types_of_the_table_are_all_compiler_keywords() @test
{
	foreach (&t : tools::BUILTIN_TYPES)
	{
		assert(tools::in_list("keywords", t.name), "%s is not in c3c --list-keywords", t.name);
	}
}

fn void the_ranges_in_the_answers_are_the_compilers() @test
{
	assert(tools::symbol_reply("int").contains(string::tformat("%d .. %d", int::min, int::max)));
	assert(tools::symbol_reply("ichar").contains(string::tformat("%d .. %d", ichar::min, ichar::max)));
	assert(tools::symbol_reply("uint").contains(string::tformat("0 .. %d", uint::max)));
	assert(tools::symbol_reply("long::max").contains(string::tformat("%d", long::max)));
	assert(tools::symbol_reply("ulong::max").contains(string::tformat("%d", ulong::max)));
	assert(tools::symbol_reply("usz::max").contains(string::tformat("%d", usz::max)));
	assert(tools::symbol_reply("sz::min").contains(string::tformat("%d", sz::min)));
}

fn void the_statement_and_declaration_words_are_all_compiler_keywords() @test
{
	foreach (w : tools::STATEMENT_WORDS) assert(tools::in_list("keywords", w), "%s is not in c3c --list-keywords", w);
	foreach (w : tools::DECLARATION_WORDS) assert(tools::in_list("keywords", w), "%s is not in c3c --list-keywords", w);
}
