// Recipe: macros: @macro name, #expr (unevaluated expression), $stringify, $Typeof (a type from an expression), generic parameter, compile-time $if
// expect: 1 + 2 = 3
// expect: 5
import std::io;

macro @print_expr(#expr)
{
	io::printfn("%s = %s", $stringify(#expr), #expr);
}

macro twice(x) => x + x;                       // no # : x is evaluated once, any type

fn void main()
{
	@print_expr(1 + 2);
	io::printn(twice(2) + 1);
	$if $feat(NEVER_DEFINED):
		io::printn("not compiled");
	$endif
}
