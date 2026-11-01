// Recipe: read lines from standard input until the end (treadline returns a fault at EOF)
// Also: stdin, scanf, gets, getline, input, read line from console, interactive, pipe
// stdin: one\ntwo three\n
// expect: 1: one
// expect: 2: two three
import std::io;

fn void main()
{
	int n;
	while (try line = io::treadline())      // io::EOF ends the loop
	{
		n++;
		io::printfn("%d: %s", n, line);
	}
}
