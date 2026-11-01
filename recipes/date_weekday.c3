// Recipe: calendar date: build a DateTime, weekday name, format a date, parts (year, month, day)
// Also: std::time, datetime, day of week, calendar, Date, strftime, timestamp, now, TzDateTime
// expect: 2026-11-01 is SUNDAY
// expect: year=2026 month=11 day=1
import std::io;
import std::time;
import std::time::datetime;

fn void main()
{
	DateTime d;
	d.set(2026, NOVEMBER, 1);               // there is no Date type: DateTime with year, month, day
	d = datetime::from_time(d.to_time());   // round trip through Time fills in weekday and yearday
	io::printfn("2026-11-01 is %s", d.weekday);     // an enum prints its constant name
	io::printfn("year=%d month=%d day=%d", d.year, (int)d.month + 1, d.day);
	// now: DateTime now = datetime::now();
}
