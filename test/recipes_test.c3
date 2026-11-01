module c3guide::test::recipes;
import c3guide::test::support;
import std::collections::list, std::core::string, std::io, std::io::file, std::io::path;

// Every recipe in recipes/ must compile and print exactly its `// expect:` lines. Recipes are what the
// server shows to a model as "this works"; a recipe that does not compile is worse than none.
// Unix only (runs each program through `sh`, in its own empty directory). `c3c test` runs in the project root.

fn String directive(String text, String prefix)
{
	DString out = dstring::temp();
	foreach (line : text.tsplit("\n"))
	{
		if (line.starts_with(prefix)) out.append(line[prefix.len..].trim());
	}
	return out.str_view();
}

fn String[] expected(String text)
{
	List{String} want;
	want.tinit();
	foreach (line : text.tsplit("\n"))
	{
		if (line.starts_with("// expect:")) want.push(line["// expect:".len..].trim());
	}
	return want.array_view();
}

// "" when the recipe works, else what is wrong with it.
fn String check_recipe(String file, String name)
{
	String text = (String)file::load_temp(file)!!;
	String[] want = expected(text);
	if (!text.starts_with("// Recipe: ") || want.len == 0) return "needs a '// Recipe: ' title and '// expect:' lines";
	Path dir = support::make_temp_dir("c3recipe");
	defer (void)path::rmtree(dir);
	String exe = string::tformat("%s/%s", (String)dir, name);
	String compile = support::sh(string::tformat("'%s' compile '%s' -o '%s' 2>&1 || echo COMPILE-FAILED", support::c3c_binary(), file, exe));
	if (compile.contains("COMPILE-FAILED")) return string::tformat("does not compile:\n%s", compile);
	// "// stdin: one\ntwo three\n" - the \n are written as backslash-n in the recipe
	String stdin_text = directive(text, "// stdin:");
	String got = support::sh(string::tformat("cd '%s' && printf '%%b' '%s' | './%s'", (String)dir, stdin_text, name));
	String[] lines = got.trim().len == 0 ? (String[]){} : got.trim().tsplit("\n");
	bool same = lines.len == want.len;
	if (same) foreach (i, l : lines) same = same && l.trim() == want[i];
	if (!same) return string::tformat("want %s\n got %s", want, got.trim());
	return "";
}

fn void every_recipe_compiles_and_prints_what_it_says() @test
{
	PathList list = path::ls(tmem, path::new(tmem, "recipes")!!, no_dirs: true, relative: true)!!;
	assert(list.len() > 0, "no recipes found: run from the project root");
	int bad = 0;
	foreach (entry : list)
	{
		String name = entry.basename();
		if (!name.ends_with(".c3")) continue;
		String problem = check_recipe(string::tformat("recipes/%s", name), name[:name.len - 3]);
		if (problem.len > 0)
		{
			io::printfn("FAIL %s: %s", name, problem);
			bad++;
		}
	}
	assert(bad == 0, "%d recipes fail", bad);
}
