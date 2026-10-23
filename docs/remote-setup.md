# Prepare a portable SSH host

Use this procedure to install workgrove on persistent storage through ordinary SSH.
It supports an existing SSH alias, including an alias registered through the [fragment helper](ssh-hosts.md).
The setup uses no cloud API, supplier command, project checkout hook, or project authentication.

The [portable installer](../lib/workgrove/portable.py) manages persistence and restoration.
The [Mac dispatcher](../lib/workgrove/setup.sh) uploads that public bootstrap without requiring a remote `wt` executable.
Existing VM installations keep their current procedure until you explicitly select a portable root.

## Prerequisites

- Verify ordinary SSH access and host trust through your chosen SSH setup procedure.
- Select an absolute persistent root outside every Git repository.
- Give the remote account ownership of that root and remove group and other write permission.
  If the filesystem cannot provide private permissions, review the [personal volume policy](#trust-a-personal-volume) before continuing.
- Select a storage policy: `volume` for a mounted persistent volume, or `os-disk` for a persistent operating-system disk.
- Select a reviewed public workgrove source URL and its full commit hash for a new checkout.
- Establish the remote user's personal Git identity, or supply an existing remote identity file through `--git-identity`.

The volume policy requires an existing root and an actual mount.
It never creates an empty replacement root when the expected volume is absent.
For a root below the volume mount, supply its mount path with `--mount`.
The operating-system disk policy permits root creation under an existing writable parent.
Neither policy proves a supplier's storage retention or deletion guarantees.

Full setup can install missing packages on Ubuntu 22.04 and 24.04.
Other Linux images need their prerequisites installed separately.
Package installation requires root or noninteractive `sudo` privileges.
The adapter installs workgrove prerequisites and terminal descriptions; it does not configure services or install agent CLIs.

Python 3.9 or later is required.
Setup, installer reruns, doctor, inventory, and task preflight check PATH Python, then `/usr/bin/python3`, for a supported version.
If Python is absent, full setup can install the minimal Python runtime through the Ubuntu adapter before persistent setup begins.
Restore-only never installs that runtime.

## Install

For a new public checkout, run this command from the Mac:

```bash
wt -H <host> setup --root <root> --storage volume --mount <mount> \
  --source <public-workgrove-https-url> --revision <full-commit> \
  --persist-agents --with-tmux-conf
```

The source URL must use HTTPS without embedded credentials, a query, or a fragment.
Source cloning uses isolated Git configuration and disables credential helpers and Git hooks.
The selected revision must exist on the source's default upstream branch.
The new `workgrove-install` branch tracks that upstream, with its initial checkout at the selected revision.
An unavailable revision causes failure; setup does not choose a newer tip.

Alternatively, seed a reviewed standalone checkout at `<root>/workgrove` before setup.
The checkout must contain its own `.git` directory and have no tracked edits.
Its object storage must have no alternates, partial-clone promises, or linked object directories.
Strict permission checks cover installed runtime files, their directories, and Git metadata.
Runtime files, runtime directories, and Git metadata must not contain symbolic links.
Unrelated environments outside those directories retain their normal layout.
An existing checkout needs no `--source`; `--revision`, when supplied, must match its current commit.
Before executing the selected installer, bootstrap checks the object store, runtime contents, requested revision, and tracked edits.
The selected installer repeats these checks before installation.
Setup does not reset, switch, or update that checkout.
Do not seed private investigation history or personal configuration into the public installation.

Use `--storage os-disk` for a root on a persistent operating-system disk.
The default volume mount is the selected root when you omit `--mount`.
With supported Python available, an existing profile keeps its storage policy when you omit `--storage`.
A new profile requires an explicit policy.

If Python is missing and the root contains a saved profile, full setup requires an explicit `--storage` before package installation.
For `volume`, also pass `--mount` when the root is below the mount.
The bootstrap checks the selected storage before installing Python; it does not read the saved profile JSON.

`--git-identity <remote-path>` selects an existing personal Git configuration file.
Without that option, setup uses the remote user's normal global Git configuration.
It copies existing include files, preserves conditional includes and credential-helper configuration, and retains existing exclusion patterns.
It preserves entry order and anchors relative include paths and conditions at their original logical locations.
Path copying preserves symlink traversal before `..` components.
Setup preserves Git's precedence: `$XDG_CONFIG_HOME/git/config` (normally `~/.config/git/config`) first, then `~/.gitconfig`.
It adds `.worktrees/` to the persistent exclusion file.
Each conditional exclusion file retains its patterns and receives `.worktrees/` too.
Git's default global ignore patterns remain when no explicit exclusion file applies.
Use absolute paths or `~/` paths for exclusion files.
Other relative paths cause refusal because Git resolves them from each repository.
Repeated identity selection retains personal settings without adding include layers or duplicate identity includes.
For identity refreshes, select the original personal file or the active global configuration.
The installer never invents an identity or copies a different user's sign-in.

After the first installation, the saved global configuration remains authoritative.
Full setup ignores replacement HOME configuration and inherited `GIT_CONFIG_GLOBAL` paths.
An explicit `--git-identity` refresh preserves saved custom settings and credential-helper resets.
If the saved global file is missing, setup requires an explicit identity file before rebuilding it.
That repair cannot recover settings from the missing file.

## Trust a personal volume

Strict permission checks are the default.
These checks cover existing target files and directories as well as their parents.
Some mounted filesystems report writable permissions for every local user even after `chmod`.
Setup refuses those permissions unless you explicitly accept the personal volume policy.
Acceptance does not repair filesystem permissions or establish exclusive access to the volume.

**WARNING:** Users or processes with volume access could read personal configuration or replace executable files.
Accept this policy only when you exclusively control the volume and trust every process with access.
Keep shared storage under the strict policy.

When a permission failure occurs within the selected mount, interactive setup asks for confirmation.
The prompt shows the canonical mount and installation root.
An empty response or a negative answer leaves the policy unchanged.
Setup validates destinations before writing private configuration.
Read-only probes and restoration never request new acceptance.

Noninteractive setup requires an explicit option:

```bash
wt -H <host> setup --root <root> --storage volume --mount <mount> \
  --trust-personal-volume
```

Use the normal source, revision, and personal configuration options with this command when needed.
The exception relaxes only permission-mode checks within the selected canonical mount.
Ownership, repository boundaries, link safety, and permission checks outside that mount remain enforced.
The option requires the volume storage policy and an existing mount.
Setup never selects this policy from a hostname, filesystem type, or supplier configuration.

The private profile records acceptance alongside its mount and root.
Setup, update, and restore-only reuse acceptance for the same scope and check that the mount remains present.
A changed mount scope requires explicit acceptance again or a return to strict checks.
Mount presence cannot prove that the supplier retained the same storage or its access controls.

To revoke acceptance, run full setup with `--strict-permissions`.
All strict checks must pass before setup saves the change.
Restore-only cannot change the saved permission policy.

Doctor reports `storage_permission_policy` and `storage_permission_warnings` separately from readiness.
An accepted exception reports `trusted-personal-volume` with the warning `unix-mode-checks-relaxed`.
A ready environment under that policy does not establish filesystem privacy.

## Persistent layout

| Location | Contents |
|---|---|
| `<root>/workgrove/` | The public installation and its standalone Git metadata. |
| `<root>/<repo>/` | Main checkouts, task worktrees, and task sidecars. |
| `<root>/.local/bin/` | Links to workgrove commands and user-installed commands. |
| `<root>/.config/workgrove/` | The private portable profile, environment exports, and selected Git configuration. |
| `<root>/.config/claude/`, `<root>/.config/codex/` | Agent configuration migrated through `--persist-agents`, unless an existing redirected root applies. |
| `<root>/.agents/skills/` | Links to public skills. |
| `<root>/.local/state/workgrove/backups/` | Private backups of displaced home-directory files. |

Home-directory command links point directly into the owning public installation.
Workgrove keeps `HOME` unchanged.
Shell files source an exports file; sourcing it never installs packages, restores files, or starts tasks.
Git uses the persistent configuration through `GIT_CONFIG_GLOBAL` and a home compatibility link.

Portable setup and restore-only write an `environment` block at the start of `~/.bashrc` and into `~/.zshenv`.
This block sources `<root>/.config/workgrove/env.sh` before bash's non-interactive return.

A second block, `interactive path`, stays at the end of `~/.bashrc`, including after repeated setup.
It restores missing `<root>/.local/bin` and `~/.local/bin` PATH entries after a supplier's PATH reset.
When both entries are missing, `<root>/.local/bin` comes first.
This block changes only PATH and preserves existing entries without duplication.
It does not source `env.sh` again, so supplier changes to `CODEX_HOME` and `CLAUDE_CONFIG_DIR` remain intact.

`~/.zshenv` has no second block.
Classic VM and Mac installs keep their existing shell blocks.

Normal `wt update` and bare installer reruns retain the portable root and selected options.
For portable profiles, `wt update` accepts `--refresh-config` and `--with-tmux-conf`.
It refuses other installer flags before `git fetch` and lists the accepted flags.

Surviving portable environment files prevent fallback to the original installer.
If the saved profile is missing, an ordinary rerun refuses and requires explicit setup.

Processes, tmux sockets, relay sockets, temporary agent status, and native terminal identities remain runtime state.
A persistent pathname cannot preserve a running process across host shutdown.

## Preserve agent configuration

Before migrating configuration directories, stop the affected agent processes.
Setup never stops them automatically.

`--persist-agents` explicitly selects personal agent configuration for persistence.
It preserves settings, authentication files, sessions, and foreign hooks while migrating the normal home directories.
It preserves an existing `CODEX_HOME` or `CLAUDE_CONFIG_DIR` instead of replacing another tool's configuration root.
Confirm persistence independently when a redirected root lies outside the selected persistent root.
Existing profiles retain their selected agent roots when HOME or inherited environment variables change.

Without a selected Claude directory, setup leaves `CLAUDE_CONFIG_DIR` unset.
Claude continues to read its global state from `~/.claude.json`.
When `--persist-agents` moves that default directory, setup also moves global state into the selected directory's `.claude.json`.
An existing explicitly redirected Claude directory keeps its own global state; unrelated default HOME state remains untouched.
Conflicting migration files cause refusal before configuration changes.
Setup never merges sign-in state.

If two separate configuration locations already exist, setup stops before migration.
It never selects between credentials or merges conversation directories.
Setup also refuses a directory move that would contain another selected agent root.
Mutable configuration links into Git repositories also cause refusal.

Before moving directories, setup checks every copied link, including links in nested state and foreign skills.
Links must retain their targets after migration and restoration of the home directory links.
Internal links that move with their targets and absolute external links remain supported.
Other links cause `agent-link-migration-conflict` before any state moves.
Resolve those conflicts privately before retrying.
Restore-only backs up regular files at home compatibility link locations before replacing them with links.
It refuses directories and foreign symbolic links at every compatibility link location.
It also refuses regular files at root-side command and skill locations, including skills in the selected Claude root.
These rules depend on each link's role, even when the persistent root or Claude root lies inside the home folder.
Missing selected persistent agent roots still cause refusal.

Restore-only and full setup report each backup on stderr.
The line names the home path with `~/` and the backup folder relative to `<root>`.
Custom agent locations use placeholders such as `<claude-root>`.

When the newest backup of the same original path has identical bytes, setup removes the duplicate and names the existing backup.
If setup cannot read the files for comparison, it keeps a new backup.
Backup records identify the original path and move order without using filesystem modification times.
Conflicts at fixed link and shell locations include the path after the refusal code.

Without `--persist-agents`, existing agent configuration remains at its current location.
Its persistence remains the user's responsibility.
The profile stores allowlisted paths and options, not a copy of arbitrary environment variables or supplier metadata.
Keep API keys and SSH keys in their existing owning stores.

Full installation merges workgrove's hook commands into the actual selected agent configuration directories.
It preserves foreign hooks and existing Codex settings and trust data.
Claude defaults to `"tui": "fullscreen"` when the selected settings omit `tui`.
An existing personal `tui` value remains unchanged.
`--refresh-config` repeats this merge for a portable profile; it does not replace existing agent settings.
This differs from the original installer’s configuration replacement procedure.

Agent CLIs remain separate prerequisites.
Use their standard installation procedures from [the VM guide](new-vm.md#block-3-agents-and-logins).
Install personal tools under persistent storage when their installation supports that layout.
Setup does not replace existing versions, authenticate agents, or change a supplier's tool loader.
It registers discovered agent commands whose owning installations already lie under the selected root.
Those links preserve the owning installer's command indirection without copying binaries or pinning another tool's version.
An existing unrelated home command remains intact; the portable command directory takes precedence for workgrove.

Use explicit nonsecret launch arguments when needed:

```bash
wt -H <host> setup --root <root> --codex-args-json '["<nonsecret-option>"]'
```

Each agent has a separate JSON argument array through `--codex-args-json` or `--claude-args-json`.
Workgrove passes each array element as one argument without evaluating shell text.
Saved task models still override profile model options.
Use options supported by the installed agent. Do not put credentials in launch arguments.
Known credential-related argument names cause refusal.

### Check agent runtime compatibility

Portable readiness does not establish that an agent can start its background server or enforce its command sandbox.
Verify those capabilities through a disposable task after personal authentication and folder trust.

Codex 0.163.0 requires private directory permissions for its background server's control socket.
A personal volume can pass workgrove's explicit trust policy while failing that separate agent check.
If the installed Codex supports it, select its foreground mode through the private profile:

```bash
wt -H <host> setup --root <root> --codex-args-json '["--no-daemon"]'
```

The [Codex CLI reference](https://developers.openai.com/codex/cli/reference) documents this option.
It changes the background-server behavior; it does not disable the command sandbox.
This command replaces the saved Codex argument array, so include any other required nonsecret arguments.
An existing agent must exit before explicit `attach --restart-agent` applies changed launch arguments.

Codex's Linux sandbox also requires container capabilities that workgrove cannot grant.
Check the installed runtime with a no-op command inside the disposable task:

```bash
codex sandbox /bin/true
```

If namespace creation fails, obtain a compatible execution environment through the host supplier.
Individual approvals can permit commands outside the sandbox; those commands do not establish sandbox compatibility.
Do not treat personal volume acceptance or `doctor` readiness as authorization to disable agent isolation.
See [Codex's Linux sandbox description](https://github.com/openai/codex/blob/main/codex-rs/linux-sandbox/README.md) for its namespace requirements.

### Preserve terminal settings and personal instructions

`--with-tmux-conf` explicitly selects workgrove's terminal settings and remains sticky across updates.
Existing unrelated shell content and personal instructions remain intact.
Full setup copies linked personal instructions before adding workgrove's instructions.
This supports migration from the original installer without writing into its old checkout.
Restore-only accepts existing instruction links only when they target the saved public installation.
Other desktop preference flags belong to the original installation procedure.

## Check readiness

Bare `wt doctor` checks cmux contracts.
Use `wt doctor --environment` for portable readiness in text format.
The `--root` and `--json` options also select portable readiness.

Run the Mac-supplied read-only doctor:

```bash
wt -H <host> doctor --json
wt hosts --json
```

Doctor works even when the remote `wt` compatibility link is missing.
Use `doctor --root <root> --json` when the home profile link was lost.
It reports fixed issue codes without printing settings, identity values, environment dumps, or captured command diagnostics.
A failed readiness check returns a nonzero status and a JSON report when `--json` is selected.

Doctor checks the profile, storage, installation identity, compatibility links, tools, terminal descriptions, Git identity, and task exclusions.
It checks installation object connectivity when Git is available.
Deleted persistent agent directories block readiness and task creation; doctor never recreates personal data.
Missing selected external agent directories also require explicit repair.
An unavailable or unsupported Python runtime produces a fixed JSON issue.
Task creation refuses an existing portable installation when Python cannot validate it.
Agent executable availability and native-hook presence have separate fields.
An SSH-only probe cannot verify native-row relay behavior or the user's hook trust decisions.
Those checks remain separate from `ready`.
A legacy installation can report `status: "legacy"` with `ready: null`.

From an authorized native SSH row, check the relay and both agent hook providers.
Use the [agent status procedure](vm-agent-status.md) with the actual selected configuration roots.
Install missing native hooks through `cmux-tui agent hook install claude codex`, then review Codex hook trust through `/hooks`.
Follow [VM open relay verification](vm-open-relay.md) for editor requests.
Successful ordinary SSH does not establish either behavior.

## Restore after a host restart

Start the existing host and refresh its SSH endpoint through its supplier.
Keep the same alias and independently verify any changed host identity.
Workgrove does not start compute or repair the supplier's SSH configuration.

Check doctor before choosing environment repair.
If only links and environment were lost, run:

```bash
wt -H <host> setup --root <root> --restore-only
wt -H <host> doctor --json
```

Restore-only uses the durable installation and Python's standard library.
It performs no download, package installation, Git update, login, or agent restart.
It backs up regular home files that the host's start command writes, including `~/.gitconfig` and selected `~/.tmux.conf`.
Each stderr line names the displaced file and its backup folder under `<root>`.
An identical newest backup of that path prevents another copy.
Directories, foreign symbolic links, and regular files at root-side link locations still cause refusal before any file changes.
Before creating links, restore-only checks any required backup storage and records.
Setup, restore-only, and doctor apply the same safety checks to managed personal configuration files.
They check ownership, permissions, repository boundaries, and link targets without requiring agent authentication.
If packages or Python were also lost, run full setup with the saved root and explicit storage policy.
Full setup can install missing prerequisites before repairing compatibility links.

The saved runtime manifest records every file and directory under `bin/`, `lib/`, and `home/`, plus `install.sh` and repository configuration.
Full setup verifies those files against the actual standalone Git checkout before saving the manifest.
Restore-only compares their contents without invoking Git.
Changes require full setup; untracked runtime files and redirected Git worktrees cause refusal.
Unrelated checkout environments, such as `.venv/`, remain outside this check.
Repository-local configuration includes and `extensions.worktreeConfig` are unsupported because they introduce additional repository configuration sources.

Older profiles with partial file signatures require one explicit full setup before restoration or task creation.
The upgrade preserves saved Git configuration and migrates stranded default Claude state when its destination is unambiguous.
Conflicting Claude state requires private resolution before retrying setup.
An older installer that cannot read the upgraded profile refuses instead of downgrading it.
Use a revision that supports the saved profile for subsequent setup and updates.

After readiness passes, follow [the shared VM recovery procedure](new-vm.md#recovering-a-vm-row).
Inspect the original checkout and task state before attaching.
A previously started task without its agent still requires explicit `--restart-agent`.
Recover only selected tasks; leave other worktrees and sessions untouched.
Missing task files or Git metadata require storage investigation, not automatic task recreation.

## Offline checks and limits

The [portable fixtures](../test/portable_test.py) use synthetic personal configuration and intercepted SSH and native-row commands.
They check installation, home replacement, persistent identity, preserved task state, and the same recovery interface for both lifecycle fixtures.
The [capacity fixtures](../test/capacity_test.py) check kernel limits and uncertain allocation.
The existing remote and native-relay suites retain their ordinary VM checks.

The [live Runpod results](runpod.md#verification-status) cover explicit personal volume acceptance, installation, update, restoration, tasks, and native relay.
They also record an agent sandbox incompatibility and the remaining acceptance checks.
Cloud lifecycle recovery remains unverified; simulated link restoration does not establish persistence across a real restart.
