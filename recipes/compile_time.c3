// Recipe: compile-time checks: $defined (does it compile, and the replacement of the removed $assignable: $defined(int v = x)), $embed("file") ?? default for a file that may be missing, $feat, $if, $switch
// Also: compile time if, conditional compilation, $Typeof, $assignable, is assignable, implements, can compile, optional embed, embed fallback, feature flag, platform, $case
// expect: 1 true false
// expect: embed default: none
// expect: integer
// expect: text
// expect: other
// expect: posix
import std::io;

// $defined: true when the expression compiles; nothing is reported when it does not
macro has_len(x) => $defined(x.len);

// `$assignable(x, int)` was removed in 0.8: ask whether the declaration compiles
macro fits_int(x) => $defined(int v = x);

// a file that may not exist: an optional on the left side and `??` with the fallback
const char[] DEFAULT_DATA = "none";
const char[] DATA = $embed("no_such_file.txt") ?? DEFAULT_DATA;

// $switch on a type picks the code at compile time; only the chosen branch is compiled
macro describe(x)
{
	$switch $Typeof(x):
		$case int:
			return "integer";
		$case String:
			return "text";
		$default:
			return "other";
	$endswitch
}

fn void main()
{
	int[3] a;
	io::printfn("%d %s %s", $defined(a.len) ? 1 : 0, fits_int(2) ? "true" : "false", fits_int("two") ? "true" : "false");
	io::printfn("embed default: %s", (String)DATA);
	io::printn(describe(1));
	io::printn(describe("x"));
	io::printn(describe(1.5));
	$if $feat(WIN32):
		io::printn("windows");
	$else
		io::printn("posix");
	$endif
}
