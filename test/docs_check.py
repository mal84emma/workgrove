"""Check tracked Layout files, required citations, and local documentation links."""

import argparse
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
import re
import shlex
import string
import subprocess
from urllib.parse import unquote, urlsplit


def diagnostic(path, line, message):
    return f"{path}:{line}: {message}"


def blank(text):
    """Mask examples and comments without changing source line numbers."""
    return re.sub(r"[^\n]", " ", text)


def inline_prose(text):
    return re.sub(r"(`+).*?\1", lambda match: blank(match[0]), text)


class IndentedCode:
    """Distinguish code indentation from list and paragraph continuations."""

    def __init__(self):
        self.list_indents = []
        self.paragraph = False
        self.active = False

    def mask(self, line):
        if not line.strip():
            self.paragraph = False
            return line
        expanded = line.expandtabs(4)
        indent = len(expanded) - len(expanded.lstrip(" "))
        while self.list_indents and indent < self.list_indents[-1]:
            self.list_indents.pop()
        base = self.list_indents[-1] if self.list_indents else 0
        if indent >= base + 4 and (self.active or not self.paragraph):
            self.active = True
            return blank(line)
        self.active = False
        item = re.match(r"^ *(?:[-+*]|[0-9]+[.)]) +", expanded)
        if item:
            self.list_indents.append(item.end())
        self.observe(expanded)
        return line

    def observe(self, line):
        self.paragraph = not re.match(r"^ *(?:#{1,6} |<!--|(?:[-*_] *){3,}$)", line)


def mask_escaped_brackets(text):
    # Consume escaped backslashes in pairs before considering an escaped bracket.
    return re.sub(r"\\[\\\[]", lambda match: blank(match[0]), text)


def heading_text(title):
    """Use displayed text while preserving punctuation inside code and escapes."""
    literals = []

    def protect(match):
        literals.append(match[2] if match[1] else match[3])
        return f"\x00{len(literals) - 1}\x00"

    pattern = r"(`+)(.*?)\1|\\([" + re.escape(string.punctuation) + r"])"
    title = re.sub(pattern, protect, title)
    title = re.sub(r"!?\[([^]]+)\]\([^)]*\)", r"\1", title)
    title = re.sub(r"<[^>]+>", "", title)
    previous = None
    while title != previous:
        previous = title
        title = re.sub(r"(?<!\w)(_+)(?=\S)(.+?)(?<=\S)\1(?!\w)", r"\2", title)
    title = unescape(title)
    return re.sub(r"\x00([0-9]+)\x00", lambda match: literals[int(match[1])], title)


def unique_slug(title, emitted):
    title = heading_text(title).lower()
    slug = "".join(c for c in title if c.isalnum() or c in "_- ").replace(" ", "-")
    candidate = slug
    suffix = 0
    while candidate in emitted:
        suffix += 1
        candidate = f"{slug}-{suffix}"
    emitted.add(candidate)
    return candidate


def prose(text):
    lines = []
    fence = None
    in_comment = False
    indented = IndentedCode()
    for line in text.splitlines(keepends=True):
        if fence:
            marker = re.match(r"^\s*([`~]+)\s*$", line)
            if marker and set(marker[1]) == {fence[0]} and len(marker[1]) >= len(fence):
                fence = None
                indented.paragraph = False
            lines.append(blank(line))
            continue
        if not in_comment:
            line = indented.mask(line)
        visible = ""
        remaining = line
        while remaining:
            if in_comment:
                end = remaining.find("-->")
                if end < 0:
                    visible += blank(remaining)
                    break
                visible += blank(remaining[:end + 3])
                remaining = remaining[end + 3:]
                in_comment = False
            else:
                start = inline_prose(remaining).find("<!--")
                if start < 0:
                    visible += remaining
                    break
                visible += remaining[:start]
                remaining = remaining[start:]
                in_comment = True
        marker = re.match(r"^\s*(`{3,}|~{3,})", visible)
        if marker:
            fence = marker[1]
            visible = blank(visible)
        elif visible.strip():
            indented.observe(visible)
        lines.append(visible)
    return "".join(lines)


class HtmlTargets(HTMLParser):
    """Collect HTML links and explicit anchors with their source lines."""

    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.links = []
        self.anchors = set()
        self.feed(text)
        self.close()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            self.anchors.add(attrs["id"])
        if tag == "a" and attrs.get("name"):
            self.anchors.add(attrs["name"])
        for attribute in ("href", "src") if tag == "img" else ("href",):
            if attrs.get(attribute):
                self.links.append((self.getpos()[0], attrs[attribute]))

    handle_startendtag = handle_starttag


def anchors(path):
    text = prose(path.read_text())
    found = HtmlTargets(inline_prose(text)).anchors
    emitted = set()
    lines = text.splitlines()
    for index, line in enumerate(lines):
        heading = re.match(r"^ {0,3}#{1,6}\s+(.+?)(?:\s+#+)?$", line)
        if heading:
            title = heading[1]
        elif index + 1 < len(lines) and line.strip() and re.match(r"^ {0,3}(?:=+|-+)\s*$", lines[index + 1]):
            title = line.strip()
        else:
            continue
        found.add(unique_slug(title, emitted))
    return found


def document_links(path):
    text = prose(path.read_text())
    text = inline_prose(text)
    links = HtmlTargets(text).links
    text = mask_escaped_brackets(text)
    references = {}
    pattern = r"^ {0,3}\[([^]\n]+)\]:[ \t]*<?(\S+?)>?(?:[ \t]+.*)?$"
    for match in re.finditer(pattern, text, re.M):
        references[match[1].lower()] = match[2]
        links.append((text.count("\n", 0, match.start()) + 1, match[2]))
    pattern = r"!?\[[^]]*\]\(\s*(<[^>]+>|(?:[^\s()]|\([^()]*\))+)"
    for match in re.finditer(pattern, text):
        links.append((text.count("\n", 0, match.start()) + 1, match[1].strip("<>")))
    for match in re.finditer(r"\[([^]]+)\](?:\[([^]]*)\])?", text):
        label = (match[2] or match[1]).lower()
        if label in references:
            links.append((text.count("\n", 0, match.start()) + 1, references[label]))
    return links


def check_layout(root):
    errors = []
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
        errors.append(diagnostic("README.md", 1, f"Layout missing tracked file: {path}"))
    for path in sorted(listed - tracked):
        errors.append(diagnostic("README.md", 1, f"Layout lists untracked file: {path}"))
    return errors


def check_citations(root):
    errors = []
    guide = root / "docs/documentation-style.md"
    section = guide.read_text().split("### Check a change\n", 1)[1]
    commands = re.findall(r"^\s+(grep .+)$", section, re.M)
    if not commands:
        errors.append(diagnostic("docs/documentation-style.md", 1, "no citation checks found"))
    for command in commands:
        args = shlex.split(command)
        if args[:2] != ["grep", "-n"] or len(args) != 4:
            errors.append(diagnostic("docs/documentation-style.md", 1, f"unsupported citation check: {command}"))
            continue
        result = subprocess.run(args, cwd=root, capture_output=True, text=True)
        if result.returncode or not result.stdout.strip():
            errors.append(diagnostic(args[3], 1, f"citation check failed: {command}"))
    return errors


def check_links(root):
    errors = []
    paths = [root / "README.md", root / "AGENTS.md", root / "home/.claude/AGENTS.md"]
    paths += sorted((root / "docs").rglob("*.md"))
    paths += sorted((root / "home/.agents/skills").rglob("*.md"))
    cache = {}
    for path in paths:
        for number, destination in document_links(path):
            url = urlsplit(destination)
            if url.scheme or url.netloc:
                continue
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            relative = path.relative_to(root)
            if not target.exists():
                errors.append(diagnostic(relative, number, f"dead link: {destination}"))
            elif url.fragment:
                if target not in cache:
                    cache[target] = anchors(target)
                if unquote(url.fragment) not in cache[target]:
                    errors.append(diagnostic(relative, number, f"missing anchor: {destination}"))
    return errors


def main():
    checks = {"layout": check_layout, "citations": check_citations, "links": check_links}
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("check", choices=checks)
    args = parser.parse_args()
    errors = checks[args.check](args.root)
    for error in errors:
        print(error)
    return bool(errors)


if __name__ == "__main__":
    raise SystemExit(main())
