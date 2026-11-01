// Recipe: HashMap with String keys (init, set, get with default, has_key, iterate, free)
// expect: the=3
// expect: bird=0
// expect: distinct: 3
import std::io;
import std::collections::map;

fn void main()
{
	HashMap{String, int} counts;
	counts.init(mem);          // mem = heap; tmem = temp allocator
	defer counts.free();

	foreach (w : "the cat the dog the".tsplit(" "))
	{
		counts.set(w, (counts.get(w) ?? 0) + 1);    // get returns an optional: ?? gives a default
	}
	io::printfn("the=%d", counts.get("the") ?? 0);
	io::printfn("bird=%d", counts.get("bird") ?? 0);
	io::printfn("distinct: %d", counts.len());

	counts.@each(; String key, int value) { /* visit every pair; order is not defined */ };
}
