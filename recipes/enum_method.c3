// Recipe: enum with a method, enum with associated values, switch on an enum
// expect: ACTIVE is active: true
// expect: GREEN=1 name=GREEN
// expect: go
import std::io;

enum Status { IDLE, ACTIVE, DONE }

fn bool Status.is_active(self) => self == ACTIVE;

enum Light : int (String action)           // associated value per constant
{
	RED { "stop" },
	GREEN { "go" },
}

fn void main()
{
	Status s = ACTIVE;
	io::printfn("%s is active: %s", s, s.is_active());

	Light l = GREEN;
	io::printfn("GREEN=%d name=%s", l.ordinal, l);
	switch (l)
	{
		case RED: io::printn(l.action);
		case GREEN: io::printn(l.action);   // no fallthrough, no break needed
	}
}
