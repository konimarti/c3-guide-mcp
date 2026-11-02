// Recipe: number of enum values: Status::len, enum element count, size an array by enum, loop over all enum values, enum names
// Also: enum length, count of constants, from_ordinal, Enum::names, EnumMap
// expect: count=3
// expect: 3 1
// expect: ACTIVE
// expect: IDLE
// expect: ACTIVE
// expect: DONE
import std::io;

enum Status { IDLE, ACTIVE, DONE }

fn void main()
{
	io::printfn("count=%d", Status::len);          // type properties use ::, not . (Status.len does not exist)
	int[Status::len] per_status;                   // a compile-time constant: usable as an array size
	per_status[Status.ACTIVE.ordinal] += 1;
	io::printfn("%d %d", per_status.len, per_status[1]);
	io::printn(Status::from_ordinal(1));           // back from the ordinal
	foreach (name : Status::names) io::printn(name);
}
