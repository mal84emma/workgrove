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

    def compatibility_fixture(self, rows):
        self.git("init", "-q")
        self.write("docs/vm-protocol.md", "## Compatibility inventory\n\n"
                   "| File | Function | Group | Condition | Check | Removal |\n"
                   "|---|---|---|---|---|---|\n" + rows)
        self.write("lib/example.sh", "first() {\n  # WT_COMPAT: First.\n}\n"
                   "# WT_COMPAT: Second.\nsecond() { :; }\n")
        self.write("lib/example.py", "def confirm():\n    # WT_COMPAT: Python.\n    pass\n")
        self.write("bin/tool", "# WT_COMPAT: Top level.\ntrue\n")
        self.write("install.sh", "install() {\n  # WT_COMPAT: Installer.\n}\n")
        self.git("add", ".")

    def compatibility_rows(self):
        return ("| `lib/example.sh` | `first` | B | Old. | Probe. | Remove. |\n"
                "| `lib/example.sh` | `second` | B | Old. | Probe. | Remove. |\n"
                "| `lib/example.py` | `confirm` | B | Old. | Probe. | Remove. |\n"
                "| `bin/tool` | `<module>` | B | Old. | Probe. | Remove. |\n"
                "| `install.sh` | `install` | B | Old. | Probe. | Remove. |\n")

    def test_compatibility_matches_shell_python_bin_and_installer(self):
        self.compatibility_fixture(self.compatibility_rows())
        self.write("lib/untracked.py", "# WT_COMPAT: Not tracked.\n")
        self.write("test/example.sh", "# WT_COMPAT: Outside the scan.\n")
        self.git("add", "test/example.sh")
        self.assertEqual([], docs_check.check_compatibility(self.root))

    def test_compatibility_reports_missing_marker_and_stale_entry(self):
        rows = self.compatibility_rows().replace("`first`", "`removed`")
        self.compatibility_fixture(rows)
        errors = docs_check.check_compatibility(self.root)
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("lib/example.sh:2:" in error and "first" in error for error in errors))
        self.assertTrue(any("removed" in error and "no code marker" in error for error in errors))

    def test_compatibility_counts_each_marker_in_one_function(self):
        self.compatibility_fixture(self.compatibility_rows())
        self.write("lib/example.sh", "first() {\n# WT_COMPAT: One.\n# WT_COMPAT: Two.\n}\n"
                   "second() {\n# WT_COMPAT: Three.\n}\n")
        self.assertEqual(len(docs_check.check_compatibility(self.root)), 1)
        path = self.root / "docs/vm-protocol.md"
        path.write_text(path.read_text() + self.compatibility_rows().splitlines()[0] + "\n")
        self.assertEqual([], docs_check.check_compatibility(self.root))

    def variable_fixture(self):
        self.git("init", "-q")
        self.write("README.md", "### Environment variables\n\n"
                   "| Knob | Default and behavior |\n|---|---|\n"
                   "| `WG_PUBLIC` | A setting. |\n\n"
                   "<!-- Internal variables begin. -->\n"
                   "- `WT_INTERNAL` holds generated data.\n"
                   "<!-- Internal variables end. -->\n")

    def test_documented_shell_and_python_variable_reads_pass(self):
        self.variable_fixture()
        self.write("bin/tool", '#!/usr/bin/env bash\nprintf "%s" "$WG_PUBLIC" "${WT_INTERNAL:-}"\n')
        self.write("lib/reader.py", 'import os\nos.environ.get("WG_PUBLIC")\nos.environ["WT_INTERNAL"]\n')
        self.git("add", ".")
        self.assertEqual([], docs_check.check_variables(self.root))

    def test_undocumented_reads_report_the_source_and_line(self):
        self.variable_fixture()
        self.write("bin/tool", '#!/bin/sh\necho "${WG_MISSING:-}"\n')
        self.write("lib/reader.py", 'import os\nos.getenv("WT_MISSING")\n')
        self.git("add", ".")
        self.assertEqual(["bin/tool:2: undocumented variable read: WG_MISSING",
                          "lib/reader.py:2: undocumented variable read: WT_MISSING"],
                         docs_check.check_variables(self.root))

    def test_variable_mentions_outside_inventory_do_not_satisfy_coverage(self):
        self.variable_fixture()
        path = self.root / "README.md"
        path.write_text(path.read_text() + "Mention `WG_MISSING` in prose.\n"
                        "### Other section\n| `WT_MISSING` | Wrong table. |\n")
        self.write("lib/reader.sh", 'echo "$WG_MISSING" "$WT_MISSING"\n')
        self.git("add", ".")
        self.assertEqual(len(docs_check.check_variables(self.root)), 2)

    def test_variable_scan_uses_tracked_bin_and_lib_sources(self):
        self.variable_fixture()
        self.write("lib/reader.sh", 'echo "$WG_PUBLIC"\n')
        self.write("test/example.sh", 'echo "$WT_OUTSIDE"\n')
        self.git("add", ".")
        self.write("lib/untracked.sh", 'echo "$WT_UNTRACKED"\n')
        self.assertEqual([], docs_check.check_variables(self.root))

    def test_tmux_environment_read_requires_documentation(self):
        self.variable_fixture()
        self.write("bin/tool", '#!/bin/sh\ntmux show-environment -t "=$session" WT_CMUX_CLOSE_ON_EXIT\n')
        self.git("add", ".")
        self.assertEqual(["bin/tool:2: undocumented variable read: WT_CMUX_CLOSE_ON_EXIT"],
                         docs_check.check_variables(self.root))
        path = self.root / "README.md"
        path.write_text(path.read_text().replace("`WT_INTERNAL`", "`WT_CMUX_CLOSE_ON_EXIT`"))
        self.assertEqual([], docs_check.check_variables(self.root))

    def test_extensionless_python_command_requires_documentation(self):
        self.variable_fixture()
        self.write("bin/tool", '#!/usr/bin/env python3\nimport os\nos.environ.get("WG_UNDOCUMENTED")\n')
        self.git("add", ".")
        self.assertEqual(["bin/tool:3: undocumented variable read: WG_UNDOCUMENTED"],
                         docs_check.check_variables(self.root))

    def test_shell_escaped_literals_and_deferred_comments_are_hidden(self):
        source = ('printf "%s" "\\$WT_LITERAL" \\$WT_UNQUOTED\n'
                  "sh -c '# $WT_COMMENT\necho \"$WG_LIVE\"'\n"
                  'echo "# $WT_HASH_DATA" # $WT_COMMENT\n')
        self.assertEqual([(3, "WG_LIVE"), (4, "WT_HASH_DATA")],
                         list(docs_check.shell_variable_reads(source)))

    def test_shell_variable_forms_and_comments(self):
        source = ('# $WT_COMMENT ${WG_COMMENT} ((WT_COMMENT))\n'
                  'WG_ASSIGNED=1 # $WT_INLINE\n'
                  'echo "$WG_SIMPLE" "${WT_DEFAULT:-}" "${#WT_LENGTH}" "${!WT_INDIRECT}"\n'
                  'echo "${WT_ARRAY[@]}" "${WT_TRIM##*/}" # ${WT_HIDDEN}\n'
                  '((WT_COUNT > 0)); echo "$((WG_SECONDS * 10))"\n'
                  '[[ -v WT_PRESENT ]]; [[ -v "WG_PRESENT" ]]\n'
                  'sh -c \'echo "$WT_REMOTE"\'\n'
                  'cat <<\'WT_DELIMITER\'\necho "$WG_PAYLOAD"\nWT_DELIMITER\n'
                  'printf "# hash" "$WT_AFTER_HASH" # $WT_HIDDEN\n')
        self.assertEqual({"WG_SIMPLE", "WT_DEFAULT", "WT_LENGTH", "WT_INDIRECT", "WT_ARRAY", "WT_TRIM",
                          "WT_COUNT", "WG_SECONDS", "WT_PRESENT", "WG_PRESENT", "WT_REMOTE", "WG_PAYLOAD",
                          "WT_AFTER_HASH"}, {name for _, name in docs_check.shell_variable_reads(source)})

    def test_python_environment_forms_ignore_comments_strings_and_writes(self):
        source = ('import os as system\nfrom os import environ as env, getenv as read_env\n'
                  '# os.getenv("WT_COMMENT")\nlabel = "WT_LITERAL"\n'
                  'system.environ["WT_WRITE"] = "generated"\n'
                  'system.environ["WT_SUBSCRIPT"]\nsystem.environ.get("WG_GET", "")\n'
                  'system.getenv("WT_GETENV")\nenv["WT_ALIAS"]\nread_env("WG_ALIAS")\n')
        self.assertEqual({"WT_SUBSCRIPT", "WG_GET", "WT_GETENV", "WT_ALIAS", "WG_ALIAS"},
                         {name for _, name in docs_check.python_variable_reads(source)})

    def test_valid_relative_links_and_encoded_anchors(self):
        self.assertEqual([], self.links("[go](docs/target.md#target)\n[local](#heading)\n# Heading\n"))
        self.write("docs/a file.md", "# Heading\n")
        self.assertEqual([], self.links("[go](docs/a%20file.md#%68eading)\n"))

    def test_dead_relative_link_reports_source_line(self):
        self.assertEqual(["README.md:2: dead link: docs/missing.md"], self.links("Text.\n[go](docs/missing.md)\n"))

    def test_shared_reference_links_are_checked(self):
        self.write("home/.claude/TASKS.md", "[restore](#portable-restore-only)\n")
        self.assertEqual(["home/.claude/TASKS.md:1: missing anchor: #portable-restore-only"],
                         docs_check.check_links(self.root))
        self.write("home/.claude/TASKS.md", "[restore](#portable-restore-only)\n## Portable restore-only\n")
        self.assertEqual([], docs_check.check_links(self.root))

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

    def test_rendered_heading_text(self):
        text = "[emphasis](#the-agent) [entity](#a--b) [code](#_literal_)\n# The _agent_\n# A &amp; B\n# `_literal_`\n"
        self.assertEqual([], self.links(text))
        self.assertEqual("file_name", docs_check.heading_text("__file_name__"))
        self.assertEqual("a_b_c", docs_check.heading_text("a_b_c"))
        self.assertEqual("_literal_", docs_check.heading_text(r"\_literal\_"))

    def test_heading_slug_collisions_reserve_emitted_ids(self):
        text = "[one](#a) [two](#a-1) [three](#a-1-1) [four](#a-2)\n# A\n# A\n# A-1\n# A\n"
        self.assertEqual([], self.links(text))
        self.assertEqual({"a", "a-1", "a-1-1", "a-2"}, docs_check.anchors(self.root / "README.md"))

    def test_escaped_brackets_are_literal(self):
        text = r"\[example](missing.md)" + "\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:2: dead link: visible-missing.md"], self.links(text))
        self.assertEqual(["README.md:1: dead link: missing.md"], self.links(r"\\[go](missing.md)"))

    def test_indented_code_preserves_later_live_links(self):
        text = "    [example](missing.md)\n    <!--\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:3: dead link: visible-missing.md"], self.links(text))
        text = "1. Item.\n\n       [example](missing.md)\n\n   [go](visible-missing.md)\n"
        self.assertEqual(["README.md:5: dead link: visible-missing.md"], self.links(text))

    def test_indented_paragraph_and_list_links_remain_live(self):
        text = "Paragraph.\n    [go](missing.md)\n"
        self.assertEqual(["README.md:2: dead link: missing.md"], self.links(text))
        text = "- Item.\n  - Nested item.\n    [go](missing.md)\n"
        self.assertEqual(["README.md:3: dead link: missing.md"], self.links(text))

    def test_inline_comments_preserve_paragraph_indentation(self):
        text = "Paragraph. <!-- note -->\n    [go](missing.md)\n"
        self.assertEqual(["README.md:2: dead link: missing.md"], self.links(text))
        text = "- Item. <!-- note -->\n      [go](missing.md)\n"
        self.assertEqual(["README.md:2: dead link: missing.md"], self.links(text))
        text = "<!-- note --> Paragraph.\n    [go](missing.md)\n"
        self.assertEqual(["README.md:2: dead link: missing.md"], self.links(text))

    def test_standalone_comments_allow_indented_code(self):
        text = "Paragraph.\n<!-- note -->\n    [example](missing.md)\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:4: dead link: visible-missing.md"], self.links(text))
        text = "<!-- note\nmore note -->\n    [example](missing.md)\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:4: dead link: visible-missing.md"], self.links(text))

    def test_html_and_markdown_images_use_destination_checks(self):
        self.write("docs/image.png", "fixture")
        self.assertEqual([], self.links('<img src="docs/image.png" alt="Example">\n'))
        self.assertEqual(["README.md:1: dead link: missing.png"], self.links('<img src="missing.png" alt="Example">\n'))
        self.assertEqual(["README.md:1: dead link: missing.png"], self.links('![Example](missing.png)\n'))

    def test_nested_link_labels_use_destination_checks(self):
        self.assertEqual([], self.links("[Read [the guide]](docs/target.md#target)\n"))
        self.assertEqual(["README.md:1: dead link: missing.md"], self.links("[Read [the guide]](missing.md)\n"))
        self.assertEqual(["README.md:1: dead link: missing.md"], self.links("[One [two [three]]](missing.md)\n"))

    def test_multiline_code_spans_preserve_later_links(self):
        text = "`literal\n[example](missing.md)`\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:3: dead link: visible-missing.md"], self.links(text))
        text = "``literal `\ntext <!-- [example](missing.md)``\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:3: dead link: visible-missing.md"], self.links(text))

    def test_code_spans_match_complete_backtick_runs(self):
        text = "``literal ` [example](missing.md) `` [go](visible-missing.md)\n"
        self.assertEqual(["README.md:1: dead link: visible-missing.md"], self.links(text))
        self.assertEqual(["README.md:2: dead link: missing.md"], self.links("`unclosed\n[go](missing.md)\n"))
        self.assertEqual(["README.md:3: dead link: missing.md"], self.links("`unclosed\n\n[go](missing.md)`\n"))

    def test_blockquote_fences_preserve_later_live_links(self):
        text = "> ```md\n> [example](missing.md)\n> ```\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:4: dead link: visible-missing.md"], self.links(text))
        text = "> > ~~~md\n> > [example](missing.md)\n> > ~~~\n> [go](visible-missing.md)\n"
        self.assertEqual(["README.md:4: dead link: visible-missing.md"], self.links(text))

    def test_fenced_quote_contents_do_not_create_new_containers(self):
        text = "> ```md\n> > [example](missing.md)\n> ```\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:4: dead link: visible-missing.md"], self.links(text))
        text = "> ```md\n> [example](missing.md)\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:3: dead link: visible-missing.md"], self.links(text))

    def test_escaped_closing_brackets_do_not_end_labels(self):
        text = r"[Read \] guide](missing.md)"
        self.assertEqual(["README.md:1: dead link: missing.md"], self.links(text))
        text = r"[Read \\](missing.md)"
        self.assertEqual(["README.md:1: dead link: missing.md"], self.links(text))
        text = r"[Read \\\] guide](docs/target.md)"
        self.assertEqual([], self.links(text))

    def test_code_spans_stop_at_block_interruptions(self):
        for block in ("# Heading", "- Item", "> Quote"):
            with self.subTest(block=block):
                text = f"`literal\n{block} [go](missing.md) `\n"
                self.assertEqual(["README.md:2: dead link: missing.md"], self.links(text))
        text = "`literal\n<!-- [example](missing.md)` -->\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:3: dead link: visible-missing.md"], self.links(text))
        text = "# Heading `literal\n[go](missing.md) `\n"
        self.assertEqual(["README.md:2: dead link: missing.md"], self.links(text))
        text = "`literal\n```md\n[example](missing.md) `\n```\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:5: dead link: visible-missing.md"], self.links(text))

    def test_destinations_balance_parentheses_without_truncation(self):
        self.write("stem", "fixture")
        text = "[go](stem(a(b)).md)\n"
        self.assertEqual(["README.md:1: dead link: stem(a(b)).md"], self.links(text))
        self.write("stem(a(b)).md", "fixture")
        self.assertEqual([], self.links(text))

    def test_destinations_decode_markdown_escapes_and_entities(self):
        for name in ("target(a).md", "a&b.md", "a[1].md", "a file.md"):
            self.write(name, "fixture")
        text = r"[one](target\(a\).md) [two](a&amp;b.md) [three](a\[1\].md) [four](<a file.md>)"
        self.assertEqual([], self.links(text))
        text = r"[one][ref]" + "\n\n" + r"[ref]: target\(a\).md" + "\n"
        self.assertEqual([], self.links(text))

    def test_inline_links_require_complete_syntax(self):
        text = "[literal](missing.md\n\n[go](visible-missing.md)\n"
        self.assertEqual(["README.md:3: dead link: visible-missing.md"], self.links(text))
        text = '[go](docs/target.md "Title") [other](docs/target.md)\n'
        self.assertEqual([], self.links(text))

    def test_reference_destinations_on_continuation_lines(self):
        text = "[go][ref]\n\n[ref]:\n  docs/target.md\n"
        self.assertEqual([], self.links(text))
        errors = self.links(text.replace("docs/target.md", "missing.md"))
        self.assertIn("README.md:1: dead link: missing.md", errors)
        self.assertIn("README.md:4: dead link: missing.md", errors)

    def test_fences_inside_list_items_preserve_later_links(self):
        text = "- ```markdown\n  [example](missing.md)\n  ```\n\n[go](live.md)\n"
        self.assertEqual(["README.md:5: dead link: live.md"], self.links(text))
        text = "> - ~~~markdown\n>   [example](missing.md)\n>   ~~~\n\n[go](live.md)\n"
        self.assertEqual(["README.md:5: dead link: live.md"], self.links(text))

    def test_list_headings_share_container_normalization(self):
        text = "[go](#heading)\n\n- # Heading\n"
        self.assertEqual([], self.links(text))
        text = "[go](#nested)\n\n- Outer.\n  - ## Nested\n"
        self.assertEqual([], self.links(text))

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
