// Recipe: parse JSON text into a tree and read values from it (std::encoding::json); reading a missing key gives an error
// Also: json, parse json, JSON object, get_int, get_string, dynamic tree, decode
// expect: name=Ada
// expect: age=36
// expect: no such key
import std::io;
import std::encoding::json;
import std::collections::object;

fn void main()
{
	Object*? doc = json::parse(tmem, `{"name": "Ada", "age": 36}`);
	if (catch doc)
	{
		io::printn("bad json");
		return;
	}
	String? name = doc.get_string("name");
	if (try n = name) io::printfn("name=%s", n);
	int? age = doc.get_int("age");
	if (try a = age) io::printfn("age=%d", a);
	int? nope = doc.get_int("nope");
	if (catch nope) io::printn("no such key");
}
