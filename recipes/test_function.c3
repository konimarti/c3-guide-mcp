// Recipe: a unit test (@test function with assert; run with c3_test / `c3c test`, not part of the program)
// Also: testing, unit test, assert, @test, test function, expect
// expect: add(2, 2)=4
import std::io;

fn int add(int a, int b) => a + b;

fn void add_works() @test
{
	assert(add(2, 2) == 4, "2 + 2 should be 4");
	assert(add(-1, 1) == 0);
}

fn void main()
{
	io::printfn("add(2, 2)=%d", add(2, 2));
}
