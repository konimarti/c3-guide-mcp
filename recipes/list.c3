// Recipe: List (dynamic array): push, index, foreach, pop, remove, free
// Also: List{int}, dynamic array, vector, ArrayList, push_back, append, remove
// expect: sum=15 len=5
// expect: last=5
// expect: after pop: 4
import std::io;
import std::collections::list;

fn void main()
{
	List{int} xs;
	xs.init(mem);
	defer xs.free();

	for (int i = 1; i <= 5; i++) xs.push(i);
	int sum;
	foreach (x : xs) sum += x;
	io::printfn("sum=%d len=%d", sum, xs.len());
	io::printfn("last=%d", xs[xs.len() - 1]);
	xs.pop()!!;
	io::printfn("after pop: %d", xs.len());
}
