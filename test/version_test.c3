module c3guide::test::version;
import c3guide, std::encoding::json, std::collections::object, std::io::file;

// project.json is the one place the version is written: the server reports exactly that (env::PROJECT_VERSION).
fn void the_reported_version_is_the_one_in_project_json() @test
{
	char[] data = file::load_temp("project.json")!!;
	Object* manifest = json::parse(tmem, (String)data)!!;
	String want = manifest.get_string("version")!!;
	assert(want.len > 0, "project.json has no version");
	assert(c3guide::VERSION == want, "the server reports '%s', project.json says '%s'", c3guide::VERSION, want);
}
