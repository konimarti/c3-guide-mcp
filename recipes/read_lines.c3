// Recipe: read a file line by line (open, readline, close)
// expect: lines: 3
// expect: longest: longer
import std::io;

fn void main()
{
	file::save("recipe_lines.txt", "ab\nlonger\nxyz\n")!!;
	defer (void)file::delete("recipe_lines.txt");

	File? f = file::open("recipe_lines.txt", "r");
	if (catch err = f)
	{
		io::printfn("cannot open: %s", err);
		return;
	}
	defer (void)f.close();

	int n;
	String longest;
	// readline returns the next line without the newline, and the fault io::EOF at the end
	while (try line = io::treadline(&f))
	{
		n++;
		if (line.len > longest.len) longest = line.tcopy();
	}
	io::printfn("lines: %d", n);
	io::printfn("longest: %s", longest);
}
