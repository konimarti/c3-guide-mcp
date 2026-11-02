// Recipe: HashSet (add, contains, remove, len): unique values, membership test
// Also: set, unique, duplicates, dedupe, membership, contains, HashSet{int}
// expect: distinct: 3
// expect: has 2: true
// expect: has 9: false
import std::io;
import std::collections::set;

fn void main()
{
	HashSet{int} seen;
	seen.init(mem);
	defer seen.free();
	foreach (v : (int[]){ 1, 2, 2, 3, 1 }) seen.add(v);
	io::printfn("distinct: %d", seen.len());
	io::printfn("has 2: %s", seen.contains(2));
	io::printfn("has 9: %s", seen.contains(9));
}
