// Recipe: macros with compile-time parameters: runtime::@enum_lookup(Type, "field", value), a macro with a trailing block (HashMap @each), @pool
// Also: $Type, $name is a string, enum associated value lookup, find enum by field, macro from another module needs its module prefix, @each_entry, block parameters after ;
// expect: GREEN has code 2
// expect: no such code
// expect: ada=36
// expect: 1-2
import std::io;
import std::collections::map;

enum Light : int (String action, int code)
{
	RED   { "stop", 1 },
	GREEN { "go", 2 },
}

fn void main()
{
	// @enum_lookup($Type, $name, value): $name is the NAME of an associated value, written as a string ("action"),
	// not as an identifier. A macro from another module is called with its module: runtime::@enum_lookup.
	Light? l = runtime::@enum_lookup(Light, "action", "go");
	if (try l) io::printfn("%s has code %d", l, l.code);
	Light? none = runtime::@enum_lookup(Light, "code", 99);
	if (catch none) io::printn("no such code");

	// A macro with a trailing block: the names after `;` are the block's parameters. HashMap.@each gives key and value
	// (Object.@each_entry gives key and value too, HashMap.@each_entry gives one Entry*).
	HashMap{String, int} ages;
	ages.tinit();
	ages.set("ada", 36);
	ages.@each(; String key, int value)
	{
		io::printfn("%s=%d", key, value);
	};

	// @pool(): temp allocations made inside are freed at the end of the block
	@pool()
	{
		String s = string::tformat("%d-%d", 1, 2);
		io::printn(s);
	};
}
