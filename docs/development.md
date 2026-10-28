# Development

This page describes the repository layout and tests.

## Layout

The tree below shows the files in this repo, with a short note on what most of them do.

```
workgrove/
├── README.md
├── AGENTS.md                  rules for agents that work on this repo
├── CLAUDE.md                  one line: @AGENTS.md
├── LICENSE
├── install.sh                 links this repo into $HOME (Mac and Ubuntu)
├── Brewfile                   bash fzf gh jq shellcheck (azure-cli commented out); casks cmux, VS Code, GCM
├── .gitignore
├── .github/
│   └── workflows/tests.yml    GitHub Actions: shellcheck and every suite in test/, on macOS and Ubuntu
├── bin/
│   ├── wt                     the task tool: worktrees, cmux rows, the picker, the driver, VMs
│   ├── agent-notify           agent lifecycle hook for Mac banners outside cmux
│   ├── cmux-hook              Mac event handler for native VM row requests
│   ├── github-guard           Claude and Codex PreToolUse hook for GitHub commands
│   ├── azml-ssh-host          Azure ML compute instance -> a Host block in ~/.ssh/config
│   └── wt-ssh-host            register a supplied SSH fragment without a cloud API
├── lib/
│   └── workgrove/
│       ├── common.sh          shared helpers that bin/wt and cmux-hook load
│       ├── task.sh            repository context, sidecars, task identity, and cleanup
│       ├── options.sh         wt command table, option parser, and command help
│       ├── automation.sh      installer support for the native notification rule
│       ├── install-files.sh   installer file replacement and JSON merge helpers
│       ├── agent-config-policy.json shared agent settings edits for both installers
│       ├── doctor.sh          Mac and VM contract checks and fixture recording
│       ├── doctor-sanitize.jq redacts recorded cmux responses
│       ├── cmux.sh            shared cmux adapter, row queries, and SSH row creation
│       ├── cmux-tui-hook.sh   gives cmux-tui's agent hooks the current row's terminal (wt run sets it)
│       ├── version.sh         shared validation for installation version reports
│       ├── hosts.sh           SSH host inventory and hardware probes
│       ├── ssh_host.py        flat SSH fragment validation and atomic registration
│       ├── setup.sh           Mac-side setup and read-only doctor over ordinary SSH
│       ├── portable.py        persistent profiles, installation, and explicit restoration
│       ├── picker.sh          task picker and driver commands
│       ├── recovery.sh        VM row recovery and task attachment
│       ├── remote.sh          remote commands and result parsing
│       ├── commands.py       generation-bound task command cancellation
│       ├── cmux_monitor.py   detached native Codex monitor identity checks
│       ├── filtered_files.py  raw tracked-file preservation checks
│       ├── branch_config.py   frozen local branch configuration cleanup
│       ├── safety.sh          worktree removal checks
│       ├── teardown.sh        durable cleanup receipts and retry handling
│       └── vm/                scripts that bin/wt sends to a VM on SSH standard input
│           ├── host-new-preflight.sh
│           ├── capacity.py    effective Linux allocation from kernel limits
│           ├── probe-host.sh
│           ├── python-runtime.sh  supported remote interpreter selection
│           ├── reinit-client-confirm.sh
│           ├── reinit-client-detach.sh
│           └── reinit-client-proof.sh
├── home/
│   ├── .zshenv                always installed
│   ├── .gitignore_global      always installed
│   ├── .zshrc                 opt-in shell config
│   ├── .gitconfig             opt-in Git config
│   ├── .tmux.conf             opt-in tmux config
│   ├── .oh-my-zsh/custom/themes/workgrove.zsh-theme   with the .zshrc opt-in
│   ├── .claude/
│   │   ├── AGENTS.md          the working conventions both agents read
│   │   ├── TASKS.md           task procedures that agents read on demand
│   │   ├── CLAUDE.md          one line: @AGENTS.md
│   │   ├── settings.base.json
│   │   ├── keybindings.json   opt-in
│   │   └── statusline-command.sh  opt-in
│   ├── .agents/skills/
│   │   ├── azml-compute/SKILL.md
│   │   ├── task-driver/SKILL.md
│   │   ├── ssh-host/SKILL.md
│   │   ├── worktree-create/SKILL.md
│   │   ├── worktree-work/SKILL.md
│   │   ├── worktree-show/SKILL.md
│   │   └── worktree-teardown/SKILL.md
│   ├── .codex/
│   │   ├── config.base.toml
│   │   └── hooks.base.json
│   ├── .cmuxterm/automations.json  native VM notification rule
│   ├── .config/cmux/cmux.json
│   └── .config/ghostty/
│       ├── config             the font, theme, and padding that cmux's terminals use
│       └── themes/
│           ├── learning-dark
│           └── learning-light
├── vscode/
│   ├── settings-snippet.jsonc six keys to paste; Settings Sync owns the rest
│   └── extensions.txt
├── test/
│   ├── run.sh                 the shared local and CI runner with bounded workers and timings
│   ├── runner-smoke.sh        runner scheduling, filters, failure logs, and interruption cleanup
│   ├── runner-git.sh          optional resolution of Apple's Git launcher for test workers
│   ├── runner-git-smoke.sh    Git selection, fallback, and fixture precedence
│   ├── wt-scenarios.sh        the wt scenario IDs and names shared by discovery and execution
│   ├── lib.sh                 the assertion functions shared by the suites
│   ├── docs-smoke.sh          Layout files, required citations, and local links and anchors
│   ├── docs_check.py          documentation checks shared by the suite and fixtures
│   ├── docs_check_test.py     regression fixtures for documentation checks
│   ├── options-smoke.sh       command metadata and option parsing
│   ├── task-smoke.sh          task context, sidecars, identity, and cleanup
│   ├── metadata-smoke.sh      sidecar compatibility, read counts, and the JSON status contract
│   ├── lib-smoke.sh           unit tests for every shared shell function
│   ├── named-outputs-smoke.sh caller-named outputs that match internal local names
│   ├── hook-wiring-smoke.sh   portable hook events match agent-notify
│   ├── install-smoke.sh       the install smoke test: the default install, the flags, stickiness
│   ├── wt-smoke.sh            the wt smoke test: sidecars, base pinning, every rm refusal
│   ├── bash5-smoke.sh         all bin/ scripts under bash 5, and the /bin/bash 3.2 handoff
│   ├── doctor-smoke.sh        cmux contracts, VM hooks, and redacted fixture recording
│   ├── fakes/
│   │   ├── cmux              the shared cmux and cmux-tui fake
│   │   ├── pgrep             supplies the fake VM's pane process status
│   │   ├── commands-python.sh  safe command-manifest fake for synthetic process IDs
│   │   ├── rows.sh           builds scenario data from recorded responses
│   │   └── tmux              supplies the fake VM's session, pane, and client answers
│   ├── fixtures/
│   │   └── cmux-0.65.1/      redacted responses recorded from real cmux
│   │       ├── REDACTED.txt   redaction notice
│   │       ├── automation.json
│   │       ├── capabilities.json
│   │       ├── event.json
│   │       ├── notifications.json
│   │       ├── rows.json
│   │       ├── rows_by_window.json
│   │       ├── ssh.json
│   │       ├── top.json
│   │       ├── version.txt
│   │       └── windows.json
│   ├── update-smoke.sh        version reporting and updates with scratch clones
│   ├── tmux-target-smoke.sh  real Linux tmux parsing on a private server
│   ├── cmux-ownership-smoke.sh  native parent snapshots and idle launch ownership
│   ├── commands-smoke.sh    task command identity and owned-process cancellation checks
│   ├── commands_test.py     fake process graphs and disposable detached children
│   ├── cmux-monitor-smoke.sh  detached native monitor proof checks
│   ├── cmux_monitor_test.py  native-shaped samples, observer binding, and kernel arguments
│   ├── branch-config-smoke.sh  hard-interruption recovery for owned Git locks
│   ├── branch_config_test.py  disposable branch configuration and lock fixtures
│   ├── hosts-smoke.sh         SSH inventory with scratch aliases and a fake ssh
│   ├── hosts_records_test.py  host fallback records and inventory validation
│   ├── ssh-host-smoke.sh      offline SSH fragment registration tests
│   ├── ssh_host_test.py       synthetic registration, trust, and confidentiality fixtures
│   ├── portable-smoke.sh      portable installation and explicit restoration
│   ├── python-scenarios.py    discovered unittest groups and test selection
│   ├── portable_test.py       home replacement, personal state, and shared task recovery
│   ├── python-runtime-smoke.sh  Python isolation and shared runtime calls
│   ├── capacity-smoke.sh      effective CPU, RAM, and GPU allocation checks
│   ├── capacity_test.py       synthetic cgroup and GPU visibility fixtures
│   ├── github-guard-smoke.sh  what the GitHub guard approves and denies, with a fake gh
│   ├── remote-new-smoke.sh    remote task preflight and recovery with fake ssh/cmux
│   └── native-relay-smoke.sh  native VM requests, the cmux-tui hook wrapper, and automation backups
└── docs/
    ├── development.md         repository layout, local tests, and CI checks
    ├── new-mac.md             set up a Mac
    ├── new-vm.md              set up an Ubuntu VM
    ├── azml-compute.md        Azure ML compute instances over ssh
    ├── runpod-integration.md  SSH integration design and acceptance limits
    ├── remote-setup.md        prepare and restore portable SSH hosts
    ├── runpod.md              Runpod preparation through the shared SSH workflow
    ├── ssh-hosts.md           register a supplied SSH fragment
    ├── cmux-integration.md     cmux commands, fields, environment, and compatibility log
    ├── vm-protocol.md          Mac–VM commands, records, requests, and tmux environment
    ├── cmux-checklist.md       checks after a cmux update
    ├── vm-open-relay.md        native VM requests after cmux 0.65
    ├── vm-agent-status.md     agent status in VM rows after cmux 0.65
    ├── wt-json.md             the JSON status contract of wt list --json and wt show --json
    ├── self-teardown-squash.md investigation of stacked squash removal and session cleanup
│   ├── task-teardown.md        implemented removal, ownership checks, and cleanup recovery
    ├── codex-self-teardown.md caller identity and failure reporting for local Codex teardown
    ├── documentation-style.md the writing rules for docs, agent instructions and comments
    └── ssh-config.example     the Host block a VM alias needs
```

### Tests

Every cmux suite uses `test/fakes/cmux` and the helpers in `test/fakes/rows.sh`.
The fake reads recorded cmux 0.65.1 responses from `test/fixtures/cmux-0.65.1/`.
`wt doctor --record test/fixtures` captures these responses and removes private values.
Sanitization keeps workspace and window refs consistent while replacing their original numbers.

`fake_row <id> <title> <description> [host state backend slot ref]` builds a row with a stable, unique workspace ref.
The optional eighth argument supplies an explicit unused `workspace:N` ref.
Helpers store reference assignments under `FAKE_CMUX_STATE`, or under `TEST_ROOT` when no state is active.
`fake_window_rows <window> [rows...]` adds the scoped response's window ref.

`FAKE_CMUX_STATE` selects a scratch state folder.
`windows.json`, `rows.json`, `rows/<window>.json`, `notifications.json`, and `top.json` override recorded responses.
`calls.log` records each command.
`fail/<command>` supplies an exit status on its first line and an error message on subsequent lines.
`fake_queue` queues response text, an exit status, and an error message.
Command keys include `list-windows`, `workspace-list`, `workspace-list--<window>`, `read-screen`, and `workspace-close`.

`after/<command>/` supplies state files to copy after a successful command.
A `mutate` file enables persistent row creation, description changes, and closure.
Creation uses the active window and reserves seeded row IDs and workspace refs.
Description changes and closure update all matching row snapshots.
Membership changes update window counts, selected workspace IDs, and scoped response refs.
A `notify-dedupe` file enables notification content suppression for relay tests.

Recorded commands require their complete supported argument forms before queues or overrides can respond.
Unsupported workspace actions return exit status 64 and preserve state.

`bash test/docs-smoke.sh` checks the Layout tree, the documentation guide's required citations, and relative links and anchors.
It also runs isolated regression fixtures for the checker.
It needs `python3` and Git. The shared runner and CI discover it through `test/*-smoke.sh`.

GitHub Actions runs [`.github/workflows/tests.yml`](../.github/workflows/tests.yml) when a pull request opens,
reopens, or receives new commits. It also runs on pushes to `main`, including merges.
Other branch pushes and tag pushes do not start the workflow.
Other branches receive no cloud checks before a pull request opens.
A new run cancels older runs for the same branch or pull request.
Main pushes and pull-request merge checks use separate cancellation groups.

The workflow makes these checks:

- On `ubuntu-24.04`, `shellcheck -x` checks `bin/*`, `lib/workgrove/*.sh`, `lib/workgrove/vm/*.sh`,
  `install.sh`, `test/*.sh`, `test/fakes/cmux`, `test/fakes/*.sh`, `home/.claude/statusline-command.sh`,
  `test/fakes/pgrep`, and `test/fakes/tmux`. The job downloads ShellCheck 0.11.0 from its official release
  and verifies the archive's SHA-256 checksum.
- On `ubuntu-24.04`, Ruff 0.14.0 checks `lib/` and `test/` for undefined names, unused code, and syntax errors.
  The job downloads Ruff from its official release and verifies the archive's SHA-256 checksum.
- A separate `ubuntu-24.04` job uses `actions/setup-python` to put Python 3.9 first on `PATH`.
  It checks the interpreter version, then runs every smoke suite through `test/run.sh`.
  This includes Python tests, documentation checks, and shell suites that call Python through `wt`.
- The suites in `test/` run in parallel on `macos-latest`, `ubuntu-22.04`, and `ubuntu-24.04`.
  Each scenario must make at least one assertion.
  - On macOS, Homebrew's bash is first on `PATH`. `install-smoke.sh` runs `install.sh` with
    `INSTALL_BASH=/bin/bash`, and `bash5-smoke.sh` tests the `/bin/bash` 3.2 handoffs.
  - On Ubuntu, the job stops when `tmux` is missing, because every VM has tmux. Without tmux, `wt rm` on a
    VM cannot check for a running agent, so it keeps the worktree, and `wt-smoke.sh` fails. The Ubuntu
    runner images include tmux.
- The workflow uses no secrets, and its token can only read the repository. The suites contact no host.
  `GIT_ALLOW_PROTOCOL=file` limits git in the suites to local repositories.

To make the same checks on the Mac, install bash, jq and shellcheck first. `Brewfile` installs all three.
Install [Ruff 0.14.0](https://github.com/astral-sh/ruff/releases/tag/0.14.0) and put its `ruff` executable on `PATH`.
Then run these commands in bash from the repository root:

```bash
export PATH="$(brew --prefix)/bin:$PATH"
shellcheck -x bin/* lib/workgrove/*.sh lib/workgrove/vm/*.sh install.sh test/*.sh test/fakes/cmux test/fakes/*.sh home/.claude/statusline-command.sh test/fakes/pgrep test/fakes/tmux
ruff check --select F,E9 lib test
GIT_ALLOW_PROTOCOL=file INSTALL_BASH=/bin/bash bash test/run.sh
```

By default, the runner limits execution to four workers across suites and discovered tasks.
It splits `wt-smoke.sh` and `remote-new-smoke.sh` into one task per scenario.
It splits the portable, SSH registration, and capacity Python suites into groups of at most eight tests.
Python discovery includes new tests without changes to the runner.
The runner starts tasks with the largest estimated durations first.
After measuring a new long task, add its duration to `queue_task` in `test/run.sh`.
The short Python checks within `hosts-smoke.sh` and `docs-smoke.sh` stay with their shell scenarios.
Set `JOBS=1` for a serial run or `JOBS=8` to allow more workers.
To select suites, pass their paths: `bash test/run.sh test/wt-smoke.sh`.
The runner prints each task's complete log, waits for all tasks, and fails if any task failed.
It keeps runner logs after a failure. Set `KEEP=1` to keep logs after a successful run.

Each suite reports its assertions and exits nonzero on failure.
Scenario and task times show individual durations in seconds.
Each suite's elapsed span runs from its first worker's start to its last worker's finish.
Total wall time includes discovery, Git selection, execution, and task log output.
On the Mac, the runner resolves Apple's Git launcher once when `/usr/bin/git` is selected.
A temporary shell wrapper preserves Git's helper and template paths.
The runner preserves custom Git selections and uses the original Git if resolution or version checks fail.

The runner shares a temporary standard-library bytecode cache across Python test processes.
Each process still starts separately. Isolated Python invocations ignore the cache environment setting.
Portable tests pack their source template's Git objects once and keep a separate source copy and durable root for each test.

Set `ONLY` to select scenario names with a shell glob pattern. The filter matches substrings too.
For example, `ONLY='11.*' bash test/wt-smoke.sh` runs scenario 11.
For a filtered runner invocation, select one suite: `ONLY='11.*' bash test/run.sh test/wt-smoke.sh`.
For the split Python suites, `ONLY` matches `module.Class.test_method` with Python `fnmatch` patterns and implicit surrounding `*` characters.
For example, `ONLY='PortableTests.test_restore*' bash test/run.sh test/portable-smoke.sh` selects restore tests.
A filter that matches no scenario or Python test exits nonzero.
Direct suite invocations remain serial.
`--list-scenarios` lists exact task IDs and names for each split suite.
Use `bash test/wt-smoke.sh --scenario scenario_shared_helpers` to run an exact scenario.
Set `KEEP=1` to keep scratch files for inspection.

`wt-smoke.sh` and `remote-new-smoke.sh` set `WG_POLL_INTERVAL=0` to shorten production poll waits.
Other suites keep the default one-second interval for checks that need real waits.
`WG_POLL_INTERVAL` passes directly to `sleep`. Invalid values produce a sleep error; no fallback interval replaces them.
An unset or empty value uses one second.

The host probe defaults to 20 seconds. `WG_HOST_PROBE_TIMEOUT` accepts decimal integers from 1 through 922337203685477580 seconds.
Leading zeros are invalid. `hosts-smoke.sh` sets `WG_HOST_PROBE_TIMEOUT=1` for its deadline check.

- **`bash test/install-smoke.sh`** checks installation across eighteen scenario groups.
  Each run uses its own throwaway `$HOME` with no network.
  - It covers:
    - the default no-flags install, into an empty home and over a stranger's own dotfiles
    - `--opinionated-config`, and each file flag on its own
    - the stickiness rules, idempotence, an unknown flag, and every refusal path
    - which links count as this repo's own
    - the don't-clobber branches of `configure_git`, retirement of renamed links, and `ZSH_CUSTOM`
    - the cmux agent paths in `home/.zshenv`. Scenario 18 sources the file with a stub `uname`, so it checks
      the Mac and Linux branches on every platform.
  - Set `INSTALL_BASH=/bin/bash` to run `install.sh` itself under bash 3.2, which is what a fresh Mac gives it.
  - Set `FORCE_OS=Linux` to drive the Linux-only steps from a Mac.
  - A run on a VM is useful, because `FORCE_OS` cannot fake everything that a real Linux box differs in.
    For example, a VM run found that the suite built its fixtures with whatever umask the machine had.
    Ubuntu's umask, 002, made a `~/.bashrc` group-writable, and `install.sh` declines to rewrite such a file.
    So a scenario that meant to test the rewrite tested the refusal instead, and only on the VM.
    `install-smoke.sh` and `wt-smoke.sh` now both pin `umask 022`.
- **`bash test/wt-smoke.sh`** checks `wt` against throwaway git repos with stub cmux commands.
  It needs no cmux, network, or VM. It covers:
  - What `wt` records in a sidecar, including a task model passed to Claude and Codex on later launches.
  - How a base is pinned: `@`, `HEAD^0`, and `--head` on a detached checkout. Without the pin, these
    spellings would compare a worktree with itself.
  - Every Git data check that `wt rm` makes, and the checks that `--force` waives.
  - That another running agent blocks removal, even with `wt rm --force`.
  - That local self-removal passes cmux's `--force` only for the caller's own row.
  - That native VM self-removal ends its tmux client and keeps older rows until they reopen.
  - That a squash-merged branch is not one of those reasons. A commit made after the squash, a partial
    revert, and a later edit to the same lines still are reasons. These cases run against a bare "origin" and a
    second clone that plays GitHub, and once more under a `git` that claims to be 2.34.
  - That `wt prune` keeps exactly what `wt rm` refuses.
  - That a VM task can remove itself only after it leaves its worktree.
  - That sandboxed removal keeps the worktree, branch, and sidecar until the agent retries with escalation.
  - That a failed tmux session query keeps the worktree, and a failed cmux row close reports its error.
  - That unreadable or malformed cmux lists and failed tmux agent probes cannot permit removal.
  - That a row in a second cmux window is still found and still closed.
  - That a task row is found by its title, its repo, and its host. Two repos can have tasks with the same name,
    and each command acts only on the row of its own repo. A row with the old `<repo>:<name>` title is still found.
    The second line names the repo by its `repo_id`, as the Mac hook does, also for a repo name with a dot.
  - That `wt rm` refuses while an agent runs in any row that may be the task's, whatever the order of the rows.
    Such a row can have a second line that the user edited or cleared. It can also be a local row whose
    directory is in the worktree, as written or through a symlink.
  - That automatic reattachment requires a connected row, a recognizable task-shell prompt, and a fresh detached-session check.
  - That explicit `--reattach` requires a shell prompt naming `user@host`, on its own line or the line above.
  - That client replacement requires a fresh status message visible in that row.
  - That `bin/wt`, when `/bin/bash` starts it, runs under bash 5, or stops with a message that names the fix.
  - The last group is different: it tests the `rm -rf` of `test/lib.sh` itself. No real run reaches that
    `rm -rf`, for two reasons. Both suites build their scratch root with `mktemp -d`. They also refuse a
    root inside the real home before they arm the trap that calls it. The group exists because nobody knows that
    a branch is broken when nothing exercises it.

  Scenario 8 uses a `uname` shim to check the Mac's row handling on every platform.
  The SSH and cmux recovery checks use fakes. The suite does not cover a live VM reconnect.
- **`bash test/hosts-smoke.sh`** checks the SSH inventory's JSON, table, alias filtering, concurrent probes, and
  failure states, with a fake `ssh` on a scratch `PATH`. It also executes the probe script against fake
  hardware commands, including malformed GPU output. It verifies the client deadline against a hanging SSH
  process. It does not contact any configured host.
- **`bash test/options-smoke.sh`** checks command help, aliases, option values, repeated flags, and `--` boundaries.
  It checks remote forwarding and command-table extension with scratch fixtures and no real SSH calls.
- **`bash test/named-outputs-smoke.sh`** checks output variables whose names match internal locals, including arrays and forwarded outputs.
- **`bash test/lib-smoke.sh`** checks the shared functions in `lib/workgrove/common.sh` and the scenario filter.
  It checks versioned task results, malformed records, duplicate records, and rejection of missing records or required facts.
  It checks host aliases, path rules, task names, identity output, and SSH config parsing with a scratch home.
  Fixed cmux responses cover row lists across windows, failure policies, checked validation, command wrappers, and lookup by title, repo, and host.
  It pins the exact `tmux_cmd` output for task, `shared`, and `reinit` forms.
  A stub tmux checks native identity precedence, explicit empty values, and unset names.
  It does not contact a host.
- **`bash test/remote-new-smoke.sh`** runs the real `bin/wt` behind scratch SSH and the shared cmux fake.
  It checks real VM `new`, `show`, and `path` commands.
  It also checks these cases:
  - remote task preflight and model forwarding
  - rejection of missing or incomplete VM result records
  - a row failure after worktree creation
  - an SSH disconnect after creation but before the Mac receives the result
  - that a brief, agent, and model survive an interrupted `.wt-setup`
- **`bash test/github-guard-smoke.sh`** checks `bin/github-guard` with a stub `gh`.
  The stub answers `gh api` from fixtures by running the guard's own `--jq` filter over them.
  Set `GUARD_BASH=/bin/bash` to start the guard with bash 3.2, which hands it to bash 5. The suite checks these
  results:
  - A command that only mentions `gh api` or `git push` (a commit message, a heredoc, a `grep`) gets no answer.
  - Approved: reads, pushes to branches other than `main`, `master`, and the default branch, pull requests, issues, comments, reviews,
    edits of your own issues and comments, and thread resolution.
  - Denied: pipes, substitutions, brace expansions, and control characters.
  - Denied: another repository, named or through `GH_REPO`, `GH_HOST`, or `gh repo set-default`.
  - Denied: someone else's issue or comment, an approval, and any other GraphQL mutation. That includes a
    mutation behind an alias, a fragment, a directive, a comment, or a block string.
  - Denied: force pushes, deletions, and a tag or a bare commit as the source.
  - Denied: the default branch, in all three cases: as GitHub names it, over a stale local HEAD, and when
    nothing can name it.
  - Denied: a body file outside the repository, and `--template`.
  - Denied: a remote whose push URL leaves github.com, including when `wt pr` would push through that remote.
  - `settings.base.json` wires the hook and carries no rule that would override it.
  - Codex payloads return denials or no decision. A synthetic dispatcher checks harmless subprocess markers.
    This simulation does not verify Codex runtime execution or hook trust.
- **`bash test/doctor-smoke.sh`** checks cmux versions, methods, response shapes, hook paths, VM checks, and fixture redaction.
  It uses `test/fakes/cmux` to serve and replay recorded contract responses.
- **`bash test/native-relay-smoke.sh`** checks native VM requests, tmux identity, notification validation, and automation backups.
  It also checks that `wt run` gives the cmux-tui agent hooks the terminal ID from the task's tmux session.
  It uses a scratch home and fake commands.
  It loads only the automation merge function; it does not run `install.sh`.
- **`bash test/portable-smoke.sh`** checks portable profiles, personal configuration, home replacement, and shared task recovery.
- **`bash test/capacity-smoke.sh`** checks cgroup limits and GPU visibility using synthetic kernel views.
- **`bash test/ssh-host-smoke.sh`** checks generic SSH registration with temporary files and an offline SSH wrapper.
  See [the registration guide](ssh-hosts.md) for validation, trust, and failure behavior.
- **`bash test/bash5-smoke.sh`** checks all bin scripts under bash 5.
  On the Mac, it also starts each script with `/bin/bash` 3.2 and checks the final interpreter.
  Script copies use scratch paths to test missing candidates, older candidates, and candidate order.
  With no bash 5 or no `lib/`, `wt` and `wt-ssh-host` stop and the hooks exit 0 without an answer.
  `agent-notify` drains its payload.
  `cmux-hook` reads its event from the environment and leaves standard input unread.
  Through a relative link to an absolute link, the suite checks that each script finds `lib/` from another folder.
