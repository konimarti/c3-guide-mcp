module c3guide::test::doctor_paths;
import c3guide::doctor;

// Where each client keeps its files, on every platform. The platform and the
// environment are arguments, so the Windows and macOS branches run here too.

fn void claude_dir_follows_its_variable_then_the_home() @test
{
	assert(doctor::client_dir(CLAUDE, LINUX, "/h", "", "") == "/h/.claude");
	assert(doctor::client_dir(CLAUDE, LINUX, "/h", "", "/moved") == "/moved");
	assert(doctor::client_dir(CODEX, MACOS, "/Users/u", "", "/cx") == "/cx");
	assert(doctor::client_dir(CODEX, MACOS, "/Users/u", "", "") == "/Users/u/.codex");
	assert(doctor::client_dir(CLAUDE, LINUX, "", "", "") == "");   // no home, no guess
}

fn void windows_uses_userprofile_and_appdata_with_backslashes() @test
{
	assert(doctor::home_of(WINDOWS, "", "C:\\Users\\Ann", "D:", "\\x") == "C:\\Users\\Ann");
	assert(doctor::home_of(WINDOWS, "", "", "D:", "\\Users\\Bob") == "D:\\Users\\Bob");
	assert(doctor::home_of(LINUX, "/h", "C:\\ignored", "", "") == "/h");
	assert(doctor::client_dir(CODEX, WINDOWS, "C:\\Users\\Ann", "", "") == "C:\\Users\\Ann\\.codex");
	assert(doctor::client_dir(DESKTOP, WINDOWS, "C:\\Users\\Ann", "C:\\Users\\Ann\\AppData\\Roaming", "") == "C:\\Users\\Ann\\AppData\\Roaming\\Claude");
	assert(doctor::client_dir(DESKTOP, WINDOWS, "C:\\Users\\Ann", "", "") == "C:\\Users\\Ann\\AppData\\Roaming\\Claude");   // APPDATA unset
	assert(doctor::client_dir(VSCODE, WINDOWS, "C:\\u", "E:\\Roam", "") == "E:\\Roam\\Code\\User");
	assert(doctor::client_dir(ANTIGRAVITY, WINDOWS, "C:\\u", "", "") == "C:\\u\\.gemini\\config");
}

fn void desktop_and_vscode_folders_per_platform() @test
{
	assert(doctor::client_dir(DESKTOP, MACOS, "/Users/u", "", "") == "/Users/u/Library/Application Support/Claude");
	assert(doctor::client_dir(DESKTOP, LINUX, "/home/u", "", "") == "/home/u/.config/Claude");
	assert(doctor::client_dir(VSCODE, MACOS, "/Users/u", "", "") == "/Users/u/Library/Application Support/Code/User");
	assert(doctor::client_dir(VSCODE, LINUX, "/home/u", "", "") == "/home/u/.config/Code/User");
	assert(doctor::client_dir(CURSOR, LINUX, "/home/u", "", "") == "/home/u/.cursor");
}

fn void claude_code_keeps_its_servers_beside_the_folder_unless_moved() @test
{
	assert(doctor::config_path(CLAUDE, LINUX, "/h/.claude", "/h", false) == "/h/.claude.json");
	assert(doctor::config_path(CLAUDE, LINUX, "/moved", "/h", true) == "/moved/.claude.json");
	assert(doctor::config_path(CODEX, LINUX, "/h/.codex", "/h", false) == "/h/.codex/config.toml");
	assert(doctor::config_path(CLAUDE, WINDOWS, "C:\\h\\.claude", "C:\\h", false) == "C:\\h\\.claude.json");
}

fn void a_server_is_present_when_the_file_names_it() @test
{
	assert(doctor::mentions_server("{\"mcpServers\":{\"c3-guide\":{}}}"));
	assert(doctor::mentions_server("[mcp_servers.c3-guide]\ncommand = \"x\""));
	assert(!doctor::mentions_server("{\"projects\":{\"/src/c3-guide-mcp\":{}}}"));
}

fn void rules_mention_the_tools_when_they_name_one() @test
{
	assert(doctor::mentions_tools("Use c3_lookup for every name"));
	assert(doctor::mentions_tools("run c3_check"));
	assert(!doctor::mentions_tools("my own notes"));
}
