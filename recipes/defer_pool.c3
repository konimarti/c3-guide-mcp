// Recipe: defer, @pool and the temporary allocator tmem (no free needed inside @pool)
// expect: working
// expect: built: x-y-z
// expect: cleanup
import std::io;

fn String build()
{
	@pool()
	{
		// tmem memory is released when the @pool block ends: copy what you return out of it
		String s = string::tformat("%s-%s-%s", "x", "y", "z");
		return s.copy(mem);
	};
}

fn void main()
{
	defer io::printn("cleanup");       // runs when main returns, last defer first
	io::printn("working");
	String s = build();
	defer s.free(mem);
	io::printfn("built: %s", s);
}
