// Recipe: optional interface method: @optional, test that an implementor has the method before calling it (if (&r.close)), calling a missing one panics
// Also: interface, @dynamic, dynamic dispatch, not implemented, may not be implemented, method exists check
// expect: finishing file
// expect: file closed
// expect: finishing memory
// expect: (no close)
import std::io;

interface Reader
{
	fn String name();
	fn void close() @optional;       // an implementor may leave this out
}

struct File (Reader) { int fd; }
struct Memory (Reader) { int n; }

fn String File.name(&self) @dynamic => "file";
fn void File.close(&self) @dynamic { io::printn("file closed"); }
fn String Memory.name(&self) @dynamic => "memory";      // no close()

fn void finish(Reader r)
{
	io::printfn("finishing %s", r.name());
	if (&r.close)                    // test that the optional method exists; calling a missing one panics
	{
		r.close();
	}
	else
	{
		io::printn("(no close)");
	}
}

fn void main()
{
	File f = { 3 };
	Memory m = { 1 };
	finish(&f);
	finish(&m);
}
