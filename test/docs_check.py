"""Check tracked Layout files, compatibility markers, citations, and local documentation links."""

import argparse
import ast
from bisect import bisect_right
from collections import Counter
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


def inline_boundaries(text):
    """Keep code spans inside a paragraph, heading, or list item."""
    boundaries = {len(text)}
    offset = 0
    previous_depth = 0
    for line, content in zip(text.splitlines(keepends=True), container_lines(text, mask_code=True)):
        depth, prefix = blockquote_prefix(line)
        heading = re.match(r"^ {0,3}#{1,6}(?:[ \t]|$)", content)
        fence = re.match(r"^ {0,3}(?:`{3,}|~{3,})", content)
        item = re.match(r"^ *(?:[-+*]|[0-9]+[.)]) +", line[prefix:])
        comment = re.match(r"^ {0,3}<!--", content)
        underline = re.match(r"^ {0,3}(?:=+|-+)[ \t]*$", content.rstrip("\n"))
        if not content.strip() or depth != previous_depth or heading or fence or item or comment or underline:
            boundaries.add(offset)
        if heading or fence:
            boundaries.add(offset + len(line))
        offset += len(line)
        previous_depth = depth
    return sorted(boundaries)


def code_spans(text):
    """Match complete backtick runs within each paragraph."""
    runs = list(re.finditer(r"`+", text))
    boundaries = inline_boundaries(text)
    index = 0
    while index < len(runs):
        opener = runs[index]
        backslashes = len(text[:opener.start()]) - len(text[:opener.start()].rstrip("\\"))
        if backslashes % 2:
            index += 1
            continue
        closing_index = None
        boundary = boundaries[bisect_right(boundaries, opener.start())]
        for candidate in range(index + 1, len(runs)):
            closer = runs[candidate]
            if closer.start() >= boundary:
                break
            if len(closer[0]) == len(opener[0]):
                closing_index = candidate
                break
        if closing_index is None:
            index += 1
        else:
            closer = runs[closing_index]
            yield opener.start(), closer.end(), text[opener.end():closer.start()]
            index = closing_index + 1


def inline_prose(text):
    parts = []
    cursor = 0
    for start, end, _ in code_spans(text):
        parts.extend((text[cursor:start], blank(text[start:end])))
        cursor = end
    return "".join(parts) + text[cursor:]


def blockquote_prefix(line, limit=None):
    """Return the quote depth and the end of its container prefix."""
    depth = 0
    offset = 0
    while limit is None or depth < limit:
        match = re.match(r" {0,3}>[ \t]?", line[offset:])
        if not match:
            break
        depth += 1
        offset += match.end()
    return depth, offset


def container_lines(text, mask_code=False):
    """Normalize quote and list prefixes with the code masker's indentation state."""
    indented = IndentedCode()
    previous_depth = 0
    for line in text.splitlines(keepends=True):
        depth, prefix = blockquote_prefix(line)
        if depth != previous_depth:
            indented = IndentedCode()
        previous_depth = depth
        line = indented.mask(line[prefix:], hide=mask_code)
        yield indented.content(line)[1]


def markdown_value(value):
    pattern = r"\\([" + re.escape(string.punctuation) + r"])"
    return unescape(re.sub(pattern, r"\1", value))


def read_destination(text, start):
    """Read one destination without consuming its surrounding link syntax."""
    cursor = start
    angle = cursor < len(text) and text[cursor] == "<"
    if angle:
        cursor += 1
    value_start = cursor
    depth = 0
    while cursor < len(text):
        char = text[cursor]
        if char == "\\" and cursor + 1 < len(text) and text[cursor + 1] in string.punctuation:
            cursor += 2
            continue
        if angle:
            if char == ">":
                return markdown_value(text[value_start:cursor]), cursor + 1
            if char in "<\n\r":
                return None
        else:
            if char.isspace():
                break
            if char == "(":
                depth += 1
            elif char == ")":
                if depth == 0:
                    break
                depth -= 1
        cursor += 1
    if angle or depth:
        return None
    return markdown_value(text[value_start:cursor]), cursor


def skip_link_space(text, start):
    match = re.match(r"[ \t]*(?:\n[ \t]*)?", text[start:])
    return start + match.end()


def read_title(text, start):
    if start >= len(text) or text[start] not in "\"'(":
        return None
    close = ")" if text[start] == "(" else text[start]
    cursor = start + 1
    while cursor < len(text):
        if text[cursor] == "\\" and cursor + 1 < len(text):
            cursor += 2
            continue
        if text[cursor] == close:
            return cursor + 1
        if re.match(r"\n[ \t]*\n", text[cursor:]):
            return None
        cursor += 1
    return None


def inline_destination(text, start):
    if start >= len(text) or text[start] != "(":
        return None
    cursor = skip_link_space(text, start + 1)
    parsed = read_destination(text, cursor)
    if parsed is None:
        return None
    value, end = parsed
    cursor = skip_link_space(text, end)
    if cursor < len(text) and text[cursor] == ")":
        return value, cursor + 1
    if cursor == end:
        return None
    title_end = read_title(text, cursor)
    if title_end is not None:
        cursor = skip_link_space(text, title_end)
        if cursor < len(text) and text[cursor] == ")":
            return value, cursor + 1
    return None


def markdown_links(text):
    """Match balanced labels and complete inline destinations."""
    stack = []
    cursor = 0
    while cursor < len(text):
        if text[cursor] == "\\" and cursor + 1 < len(text) and text[cursor + 1] in string.punctuation:
            cursor += 2
            continue
        if text[cursor] == "[":
            stack.append(cursor)
        elif text[cursor] == "]" and stack:
            start = stack.pop()
            target = inline_destination(text, cursor + 1)
            if target is not None:
                value, cursor = target
                yield text.count("\n", 0, start) + 1, value
                continue
        cursor += 1


def reference_destinations(text):
    """Read destinations on the definition line or its continuation line."""
    references = {}
    links = []
    pattern = r"^ {0,3}\[((?:\\.|[^]\\\n])+)\]:[ \t]*(?:\n[ \t]*)?"
    for match in re.finditer(pattern, text, re.M):
        parsed = read_destination(text, match.end())
        if parsed is None or parsed[1] == match.end():
            continue
        value, end = parsed
        line_end = text.find("\n", end)
        if line_end < 0:
            line_end = len(text)
        remainder = text[end:line_end]
        if remainder.strip():
            title_end = read_title(text, skip_link_space(text, end))
            if title_end is None or text[title_end:line_end].strip():
                continue
        label = " ".join(markdown_value(match[1]).split()).casefold()
        references[label] = value
        links.append((text.count("\n", 0, match.end()) + 1, value))
    return references, links


class IndentedCode:
    """Distinguish code indentation from list and paragraph continuations."""

    def __init__(self):
        self.list_indents = []
        self.paragraph = False
        self.active = False

    def mask(self, line, hide=True):
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
            return blank(line) if hide else line
        self.active = False
        item = re.match(r"^ *(?:[-+*]|[0-9]+[.)]) +", expanded)
        if item:
            self.list_indents.append(item.end())
        self.observe(expanded)
        return line

    def content(self, line):
        expanded = line.expandtabs(4)
        base = self.list_indents[-1] if self.list_indents else 0
        indent = len(expanded) - len(expanded.lstrip(" "))
        item = re.match(r"^ *(?:[-+*]|[0-9]+[.)]) +", expanded)
        cut = base if indent >= base or (item and item.end() == base) else 0
        return expanded[:cut], expanded[cut:]

    def observe(self, line):
        self.paragraph = not re.match(r"^ *(?:#{1,6} |<!--|(?:[-*_] *){3,}$)", line)


def mask_escaped_brackets(text):
    # Consume escaped backslashes in pairs before considering an escaped bracket.
    return re.sub(r"\\[\\\[\]]", lambda match: blank(match[0]), text)


def heading_text(title):
    """Use displayed text while preserving punctuation inside code and escapes."""
    literals = []

    def protect(value):
        literals.append(value)
        return f"\x00{len(literals) - 1}\x00"

    parts = []
    cursor = 0
    for start, end, content in code_spans(title):
        parts.extend((title[cursor:start], protect(content)))
        cursor = end
    title = "".join(parts) + title[cursor:]
    pattern = r"\\([" + re.escape(string.punctuation) + r"])"
    title = re.sub(pattern, lambda match: protect(match[1]), title)
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
    quote_depth = 0
    protected_lines = inline_prose(text).splitlines(keepends=True)
    for line, protected in zip(text.splitlines(keepends=True), protected_lines):
        depth, prefix = blockquote_prefix(line, quote_depth if fence else None)
        container_prefix = line[:prefix]
        line, protected = line[prefix:], protected[prefix:]
        if depth != quote_depth:
            fence = None
            indented = IndentedCode()
        quote_depth = depth
        expanded = line.expandtabs(4)
        list_base = indented.list_indents[-1] if indented.list_indents else 0
        indent = len(expanded) - len(expanded.lstrip(" "))
        if fence and line.strip() and indent < list_base:
            fence = None
        if fence:
            _, content = indented.content(line)
            marker = re.match(r"^\s*([`~]+)\s*$", content)
            if marker and set(marker[1]) == {fence[0]} and len(marker[1]) >= len(fence):
                fence = None
                indented.paragraph = False
            lines.append(blank(container_prefix + line))
            continue
        if not in_comment:
            masked = indented.mask(line)
            if masked != line:
                protected = blank(protected)
            line = masked
        list_prefix, line = indented.content(line)
        protected = protected.expandtabs(4)[len(list_prefix):]
        container_prefix += list_prefix
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
                protected = protected[end + 3:]
                in_comment = False
            else:
                start = protected.find("<!--")
                if start < 0:
                    visible += remaining
                    break
                visible += remaining[:start]
                remaining = remaining[start:]
                protected = protected[start:]
                in_comment = True
        marker = re.match(r"^\s*(`{3,}|~{3,})", visible)
        if marker:
            fence = marker[1]
            visible = blank(visible)
        elif visible.strip():
            indented.observe(visible)
        lines.append(container_prefix + visible)
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
    lines = "".join(container_lines(text)).splitlines()
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
    text = "".join(container_lines(inline_prose(text)))
    links = HtmlTargets(text).links
    references, definitions = reference_destinations(text)
    links.extend(definitions)
    links.extend(markdown_links(text))
    reference_text = mask_escaped_brackets(text)
    for match in re.finditer(r"\[([^]]+)\](?:\[([^]]*)\])?", reference_text):
        group = 2 if match[2] else 1
        label = " ".join(markdown_value(text[match.start(group):match.end(group)]).split()).casefold()
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
    paths = [root / "README.md", root / "AGENTS.md"]
    paths += sorted((root / "home/.claude").glob("*.md"))
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


def compatibility_markers(path):
    """Identify each tracked marker by its containing function or module variable."""
    lines = path.read_text().splitlines()
    if path.suffix == ".py":
        functions = [node for node in ast.walk(ast.parse("\n".join(lines)))
                     if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]
        for index, line in enumerate(lines, 1):
            if "WT_COMPAT" in line:
                owners = [node for node in functions if node.lineno <= index <= node.end_lineno]
                yield index, max(owners, key=lambda node: node.lineno).name if owners else "<module>"
        return
    definition = re.compile(r"^([A-Za-z_][A-Za-z_0-9]*)(?:\(\)\s*[({]|=)")
    owner = "<module>"
    for index, line in enumerate(lines):
        match = definition.match(line)
        if match:
            owner = match[1]
        if "WT_COMPAT" not in line:
            continue
        following = index + 1
        while following < len(lines) and (not lines[following].strip() or lines[following].startswith("#")):
            following += 1
        match = definition.match(lines[following]) if following < len(lines) else None
        yield index + 1, match[1] if match else owner


def check_compatibility(root):
    errors = []
    inventory = "docs/vm-protocol.md"
    text = (root / inventory).read_text()
    section = text.split("## Compatibility inventory\n", 1)[-1].split("\n## ", 1)[0]
    listed = Counter(re.findall(r"^\| `([^`]+)` \| `([^`]+)` \|", section, re.M))
    actual = Counter()
    paths = subprocess.check_output(["git", "ls-files", "-z", "--", "bin", "lib", "install.sh"], cwd=root)
    for name in paths.decode().split("\0"):
        if not name:
            continue
        for line, owner in compatibility_markers(root / name):
            key = (name, owner)
            actual[key] += 1
            if actual[key] > listed[key]:
                errors.append(diagnostic(name, line, f"WT_COMPAT marker missing from inventory: {owner}"))
    for (name, owner), count in (listed - actual).items():
        errors.append(diagnostic(inventory, 1, f"inventory has {count} entry with no code marker: {name} {owner}"))
    return errors


VARIABLE_NAME = r"(?:WG|WT)_[A-Z0-9_]+"


def shell_variable_reads(text):
    """Find expansions, arithmetic names, and variable-existence tests in shell sources.

    Keep quoted payloads because remote scripts also read variables when executed.
    Ignore comments, assignment names, record labels, and heredoc delimiters.
    """
    tokens = re.compile(r"('([^']*)'|\"(?:\\.|[^\"\\])*\"|\$\{[^}]*\}|\\.)|(?<![^\s;|&()])#[^\n]*")
    source = tokens.sub(lambda match: match[0] if match[1] else blank(match[0]), text)
    expansion = re.compile(r"\$(?:\{[!#]?)?(" + VARIABLE_NAME + r")\b")
    for match in expansion.finditer(source):
        yield text.count("\n", 0, match.start(1)) + 1, match[1]
    for arithmetic in re.finditer(r"\(\((.*?)\)\)", source, re.S):
        for match in re.finditer(r"\b" + VARIABLE_NAME + r"\b", arithmetic[1]):
            yield text.count("\n", 0, arithmetic.start(1) + match.start()) + 1, match[0]
    for match in re.finditer(r"(?<!\S)-v\s+[\"']?(" + VARIABLE_NAME + r")\b", source):
        yield text.count("\n", 0, match.start(1)) + 1, match[1]


def python_variable_reads(text):
    """Read literal environment keys and Python names, excluding comments and unrelated strings."""
    tree = ast.parse(text)
    os_names = {"os"}
    environments = set()
    getters = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            os_names.update(alias.asname or alias.name for alias in node.names if alias.name == "os")
        elif isinstance(node, ast.ImportFrom) and node.module == "os":
            environments.update(alias.asname or alias.name for alias in node.names if alias.name == "environ")
            getters.update(alias.asname or alias.name for alias in node.names if alias.name == "getenv")

    def environment(node):
        return ((isinstance(node, ast.Name) and node.id in environments)
                or (isinstance(node, ast.Attribute) and node.attr == "environ"
                    and isinstance(node.value, ast.Name) and node.value.id in os_names))

    for node in ast.walk(tree):
        key = None
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and re.fullmatch(VARIABLE_NAME, node.id):
            yield node.lineno, node.id
        elif isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Load) and environment(node.value):
            key = node.slice
        elif isinstance(node, ast.Call) and node.args:
            function = node.func
            if ((isinstance(function, ast.Name) and function.id in getters)
                    or (isinstance(function, ast.Attribute) and
                        ((function.attr == "get" and environment(function.value))
                         or (function.attr == "getenv" and isinstance(function.value, ast.Name)
                             and function.value.id in os_names)))):
                key = node.args[0]
        if isinstance(key, ast.Constant) and isinstance(key.value, str) and re.fullmatch(VARIABLE_NAME, key.value):
            yield key.lineno, key.value


def check_variables(root):
    """Require each WG_* and WT_* read to have configuration or internal documentation."""
    readme = (root / "README.md").read_text()
    section = readme.split("### Environment variables\n", 1)[-1].split("\n### ", 1)[0].split("\n## ", 1)[0]
    documented = set(re.findall(r"^\| `(" + VARIABLE_NAME + r")` \|", section, re.M))
    internal = re.search(r"<!-- Internal variables begin\. -->(.*?)<!-- Internal variables end\. -->", section, re.S)
    if internal:
        documented.update(re.findall(r"`(" + VARIABLE_NAME + r")`", internal[1]))
    errors = []
    paths = subprocess.check_output(["git", "ls-files", "-z", "--", "bin", "lib"], cwd=root)
    for name in paths.decode().split("\0"):
        if not name:
            continue
        path = root / name
        text = path.read_text()
        if path.suffix == ".py":
            reads = python_variable_reads(text)
        elif path.suffix == ".sh" or re.match(r"#![^\n]*\b(?:ba|z|da|k)?sh\b", text):
            reads = shell_variable_reads(text)
        else:
            continue
        for line, variable in sorted(set(reads)):
            if variable not in documented:
                errors.append(diagnostic(name, line, f"undocumented variable read: {variable}"))
    return errors


def main():
    checks = {"layout": check_layout, "citations": check_citations, "links": check_links,
              "compatibility": check_compatibility, "variables": check_variables}
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
