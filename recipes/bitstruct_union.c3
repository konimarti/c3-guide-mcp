// Recipe: bitstruct (named bit fields packed in an integer) and union (one storage, several views)
// Also: flags, bit flags, bit field, bitmask, union, reinterpret
// expect: read=true write=false
// expect: raw=5
// expect: sizes: 1 4
import std::io;

bitstruct Perm : char
{
	bool read : 0;
	bool write : 1;
	bool exec : 2;
}

union Number
{
	int as_int;
	float as_float;
}

fn void main()
{
	Perm p = { .read = true, .exec = true };
	io::printfn("read=%s write=%s", p.read, p.write);
	io::printfn("raw=%d", (char)p);
	Number n;
	n.as_int = 1;
	io::printfn("sizes: %d %d", Perm::size, Number::size);
}
