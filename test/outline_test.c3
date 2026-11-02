module c3guide::test::outline;
import c3guide::outline, c3guide::test::support;

const String SAMPLE = `module demo::shapes;
import std::io;

<* Area of a circle. @require r >= 0 *>
fn double circle_area(double r) => 3.14159 * r * r;

struct Point { int x; int y; }
enum Color : int { RED, GREEN }
faultdef BAD_INPUT;
macro @twice(#e) { return #e * 2; }
fn int Point.sum(&self) => self.x + self.y;
const int LIMIT = 10;
alias Pt = Point;
fn void main() { int local = 1; io::printn(local); }
`;

fn void lists_top_level_declarations_with_lines() @test
{
	String o = outline::outline_source(SAMPLE);
	assert(o.contains("5    fn double circle_area(double r)"), "line of the declaration, not of its doc comment: %s", o);
	assert(o.contains("-- Area of a circle."), "doc comment: %s", o);
	assert(o.contains("fn int Point.sum(&self)"), "method keeps its receiver: %s", o);
	assert(o.contains("struct Point") && o.contains("enum Color : int") && o.contains("faultdef BAD_INPUT"), "%s", o);
	assert(o.contains("macro @twice(#e)") && o.contains("const int LIMIT") && o.contains("alias Pt = Point"), "%s", o);
	assert(!o.contains("local"), "locals are not top-level: %s", o);
	String g = outline::outline_source("module m <Key, Value>;\nfn int f() => 1;\n");
	assert(g.contains("module m <Key, Value>") && g.contains("fn int f()") && !g.contains("=>"), "%s", g);
	assert(!o.contains("import"), "imports are not listed: %s", o);
}

fn void outlines_a_project_and_a_file() @test
{
	String own = outline::c3_outline("src");
	assert(own.contains("check.c3") && own.contains("fn String c3_check("), "%s", own);
	assert(own.contains("more files") || own.contains("tools.c3"), "the cap is announced, not silent: %s", own);
	assert(!own.contains("vendor"), "%s", own);
	String one = outline::c3_outline("src/outline.c3");
	assert(one.contains("fn String c3_outline("), "%s", one);
	String small = outline::c3_outline("src/util.c3");
	assert(small.contains("fn String clip("), "%s", small);
	assert(outline::c3_outline("nope.txt").contains("must be"));
	assert(outline::c3_outline("src").len <= 6 * 1024 + 128, "capped");
}
