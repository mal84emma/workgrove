#!/usr/bin/env bash
# Check the README tree, required citations, and local documentation links.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
# shellcheck source=test/lib.sh
source "$REPO/test/lib.sh"

check_docs() {
  local mode=$1 output status=0
  output=$(python3 - "$REPO" "$mode" <<'PY'
import pathlib
import re
import shlex
import subprocess
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
errors = []


def report(path, line, message):
    errors.append(f"{path}:{line}: {message}")


def prose(text):
    # Fenced examples contain paths and Markdown that are not document links.
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            token = marker[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            lines.append("")
        else:
            lines.append(line if fence is None else "")
    return lines


def anchors(path):
    found = set()
    counts = {}
    for line in prose(path.read_text()):
        heading = re.match(r"^ {0,3}#{1,6}\s+(.+?)(?:\s+#+)?$", line)
        if not heading:
            continue
        title = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", heading[1])
        title = re.sub(r"<[^>]+>", "", title).lower()
        slug = "".join(c for c in title if c.isalnum() or c in "_- ").replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        found.add(slug + (f"-{count}" if count else ""))
    return found


if mode == "layout":
    readme = (root / "README.md").read_text()
    section = readme.split("## Layout\n", 1)[1].split("\n## ", 1)[0]
    tree = section.split("```", 2)[1].splitlines()
    stack = []
    listed = set()
    for line in tree:
        entry = re.match(r"^((?:│   |    )*)(?:├── |└── )(\S+)", line)
        if not entry:
            continue
        depth = len(entry[1]) // 4
        name = entry[2]
        stack = stack[:depth]
        path = "/".join(stack + [name.rstrip("/")])
        if name.endswith("/"):
            stack.append(name.rstrip("/"))
        else:
            listed.add(path)
    tracked = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")) - {""}
    for path in sorted(tracked - listed):
        report("README.md", 1, f"Layout missing tracked file: {path}")
    for path in sorted(listed - tracked):
        report("README.md", 1, f"Layout lists untracked file: {path}")
elif mode == "citations":
    guide = root / "docs/documentation-style.md"
    section = guide.read_text().split("### Check a change\n", 1)[1]
    commands = re.findall(r"^\s+(grep .+)$", section, re.M)
    if not commands:
        report("docs/documentation-style.md", 1, "no citation checks found")
    for command in commands:
        args = shlex.split(command)
        if args[:2] != ["grep", "-n"] or len(args) != 4:
            report("docs/documentation-style.md", 1, f"unsupported citation check: {command}")
            continue
        result = subprocess.run(args, cwd=root, capture_output=True, text=True)
        if result.returncode or not result.stdout.strip():
            report(args[3], 1, f"citation check failed: {command}")
elif mode == "links":
    paths = [root / "README.md", root / "AGENTS.md", root / "home/.claude/AGENTS.md"]
    paths += sorted((root / "docs").rglob("*.md"))
    paths += sorted((root / "home/.agents/skills").rglob("*.md"))
    cache = {}
    for path in paths:
        lines = prose(path.read_text())
        # Preserve newlines so diagnostics retain the source line numbers.
        text = "\n".join(lines)
        text = re.sub(r"(`+).*?\1", lambda match: " " * len(match[0]), text)
        references = {}
        links = []
        for definition in re.finditer(r"^ {0,3}\[([^]\n]+)\]:[ \t]*<?(\S+?)>?(?:[ \t]+.*)?$", text, re.M):
            references[definition[1].lower()] = definition[2]
            links.append((definition.start(), definition[2]))
        pattern = r"!?\[[^]]*\]\(\s*(<[^>]+>|(?:[^\s()]|\([^()]*\))+)"
        for match in re.finditer(pattern, text):
            links.append((match.start(), match[1]))
        for match in re.finditer(r"\[([^]]+)\](?:\[([^]]*)\])?", text):
            label = (match[2] or match[1]).lower()
            if label in references:
                links.append((match.start(), references[label]))
        for offset, destination in links:
            number = text.count("\n", 0, offset) + 1
            destination = destination.strip("<>")
            url = urllib.parse.urlsplit(destination)
            if url.scheme or url.netloc:
                continue
            target = (path.parent / urllib.parse.unquote(url.path)).resolve() if url.path else path
            relative = path.relative_to(root)
            if not target.exists():
                report(relative, number, f"dead link: {destination}")
            elif url.fragment:
                if target not in cache:
                    cache[target] = anchors(target)
                if urllib.parse.unquote(url.fragment) not in cache[target]:
                    report(relative, number, f"missing anchor: {destination}")

else:
    raise SystemExit(f"unknown check: {mode}")

print("\n".join(errors), end="\n" if errors else "")
raise SystemExit(bool(errors))
PY
) || status=$?
  if ((status == 0)); then pass; else fail "$mode checks (exit $status): $output"; fi
}

scenario_layout() {
  begin_scenario 'README Layout matches tracked files' || return 0
  check_docs layout
  end_scenario
}
scenario_citations() {
  begin_scenario 'documentation guide citation checks' || return 0
  check_docs citations
  end_scenario
}
scenario_links() {
  begin_scenario 'relative documentation links and anchors resolve' || return 0
  check_docs links
  end_scenario
}
scenario_layout
scenario_citations
scenario_links
lib_summary
