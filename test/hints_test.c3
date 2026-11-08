module c3guide::test::hints_test;
import c3guide::hints;
import std::core::string;

fn void return_fault_question_mark_is_rewritten() @test
{
	hints::Rewrite r = hints::rewrite("fn int? f(int x)\n{\n\tif (x < 0) return BAD?;\n\treturn io::EOF? ;\n}");
	assert(r.count == 2 && r.code.contains("return BAD~;") && r.code.contains("return io::EOF~ ;"), "%s", r.code);
	hints::Rewrite k = hints::rewrite("fn int f(int a, int b)\n{\n\t// return X?;\n\tString s = \"return Y?;\";\n\treturn a ? b : 0;\n}");
	assert(k.count == 0 && k.code.contains("// return X?;") && k.code.contains("\"return Y?;\""), "%s", k.code);
}
