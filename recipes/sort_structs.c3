// Recipe: sort structs by a field, sort strings, and list a HashMap's keys in sorted order
// Also: order by key, sort by age, compare_to, keys(), alphabetical, string compare, qsort
// expect: Bob 25
// expect: Ann 31
// expect: a b c
import std::io;
import std::sort;
import std::collections::map;

struct Person
{
	String name;
	int age;
}

fn int by_age(Person a, Person b) => a.age - b.age;
fn int by_text(String a, String b) => a.compare_to(b);     // String cannot be ordered with < >: use compare_to

fn void main()
{
	Person[2] people = { { "Ann", 31 }, { "Bob", 25 } };
	sort::quicksort(people[..], &by_age);
	foreach (p : people) io::printfn("%s %d", p.name, p.age);

	HashMap{String, int} m;
	m.init(mem);
	defer m.free();
	m.set("c", 3);
	m.set("a", 1);
	m.set("b", 2);
	String[] keys = m.keys(tmem);          // iteration order of a map is not defined: sort the keys
	sort::quicksort(keys, &by_text);
	foreach (i, k : keys) io::printf(i == 0 ? "%s" : " %s", k);
	io::printn("");
}
