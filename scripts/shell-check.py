#!/usr/bin/env python3
"""Catch shell mistakes that only fail on someone else's machine.

Two kinds so far, both of which shipped: a helper called but never
defined, and a backslash continuation inside a single-quoted Makefile
recipe. Neither is caught by `bash -n`, and the second is worse — it
works on GNU make 3.81 and fails on 4.3, so the author cannot
reproduce what the operator is seeing.

`bash -n` does not catch this: an undefined function is a runtime error, and
these scripts are mostly branches that a syntax check never executes. So a
whole section of `make iam-check` printed

    infra/gcloud/02-verify-admin.sh: line 171: warn: command not found

seven times, losing the explanation it was carrying, and still exited 0 —
because the failing command was the reporter itself.

Indirect calls are the real trap. `report=$(... && echo bad || echo warn)`
followed by `$report "..."` hides both names from every grep you would
normally run, which is exactly how `warn` survived undefined.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = sorted(ROOT.glob("scripts/*.sh")) + sorted(ROOT.glob("infra/gcloud/*.sh"))

# Anything on PATH or built in. We only care about helpers the script itself
# is supposed to define.
KNOWN_EXTERNAL = re.compile(r"^(gcloud|curl|python3|printf|echo|grep|sed|awk|tar|mktemp|"
                            r"unzip|sha256sum|shasum|chmod|mkdir|rm|cat|tr|sort|head|tail|"
                            r"wc|cut|test|source|exit|return|local|declare|eval|read|set|"
                            r"trap|command|uname|git|make|diff|xargs|date|dirname|basename)$")

problems = []
for f in SCRIPTS:
    text = f.read_text()
    defined = set(re.findall(r"^\s*([a-z_][a-z0-9_]*)\s*\(\)\s*\{", text, re.M))

    # Names selected at runtime and then invoked as "$var ...".
    for m in re.finditer(r"(\w+)=\$\(.*?echo\s+(\w+).*?echo\s+(\w+).*?\)", text):
        var, a, b = m.group(1), m.group(2), m.group(3)
        if not re.search(rf"\$\{{?{var}\}}?\s", text):
            continue
        for name in (a, b):
            if name not in defined and not KNOWN_EXTERNAL.match(name):
                line = text[: m.start()].count("\n") + 1
                problems.append(
                    f"{f.relative_to(ROOT)}:{line}: ${var} can resolve to `{name}`, "
                    f"which is never defined in this file"
                )

    # Direct calls to something that looks like a local reporter helper.
    for m in re.finditer(r"^\s*([a-z_][a-z0-9_]*)\s+\"", text, re.M):
        name = m.group(1)
        if name in defined or KNOWN_EXTERNAL.match(name):
            continue
        # Only flag names this family of scripts uses as reporters.
        if name in {"pass", "bad", "err", "warn", "note", "say", "head2", "ok"}:
            line = text[: m.start()].count("\n") + 1
            problems.append(
                f"{f.relative_to(ROOT)}:{line}: calls `{name}`, which is never defined here"
            )

# Makefile recipes: a backslash continuation inside a single-quoted string.
#
# The quotes make the backslash literal to the shell, and GNU make 3.81 and
# 4.3 disagree about whether they strip it first. So this works on macOS and
# fails in Cloud Shell, which is the worst way for it to fail: the author
# cannot reproduce it.
makefile = ROOT / "Makefile"
if makefile.exists():
    for i, line in enumerate(makefile.read_text().splitlines(), 1):
        if not line.startswith("\t") or not line.rstrip().endswith("\\"):
            continue
        if line.rstrip()[:-1].count("'") % 2 == 1:
            problems.append(
                f"Makefile:{i}: backslash continuation inside a single-quoted "
                f"string — put it on one line (breaks on GNU make 4.3)"
            )

if problems:
    print("Shell problems:\n")
    for p in sorted(set(problems)):
        print(f"  {p}")
    print(f"\n{len(set(problems))} problem(s).")
    sys.exit(1)

print(f">> shell-check OK: {len(SCRIPTS)} scripts + Makefile recipes")
