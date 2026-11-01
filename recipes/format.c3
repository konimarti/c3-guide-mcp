// Recipe: formatting and printing (printfn, %d %s %f %x %p, width, padding, string::format, DString)
// expect: n=42 hex=2a pi=3.14 [   7] [0007]
// expect: hello, 3
// expect: abc
import std::io;

fn void main()
{
	io::printfn("n=%d hex=%x pi=%.2f [%4d] [%04d]", 42, 42, 3.14159, 7, 7);

	String s = string::format(mem, "hello, %d", 3);   // allocates: free it
	defer s.free(mem);
	io::printn(s);

	DString d = dstring::temp();                      // growable string builder
	d.append("a");
	d.append_char('b');
	d.appendf("%s", "c");
	io::printn(d.str_view());
}
