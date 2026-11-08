module c3guide::test::support;
import c3guide::compiler;
import c3guide::check, c3guide::corpus;
import std::core::string, std::core::string::conv, std::io, std::io::file, std::io::path, std::os::env, std::os::process, std::time::clock;

// The snapshot is parsed once, before the tests start (so the test allocator does not count it as a leak).
fn void load_corpus() @init(2000) @local { corpus::load(); }

fn bool contains_ci(String text, String want)
{
	return text.to_lower_tcopy().contains(want.to_lower_tcopy());
}

// A fresh empty directory under the system temp dir; remove it with path::rmtree.
fn Path make_temp_dir(String prefix)
{
	Path tmp = path::temp_directory(tmem)!!;
	Path dir = tmp.tappend(string::tformat("%s-%d", prefix, (long)clock::now()))!!;
	path::mkdir(dir)!!;
	return dir;
}

// Run `sh -c script` and return what it printed (stdout only). Unix only.
fn String sh(String script)
{
	char[] buf = mem::talloc_array(char, 64 * 1024);
	String out = process::run_capture_stdout(buf, { "sh", "-c", script }, process::SpawnOptions.INHERIT_ENV)!!;
	return out;
}

// The compiler the tests use: the one the server itself would find.
fn String c3c_binary() => compiler::c3c_binary();

// Is every byte of `s` part of a well-formed UTF-8 character? (A cut inside a character would make the
// whole JSON-RPC line invalid for the client.)
fn bool valid_utf8(String s)
{
	sz i = 0;
	while (i < s.len)
	{
		sz size = s.len - i;
		Char32? c = conv::utf8_to_char32(&s[i], &size);
		if (catch c) return false;
		if (i + size > s.len) return false;
		i += size;
	}
	return true;
}

// Run `body` as the C3C compiler for the duration of one c3_check call. Unix only.
// (The fakes `exec` their work: a grandchild would keep the pipe open and only the SDK's 30 s @Timeout would end the call.)
fn String write_fake(Path dir, String name, String body)
{
	String file = string::tformat("%s/%s", (String)dir, name);
	file::save(file, string::tformat("#!/bin/sh\n%s\n", body))!!;
	sh(string::tformat("chmod 755 '%s'", file));
	return file;
}

fn void set_c3c(String value)
{
	env::set_var("C3C", value);
}

// The C3C variable as the test run got it, to put back after a test pointed it at a fake.
String original_c3c;
fn void remember_c3c() @init(2001) @local
{
	original_c3c = (env::get_var(mem, "C3C") ?? "").copy(mem);
}
fn void restore_c3c()
{
	if (original_c3c.len > 0)
	{
		env::set_var("C3C", original_c3c);
	}
	else
	{
		env::clear_var("C3C");
	}
}
