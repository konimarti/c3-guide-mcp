// Recipe: list a directory, only the files that match a mask (*.txt), sorted by name
// Also: glob, filter files, extension, readdir, opendir, scandir, directory listing, file names
// expect: a.txt
// expect: b.txt
import std::io;
import std::io::path;
import std::sort;

fn int by_text(String a, String b) => a.compare_to(b);

fn void main()
{
	Path? dir = path::temp_directory(tmem);
	if (catch err = dir) return;
	Path? sub = dir.tappend("recipe_mask");
	if (catch err = sub) return;
	if (path::exists(sub)) path::rmtree(sub)!!;
	path::mkdir(sub, true)!!;
	defer (void)path::rmtree(sub);
	String base = (String)sub;
	file::save(string::tformat("%s/b.txt", base), "b")!!;
	file::save(string::tformat("%s/a.txt", base), "a")!!;
	file::save(string::tformat("%s/c.log", base), "c")!!;

	// path::ls(allocator, dir, no_dirs, no_symlinks, mask)
	PathList? entries = path::ls(tmem, sub, true, false, "*.txt");
	if (catch err = entries) return;
	String[] names = mem::talloc_array(String, entries.len());
	foreach (i, e : entries) names[i] = e.basename();
	sort::quicksort(names, &by_text);
	foreach (n : names) io::printn(n);
}
