// Recipe: random numbers (random::rand, seeded generator)
// expect: in range: true
// expect: same sequence: true
import std::io;
import std::math::random;

fn void main()
{
	int n = random::rand(10);                  // 0..9
	io::printfn("in range: %s", n >= 0 && n < 10);

	Sfc64Random a, b;
	random::seed(&a, 42);                      // the same seed gives the same sequence
	random::seed(&b, 42);
	io::printfn("same sequence: %s", a.next_int() == b.next_int());
}
