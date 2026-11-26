#!/usr/bin/env python3
"""Regenerate _digested/_meta/git-tracking/coverage-map.md from doc citations.

Usage:
    python3 _digested/_meta/git-tracking/scripts/build-coverage.py [--check]

--check  exit 1 if the on-disk map differs from a fresh generation (CI-friendly).

Semantics:
    full  at least one doc cites the file AND gives a line anchor
    cite  cited without a line anchor
    gap   no _digested doc cites the file

Primary doc: the doc whose frontmatter `owns` names the file (READMEs lose to
named docs), tie-broken by anchor count, then path. Falls back to the most
anchored citing doc.
"""

from __future__ import annotations

import collections
import os
import re
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
MAP_PATH = os.path.join(REPO, "_digested/_meta/git-tracking/coverage-map.md")


def src_files() -> list[str]:
    out = subprocess.run(
        ["git", "-C", REPO, "ls-tree", "-r", "--name-only", "HEAD", "--", "src"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [f for f in out if f.endswith((".ts", ".tsx"))]


def docs() -> list[str]:
    found: list[str] = []
    for root, _, files in os.walk(os.path.join(REPO, "_digested")):
        if "/_meta" in root:
            continue
        for name in files:
            if name.endswith(".md"):
                found.append(os.path.join(root, name))
    return sorted(found)


def main() -> int:
    os.chdir(REPO)
    files = src_files()
    file_set = set(files)
    ref = re.compile(r"(src/[A-Za-z0-9_./@\-]+)(?::(\d+))?")

    refs: dict[str, set[str]] = collections.defaultdict(set)
    anchored: dict[str, set[str]] = collections.defaultdict(set)
    owners: dict[str, set[str]] = collections.defaultdict(set)
    anchor_counts: collections.Counter = collections.Counter()

    for doc in docs():
        text = open(doc, encoding="utf-8").read()
        fm = text.split("---")[1] if text.startswith("---") else ""
        owns_match = re.search(r'^owns:\s*"?(.*?)"?\s*$', fm, re.M)
        owns = owns_match.group(1) if owns_match else ""
        for path in file_set:
            if path in owns:
                owners[path].add(doc)
        for match in ref.finditer(text):
            path = match.group(1).rstrip(".,;:")
            if path not in file_set:
                continue
            refs[path].add(doc)
            if match.group(2):
                anchored[path].add(doc)
                anchor_counts[(doc, path)] += 1

    def short(doc: str) -> str:
        return os.path.relpath(doc, os.path.join(REPO, "_digested"))

    def zone(path: str) -> str:
        return "/".join(path.split("/")[:2])

    by_zone: dict[str, list[str]] = collections.defaultdict(list)
    for path in files:
        by_zone[zone(path)].append(path)

    body: list[str] = [
        "| 覆盖度 | 含义 |",
        "|--------|------|",
        "| **full** | 至少一篇文档引用该文件**并带行号锚** |",
        "| **cite** | 被引用但只提到文件名/符号，无行号 |",
        "| **gap** | 无任何 `_digested` 文档引用 |",
        "",
    ]
    totals: collections.Counter = collections.Counter()
    for z in sorted(by_zone):
        body += [
            f"### `{z}/`",
            "",
            "| 源文件 | 覆盖度 | 主责/首引文档 | 引用数 |",
            "|--------|--------|--------------|--------|",
        ]
        for path in sorted(by_zone[z]):
            if path in anchored:
                mark = "full"
                totals["full"] += 1
            elif path in refs:
                mark = "cite"
                totals["cite"] += 1
            else:
                mark = "gap"
                totals["gap"] += 1
            candidates = [d for d in owners.get(path, ()) if not d.endswith("README.md")]
            if not candidates:
                candidates = list(owners.get(path, ()))
            candidates = sorted(candidates, key=lambda d: (-anchor_counts[(d, path)], d))
            if not candidates and refs.get(path):
                candidates = sorted(refs[path], key=lambda d: (-anchor_counts[(d, path)], d))
            primary = short(candidates[0]) if candidates else "—"
            body.append(f"| `{path}` | {mark} | {primary} | {len(refs.get(path, ()))} |")
        body.append("")

    body.append(
        f"**统计**：full {totals['full']} / cite {totals['cite']} / gap {totals['gap']}，"
        f"合计 {sum(totals.values())}。"
    )
    gaps = [p for p in files if p not in refs]
    if gaps:
        body += ["", "## gap 清单（无文档引用）", ""]
        body += [f"- `{p}`" for p in gaps]

    fresh = "\n".join(body) + "\n"
    if "--check" in sys.argv:
        current = open(MAP_PATH, encoding="utf-8").read()
        tail = current.split("## 覆盖度语义", 1)[-1]
        # compare only the generated tail, ignoring the hand-written preamble
        ok = fresh.strip() in current or fresh.strip() == tail.strip()
        print("coverage map is current" if ok else "coverage map is STALE")
        return 0 if ok else 1

    print(fresh, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
