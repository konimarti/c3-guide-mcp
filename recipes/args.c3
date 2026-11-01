// Recipe: command line arguments (main with String[] args)
// Also: argv, argc, main arguments, command line parameters, program name
// expect: args: 0
import std::io;

fn void main(String[] args)
{
	// args[0] is the program name
	io::printfn("args: %d", args.len - 1);
	foreach (i, a : args[1..]) io::printfn("%d: %s", i, a);
}
