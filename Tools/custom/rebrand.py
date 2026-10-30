#!/usr/bin/env python3
"""nikhil/custom: rename the app the user sees from NOOP to XYLO.

Rewrites the whole word NOOP to XYLO in text people read, and nothing else:

- string literals in Swift sources (comments and identifiers are left alone, so `NOOPWatch`,
  `NOOP_DEMO_SCREEN` and widget kinds such as `NOOPChargeComplication` keep working);
- the String Catalogs (keys and translations together, so lookups still match the Swift literals);
- the Info.plist names and permission prompts declared in project.yml.

Idempotent: run it again after merging upstream and it only touches the new mentions. A Swift line
carrying `rebrand:keep` is skipped (the "built on NOOP" credit), as are the files in SKIP_FILES.

Usage: python3 Tools/custom/rebrand.py [--check]   (--check lists what would change, writes nothing)
"""
import json
import re
import subprocess
import sys
from pathlib import Path

OLD, NEW = "NOOP", "XYLO"
WORD = re.compile(r"(?<![A-Za-z0-9_])" + OLD + r"(?![A-Za-z0-9_])")
ROOT = Path(__file__).resolve().parents[2]

SWIFT_DIRS = [
    "Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "NOOPWatch", "NOOPWatchComplications",
    "StrandTests", "Packages/StrandDesign", "Packages/StrandAnalytics",
]
# The update checker announces upstream NOOP releases, and the bug-report test reads the upstream
# GitHub issue template, so both keep the upstream name.
SKIP_FILES = {"Strand/System/UpdateAvailability.swift", "StrandTests/BugReportTemplateTests.swift"}
PLIST_KEY = re.compile(r"^\s+(CFBundleName|CFBundleDisplayName|NS\w+UsageDescription):")


def rebrand_swift(src: str) -> str:
    """Replace OLD in string-literal text only. A small Swift lexer: comments, "...", \"\"\"...\"\"\",
    raw #"..."# strings and \\( ) interpolation (whose code is scanned as code, recursively)."""
    out, i, n = [], 0, len(src)
    # Stack of contexts: ("code", paren_depth) or ("str", delimiter, hashes).
    stack = [("code", 0)]
    lit_start = None  # start index of the current run of literal text

    def flush_literal(end):
        nonlocal lit_start
        if lit_start is not None:
            out.append(WORD.sub(NEW, src[lit_start:end]))
            lit_start = None

    while i < n:
        ctx = stack[-1]
        if ctx[0] == "code":
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                out.append(src[i:j]); i = j
            elif src.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if src.startswith("/*", j): depth += 1; j += 2
                    elif src.startswith("*/", j): depth -= 1; j += 2
                    else: j += 1
                out.append(src[i:j]); i = j
            else:
                m = re.match(r'(#*)("""|")', src[i:i + 8])
                if m and (m.group(1) == "" or src[i] == "#"):
                    hashes, delim = len(m.group(1)), m.group(2)
                    out.append(m.group(0)); i += len(m.group(0))
                    stack.append(("str", delim, hashes)); lit_start = i
                elif src[i] == "(":
                    stack[-1] = ("code", ctx[1] + 1); out.append("("); i += 1
                elif src[i] == ")":
                    if ctx[1] == 0 and len(stack) > 1:
                        stack.pop(); out.append(")"); i += 1; lit_start = i  # back into the string
                    else:
                        stack[-1] = ("code", max(0, ctx[1] - 1)); out.append(")"); i += 1
                else:
                    out.append(src[i]); i += 1
        else:
            _, delim, hashes = ctx
            close = delim + "#" * hashes
            esc = "\\" + "#" * hashes
            if src.startswith(esc + "(", i):
                flush_literal(i)
                out.append(esc + "("); i += len(esc) + 1
                stack.append(("code", 0))
            elif src.startswith(esc, i) and hashes == 0:
                i += 2  # skip the escaped character; stays part of the literal run
            elif src.startswith(close, i):
                flush_literal(i)
                out.append(close); i += len(close); stack.pop()
            elif delim == '"' and src[i] == "\n":
                flush_literal(i); stack.pop()  # unterminated: bail out to code rather than run away
            else:
                i += 1
    flush_literal(n)
    return "".join(out)


def rebrand_swift_file(text: str) -> str:
    kept = {}
    lines = text.split("\n")
    for k, line in enumerate(lines):
        if "rebrand:keep" in line:
            kept[k] = line
    new = rebrand_swift(text).split("\n")
    if len(new) != len(lines):
        raise SystemExit("rebrand: lexer changed the line count, refusing to write")
    for k, line in kept.items():
        new[k] = line
    return "\n".join(new)


def rebrand_catalog(text: str, path: Path) -> str:
    new = WORD.sub(NEW, text)

    def no_dupes(pairs):
        keys = [k for k, _ in pairs]
        if len(keys) != len(set(keys)):
            raise SystemExit(f"rebrand: {path} would end up with a duplicate key")
        return dict(pairs)

    json.loads(new, object_pairs_hook=no_dupes)
    return new


def rebrand_project_yml(text: str) -> str:
    return "\n".join(WORD.sub(NEW, l) if PLIST_KEY.match(l) else l for l in text.split("\n"))


def tracked(*patterns):
    res = subprocess.run(["git", "ls-files", *patterns], cwd=ROOT, capture_output=True, text=True, check=True)
    return [p for p in res.stdout.split("\n") if p]


def main():
    check = "--check" in sys.argv
    jobs = [(p, rebrand_swift_file) for d in SWIFT_DIRS for p in tracked(f"{d}/*.swift") if p not in SKIP_FILES]
    jobs += [(p, None) for p in tracked("*.xcstrings")]
    jobs.append(("project.yml", rebrand_project_yml))
    changed = 0
    for rel, fn in jobs:
        path = ROOT / rel
        text = path.read_text(encoding="utf-8")
        new = rebrand_catalog(text, path) if fn is None else fn(text)
        if new != text:
            changed += 1
            count = len(WORD.findall(text)) - len(WORD.findall(new))
            print(f"{rel}: {count}")
            if not check:
                path.write_text(new, encoding="utf-8")
    print(f"{'would change' if check else 'changed'} {changed} files")


if __name__ == "__main__":
    main()
