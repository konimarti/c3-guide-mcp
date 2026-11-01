// Recipe: loops: foreach with index, foreach over a slice of an array, for, while, break and continue (there is no range in foreach)
// Also: range, for each, 0..n, iterate, enumerate, index, while, for loop
// expect: 0:a 1:b
// expect: 1 2 3
// expect: 0 1 2
// expect: 20 30
import std::io;

fn void main()
{
	String[] xs = { "a", "b" };
	foreach (i, x : xs) io::printf(i == 0 ? "%d:%s" : " %d:%s", i, x);
	io::printn("");

	for (int i = 1; i < 4; i++) io::printf(i == 1 ? "%d" : " %d", i);   // counting: use for
	io::printn("");

	int n;
	while (n < 10)
	{
		if (n == 3) break;
		io::printf(n == 0 ? "%d" : " %d", n);
		n++;
	}
	io::printn("");

	int[4] a = { 10, 20, 30, 40 };
	foreach (v : a[1..2]) io::printf(v == 20 ? "%d" : " %d", v);       // slice a[1..2] includes index 2
	io::printn("");
}
