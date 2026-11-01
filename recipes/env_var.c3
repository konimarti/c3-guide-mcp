// Recipe: read an environment variable (env::tget_var, get_var, set_var)
// expect: RECIPE_X=42
// expect: RECIPE_Y is not set
import std::io;
import std::os::env;

fn void main()
{
	env::set_var("RECIPE_X", "42");
	String? x = env::tget_var("RECIPE_X");      // temp allocator; get_var(allocator, name) for your own
	if (try x) io::printfn("RECIPE_X=%s", x);

	String? y = env::tget_var("RECIPE_Y");
	if (catch y) io::printn("RECIPE_Y is not set");
}
