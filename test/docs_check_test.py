"""Exercise documentation checks in disposable repository fixtures."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import docs_check


class DocsCheckTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="docs-check-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for path in ("README.md", "AGENTS.md", "home/.claude/AGENTS.md"):
            self.write(path, "")
        self.write("docs/target.md", "# Target\n")

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        return target

    def links(self, text):
        self.write("README.md", text)
        return docs_check.check_links(self.root)

    def git(self, *args):
        env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        subprocess.run(["git", *args], cwd=self.root, env=env, check=True, capture_output=True)

    def test_valid_relative_links_and_encoded_anchors(self):
        self.assertEqual([], self.links("[go](docs/target.md#target)\n[local](#heading)\n# Heading\n"))
        self.write("docs/a file.md", "# Heading\n")
        self.assertEqual([], self.links("[go](docs/a%20file.md#%68eading)\n"))

    def test_dead_relative_link_reports_source_line(self):
        self.assertEqual(["README.md:2: dead link: docs/missing.md"], self.links("Text.\n[go](docs/missing.md)\n"))

    def test_dead_anchor(self):
        self.assertEqual(["README.md:1: missing anchor: #missing"], self.links("[go](#missing)\n"))

    def test_multiline_and_reference_links(self):
        errors = self.links("[multi\nline](missing.md)\n[go][target]\n[target]: docs/target.md#target\n")
        self.assertEqual(["README.md:1: dead link: missing.md"], errors)
        self.assertTrue(any("dead link: missing.md" in error for error in self.links("[go][bad]\n[bad]: missing.md\n")))

    def test_comments_are_hidden_and_preserve_line_numbers(self):
        text = "<!-- [draft](missing.md)\n<a href='also-missing.md'>draft</a>\n-->\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:4: dead link: visible-missing.md"], self.links(text))

    def test_fenced_and_inline_examples_are_hidden(self):
        text = "```md\n[example](missing.md)\n<!--\n```\n`[example](missing.md)`\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:6: dead link: visible-missing.md"], self.links(text))

    def test_inline_comment_openers_do_not_hide_live_links(self):
        text = "Use `<!--` to start a comment.\n[go](missing.md)\n"
        self.assertEqual(["README.md:2: dead link: missing.md"], self.links(text))

    def test_code_examples_do_not_define_html_anchors(self):
        text = '[go](#hidden)\n`<a id="hidden"></a>`\n'
        self.assertEqual(["README.md:1: missing anchor: #hidden"], self.links(text))

    def test_setext_and_atx_heading_anchors(self):
        text = "[one](#first) [two](#second) [three](#third)\n\nFirst\n=====\n\nSecond\n------\n\n## Third\n"
        self.assertEqual([], self.links(text))

    def test_explicit_html_anchors(self):
        text = '[id](#stable) [name](#legacy) [section](#section)\n<a id="stable"></a>\n<a name="legacy"></a>\n<section id="section"></section>\n'
        self.assertEqual([], self.links(text))
        self.assertEqual(["README.md:2: missing anchor: #hidden"], self.links('<!-- <a id="hidden"></a> -->\n[go](#hidden)\n'))

    def test_html_links_use_destination_checks(self):
        self.assertEqual([], self.links('<a href="docs/target.md#target">go</a>\n'))
        self.assertEqual(["README.md:1: dead link: missing.md"], self.links('<a href="missing.md">go</a>\n'))
        self.assertEqual(["README.md:1: missing anchor: docs/target.md#missing"], self.links('<a href="docs/target.md#missing">go</a>\n'))

    def test_external_links_are_skipped(self):
        self.assertEqual([], self.links('[web](https://example.com/missing#missing)\n<a href="mailto:test@example.com">mail</a>\n'))

    def test_layout_requires_every_tracked_file(self):
        self.write("README.md", "## Layout\n\n```\nrepo/\n├── README.md\n```\n")
        self.git("init", "-q")
        self.git("add", "README.md")
        self.assertEqual([], docs_check.check_layout(self.root))
        self.write("new.txt", "")
        self.git("add", "new.txt")
        self.assertEqual(["README.md:1: Layout missing tracked file: new.txt"], docs_check.check_layout(self.root))

    def test_layout_rejects_nonexistent_entry(self):
        self.write("README.md", "## Layout\n\n```\nrepo/\n├── README.md\n└── missing.md\n```\n")
        self.git("init", "-q")
        self.git("add", "README.md")
        self.assertEqual(["README.md:1: Layout lists untracked file: missing.md"], docs_check.check_layout(self.root))

    def test_citation_checks_require_matching_output(self):
        self.write("docs/documentation-style.md", "### Check a change\n\n   grep -n '^# Required$' README.md\n")
        self.write("README.md", "# Required\n")
        self.assertEqual([], docs_check.check_citations(self.root))
        self.write("README.md", "# Changed\n")
        self.assertEqual(1, len(docs_check.check_citations(self.root)))

    def test_citation_checks_reject_unsupported_commands(self):
        self.write("docs/documentation-style.md", "### Check a change\n\n   grep -n pattern README.md ; touch unwanted\n")
        self.assertIn("unsupported citation check", docs_check.check_citations(self.root)[0])
        self.assertFalse((self.root / "unwanted").exists())


if __name__ == "__main__":
    unittest.main()
