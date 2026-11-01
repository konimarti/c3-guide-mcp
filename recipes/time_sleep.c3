// Recipe: time: measure elapsed time (clock::now, mark), sleep (thread::sleep, ms)
// expect: slept at least 50ms: true
import std::io;
import std::time;
import std::thread;

fn void main()
{
	Clock start = clock::now();
	thread::sleep(time::ms(50))!!;
	NanoDuration elapsed = start.to_now();
	io::printfn("slept at least 50ms: %s", elapsed.to_ms() >= 50);
}
