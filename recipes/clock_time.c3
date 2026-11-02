// Recipe: wall clock and stopwatch (time::now for the date, clock::now for measuring how long something takes)
// Also: current time, timestamp, unix time, milliseconds, elapsed, stopwatch, benchmark, duration
// expect: after 2000: true
// expect: elapsed ok: true
import std::io;
import std::time;
import std::time::clock;
import std::thread;

fn void main()
{
	Time t = time::now();                           // wall clock, for dates
	io::printfn("after 2000: %s", t.to_seconds() > 946684800);
	Clock c = clock::now();                         // monotonic, for durations
	thread::sleep_ms(20);
	long ms = (long)c.to_now() / 1_000_000;         // nanoseconds to milliseconds
	io::printfn("elapsed ok: %s", ms >= 20);
}
