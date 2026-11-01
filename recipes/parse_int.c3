// Recipe: parse a string to an integer or a float; a failed parse is a fault, not a crash
// expect: value=1234
// expect: invalid
// expect: pi=3.14
import std::io;

fn void main()
{
	int? v = "1234".to_int();
	if (try x = v) io::printfn("value=%d", x);

	int? bad = "12x".to_int();
	if (catch bad) io::printn("invalid");

	double? d = "3.14".to_double();
	if (try y = d) io::printfn("pi=%.2f", y);
}
