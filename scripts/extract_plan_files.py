#!/usr/bin/env python3
"""Write the code blocks of an implementation plan to disk.

Usage: extract_plan_files.py PLAN.md [--task N] PATH [PATH ...]
Each block must be preceded by a line `<!-- file: PATH -->`; PATH is relative to the repo root.
With --task, only that task's section is searched (a file may appear in several tasks).
"""
import pathlib
import re
import sys

plan, args = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2:]
if args[:1] == ["--task"]:
    start = plan.index(f"### Task {args[1]}:")
    end = plan.find("\n### Task ", start + 1)
    plan, args = plan[start:end if end != -1 else None], args[2:]
wanted = set(args)
root = pathlib.Path(__file__).resolve().parent.parent
pattern = re.compile(r"<!-- file: (\S+) -->\n```[^\n]*\n(.*?)\n```\n", re.S)
found = {m.group(1): m.group(2) for m in pattern.finditer(plan)}
missing = wanted - found.keys()
if missing:
    sys.exit(f"not in plan: {sorted(missing)}")
for rel in sorted(wanted):
    target = root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(found[rel] + "\n")
    print("wrote", rel)
