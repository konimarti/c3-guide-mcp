// Recipe: sort an array or a List with a comparison function (std::sort quicksort, insertion_sort)
// Also: quicksort, insertion_sort, comparator, cmp, order by field, sort struct array, sort by key, qsort
// expect: 9 5 3 1
// expect: 1 3 5 9
import std::io;
import std::sort;

fn int desc(int a, int b) => b - a;      // negative: a comes first

fn void main()
{
	int[4] a = { 5, 1, 9, 3 };
	sort::quicksort(a[..], &desc);
	foreach (i, v : a) io::printf(i == 0 ? "%d" : " %d", v);
	io::printn("");

	// without a comparison function, the elements' own order is used
	sort::quicksort(a[..]);
	foreach (i, v : a) io::printf(i == 0 ? "%d" : " %d", v);
	io::printn("");
}
