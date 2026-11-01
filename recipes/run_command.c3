// Recipe: run an external command and capture its output (process::run_capture_stdout)
// expect: hi
import std::io;
import std::os::process;

fn void main()
{
	char[256] buffer;
	String? out = process::run_capture_stdout(buffer[..], { "echo", "hi" });
	if (catch err = out)
	{
		io::printfn("failed: %s", err);
		return;
	}
	io::printn(out.trim());
}
