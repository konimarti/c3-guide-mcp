module c3guide::compat;
import mcp, std::core::string, std::io, std::collections::object, std::collections::list, std::encoding::json;

// The argument names and tool names of earlier releases (0.5/0.6: c3_symbol name, c3_examples symbol, c3_outline file, ...)
// are still in clients' habits and in task files written for them. They are handled here, where the arguments are read, and
// are not in the published schemas:
//   - `name` and `symbol` are `query`, and `file` is `path` (for a tool that takes a `path` and has no `file` of its own);
//     when the real name is given as well, it wins and the alias is dropped;
//   - an argument the tool does not take is answered with the arguments it does take, and nothing is run;
//   - a call to a tool of the old set is forwarded to the tool that replaced it, with a note in front of the answer.
// Everything else goes to the library's handler unchanged.

const MAX_LINE = 4 * 1024 * 1024;

// Serve on stdin/stdout like `Server.serve_stdio`, with `handle` below in front of the library's.
fn void serve_stdio(mcp::Server* s)
{
	while (true)
	{
		bool eof = false;
		@pool()
		{
			String? line = io::treadline(io::stdin(), MAX_LINE);
			if (catch err = line)
			{
				if (err != io::EOF) io::eprintfn("c3-guide-mcp: stdin error: %s", err.description);
				eof = true;
			}
			else if (line.len > 0)
			{
				String response = handle(s, tmem, line);
				if (response.len > 0)
				{
					io::printn(response);
					(void)io::stdout().flush();
				}
			}
		};
		if (eof) break;
	}
}

// The target of an argument name that is not one of the tool's: "" when it is not an alias of anything.
fn String alias_of(mcp::Tool* t, String key)
{
	if ((key == "name" || key == "symbol" || key == "topic") && takes(t, "query") && !takes(t, key)) return "query";
	if (key == "file" && takes(t, "path") && !takes(t, "file")) return "path";
	return "";
}

fn bool takes(mcp::Tool* t, String key)
{
	if (!t.schema_obj) return false;
	Object*? props = t.schema_obj.get("properties");
	if (catch props) return false;
	return props.is_map() && props.has_key(key);
}

// "query (string), path (string), ..." from the tool's own schema.
fn String parameters_of(mcp::Tool* t)
{
	DString out = dstring::temp();
	if (!t.schema_obj) return "";
	Object*? props = t.schema_obj.get("properties");
	if (catch props) return "";
	if (!props.is_map()) return "";
	props.@each_entry(; String key, Object* p)
	{
		if (out.len() > 0) out.append(", ");
		String? type = p.get_string("type");
		out.appendf("%s (%s)", key, type ?? "any");
	};
	return out.str_view();
}

fn String tool_text(Allocator a, String id, String text)
	=> string::format(a, `{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":%s}],"isError":false}}`, id, json::marshal(a, text));

fn String call_message(Allocator a, String id, String name, String arguments)
	=> string::format(a, `{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":%s,"arguments":{%s}}}`, id, json::marshal(a, name), arguments);

// `"key":value` appended to a JSON object body.
fn void add_pair(Allocator a, DString* body, String key, String value_json)
{
	if (body.len() > 0) body.append(",");
	body.appendf("%s:%s", json::marshal(a, key), value_json);
}

// The first of `names` that args holds as a string, else "".
fn String first_string(Object* args, String[] names)
{
	if (!args) return "";
	foreach (n : names)
	{
		String? v = args.get_string(n);
		if (try v) return v;
	}
	return "";
}

// A call to a tool of the 0.5/0.6 set: the replacement and its arguments, or "" for a name that was never ours.
fn String forward_legacy(Allocator a, String id, String old, Object* args, String* note)
{
	String tool;
	String scope = "";
	String query = "";
	String path = "";
	String code = "";
	switch (old)
	{
		case "c3_symbol":
			tool = "c3_lookup";
			query = first_string(args, { "query", "name", "symbol" });
			path = first_string(args, { "path" });
		case "c3_examples":
			tool = "c3_lookup";
			query = first_string(args, { "query", "symbol", "name" });
		case "c3_outline":
			tool = "c3_lookup";
			path = first_string(args, { "path", "file" });
			query = first_string(args, { "query", "match", "name" });
		case "c3_syntax":
			tool = "c3_search";
			scope = "syntax";
			query = first_string(args, { "query", "topic", "list", "name" });
		case "c3_changes":
			tool = "c3_search";
			scope = "changes";
			query = first_string(args, { "query", "topic", "name", "symbol" });
		case "c3_fix":
			tool = "c3_check";
			code = first_string(args, { "code" });
		default:
			return "";
	}
	DString body = dstring::temp();
	if (query.len > 0) add_pair(a, &body, "query", json::marshal(a, query));
	if (path.len > 0) add_pair(a, &body, "path", json::marshal(a, path));
	if (code.len > 0) add_pair(a, &body, "code", json::marshal(a, code));
	if (scope.len > 0) add_pair(a, &body, "scope", json::marshal(a, scope));
	*note = string::format(a, "(%s is called %s%s in this version; forwarded. Use %s from now on.)\n", old, tool, scope.len > 0 ? string::format(a, " with scope=%s", scope) : "", tool);
	return call_message(a, id, tool, body.str_view());
}

// `note` in front of the text of a tool result (the library's reply has the fixed shape {"content":[{"type":"text","text":"...).
fn String with_note(Allocator a, String response, String note)
{
	String marker = `"text":"`;
	sz? at = response.index_of(marker);
	if (catch at) return response;
	String quoted = json::marshal(a, note);
	String escaped = quoted[1:quoted.len - 2];
	return string::format(a, "%s%s%s", response[:at + marker.len], escaped, response[at + marker.len..]);
}

// One request line to one response line (what `Server.handle` is), with the argument names and tool names above.
fn String handle(mcp::Server* s, Allocator a, String line)
{
	Object*? req = json::parse(a, line);
	if (catch req) return s.handle(a, line);
	if (!req.is_map()) return s.handle(a, line);
	String? method = req.get_string("method");
	if (catch method) return s.handle(a, line);
	if (method != "tools/call" || !req.has_key("id")) return s.handle(a, line);
	Object*? params = req.get("params");
	if (catch params) return s.handle(a, line);
	if (!params.is_map()) return s.handle(a, line);
	String? name = params.get_string("name");
	if (catch name) return s.handle(a, line);
	Object* args = null;
	if (try ao = params.get("arguments"))
	{
		if (ao.is_map()) { args = ao; }
		else if (!ao.is_null()) { return s.handle(a, line); }   // not an object: the library says so
	}
	String id = "null";
	Object*? idobj = req.get("id");
	if (try idobj) id = json::marshal(a, idobj);

	mcp::Tool* t = s.find_tool(name);
	if (!t)
	{
		if (!args) return s.handle(a, line);
		String note;
		String forwarded = forward_legacy(a, id, name, args, &note);
		if (forwarded.len == 0) return s.handle(a, line);
		return with_note(a, s.handle(a, forwarded), note);
	}
	if (!args) return s.handle(a, line);

	DString body = dstring::temp();
	DString unknown = dstring::temp();
	DString given = dstring::temp();   // the names already written, as |name|
	bool changed = false;
	args.@each_entry(; String key, Object* value)
	{
		String to = key;
		if (!takes(t, key))
		{
			String target = alias_of(t, key);
			if (target.len == 0)
			{
				if (unknown.len() > 0) unknown.append(", ");
				unknown.appendf("'%s'", clip_name(key));
				to = "";
			}
			else
			{
				changed = true;
				to = target;
				// the real name wins when both are given, and `name` when there are two
				if (args.has_key(target) || ((key == "symbol" || key == "topic") && args.has_key("name")) || given.str_view().contains(string::tformat("|%s|", target))) to = "";
			}
		}
		if (to.len > 0)
		{
			add_pair(a, &body, to, json::marshal(a, value));
			given.appendf("|%s|", to);
		}
	};
	if (unknown.len() > 0)
	{
		String text = string::format(a, "%s does not take %s. It takes: %s.", name, unknown.str_view(), parameters_of(t));
		return tool_text(a, id, text);
	}
	if (!changed) return s.handle(a, line);
	return s.handle(a, call_message(a, id, name, body.str_view()));
}

fn String clip_name(String s) => s.len > 40 ? s[:40] : s;
