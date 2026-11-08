module c3guide::util;
import std::core::string, std::os::env;

extern fn CInt chmod(ZString, uint) @if(!env::WIN32);

fn bool is_c3_file(String name) => name.ends_with(".c3") || name.ends_with(".c3i");

// Owner-only (0o600) or executable (0o755) mode for a file this server created. No-op on Windows.
fn void set_mode(String file, uint mode)
{
	$if !env::WIN32:
		chmod(file.zstr_tcopy(), mode);
	$endif
}

// Largest n <= max such that s[:n] does not end inside a UTF-8 sequence (a cut in the middle of a
// character would make the whole JSON-RPC line invalid for the client).
fn sz utf8_boundary(String s, sz max)
{
	if (s.len <= max) return s.len;
	sz n = max;
	while (n > 0 && (s[n] & 0xC0) == 0x80) n--;   // s[n] is a continuation byte: step back to its lead byte
	return n;
}

// Like clip, but keeps the last `tail` bytes (from a line start): test output ends with the summary line.
fn String clip_keep_tail(String s, sz max, sz tail)
{
	if (s.len <= max) return s;
	String head = s[:utf8_boundary(s, max - tail)];
	sz cut = head.rindex_of("\n") ?? head.len;
	String end = s[s.len - tail..];
	sz nl = end.index_of("\n") ?? 0;   // start at a line, never in the middle of one (or of a character)
	return string::tformat("%s\n[...cut]\n%s", head[:cut], end[nl + 1..]);
}

// Cut `s` below `max` bytes at a line boundary (else at a character boundary), marking the cut.
fn String clip(String s, sz max)
{
	if (s.len <= max) return s;
	String head = s[:utf8_boundary(s, max)];
	sz cut = head.rindex_of("\n") ?? head.len;
	return string::tformat("%s\n[...cut]", head[:cut]);
}

// The length of `s` without a trailing UTF-8 sequence that was cut in the middle.
fn sz cut_utf8(String s)
{
	sz j = s.len;
	int back = 0;
	while (j > 0 && back < 3 && (s[j - 1] & 0xC0) == 0x80) { j--; back++; }
	if (j == 0) return s.len;
	char lead = s[j - 1];
	sz need = lead >= 0xF0 ? 4 : (lead >= 0xE0 ? 3 : (lead >= 0xC0 ? 2 : 1));
	return s.len - (j - 1) < need ? j - 1 : s.len;
}

fn bool ident_char(char c) @inline => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';

// `s` with every byte that is not part of well-formed UTF-8 replaced by '?'. Source files can hold anything, and
// a reply with an invalid byte makes the whole JSON-RPC line unreadable for the client.
fn String sanitize_utf8(String s)
{
	DString out = dstring::temp();
	sz i = 0;
	while (i < s.len)
	{
		char c = s[i];
		sz need = c < 0x80 ? 0 : (c >= 0xC2 && c <= 0xDF ? 1 : (c >= 0xE0 && c <= 0xEF ? 2 : (c >= 0xF0 && c <= 0xF4 ? 3 : -1)));
		bool ok = need >= 0 && i + need < s.len;   // the whole sequence is inside the string
		if (need > 0 && ok)
		{
			for (sz k = 1; k <= need; k++) if ((s[i + k] & 0xC0) != 0x80) ok = false;
			if (ok && c == 0xE0 && s[i + 1] < 0xA0) ok = false;    // overlong
			if (ok && c == 0xED && s[i + 1] >= 0xA0) ok = false;   // surrogate
			if (ok && c == 0xF0 && s[i + 1] < 0x90) ok = false;    // overlong
			if (ok && c == 0xF4 && s[i + 1] >= 0x90) ok = false;   // beyond U+10FFFF
		}
		if (need < 0 || !ok)
		{
			out.append_char('?');
			i++;
			continue;
		}
		out.append(s[i:need + 1]);
		i += need + 1;
	}
	return out.str_view();
}

extern fn char* realpath(char*, char*) @if(!env::WIN32);

// The path as the system sees it (links and `..` resolved); "" when it does not exist.
fn String canonical(String p)
{
	$if env::WIN32:
		return p;
	$else
		char[4096] buf;
		char* r = realpath(p.zstr_tcopy(), &buf);
		if (!r) return "";
		return string::tformat("%s", (ZString)&buf);
	$endif
}

// True when `target` is `root` or below it (both canonical).
fn bool inside(String root, String target) => target == root || (target.len > root.len && target.starts_with(root) && target[root.len] == '/');
