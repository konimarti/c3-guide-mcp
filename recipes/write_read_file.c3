// Recipe: write a string to a file and read a whole file back (file::save, file::load_temp)
// expect: hello file
import std::io;

fn void main()
{
	String path = "recipe_rw.txt";
	if (catch err = file::save(path, "hello file"))
	{
		io::printfn("write failed: %s", err);
		return;
	}
	defer (void)file::delete(path);

	char[]? data = file::load_temp(path);   // temp allocator: no free needed
	if (catch err = data) return;
	io::printn((String)data);
}
