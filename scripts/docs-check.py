#!/usr/bin/env python3
"""Verify the docs only reference things that exist.

The docs are the handoff artifact: OMES runs this project from them, with
nobody to ask when a command turns out not to exist. Several couplings
between the docs and the code were introduced at once — make targets, the
naming convention, scripts, terraform outputs — and every one of them is the
kind that rots silently, because nothing fails until a person follows the
instructions.

Only commands are checked, not prose. A `make` inside a sentence is English.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = sorted(ROOT.glob("docs/*.md")) + [ROOT / "README.md"]

makefile = (ROOT / "Makefile").read_text()
targets = set(re.findall(r"^([a-z][a-z0-9-]*):", makefile, re.M))
outputs = set(re.findall(r'output "([a-z_]+)"',
                         (ROOT / "infra/terraform/envs/dev/outputs.tf").read_text()))

problems = []

for doc in DOCS:
    text = doc.read_text()
    lines = text.splitlines()

    # `make X` only where it is a command: at the start of a line inside a
    # fenced block, or inside an inline code span.
    in_fence = False
    cmds = []
    for i, line in enumerate(lines, 1):
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            m = re.match(r"^\s*make\s+([a-z][a-z0-9-]*)(?![\w*-])", line)
            if m:
                cmds.append((i, m.group(1)))
        # The trailing (?![\w*-]) is a token boundary, not just a "no star":
        # without it the greedy [a-z0-9-]* simply backtracks off the hyphen
        # and `make tf-*` reports as a missing target named "tf".
        for m in re.finditer(r"`make\s+([a-z][a-z0-9-]*)(?![\w*-])", line):
            cmds.append((i, m.group(1)))

    for line_no, t in cmds:
        if t not in targets:
            problems.append(f"{doc.relative_to(ROOT)}:{line_no}: `make {t}` — no such target")

    for m in re.finditer(r"NAME=([a-z_]+)", text):
        if m.group(1) not in outputs:
            line_no = text[: m.start()].count("\n") + 1
            problems.append(f"{doc.relative_to(ROOT)}:{line_no}: NAME={m.group(1)} — no such terraform output")

    for m in re.finditer(r"(?:scripts|infra/bootstrap)/[\w.-]+\.(?:sh|py)", text):
        if not (ROOT / m.group(0)).exists():
            line_no = text[: m.start()].count("\n") + 1
            problems.append(f"{doc.relative_to(ROOT)}:{line_no}: {m.group(0)} — file does not exist")

    # A hardcoded project id in a raw gcloud/bq command is how you aim a
    # command at the wrong environment. The docs are run once per
    # environment, so a literal has to be hand-substituted on the second
    # pass, in every command, with production on the other end. Use
    # $PROJECT, which `make env-exports` sets from that environment's tfvars.
    for m in re.finditer(r"--project(?:_id)?[= ]owc-[a-z-]+", text):
        line_no = text[: m.start()].count("\n") + 1
        problems.append(
            f"{doc.relative_to(ROOT)}:{line_no}: {m.group(0)} — hardcoded project; use $PROJECT"
        )

    # $PROJECT used before anything sets it. Made exactly this mistake:
    # substituting the literals put $PROJECT into the FIRST commands in the
    # document while the block that sets it sat further down. An undefined
    # shell variable does not error, so the reader gets "--project " with
    # nothing after it, or a name like "gcs--raw-1".
    #
    # Only inside fenced blocks: prose that mentions $PROJECT is explaining
    # it, not running it.
    first_use = first_set = None
    in_fence = False
    for i, line in enumerate(lines, 1):
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if first_set is None and re.search(r"env-exports|export\s+(?:PROJECT|PREFIX)=", line):
            first_set = i
        if in_fence and first_use is None and re.search(r"\$(?:PROJECT|PREFIX)\b", line):
            first_use = i
    if first_use is not None and (first_set is None or first_set > first_use):
        problems.append(
            f"{doc.relative_to(ROOT)}:{first_use}: $PROJECT/$PREFIX used in a command "
            f"before anything sets it — add or move the `make env-exports` block above it"
        )

    # The old names must not creep back via a copy-paste from an older doc.
    for m in re.finditer(r"\bokw-[a-z]+", text):
        line_no = text[: m.start()].count("\n") + 1
        problems.append(f"{doc.relative_to(ROOT)}:{line_no}: {m.group(0)} — pre-rename resource name")

if problems:
    print("Docs reference things that do not exist:\n")
    for p in problems:
        print(f"  {p}")
    print(f"\n{len(problems)} problem(s).")
    sys.exit(1)

print(f">> docs-check OK: {len(DOCS)} docs, all make targets, outputs and scripts resolve")
