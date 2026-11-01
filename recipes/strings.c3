// Recipe: strings: split, join, trim, upper case, contains, starts_with, replace, parse (temp-allocator versions end in t)
// expect: a-b-c
// expect: [hi there]
// expect: HELLO
// expect: true true
// expect: a_b_c
import std::io;

fn void main()
{
	String[] parts = "a,b,c".tsplit(",");
	io::printn(string::tjoin(parts, "-"));
	io::printfn("[%s]", "   hi there  ".trim());
	io::printn("hello".to_upper_tcopy());
	io::printfn("%s %s", "hello world".contains("o w"), "hello".starts_with("he"));
	io::printn("a,b,c".treplace(",", "_"));
}
