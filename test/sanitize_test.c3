module c3guide::test::sanitize;
import c3guide::check, c3guide::proc, c3guide::compiler, c3guide::test::support;
import std::core::string, std::io::file, std::io::path, std::os::env;

fn bool has(String hay, String needle) @local => hay.contains(needle);

// A sandbox can set a soft data-segment or address-space limit far below the hard one. A run with a sanitizer raises the soft
// limits to the hard ones before it starts the compiler (and never above them); other runs are left as they are.
fn String limits_after(String lowered) @local
{
	return support::sh(string::tformat("%s%s ulimit -S -d; ulimit -S -v", lowered, proc::RAISE_LIMITS)).trim();
}

fn void raising_goes_to_the_hard_limit_and_not_above() @test
{
	$if !env::WIN32:
		// hard limits of 3 GB and 5 GB (KB units), soft ones far below
		String r = limits_after("ulimit -S -d 1000000; ulimit -H -d 3000000; ulimit -S -v 2000000; ulimit -H -v 5000000;");
		assert(r == "3000000\n5000000", "%s", r);
		// the data limit alone is lowered: the address-space limit stays where it was
		String d = limits_after("ulimit -S -d 100000; ulimit -H -d 2500000;");
		assert(d.starts_with("2500000\n"), "%s", d);
	$endif
}

extern fn CInt setrlimit(CInt resource, ulong* limit);
extern fn CInt getrlimit(CInt resource, ulong* limit);
const CInt RLIMIT_DATA = 2;   // Linux

// The data limit of this process lowered to 1 GB; false when the platform or the hard limit does not allow it.
fn bool lower_data_limit(ulong[2]* old)
{
	$if env::LINUX:
		if (getrlimit(RLIMIT_DATA, old) != 0) return false;
		ulong[2] low = { 1_000_000_000, (*old)[1] };
		return (*old)[1] >= low[0] && setrlimit(RLIMIT_DATA, &low) == 0;
	$else
		return false;
	$endif
}

fn void only_a_run_that_asks_gets_raised_limits() @test
{
	$if env::LINUX:
		ulong[2] old;
		if (!lower_data_limit(&old)) return;
		int code = 0;
		bool timed_out = false;
		String[] show = { "/bin/sh", "-c", "ulimit -S -d" };
		String plain = proc::run_capped(show, &code, &timed_out) ?? "failed";
		String raised = proc::run_capped(show, &code, &timed_out, { .raise_limits = true }) ?? "failed";
		(void)setrlimit(RLIMIT_DATA, &old);
		String hard = old[1] == ulong::max ? "unlimited" : string::tformat("%d", old[1] / 1024);
		assert(plain == "976562\n" || plain == "976563\n", "%s", plain);
		assert(raised == string::tformat("%s\n", hard), "want %s: %s", hard, raised);
	$endif
}

// With a soft data limit of 1 GB, like the sandbox: c3_test with sanitize=address must still start the sanitizer (it reserves
// terabytes of address space for its shadow memory).
fn void a_sanitizer_run_starts_under_a_soft_data_limit() @test
{
	$if env::LINUX:
		Path dir = support::make_temp_dir("c3san");
		defer (void)path::rmtree(dir);
		String f = string::tformat("%s/ok.c3", (String)dir);
		file::save(f, "module ok;\nfn void fine() @test { assert(1 + 1 == 2); }\n")!!;
		ulong[2] old;
		if (!lower_data_limit(&old)) return;
		String t = check::c3_test(f, sanitize: "address");
		(void)setrlimit(RLIMIT_DATA, &old);
		// it runs, or (a c3c that lowers the limit again itself, as a sandbox wrapper does) it says so in one line; never the raw report
		assert(!has(t, "ReserveShadowMemoryRange") && !has(t, "AddressSanitizer failed"), "%s", t);
		assert(has(t, "1 passed") || has(t, "no output") || (has(t, "did not run") && t.len < 500), "%s", t);
	$endif
}

fn void a_sanitizer_that_still_cannot_reserve_gives_one_line() @test
{
	$if !env::WIN32:
		Path dir = support::make_temp_dir("c3fake");
		defer (void)path::rmtree(dir);
		defer support::restore_c3c();
		support::set_c3c(support::write_fake(dir, "asan.sh", "echo '==1==ERROR: AddressSanitizer failed to allocate 0xdfff0001000 bytes (errno: 12)'\necho '==1==ReserveShadowMemoryRange failed while trying to map 0xdfff0001000 bytes. Perhaps you are using ulimit -v or ulimit -d'\nexit 1"));
		String f = string::tformat("%s/ok.c3", (String)dir);
		file::save(f, "module ok;\nfn void fine() @test {}\n")!!;
		String t = check::c3_test(f, sanitize: "address");
		// without a sanitizer the same output is not rewritten
		String p = check::c3_test(f);
		support::restore_c3c();   // before any assert: a failed assert skips the defer, and the fake would stay for every later test
		assert(has(t, "did not run") && has(t, "ulimit") && !has(t, "AddressSanitizer failed") && !has(t, "0xdfff"), "%s", t);
		assert(!has(t, "\n\n") && t.len < 400, "%s", t);
		// the answer does not blame limits that are not set (when both hard limits are unlimited it says no limit is too small)
		assert(!(has(t, "data unlimited soft, unlimited hard; address space unlimited soft, unlimited hard") && has(t, "too small")), "%s", t);
		assert(has(p, "ReserveShadowMemoryRange") || has(p, "exit code"), "%s", p);
	$endif
}

// What was learned about one compiler is not kept for another: a test (or a user) that points C3C at a program that cannot
// say its version must not leave the real compiler without one afterwards.
fn void the_compiler_caches_follow_the_c3c_in_use() @test
{
	$if !env::WIN32:
		String real = compiler::compiler_version().copy(mem);
		defer real.free(mem);
		String real_root = compiler::stdlib_root().copy(mem);
		defer real_root.free(mem);
		Path dir = support::make_temp_dir("c3cache");
		defer (void)path::rmtree(dir);
		String fake_version;
		String fake_root;
		{
			defer support::restore_c3c();
			support::set_c3c(support::write_fake(dir, "nover.sh", "echo 'no version here'"));
			fake_version = compiler::compiler_version().copy(mem);
			fake_root = compiler::stdlib_root().copy(mem);
		}
		defer fake_version.free(mem);
		defer fake_root.free(mem);
		assert(fake_version == "", "a program that prints no version has none: %s", fake_version);
		assert(fake_root == "", "its library cannot be found: %s", fake_root);
		assert(compiler::compiler_version() == real, "'%s' after the fake, '%s' before", compiler::compiler_version(), real);
		assert(compiler::stdlib_root() == real_root, "'%s' after the fake, '%s' before", compiler::stdlib_root(), real_root);
	$endif
}
