// Recipe: an atomic counter (Atomic{int}: add, store, load) that threads can share without a mutex
// Also: atomics, atomic add, fetch_add, lock free, counter, thread safe
// expect: total=7
import std::io;
import std::atomic;

fn void main()
{
	Atomic{int} counter;
	counter.store(5);
	counter.add(2);
	io::printfn("total=%d", counter.load());
}
