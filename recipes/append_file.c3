// Recipe: append a line to a file (file::open with mode "a"), then read the file back
// Also: append, add to file, log file, write lines, open for append, file::open, File.write
// expect: lines: 2
import std::io;
import std::io::file;

fn void? run(String path)
{
	File f = file::open(path, "a")!;
	defer (void)f.close();
	f.write("first\n")!;
	f.write("second\n")!;
}

fn void main()
{
	String path = "recipe_append.txt";
	defer (void)file::delete(path);
	if (catch run(path))
	{
		io::printn("write failed");
		return;
	}
	String text = (String)file::load_temp(path)!!;
	io::printfn("lines: %d", text.trim().tsplit("\n").len);
}
