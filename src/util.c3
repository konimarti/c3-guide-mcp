module c3guide::util;
import std::core::string;

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
