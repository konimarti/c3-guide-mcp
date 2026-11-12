#!/usr/bin/env python3
"""Build data/corpus.dat from a c3c install (dev-time only; the binary needs no Python).

usage: scripts/gen_corpus.py [C3_DIR] [all.md]
  C3_DIR  c3c install dir (MANUAL.md, releasenotes.md, lib/std, c3c); default: dir of `c3c` on PATH
  all.md  optional copy of https://c3-lang.org/all.md (curl -o all.md https://c3-lang.org/all.md);
          only sections absent from MANUAL.md are kept. The committed snapshot was built WITH it.

Record format (parsed by src/corpus.c3): records end with \\x1e, fields split by \\x1f:
  kind, title, body, loc
kinds: meta | doc | change | list | recipe | fn | macro | method | mmethod | type | var
"""
import json, os, re, shutil, subprocess, sys

CAP = 1800
RS, US = "\x1e", "\x1f"

def c3_dir():
    if len(sys.argv) > 1:
        d = sys.argv[1]
    else:
        exe = shutil.which("c3c")
        if not exe:
            sys.exit("give the c3c install dir as first argument (or put c3c on PATH)")
        d = os.path.dirname(os.path.realpath(exe))
    for f in ("c3c", "MANUAL.md", "releasenotes.md", "lib/std"):
        if not os.path.exists(os.path.join(d, f)):
            sys.exit(f"{d} is not a c3c install dir: {f} is missing")
    return d

def chunk_md(text, min_level=1):
    """Split at headings (ignoring fenced code), keep breadcrumb titles, cap size at blank lines."""
    out, stack, buf, fence = [], {}, [], False
    def flush():
        body = "\n".join(buf).strip()
        buf.clear()
        if not body or len(body.splitlines()) < 2 and len(body) < 40:
            return
        path = " > ".join(stack[k] for k in sorted(stack))
        cur, infence = "", False
        for para in re.split(r"\n\n", body):
            if cur and len(cur) + len(para) > CAP and not infence:
                out.append((path, cur.strip())); cur = ""
            cur += para + "\n\n"
            infence = (cur.count("```") % 2) == 1
        if cur.strip():
            out.append((path, cur.strip()))
    for line in text.splitlines():
        if line.startswith("```"):
            fence = not fence
        m = None if fence else re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            flush()
            lvl = len(m.group(1))
            stack[lvl] = m.group(2).strip()
            for k in [k for k in stack if k > lvl]:
                del stack[k]
        buf.append(line)
    flush()
    return out

CWD = os.getcwd()

# Statements of the manual that the compiler contradicts, checked by hand. (old text, corrected text). A correction
# whose old text is gone (the manual was fixed) is reported, then dropped from this list.
ERRATA = [
    # `$assignable` was removed in 0.8.0 ("Removed deprecated `$assignable`" in the release notes); the 0.8.6 manual still uses it
    # in two examples. `$defined(Type v = expr)` asks the same thing (checked with c3c 0.8.6: both examples compile and run).
    ('@require $assignable(resource.open(), void*)',
     '@require $defined(void* p = resource.open())   // [c3-guide-mcp: the manual wrote $assignable(resource.open(), void*); $assignable was removed in 0.8.0]'),
    ('@require $assignable(1, TypeB) && $assignable(1, TypeC)\n @require $assignable((TypeB)1, TypeA) && $assignable((TypeC)1, TypeA)',
     '@require $defined(TypeB b = 1) && $defined(TypeC c = 1)\n @require $defined(TypeA a1 = (TypeB)1) && $defined(TypeA a2 = (TypeC)1)\n// [c3-guide-mcp: the manual wrote $assignable(x, T); $assignable was removed in 0.8.0, $defined(T v = x) asks the same]'),
    ('@require "$assignable((TypeB)1, TypeA) && $assignable((TypeC)1, TypeA)" violated.',
     '@require "$defined(TypeA a1 = (TypeB)1) && $defined(TypeA a2 = (TypeC)1)" violated.'),
]

def apply_errata(text):
    for old, new in ERRATA:
        if old in text:
            text = text.replace(old, new)
        else:
            print("errata no longer needed (the manual changed): " + old[:60])
    return text

def clean(s):
    # docgen evaluates $$PROJECT_PATH and similar: keep the machine's paths out of the snapshot
    return s.replace(RS, " ").replace(US, " ").replace(CWD, "<project>")

def rec(kind, title, body, loc=""):
    return RS.join([US.join(clean(x) for x in (kind, title, body, loc)), ""])

def sig(it):
    kind, name = it["kind"], it["name"]
    gp = it.get("generic_parameters")
    gen = "{%s}" % ", ".join(g if isinstance(g, str) else g.get("name", "?") for g in gp) if gp else ""
    ret = (it.get("return_type") or {}).get("name", "")
    ps = []
    for m in it.get("members") or []:
        t = (m.get("type") or {}).get("name", "")
        s = (t + " " + m.get("name", "")).strip()
        if m.get("is_ref"): s = "&" + s
        if "default_value" in m: s += " = " + str(m["default_value"])
        ps.append(s)
    if kind in ("function", "method"):
        return f"fn {ret} {name}{gen}({', '.join(ps)})".replace("  ", " ")
    if kind in ("macro", "macro_method"):
        return f"macro {ret} {name}{gen}({', '.join(ps)})".replace("  ", " ")
    if kind in ("constant", "variable"):
        v = f" = {it['value']}" if "value" in it else ""
        return f"{(it.get('type') or {}).get('name', '')} {name}{v}".strip()
    base = (it.get("base_type") or {}).get("uid", "")
    if base and kind in ("distinct type", "alias"):
        return f"{kind} {name}{gen} = {'inline ' if it.get('is_inline') else ''}{base}"
    ifs = ", ".join(i.get("name", "?") for i in it.get("interfaces") or [])
    mem = ", ".join(ps)
    return f"{kind} {name}{gen}" + (f" ({ifs})" if ifs else "") + (f" {{ {mem} }}" if mem and len(mem) < 300 else "")

def symbols(c3):
    # run inside the install dir: docgen prints locations relative to the working directory. --stdlib names that same
    # library: without it c3c also finds a lib/ next to the install dir (a c3/ folder inside an unpacked release, 0.8.6) and loads the std twice
    r = subprocess.run([os.path.join(c3, "c3c"), "--stdlib", "lib/std", "docgen", "lib/std", "--json"],
                       capture_output=True, text=True, check=True, cwd=c3)
    dg = json.loads(r.stdout.replace(os.path.realpath(c3), "<project>"))
    root = os.path.join(c3, "")
    out = []
    for mod in dg["modules"].values():
        for k, code in (("functions", "fn"), ("methods", "method"), ("macros", "macro"),
                        ("macro_methods", "mmethod"), ("types", "type"), ("variables", "var")):
            for it in mod.get(k, []):
                if it.get("visibility") in ("private", "local"):
                    continue
                d = it.get("docs") or {}
                doc = " ".join((d.get("text") or "").split())
                for p in d.get("params") or []:
                    desc = " ".join((p.get("description") or "").split())
                    if desc:
                        doc += f" @param {p.get('name')}: {desc}"
                if d.get("return"):
                    doc += " @return " + " ".join(d["return"].split())
                if d.get("deprecated"):
                    doc += " DEPRECATED: " + d["deprecated"]
                body = sig(it) + (("\n" + doc.strip()) if doc.strip() else "")
                out.append(rec(code, it["uid"], body, it.get("file", "").replace(root, "")))
    return out

ALIAS = re.compile(r"(?:<\*(?P<doc>.*?)\*>\s*)?^alias\s+(?P<name>\w+)\s*@builtin\s*=\s*(?P<to>[^;]+);", re.S | re.M)

def aliases(c3):
    """`mem`, `tmem`, `I` ...: docgen skips aliases, but they are what models use in almost every program."""
    out, root = [], os.path.join(c3, "")
    for dirpath, _, files in sorted(os.walk(os.path.join(c3, "lib", "std"))):
        for fn in sorted(files):
            if not fn.endswith(".c3"):
                continue
            path = os.path.join(dirpath, fn)
            text = open(path, encoding="utf-8").read()
            mod = re.search(r"^module\s+([\w:]+)", text, re.M)
            for m in ALIAS.finditer(text):
                doc = " ".join((m.group("doc") or "").split())
                line = text.count("\n", 0, m.start("name")) + 1
                to = " ".join(m.group("to").split())
                body = f"alias {m.group('name')} = {to}" + (("\n" + doc) if doc else "")
                out.append(rec("var", f"{mod.group(1)}::{m.group('name')}", body, f"{path.replace(root, '')}:{line}"))
    return out

def recipes():
    """recipes/*.c3: small programs that compile and print what their `// expect:` lines say (test/recipes_test.c3 runs them)."""
    out, here = [], os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "recipes")
    for fn in sorted(os.listdir(here)):
        if not fn.endswith(".c3"):
            continue
        lines = open(os.path.join(here, fn), encoding="utf-8").read().split("\n")
        title = lines[0].removeprefix("// Recipe: ")
        code = "\n".join(l for l in lines[1:] if not l.startswith(("// expect:", "// stdin:"))).strip()
        out.append(rec("recipe", "Recipe: " + title, code, "recipes/" + fn))
    return out

def lists(c3):
    out = []
    for flag in ("attributes", "builtins", "keywords", "type-properties", "operators", "precedence"):
        r = subprocess.run([os.path.join(c3, "c3c"), f"--list-{flag}"], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            out.append(rec("list", flag, r.stdout.strip()))
    return out

def main():
    c3 = c3_dir()
    ver = subprocess.run([os.path.join(c3, "c3c"), "--version"], capture_output=True, text=True).stdout
    ver = re.search(r"Version:\s*(\S+)", ver).group(1)
    recs = []
    manual = chunk_md(apply_errata(open(os.path.join(c3, "MANUAL.md"), encoding="utf-8").read()))
    seen = {p for p, _ in manual}
    manual = [(p, b) for p, b in manual if not p.lower().endswith("table of contents") and "Table of Contents" not in p]
    recs += [rec("doc", p, b) for p, b in manual]
    if len(sys.argv) > 2:
        extra = [(p, b) for p, b in chunk_md(open(sys.argv[2], encoding="utf-8").read()) if p not in seen and "Table of Contents" not in p]
        recs += [rec("doc", p + " [all.md]", b) for p, b in extra]
    recs += [rec("change", p, b) for p, b in chunk_md(open(os.path.join(c3, "releasenotes.md"), encoding="utf-8").read())]
    recs += lists(c3)
    recs += recipes()
    # sorted by name: the server reading the same library live (src/live.c3) sorts the same way, so ranking ties
    # (broken by position) come out the same whichever way the docs were produced
    syms = sorted(symbols(c3) + aliases(c3), key=lambda r: r.split(US)[1].encode())
    recs += syms
    meta = rec("meta", "c3c", ver, f"records={len(recs)}")
    out = os.environ.get("C3GUIDE_OUT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "corpus.dat")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(meta + "".join(recs))
    print(f"c3c {ver}: {len(recs)} records ({len(syms)} symbols), {out} = {os.path.getsize(out)/1024:.0f} KB")

main()
