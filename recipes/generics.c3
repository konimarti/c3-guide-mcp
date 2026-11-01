// Recipe: generic function and generic struct (module with {Type}, instantiate with {int})
// expect: 7
// expect: max=9
// expect: box=abc
module recipe_generics <Type>;
import std::io;

struct Box
{
	Type value;
}

fn Type Box.get(self) => self.value;


module recipe_max <Type>;      // every function of a module is instantiated: keep max away from Box{String}

fn Type max(Type a, Type b) => a > b ? a : b;

module recipe_generics;
import std::io, recipe_max;

alias IntBox = recipe_generics::Box{int};
alias StrBox = recipe_generics::Box{String};

fn void main()
{
	IntBox a = { 7 };
	io::printn(a.get());
	io::printfn("max=%d", recipe_max::max{int}(4, 9));
	StrBox b = { "abc" };
	io::printfn("box=%s", b.get());
}
