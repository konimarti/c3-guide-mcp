// Recipe: threads: Thread.create, join, Mutex lock/unlock
// expect: counter=2000
import std::io;
import std::thread;

Mutex lock;
int counter;

fn int work(void* arg)
{
	for (int i = 0; i < 1000; i++)
	{
		lock.lock()!!;
		counter++;
		lock.unlock();
	}
	return 0;
}

fn void main()
{
	lock.init()!!;
	defer (void)lock.destroy();
	Thread a, b;
	a.create(&work, null)!!;
	b.create(&work, null)!!;
	a.join()!!;
	b.join()!!;
	io::printfn("counter=%d", counter);
}
