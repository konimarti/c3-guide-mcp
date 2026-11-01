// Recipe: faults and optionals (faultdef, int? return, return FAULT~, if catch, try, ??, rethrow with !, !! to panic)
// expect: error: faults::NEGATIVE_INPUT
// expect: ok: 7
// expect: default: 0
import std::io;

faultdef NEGATIVE_INPUT;                  // 0.8: faultdef, not "fault Name { ... }"

fn int? check(int val)
{
	if (val < 0) return NEGATIVE_INPUT~;  // returning a fault: add ~
	return val;
}

fn int? twice(int val)
{
	int v = check(val)!;                  // ! passes the fault up to the caller
	return v * 2;
}

fn void main()
{
	int? r = check(-5);
	if (catch err = r) io::printfn("error: %s", err);

	if (try v = check(7)) io::printfn("ok: %d", v);

	io::printfn("default: %d", twice(-1) ?? 0);   // ?? gives a fallback when there is a fault
}
