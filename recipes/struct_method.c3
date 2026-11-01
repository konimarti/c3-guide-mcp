// Recipe: struct with methods (fn Type.method), construction, interface implementation
// expect: area=12
// expect: Rect 3x4
import std::io;

struct Rect (Describe)
{
	int w, h;
}

fn int Rect.area(self) => self.w * self.h;
fn void Rect.scale(&self, int f) { self.w *= f; self.h *= f; }   // &self: modifies the original

interface Describe
{
	fn String describe();
}

fn String Rect.describe(&self) @dynamic => string::tformat("Rect %dx%d", self.w, self.h);

fn void main()
{
	Rect r = { .w = 3, .h = 4 };
	io::printfn("area=%d", r.area());

	Describe d = &r;                       // interface value from a pointer
	io::printn(d.describe());
}
