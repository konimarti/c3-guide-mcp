// Recipe: create a directory (mkdir), list a directory (ls), check that a path exists, delete a directory (rmtree)
// expect: exists: true
// expect: entries: 2
// expect: gone: true
import std::io;
import std::io::path;

fn void main()
{
	Path? dir = path::temp_directory(tmem);
	if (catch err = dir) return;
	Path? sub = dir.tappend("recipe_dir");
	if (catch err = sub) return;
	if (path::exists(sub)) path::rmtree(sub)!!;

	path::mkdir(sub, true)!!;            // true: also create missing parents
	String base = (String)sub;           // a Path is a String underneath
	file::save(string::tformat("%s/a.txt", base), "a")!!;
	file::save(string::tformat("%s/b.txt", base), "b")!!;
	io::printfn("exists: %s", path::exists(sub));

	PathList? list = path::ls(tmem, sub);
	if (try l = list) io::printfn("entries: %d", l.len());

	path::rmtree(sub)!!;
	io::printfn("gone: %s", !path::exists(sub));
}
