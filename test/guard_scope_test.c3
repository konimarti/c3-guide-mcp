module c3guide::test::guard_scope;
import c3guide::compiler, c3guide::proc;
import c3guide::check, c3guide::util, c3guide::guard, c3guide::sources, c3guide::test::support;
import std::core::string, std::io, std::io::file, std::io::path, std::os::env, std::collections::list;

// The guard reads the files c3c compiles (src/guard.c3), not the folder tree: scratch folders and review fixtures in a
// project, which c3c never reads, do not get the project refused. Each case is one project in a fresh folder.

fn bool has(String hay, String needle) @local => hay.contains(needle);

const String EVIL = "module evil;\nconst char C = $embed(\"/etc/passwd\")[0];\n";
const String CLEAN_MAIN = "module app;\nfn void main() {}\n";
const String LIB_MANIFEST = "{ \"provides\": \"lexer\", \"sources\": [\"src/**\"], \"targets\": { \"linux-x64\": {}, \"macos-aarch64\": {}, \"macos-x64\": {}, \"windows-x64\": {} } }";

fn void put(String proj, String rel, String text) @local
{
	String f = string::tformat("%s/%s", proj, rel);
	String d = f[:f.rindex_of("/") ?? 0];
	path::mkdir(path::new(tmem, d)!!, recursive: true)!!;
	file::save(f, text)!!;
}

// Like c3f: sources and test-sources by pattern, a library in lib/, a work folder and a review folder next to them.
fn String c3f_like(String root, String name, String sources) @local
{
	String proj = string::tformat("%s/%s", root, name);
	put(proj, "project.json", string::tformat("{ \"langrev\": \"1\", \"sources\": [%s], \"test-sources\": [\"test/**\"], \"dependency-search-paths\": [\"lib\"], \"dependencies\": [\"lexer\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }", sources));
	put(proj, "src/c3f/main.c3", "module app;\nimport lexer;\nfn void main() { lexer::tok(); }\n");
	put(proj, "test/t.c3", "module app_test;\nfn void helper() {}\n");
	put(proj, "lib/lexer.c3l/manifest.json", LIB_MANIFEST);
	put(proj, "lib/lexer.c3l/src/lexer.c3", "module lexer;\nfn void tok() {}\n");
	return proj;
}

fn void scratch_folders_and_fixtures_do_not_get_a_project_refused() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	String proj = c3f_like(root, "c3f", "\"src/c3f/**\"");
	// a stdlib copy and a source that reads /etc/passwd in an ignored work folder, a library that names sources outside
	// itself and an evil source in review fixtures: none of it is compiled
	put(proj, ".work/prev/round1/unit-stdlib/std/libc/x.c3", EVIL);
	put(proj, ".work/evil.c3", EVIL);
	put(proj, "review/probes/lib_manifest/proj/lib/evil.c3l/manifest.json", "{ \"provides\": \"evil\", \"sources\": [\"../../../../../../outside/**\"] }");
	put(proj, "review/probes/evil.c3", EVIL);
	put(proj, "docs/example.c3", EVIL);
	String note;
	assert(guard::project_escape_note(proj, &note) == "", "%s", guard::project_escape_note(proj, &note));
	assert(note == "", "no whole-tree scan for plain patterns: %s", note);
	String r = check::c3_check(path: proj);
	assert(has(r, "OK: no errors"), "%s", r);
	assert(!has(r, "rejected") && !has(r, "scanned the whole tree"), "%s", r);
}

// The same file in a place c3c compiles is refused, with the file, the line and the reason on one line.
fn void the_same_evil_file_in_a_compiled_place_is_refused_in_one_line() @test
{
	$if !env::WIN32:
		Path dir = proc::scratch_dir()!!;
		defer (void)path::rmtree(dir);
		String root = (String)dir;
		String proj = c3f_like(root, "c3f", "\"src/c3f/**\"");
		put(proj, "review/evil.c3", EVIL);
		assert(guard::project_escape(proj) == "");
		// 1) in a source folder
		put(proj, "src/c3f/sub/evil.c3", EVIL);
		String why = guard::project_escape(proj);
		assert(why == "src/c3f/sub/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s", why);
		String r = check::c3_check(path: proj);
		assert(has(r, "rejected: src/c3f/sub/evil.c3:2: $embed path") && has(r, "c3c build") && !has(r, "cannot be shown"), "%s", r);
		(void)file::delete(string::tformat("%s/src/c3f/sub/evil.c3", proj));
		// 2) in a test-sources folder
		put(proj, "test/evil.c3", EVIL);
		assert(guard::project_escape(proj) == "test/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s", guard::project_escape(proj));
		(void)file::delete(string::tformat("%s/test/evil.c3", proj));
		// 3) in a dependency library (its manifest names src/**)
		put(proj, "lib/lexer.c3l/src/evil.c3", EVIL);
		assert(guard::project_escape(proj) == "lib/lexer.c3l/src/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s", guard::project_escape(proj));
		(void)file::delete(string::tformat("%s/lib/lexer.c3l/src/evil.c3", proj));
		// 4) in a folder a source pattern names through a link (the target is inside the project, read where it is compiled)
		support::sh(string::tformat("cd '%s' && ln -s review linked", proj));
		put(proj, "project.json", "{ \"sources\": [\"src/c3f/**\", \"linked/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }");
		String linked = guard::project_escape(proj);
		assert(linked == "linked/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s", linked);
		// 5) named as a file, by a plain sources entry
		put(proj, "project.json", "{ \"sources\": [\"src/c3f/**\", \"review/evil.c3\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }");
		assert(guard::project_escape(proj) == "review/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s", guard::project_escape(proj));
		// 6) a folder the target adds (a target's sources are compiled for it)
		put(proj, "project.json", "{ \"sources\": [\"src/c3f/**\"], \"targets\": { \"app\": { \"type\": \"executable\", \"sources\": [\"review\"] } } }");
		assert(guard::project_escape(proj) == "review/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s", guard::project_escape(proj));
		// 7) .c3t and .c3i are sources too
		put(proj, "project.json", "{ \"sources\": [\"src/c3f/**\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }");
		put(proj, "src/c3f/x.c3t", EVIL);
		assert(guard::project_escape(proj) == "src/c3f/x.c3t:2: $embed path '/etc/passwd' leaves the project", "%s", guard::project_escape(proj));
	$endif
}

fn void the_messages_say_what_is_wrong() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	String proj = c3f_like(root, "p", "\"src/c3f/**\"");
	String[] bodies = {
		"module a;\nconst String N = \"x\";\nconst char C = $embed(N)[0];\n",
		"module a;\nconst char C = $embed(\"a\" +++ \"b\")[0];\n",
		"module a;\nconst char C = $embed(\"\\x2fetc/passwd\")[0];\n",
		"module a;\nmacro m() { $exec(\"id\"); }\n",
	};
	String[] reasons = { "$embed with a computed path", "$embed with a path built from parts", "$embed with a path written with escapes", "$exec runs a program" };
	foreach (i, body : bodies)
	{
		put(proj, "src/c3f/bad.c3", body);
		String why = guard::project_escape(proj);
		assert(why.starts_with("src/c3f/bad.c3:") && has(why, reasons[i]), "%s: %s", reasons[i], why);
	}
	// a library whose manifest names sources outside it
	put(proj, "src/c3f/bad.c3", CLEAN_MAIN);
	put(proj, "lib/lexer.c3l/manifest.json", "{ \"provides\": \"lexer\", \"sources\": [\"../../../outside/**\"] }");
	path::mkdir(path::new(tmem, string::tformat("%s/outside", root))!!)!!;
	String why = guard::project_escape(proj);
	assert(why == "lib/lexer.c3l/manifest.json: library manifest names sources outside its library ('../../../outside/**')", "%s", why);
}

// A pattern the guard cannot expand exactly like c3c: the whole tree is read, as before, and the answer says why.
fn void a_pattern_the_guard_cannot_expand_reads_the_whole_tree_and_says_so() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	String[] odd = { "\"src/c3f/m*\"", "\"src/c3f/m?in\"", "\"src/**/\"", "\"${HOME}/x/**\"" };
	int n = 0;
	foreach (pattern : odd)
	{
		String proj = c3f_like(root, string::tformat("p%d", n++), pattern);
		String note;
		String why = guard::project_escape_note(proj, &note);
		assert(why == "", "%s: %s", pattern, why);
		assert(has(note, "scanned the whole tree because") && has(note, "pattern"), "%s: %s", pattern, note);
		String r = check::c3_check(path: proj);
		assert(r.starts_with("(scanned the whole tree because"), "%s: %s", pattern, r);
		// the whole tree: what the work folder holds is read now
		put(proj, ".work/evil.c3", EVIL);
		why = guard::project_escape_note(proj, &note);
		assert(why == ".work/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s: %s", pattern, why);
		assert(has(check::c3_check(path: proj), "rejected"), "%s", pattern);
	}
	// a template and a project.json that is not JSON
	String t = c3f_like(root, "tpl", "\"src/c3f/**\"");
	put(t, "project.json", "{ \"sources\": [\"src/c3f/**\"], \"targets\": { \"app\": { \"type\": \"executable\", \"template\": \"x/y\" } } }");
	String note;
	assert(guard::project_escape_note(t, &note) == "" && has(note, "template"), "%s", note);
	put(t, "project.json", "{ \"sources\": [\"src/c3f/**\" ");
	String why = guard::project_escape_note(t, &note);
	assert(has(note, "scanned the whole tree") && has(why, "project.json"), "%s %s", note, why);
}

// The expansion follows c3c (probes in docs/MAINTAINING.md): dot names are skipped, .c3t and .c3i count, case matters,
// `src/*` is one folder, a folder name is a folder, a loop through a link is entered once.
fn void patterns_are_expanded_like_c3c() @test
{
	$if !env::WIN32:
		Path dir = proc::scratch_dir()!!;
		defer (void)path::rmtree(dir);
		String proj = string::tformat("%s/p", (String)dir);
		String[] files = { "src/a.c3", "src/b.c3t", "src/c.c3i", "src/UP.C3", "src/n.txt", "src/.h.c3", "src/.hid/x.c3", "src/sub/d.c3", "src/dir.c3/in.c3", "top.c3", "other/o.c3" };
		foreach (f : files) put(proj, f, "module m;\n");
		support::sh(string::tformat("cd '%s' && ln -s .. src/sub/up && ln -s ../other src/lk && ln -s a.c3 src/fl.c3 && ln -s a.c3 src/fl.txt", proj));
		String[] patterns = { "src/**", "src/*", "src", "src/", "./src/**", "src/sub/../**", "./*", "*", "**", "src/a.c3", "src/n.txt", "src/*.c3", "src/**/", "src/sub", "src/main.C3" };
		String[] want = {
			"src/a.c3 src/b.c3t src/c.c3i src/fl.c3 src/lk/o.c3 src/sub/d.c3",
			"src/a.c3 src/b.c3t src/c.c3i src/fl.c3",
			"src/a.c3 src/b.c3t src/c.c3i src/fl.c3 src/lk/o.c3 src/sub/d.c3",
			"src/a.c3 src/b.c3t src/c.c3i src/fl.c3 src/lk/o.c3 src/sub/d.c3",
			"src/a.c3 src/b.c3t src/c.c3i src/fl.c3 src/lk/o.c3 src/sub/d.c3",
			"src/a.c3 src/b.c3t src/c.c3i src/fl.c3 src/lk/o.c3 src/sub/d.c3",
			"top.c3",
			"top.c3",
			"other/o.c3 src/a.c3 src/b.c3t src/c.c3i src/fl.c3 src/lk/o.c3 src/sub/d.c3 top.c3",
			"src/a.c3",
			"!",
			"!",   // a wildcard before the end: not a form c3c expands
			"!",
			"src/sub/d.c3 src/sub/up/a.c3 src/sub/up/b.c3t src/sub/up/c.c3i src/sub/up/fl.c3 src/sub/up/lk/o.c3",   // up -> .. is entered once; its own way back (up/sub) is the loop
			"!",
		};
		foreach (i, pattern : patterns)
		{
			List{String} found;
			found.init(tmem);
			String base;
			String why = sources::expand_pattern(proj, pattern, &found, 600, &base);
			DString got = dstring::temp();
			String[] names = mem::talloc_array(String, found.len());
			foreach (k, f : found) names[k] = f[proj.len + 1..].replace(tmem, "sub/../", "").replace(tmem, "./", "");
			// order: sorted per folder; compare as a sorted list
			quicksort_strings(names);
			foreach (k, nm : names) got.appendf("%s%s", k > 0 ? " " : "", nm);
			String expect = want[i];
			if (expect == "!") { assert(why.len > 0 && found.len() == 0, "%s: %s | %s", pattern, why, got.str_view()); }
			else { assert(why == "" && got.str_view() == expect, "%s: '%s' (%s) wanted '%s'", pattern, got.str_view(), why, expect); }
		}
	$endif
}

fn void quicksort_strings(String[] a) @local
{
	for (sz i = 1; i < a.len; i++)
	{
		String x = a[i];
		sz j = i;
		while (j > 0 && a[j - 1].compare_to(x) > 0) { a[j] = a[j - 1]; j--; }
		a[j] = x;
	}
}

// The folders c3c can find libraries in are not only the top level's `dependency-search-paths`: code + path gives it lib and
// deps when the top level has none, a target can have search paths of its own, and a target without any (or with an empty
// `-override`) searches the project's own folder. A library in any of them is read.
fn void a_library_in_a_folder_c3c_can_search_is_read_wherever_the_key_is() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	// 1) search paths only inside a target; code + path hands c3c `--libdir lib` all the same
	String a = string::tformat("%s/a", root);
	put(a, "project.json", "{ \"sources\": [\"src/**\"], \"dependencies\": [\"evil\"], \"targets\": { \"app\": { \"type\": \"executable\", \"dependency-search-paths\": [\"libs\"] } } }");
	put(a, "src/main.c3", CLEAN_MAIN);
	put(a, "libs/.keep", "");
	put(a, "lib/evil.c3l/manifest.json", "{ \"provides\": \"evil\", \"sources\": [\"src/**\"] }");
	put(a, "lib/evil.c3l/src/evil.c3", EVIL);
	String r = check::c3_check("import evil;", path: a);
	assert(has(r, "rejected: lib/evil.c3l/src/evil.c3:2: $embed path"), "%s", r);
	r = check::c3_run("import evil;\nfn void main() {}", path: a);
	assert(has(r, "rejected: lib/evil.c3l/src/evil.c3:2: $embed path"), "%s", r);
	// 2) a library in the project's own folder, found by a target that has no search paths of its own
	String b = string::tformat("%s/b", root);
	put(b, "project.json", "{ \"sources\": [\"src/**\"], \"dependency-search-paths\": [\"lib\"], \"dependencies\": [\"evil\"], \"targets\": { \"app\": { \"type\": \"executable\" }, \"other\": { \"type\": \"executable\", \"dependency-search-paths-override\": [] } } }");
	put(b, "src/main.c3", CLEAN_MAIN);
	put(b, "lib/.keep", "");
	put(b, "evil.c3l/manifest.json", "{ \"provides\": \"evil\", \"sources\": [\"src/**\"] }");
	put(b, "evil.c3l/src/evil.c3", EVIL);
	r = check::c3_check(path: b, target: "other");
	assert(has(r, "rejected: evil.c3l/src/evil.c3:2: $embed path"), "%s", r);
}

// The whole-tree fallback is said in the answer of c3_run with a project too.
fn void c3_run_with_a_project_says_when_the_whole_tree_was_read() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String proj = c3f_like((String)dir, "p", "\"src/c3f/**\", \"src/c3f/zz?\"");
	String r = check::c3_run("import std::io;\nfn void main() { io::printn(\"hi\"); }", path: proj);
	assert(r.starts_with("(scanned the whole tree because"), "%s", r);
}

// A link at the root of a pattern, or named as a source, that leaves the project (or ends nowhere) is refused: c3c compiles
// what it points to, and the target's folder is not a tree of the project's own. A pattern that is spelled to leave
// (`../shared/**`, an absolute path) is another thing: it names a folder of its own.
fn void a_link_named_by_a_pattern_that_leaves_the_project_is_refused() @test
{
	$if !env::WIN32:
		Path dir = proc::scratch_dir()!!;
		defer (void)path::rmtree(dir);
		String root = (String)dir;
		put(root, "ext/secret.txt", "S3CRET");
		put(root, "ext/evil.c3", "module evil;\nconst char[*] S = $embed(\"secret.txt\");\n");
		String[] sources = { "\"link.c3\"", "\"sym_dir/**\"", "\"sym_dir/*\"", "\"sym_dir\"", "\"dangle.c3\"", "\"dangle_dir/**\"", "\"src/main.c3\", \"link.c3\"" };
		String[] expect = { "link.c3: link leaves the project", "sym_dir: link leaves the project", "sym_dir: link leaves the project", "sym_dir: link leaves the project", "dangle.c3: link that ends nowhere", "dangle_dir: link that ends nowhere", "link.c3: link leaves the project" };
		foreach (i, one : sources)
		{
			String proj = string::tformat("%s/p%d", root, i);
			put(proj, "project.json", string::tformat("{ \"sources\": [%s], \"targets\": { \"app\": { \"type\": \"executable\" } } }", one));
			put(proj, "src/main.c3", CLEAN_MAIN);
			support::sh(string::tformat("cd '%s' && ln -s '%s/ext/evil.c3' link.c3 && ln -s '%s/ext' sym_dir && ln -s nowhere.c3 dangle.c3 && ln -s nowhere dangle_dir", proj, root, root));
			String why = guard::project_escape(proj);
			assert(why == expect[i], "%s: %s", one, why);
			assert(has(check::c3_check(path: proj), "rejected"), "%s", one);
		}
		// spelled to leave: a folder and a file of their own, read in their own tree (clean here, so accepted)
		String own = string::tformat("%s/own", root);
		put(own, "project.json", "{ \"sources\": [\"src/**\", \"../shared/**\", \"../one.c3\"], \"targets\": { \"app\": { \"type\": \"executable\" } } }");
		put(own, "src/main.c3", CLEAN_MAIN);
		put(root, "shared/s.c3", "module s;\nfn void f() {}\n");
		put(root, "one.c3", "module one;\nfn void g() {}\n");
		assert(guard::project_escape(own) == "", "%s", guard::project_escape(own));
		put(root, "shared/bad.c3", "module bad;\nconst char C = $embed(\"/etc/passwd\")[0];\n");
		assert(has(guard::project_escape(own), "bad.c3:2: $embed path"), "%s", guard::project_escape(own));
	$endif
}

// A refusal inside a library archive is a message that must still be there when it is shown (it was built in a pool that
// was gone on return: the bytes were 0xaa).
fn void a_refusal_for_a_library_archive_is_readable() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String proj = c3f_like((String)dir, "p", "\"src/c3f/**\"");
	String z = string::tformat("%s/lib/zip.c3l", proj);
	support::sh(string::tformat("cd '%s' && printf 'module zipped;\\nconst char C = $embed(\"/etc/passwd\")[0];\\n' > zipped.c3 && python3 -c \"import zipfile; z = zipfile.ZipFile('%s', 'w'); z.write('zipped.c3'); z.write('/dev/null', 'manifest.json'); z.close()\"", (String)dir, z));
	String why = guard::project_escape(proj);
	assert(why == "lib/zip.c3l!/zipped.c3:2: $embed path '/etc/passwd' leaves the project", "%s", why);
	String r = check::c3_check(path: proj);
	assert(has(r, "rejected: lib/zip.c3l!/zipped.c3:2") && support::valid_utf8(r), "%s", r);
}

// A wildcard in the folder part of a pattern is not a form c3c expands, so the whole tree is read, also when no folder of
// that name exists (nothing matches, and the build fails: but the guard must not have taken "no files" for "clean").
fn void a_wildcard_in_a_folder_part_reads_the_whole_tree_even_when_nothing_matches() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	String[] odd = { "\"src/su?/**\"", "\"src/[s]ub/**\"", "\"src/*/x/**\"", "\"s*c/**\"", "\"src/**/x.c3\"", "\"src/su?/*\"" };
	foreach (i, pattern : odd)
	{
		String proj = c3f_like(root, string::tformat("w%d", i), pattern);
		put(proj, ".work/evil.c3", EVIL);
		String note;
		String why = guard::project_escape_note(proj, &note);
		assert(why == ".work/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s: %s", pattern, why);
		assert(has(note, "scanned the whole tree because") && has(note, "wildcard"), "%s: %s", pattern, note);
	}
}

// A library target can replace its sources (`sources-override`): both what it names and where it names it are read.
fn void a_library_manifest_sources_override_is_read() @test
{
	Path dir = proc::scratch_dir()!!;
	defer (void)path::rmtree(dir);
	String root = (String)dir;
	// inside the library: the folder it names is read
	String proj = c3f_like(root, "in", "\"src/c3f/**\"");
	put(proj, "lib/lexer.c3l/manifest.json", "{ \"provides\": \"lexer\", \"sources\": [\"src/**\"], \"targets\": { \"linux-x64\": { \"sources-override\": [\"alt/**\"] } } }");
	put(proj, "lib/lexer.c3l/alt/evil.c3", EVIL);
	assert(guard::project_escape(proj) == "lib/lexer.c3l/alt/evil.c3:2: $embed path '/etc/passwd' leaves the project", "%s", guard::project_escape(proj));
	// outside the library: the manifest is refused
	String out = c3f_like(root, "out", "\"src/c3f/**\"");
	path::mkdir(path::new(tmem, string::tformat("%s/outside", root))!!)!!;
	put(out, "lib/lexer.c3l/manifest.json", "{ \"provides\": \"lexer\", \"targets\": { \"linux-x64\": { \"sources-override\": [\"../../../outside/**\"] } } }");
	String why = guard::project_escape(out);
	assert(why == "lib/lexer.c3l/manifest.json: library manifest names sources outside its library ('../../../outside/**')", "%s", why);
}
