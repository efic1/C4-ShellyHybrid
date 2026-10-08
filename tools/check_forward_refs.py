#!/usr/bin/env python3
"""Gate: a function that calls a `local` defined LATER in the file compiles cleanly and fails at runtime.

Lua resolves such a name as a GLOBAL (nil). We list every global lookup with `luac -l` and flag names that the same
file also declares as a local. Learned the hard way in efic1/C4-UnifiProtect (docs/DEVELOPMENT_NOTES.md).
"""
import re, subprocess, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Names that are legitimately global in a Control4 driver, or Lua built-ins, even if a module also has a local of that name.
ALLOWED = set()


def check(path):
    src = open(path, encoding="utf-8").read()
    locals_ = set(re.findall(r"\blocal\s+function\s+([A-Za-z_]\w*)", src))
    for m in re.finditer(r"^\s*local\s+([A-Za-z_][\w\s,]*?)\s*(?:=|$)", src, re.M):
        for n in m.group(1).split(","):
            n = n.strip()
            if re.fullmatch(r"[A-Za-z_]\w*", n):
                locals_.add(n)
    out = subprocess.run(["luac5.1", "-l", "-p", path], capture_output=True, text=True)
    if out.returncode != 0:
        return [f"{path}: does not compile: {out.stderr.strip()}"]
    problems = []
    for line in out.stdout.splitlines():
        m = re.search(r"\b(GETGLOBAL|SETGLOBAL)\b.*;\s*([A-Za-z_]\w*)\s*$", line)
        if m and m.group(2) in locals_ and m.group(2) not in ALLOWED:
            ln = re.search(r"\[(\d+)\]", line)
            problems.append(f"{os.path.relpath(path, ROOT)}:{ln.group(1) if ln else '?'}: '{m.group(2)}' is used as a global but declared local in this file (defined later?)")
    return problems


def main():
    files = sorted(glob.glob(os.path.join(ROOT, "src", "**", "*.lua"), recursive=True))
    bad = []
    for f in files:
        bad += check(f)
    for b in sorted(set(bad)):
        print(b)
    print("forward-reference gate: %s (%d files)" % ("FAILED" if bad else "ok", len(files)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
