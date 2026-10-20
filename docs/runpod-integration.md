# Runpod hosts through ordinary SSH

Workgrove supports remote host preparation through ordinary SSH configuration, including Runpod hosts.
The SSH supplier needs no knowledge of workgrove, its installation, or its task workflow.
No supplier changes are required for the first implementation.

This document describes SSH registration, portable setup, readiness, and effective-capacity reporting.
Use the [SSH registration guide](ssh-hosts.md), [portable setup procedure](remote-setup.md), and [Runpod guide](runpod.md) for implemented interfaces and limits.

## Scope and evidence

An SSH supplier is the person or tool that provides and maintains a host's SSH configuration.
Workgrove consumes that configuration like other SSH clients.
The supplier remains responsible for compute creation, billing, endpoint refresh, and establishing SSH trust.
Users perform those operations separately through their chosen supplier.

The evidence below references workgrove's public source files and generic Linux host capabilities.
The [verification status](runpod.md#verification-status) separates offline coverage from the limited live SSH checks.
The full remote task workflow still requires live acceptance.

A Runpod host must provide ordinary remote-command SSH and storage with an understood persistence policy.
Do not assume that a running container has every package required by workgrove.
Do not assume that stopping compute preserves processes or that deleting compute preserves its storage.
Verify those properties through the supplier's own documentation and an authorized acceptance check.

CPU means central processing unit; GPU means graphics processing unit.
RAM means random-access memory. MiB means mebibytes; one MiB contains 1,048,576 bytes.
Control groups, or cgroups, are Linux resource controls used in the capacity checks.

## Current workgrove behavior

Workgrove discovers literal `Host` aliases in the Mac's main SSH configuration.
Its discovery function does not expand `Include` files.
An outer alias with an included endpoint fragment therefore fits the existing discovery model.
Evidence: [common.sh](../lib/workgrove/common.sh), `ssh_hosts` and `known_host`.

Remote task commands invoke `$HOME/.local/bin/wt` through SSH.
Remote preflight checks that executable, the requested repository, tmux, and the selected agent executable.
Rows retain the task title and `@<host> · <repo>` description.
Evidence: [remote.sh](../lib/workgrove/remote.sh), [preflight](../lib/workgrove/vm/host-new-preflight.sh), and [task.sh](../lib/workgrove/task.sh).

The Azure ML precedent separates endpoint registration from remote installation.
The Azure helper obtains connection details, updates its own configuration region, and verifies SSH.
The ordinary VM guide then prepares the machine for workgrove.
Reuse that separation without introducing another cloud-specific API client.
Evidence: [Azure helper](../bin/azml-ssh-host), [Azure ML guide](azml-compute.md), and [VM guide](new-vm.md).

The legacy inventory obtains CPU count from `getconf` and RAM from `/proc/meminfo`.
The current probe adds effective cgroup limits, affinity, allocation verification, and readiness.
It retains bounded NVIDIA queries and legacy report compatibility.
Evidence: [hardware probe](../lib/workgrove/vm/probe-host.sh) and [host parser](../lib/workgrove/hosts.sh).

Current task recovery distinguishes a surviving session from a lost agent.
A previously started task without its agent requires explicit `--restart-agent`.
Codex restarts from the saved brief; Claude uses its existing continuation option.
Evidence: [recovery.sh](../lib/workgrove/recovery.sh) and [bin/wt](../bin/wt), `cmd_run`.

## Responsibility boundary

| Component | Responsibility |
|---|---|
| SSH supplier | Create, start, stop, and delete compute; maintain endpoint configuration, client credentials, and host trust. |
| Generic workgrove registration helper | Register a user-selected alias that includes the supplied fragment; verify ordinary SSH. |
| Workgrove remote setup | Install or restore portable tools, persistent configuration, environment, and compatibility links over SSH. |
| Workgrove task workflow | Create worktrees, open rows, attach sessions, report status, open editors, and remove tasks. |
| Workgrove capacity probe | Measure effective usable allocation and support the existing hardware-selection rules. |
| User and agent instructions | Select explicit setup options, preserve personal identities, and separate compute lifecycle from task recovery. |

Workgrove uses ordinary SSH without inspecting supplier state, invoking supplier commands, or accessing supplier API credentials.
Optional descriptive supplier output can help a person choose an alias or root, but it is not a runtime dependency.

The required interoperability contract is ordinary SSH configuration.
No additional metadata export or provider registry is required.
The supplier owns coherent replacement of its own configuration.
Workgrove treats a missing or invalid fragment as a connection problem and never repairs the supplier's state.

## SSH registration

### Accept existing aliases

An already registered and trusted SSH alias requires no new registration format.
Use it with the existing `wt -H <host> ...` interface.
Keep SSH configuration as the host list rather than adding a provider registry.
The helper below is a convenience for users who receive a fragment without an outer `Host` entry.

### Add a generic helper

The first implementation provides this provider-neutral interface:

```text
wt-ssh-host [-F <config>] add <alias> --fragment <path>
wt-ssh-host [-F <config>] list --json
wt-ssh-host [-F <config>] rm <alias>
```

The user supplies both the alias and the fragment path.
Do not locate the fragment by searching private checkout layouts or assuming a provider-specific directory name.
Do not encode provider IDs, workspace names, account IDs, or API routes in the helper.

A redacted managed block has this shape:

```text
# >>> wt-ssh-host <host>
Host <host>
    StrictHostKeyChecking yes
    Include "<supplied-fragment>"
Host *
# <<< wt-ssh-host <host>
```

If the fragment supplies a stable `HostKeyAlias`, preserve its exact opaque value before the `Include` line.
Do not parse that value as a provider identifier or synthesize one from a naming convention.
That registration pin prevents ordinary fragment replacement from silently changing the accepted host-key alias.
An unexpected change requires explicit identity verification and registration update.
Address-based trust remains supported, but endpoint changes can require separate trust verification.

The fragment can supply hostname, port, user, identity-file references, trust-file references, and ordinary connection policy.
Do not copy private key contents or replace the supplier's trust file.
The helper never uses trust-on-first-use to repair missing trust automatically.
An initial unknown key must be verified through the user's chosen SSH setup procedure.

Reuse the Azure helper's atomic configuration replacement, backups, restrictive local modes, and unmanaged-alias refusal.
Prepend the managed block before existing wildcard defaults, as the Azure helper does.
Keep the literal outer alias in the main config so existing workgrove discovery sees it.
Reset the scope with `Host *` before the managed region ends to preserve preexisting global settings.
Reject new configuration or backup destinations that resolve inside a Git working tree or Git administrative directory.
Existing unrelated aliases and settings remain unchanged.

Removing a registration removes only its managed region.
It does not delete the fragment, credentials, remote files, tasks, or compute.
Listing reports managed registrations and local fragment health; it does not enumerate a cloud account.
Registration success must distinguish a written alias from successful SSH verification.

### Validate supplied fragments safely

Validate imported fragments with an independent parser before invoking OpenSSH, including `ssh -G`.
Accept a documented flat set of connection directives with typed values and literal path references.
Reject nested `Include`, `Host`, `Match`, command directives, unknown keywords, duplicate fields, and unsupported expansion.
Support quoted spaces and the documented encoding of literal percent signs.
Use synthetic fixtures to define the accepted grammar independently of any private supplier's output.

After independent validation, inspect effective settings through the user's existing SSH configuration.
Keep that output private and require strict host-key verification.
Check that effective destination, port, user, opaque host-key alias, and trust-file policy match the approved registration.
If existing configuration conflicts, fail with a private diagnostic rather than rewriting the user's unrelated settings.
Do not rewrite intentional user-owned configuration control flow.
Imported-fragment validation applies to helper-managed aliases; ordinary existing aliases retain normal OpenSSH semantics.
The placement and precedence baseline follows the [Azure helper](../bin/azml-ssh-host), `write_config` and `install_block`.

OpenSSH's `Match exec` can execute a shell command during configuration processing.
OpenSSH invocation is therefore not the independent validation step for a newly imported fragment.
Evidence: [OpenSSH configuration manual](https://man.openbsd.org/ssh_config#Match).

Before workgrove-managed connections, validate helper-managed fragments again and check their opaque identity pin.
Treat supplier-managed fragments as trusted local configuration shared with other SSH clients.
Workgrove cannot police independent clients or an already reconnecting cmux transport.
It must not claim that one registration check permanently validates every future fragment revision.

## Persistent storage

Use `/workspace` as the suggested persistent root for a host with that mounted storage.
Allow another explicit absolute root through the same portable profile.
Existing VMs retain their current installation until the user explicitly migrates them.
Do not change `HOME`, replace the whole home directory, or assume a particular login username.

| Durable location | Contents |
|---|---|
| `<root>/workgrove/` | The installed public workgrove checkout at an explicitly selected revision. |
| `<root>/<repo>/` | The user's main checkouts, Git metadata, task worktrees, and sidecars. |
| `<root>/.local/bin/` | User commands and links into their owning installations. |
| `<root>/.config/workgrove/` | Allowlisted portable profile, root, alias, managed paths, and selected options. |
| `<root>/.config/` | Personal configuration that the user explicitly selects for persistent storage. |
| `<root>/.agents/skills/` | Portable skill links. |
| `<root>/.local/state/workgrove/backups/` | Confidential migration backups outside every checkout. |
| `<root>/.cache/` | Rebuildable workgrove-owned caches. |

Keep processes, tmux sockets, locks, temporary runtime status, and cmux terminal identities on runtime storage.
Persisting their pathnames does not preserve their processes.
Record setup results for the current container or operating-system instance rather than trusting an old completion file.

Create direct home-directory links to durable workgrove scripts.
For example, `$HOME/.local/bin/wt` points directly to `<root>/workgrove/bin/wt`.
Recreate shell source blocks, personal Git includes, exclusions, and selected tmux configuration during explicit restoration.
Keep mutable personal files outside the tracked workgrove checkout.

Detect existing agent configuration through standard environment variables and normal home-directory locations.
Preserve existing configuration roots when they already provide the required persistence.
Do not assume a private tool's directory names or modify its environment loader.
If home and redirected configuration contain different data, stop before migration and identify the private conflict locally.
Never select credentials or merge sessions automatically.

Keep personal Git identity and all required includes persistent, including `.gitconfig.local` when that convention is used.
Verify the effective identity and `.worktrees/` exclusion after setup and after simulated home replacement.
Preserve external credential helpers and additional exclusions without exposing their contents.
The current installer uses home-relative Git identity and exclusion references that the portable profile must handle explicitly.
Evidence: [installer](../install.sh), `require_git_identity`, `configure_git`; [Git base](../home/.gitconfig).

## Workgrove-owned remote preparation

### Implemented interface

The Mac supplies generic setup and doctor operations:

```text
wt -H <host> setup --root <persistent-root>
wt -H <host> setup --root <persistent-root> --restore-only
wt -H <host> doctor --json
```

These commands are implemented in [setup.sh](../lib/workgrove/setup.sh) and [portable.py](../lib/workgrove/portable.py).
Initial setup also requires an explicit storage policy and either a selected public source revision or a seeded standalone checkout.
The setup dispatcher must use ordinary SSH directly, without first invoking the remote `$HOME/.local/bin/wt`.
That path can be missing after Pod stop/start when runtime setup has been lost.
Do not create a row, tmux session, or task merely to prepare the host.
Doctor must also report a missing remote `wt` through a Mac-supplied read-only SSH probe.
An unavailable remote doctor executable must not prevent it from identifying the setup prerequisite.

The Mac uploads a small public bootstrap through SSH using the existing safe argument-quoting conventions.
It discovers generic operating-system capabilities and validates the selected persistent root.
It obtains the explicitly selected public workgrove revision without overwriting an existing checkout.
A matching upstream-tracking installation branch preserves the ordinary reviewed update workflow.
If the requested revision is unavailable, stop rather than selecting a branch tip silently.

Full setup may install missing workgrove prerequisites through a supported operating-system adapter.
Check whether the remote account has the necessary privileges; do not assume root or passwordless sudo.
Report unsupported platforms or insufficient privileges without attempting unrelated configuration changes.
Setup must not create compute, authenticate to project services, run repository dependency setup, or invoke project hooks.

The portable installer owns links, environment, instructions, configuration preservation, and profile persistence.
Operating-system adapters own package installation, not cloud-specific lifecycle behavior.
The persistent installer profile supports `install.sh --remote-root <root>` and sticky plain installer reruns.
It requires explicit Git identity inputs or an existing validated personal identity file.
It must not require oh-my-zsh or impose optional shell preferences.

### Full setup and restore-only behavior

| Operation | Allowed behavior |
|---|---|
| Full setup | Install missing portable prerequisites, obtain an approved public revision, install the profile, and restore compatibility links. |
| Restore-only | Use the existing durable installation to restore links and environment; perform no download, package installation, Git update, login, or agent restart. |
| Doctor and inventory | Read current capabilities and report readiness without repair or cloud calls. |

Declare prerequisites from public workgrove behavior: Bash 5, Git, tmux, jq, Python, rsync, process tools, core utilities, and terminal descriptions.
Check required agent executables separately from project dependencies and personal authentication.
Use existing agent installations when suitable; do not replace another tool's pins or configuration.
If an agent is absent, report the standard workgrove installation procedure instead of invoking a supplier's bootstrap.
Evidence for existing requirements: [VM guide](new-vm.md), [preflight](../lib/workgrove/vm/host-new-preflight.sh), and [task-driver skill](../home/.agents/skills/task-driver/SKILL.md).

Restore-only may use Python 3's standard library through a small shell bootstrap.
It must not require jq, Git, tmux, or project Python packages merely to recreate links safely.
If its minimal runtime is missing, report incomplete readiness and the explicit full-setup command.
Leave ordinary SSH usable; do not install an automatic fallback.
Full setup reruns restoration after installing missing prerequisites.

Validate physical destinations, mount policy, ownership, and installation identity before writes.
A container-volume policy requires evidence that the expected storage is mounted.
An ordinary persistent-OS-disk policy does not require a separate mount at the selected root.
Do not create an empty replacement persistent root on the container disk when the expected mount is absent.
Use installation locks and atomic replacement, and preserve unrelated home-directory content.

### Recover tasks after a host stop/start

Do not modify supplier startup commands, container entrypoints, project hooks, or template versions.
Do not install implicit package repair into shell startup files.
Normal shell files may source workgrove environment exports; sourcing must not trigger installation or restoration.

Use the existing Azure VM recovery model.
Restore SSH, verify the environment, inspect the task, and attach or restart explicitly.
Runpod can require more environment repair after stop/start, but task recovery uses the same commands and state checks.
Accept explicit environment repair instead of adding supplier startup integration.
The baseline procedure is [Recover a VM row](../README.md#recover-a-vm-row) and [VM recovery](new-vm.md#recovering-a-vm-row).
Its implementation is [recovery.sh](../lib/workgrove/recovery.sh), `host_attach`.

The following checklist applies to both host types after an authorized restart:

1. Start the existing host through its supplier and refresh its SSH endpoint when necessary.
   Keep the same alias and verify ordinary SSH before attempting task recovery.
   Do not bypass changed host keys or create a replacement host to repair a connection.
2. Check remote installation and environment through the doctor operation.
   If checks pass, skip setup repair.
   If only compatibility links or environment were lost, run `wt -H <host> setup --root <root> --restore-only`.
   If required packages were also lost, run `wt -H <host> setup --root <root>`.
3. Verify the original checkout, Git metadata, worktrees, and sidecars remain at their saved paths.
   Preserve uncommitted files, branches, briefs, models, selected agents, and started markers.
   Setup repairs the installation; it must not replace task checkouts or reset task metadata.
4. Inspect tasks with `wt -H <host> list -r <repo>` and `wt -H <host> show -r <repo> <task>`.
   Select only the tasks the user wants to recover.
5. Apply the same attachment decision used for Azure VM rows, as defined in the table below.
   Verify the recovered row, agent state, and terminal settings before reporting recovery complete.

| Inspected task state | Existing command and behavior |
|---|---|
| The task was deferred and never started. | Use `wt -H <host> attach -r <repo> <task>` to start its saved agent. |
| Its agent and tmux session still exist. | Use ordinary `attach` to reconnect or restore the task's tmux terminal settings. |
| Its session exists but the connected row shows a confirmed bare shell. | Use `attach --reattach` under the existing shell-prompt and session checks. |
| A previously started task has lost its agent or tmux session. | Use explicit `attach --restart-agent`; its safety check must refuse when an agent remains or its state is unknown. |
| Task files or required Git metadata are missing. | Stop task recovery and investigate storage or backups. Do not recreate the task automatically. |

An agent must follow the existing recovery authorization policy before invoking recovery or either explicit recovery flag.
Setup and attachment must not restart every saved task after a host restart.
An idle host can retain many worktrees without running their agents.
`--restart-agent` starts the saved agent using current continuation behavior; it does not restore process memory or promise automatic Codex conversation resume.

Distinguish the lifecycle events in instructions and diagnostics:

| Event | Recovery scope |
|---|---|
| Client disconnect or brief network interruption | Inspect surviving processes and use ordinary attachment when appropriate. Do not assume setup was lost. |
| Host stop/start with persistent storage retained | Repair missing environment as needed, then use the same Azure VM task attachment decisions. |
| Host deletion or loss of persistent storage | Follow the supplier's storage and backup procedure. Workgrove attachment cannot reconstruct deleted files. |

A read-only preflight failure must print the generic preparation command rather than launching supplier commands or repairing implicitly.
If a row cannot reconnect through a refreshed alias, reopen only that task's stale transport when necessary.
Do not kill a surviving tmux session or change task identity to refresh the SSH connection.
Existing task commands and row descriptions retain their current interface after preparation.

### Updates and agents

Make the selected root, alias, storage policy, and opt-ins sticky across plain `wt update` and installer reruns.
Resolve the canonical script consistently when finding the installed checkout.
Startup and `cmd_update` now resolve the same owning installation through its loaded library path.
Evidence: [bin/wt](../bin/wt), startup and `cmd_update`; [update tests](../test/update-smoke.sh).

Preserve personal sign-ins, agent settings, trust decisions, and foreign hooks.
Merge only workgrove-owned configuration and keep mutable files out of tracked templates.
Maintain normal tmux options as explicit opt-ins, including `--with-tmux-conf` for standard modified-key, mouse, and color behavior.
Evidence: [installer](../install.sh), [VM guide](new-vm.md#keys-and-colors-inside-tmux), and [tmux configuration](../home/.tmux.conf).

Support explicit agent-specific launch arguments where a host needs them.
Do not rely on interactive aliases when `wt run` invokes an executable by variable name.
Record explicit nonsecret launch options in the local profile and test their behavior with the selected agent.
Evidence for launch behavior: [bin/wt](../bin/wt), `cmd_run`.

Check portable cmux-tui hooks from a native row using the agent's actual configuration directory.
Keep the existing task-scoped identity wrapper and require normal hook trust after changes.
Do not persist relay sockets or report successful SSH as proof of a working native relay.
Evidence: [agent status](vm-agent-status.md), [open relay](vm-open-relay.md), and [hook wrapper](../lib/workgrove/cmux-tui-hook.sh).

## Readiness and effective capacity

Keep `wt hosts --json` status compatible: `available` still describes successful SSH probing.
Add generic workgrove readiness and capacity-verification fields rather than provider-specific status fields.
Distinguish missing tools, incomplete profile restoration, unknown legacy capability, and unreachable SSH.
Do not add provider IDs, private project names, or supplier lifecycle state to inventory.
Evidence for current fields: [host parser](../lib/workgrove/hosts.sh) and [JSON guide](wt-json.md).

Apply container-aware probing independently of alias spelling, registration helper, or provider identity.
A manually registered host must not bypass resource-limit checks.
Take CPU capacity from the intersection of online CPUs, process affinity, effective CPU sets, and applicable quota limits.
Round fractional quota capacity down to whole CPUs; report zero when a verified allocation cannot satisfy one whole CPU.
Take RAM capacity from the smallest applicable finite container limit and reported physical RAM, converted down to MiB.
Handle cgroup versions 1 and 2, ancestor limits, unlimited values, malformed data, and hidden limits explicitly.

If effective allocation cannot be established, report uncertain fields as null and exclude that container from automatic selection.
Keep the existing full-host path for ordinary VMs when resource visibility supports it.
Never substitute requested hardware or optional supplier descriptions for measured usable allocation.
Continue querying visible allocated GPUs, with unknown device memory remaining unknown.
GPU partitions and fractional sharing need separate validation before automatic selection.

Keep capacity separate from current utilization; this version provides no scheduling reservations.
Hardware-based selection must use verified sufficient capacity and applicable workgrove readiness.
Project repository and agent requirements remain separate preflight checks immediately before task creation.
Existing legacy hosts retain compatibility behavior where the new capability fields are unavailable.
Evidence for selection requirements: [task-driver skill](../home/.agents/skills/task-driver/SKILL.md).

## Agent procedure and task interface

The [SSH onboarding skill](../home/.agents/skills/ssh-host/SKILL.md) uses these shared steps:

1. Obtain the existing alias or the user-selected alias and supplied SSH fragment.
   Establish SSH trust through the supplier or the user's normal procedure without reading private project state.
2. Register a fragment through `wt-ssh-host add <host> --fragment <path>` when an outer alias is missing.
   Skip this step for an already usable alias.
3. Confirm the persistent root, storage policy, public workgrove revision, personal identity source, and optional terminal settings.
4. Run `wt -H <host> setup --root <root>` over ordinary SSH.
   Preserve existing agent configuration and resolve migration conflicts before writes.
5. Verify remote version, repository discovery, doctor, and effective hardware inventory.
   Report preparation separately from project authentication and native-row verification.
6. When authorized, create and inspect a disposable task through the standard remote workflow.
   Check native hooks, agent status, keyboard behavior, and VM-side open; remove the task through normal safeguards.

After a host stop/start, follow the [shared recovery checklist](#recover-tasks-after-a-host-stopstart).
Once the host passes readiness checks, create new tasks with the ordinary `wt -H <host> new ...` workflow.
New task creation does not resume old tasks or require every saved agent to restart first.
Keep the Runpod guide's additional setup-repair notes separate from the shared Azure VM attachment instructions.
Automatic cmux endpoint rereading remains an acceptance check rather than an assumed guarantee.

| Existing interface | Required result after preparation |
|---|---|
| `wt task`, `--where <host>`, shell choices | Use the same picker and native shell rows; no separate cloud picker. |
| `wt -H <host> repos --porcelain` | Discover the user's repositories through the configured root. |
| `new`, `--no-workspace`, `--prompt-stdin`, model and agent flags | Preserve task creation, exact briefs, deferred uploads, and saved agent selection. |
| `path`, `list --json`, and `show --json` | Preserve remote paths, repository requirements, and task schemas. |
| `attach`, `--reattach`, and `--restart-agent` | Preserve existing recovery distinctions and process-state safety checks. |
| Mac-side and VM-side `open` | Use the alias and existing native open relay. |
| Row descriptions and agent status | Keep `@<host> · <repo>` and task-scoped Running/Idle/Needs input behavior. |
| Task removal and self-removal | Preserve uncommitted-work safeguards and scoped row/session closure; never stop compute. |
| `update` and `version` | Retain ordinary reviewed updates and protocol reporting through the persistent profile. |
| `hosts --json` and hardware selection | Use ordinary inventory with verified effective allocation and no cloud API access. |

Do not add remote forms for commands currently restricted to local execution.
The current command contract comes from [options.sh](../lib/workgrove/options.sh), [remote.sh](../lib/workgrove/remote.sh), and [recovery.sh](../lib/workgrove/recovery.sh).

## Confidentiality and publication

The public implementation must contain no private supplier repository names, paths, API shapes, setup recipes, image pins, or revision identifiers.
Use provider-neutral fixtures, generic schema fields, public technical references, and synthetic examples.
A Runpod-specific setup guide may explain explicit persistent storage preparation without describing a private supplier's internals.
Optional supplier descriptions stay private local inputs and must not become committed defaults or fixtures.

Validate physical destinations, including symlinked parents, before writing personal state, SSH configuration, exports, or backups.
Reject destinations inside Git working trees or Git administrative directories.
Read-only links to public scripts, skills, instructions, and templates are permitted; mutable settings must never target them.
Do not rely on `.gitignore` to protect personal configuration from entering a public repository.
Keep the existing project worktrees and Git sidecars as deliberate task-data locations rather than destinations for installation credentials.

Use allowlisted profile fields and diagnostic result codes.
Do not copy arbitrary environments, Git helpers, shell overrides, agent settings, or supplier metadata into manifests.
Keep private keys and tokens in their existing owning stores; workgrove only references SSH identity and trust files.
Treat aliases, endpoints, paths, personal identity, task briefs, captured output, and configuration backups as private operational data.
Sanitize runtime evidence before publication and mark sanitized logs as redacted.
Do not publish raw `ssh -G`, login output, complete environments, connection fragments, or migration-conflict dumps.
Evidence for publication rules: [AGENTS.md](../AGENTS.md#public-information).

Use synthetic fixtures and fake-secret canaries in temporary directories.
Never create public snapshots from real home directories, private checkouts, supplier state, agent configuration, or task sidecars.
Keep integration state, credentials, agent directories, and backups out of `.wt-include` and project setup hooks.
The existing task-copy interface can copy ignored project settings, so publication checks must include task content too.
Evidence: [safety.sh](../lib/workgrove/safety.sh), `copy_includes`; [bin/wt](../bin/wt), `cmd_new` and `cmd_show`.

## Acceptance and limits

Offline tests must cover fragment grammar, alias conflicts, opaque identity pins, atomic supplier fragment replacement, and broken references.
Include conflicting `Host *` defaults and assert that effective connection settings match the approved registration or fail safely.
Test canonical-path boundaries, secret-bearing synthetic diagnostics, and configuration parents pointing into repositories.
Test full setup and restore-only after simulated Pod stop/start when the remote `wt` link or optional packages disappeared.
Test failure with missing restoration runtime, invalid storage, unavailable privileges, and conflicting personal configuration.
Test persistent Git identity, exclusions, sticky updates, and direct or indirect executable links.

Run the same recovery fixtures for an Azure-style VM reboot and a Pod stop/start with persistent task files retained.
Keep the VM environment installed in the first fixture and remove runtime links or packages in the second.
After any required setup repair, assert identical attachment decisions, saved task identity, and explicit restart requirements.
Assert that only selected tasks restart and that unrelated worktrees and sessions remain unchanged.
Test two task rows, both agents, deferred creation, verified uploads, open relay, status, and scoped removal.
Assert that discovery, inventory, setup, attach, and task removal never invoke supplier commands or cloud APIs.
Test that setup invokes no project dependency installation, private repository clone, project authentication, or project hook.
Test that sourced shell files perform no implicit restoration or package installation.

Live acceptance requires separate authorization and a bounded compute budget.
Verify the selected root's persistence, effective CPU/RAM/GPU visibility, native relay, agent sandboxing, and refreshed-endpoint reconnect behavior.
Verify task files across stop/start, explicit preparation when runtime setup is lost, and explicit restart for lost agents.
Check final lifecycle and billing state through the supplier independently.
Initial [live checks](runpod.md#verification-status) verified SSH registration and read-only probes on an active Pod.
The initial persistent setup check found a volume permission blocker.
Generic personal volume acceptance is now implemented; live setup under that policy remains unverified.
Cloud lifecycle recovery and the complete remote task workflow remain unverified.

## Recommended implementation order

Implement the first version entirely in workgrove against generic SSH configuration.
Keep supplier metadata enhancements optional and outside the task runtime contract.
The ordinary task interface remains unchanged after explicit preparation.

### Workgrove steps

1. The generic SSH fragment helper and connection revalidation are implemented; existing alias support remains unchanged.
   The [registration guide](ssh-hosts.md) defines its flat grammar, identity pin, atomic edits, and repository-boundary checks.
   An explicit registration permits validated trust-policy changes; changing the identity pin requires removal and registration again.
   Remote commands, host inventory, and native SSH row creation revalidate managed fragments before connecting.

   **Open questions:** Which additional flat directives are justified by public compatibility tests?

2. Mac-side remote setup, portable profiles, restore-only, and read-only doctor are implemented.
   The initial package adapter supports Ubuntu 22.04 and 24.04 with root or noninteractive sudo privileges.
   Mountinfo supplies volume evidence; the operating-system disk policy remains an explicit user choice.
   Personal configuration, terminal opt-ins, and reviewed updates use the shared portable installer.
   Strict permissions remain the default; interactive confirmation or `--trust-personal-volume` records an explicit exception for one mounted personal volume.
   Doctor reports the accepted policy separately from readiness; restore-only reuses acceptance without granting new trust.

   **Open questions:** Which additional operating systems and volume implementations pass the same offline and live acceptance checks?

3. Effective-capacity and readiness fields are implemented with legacy report compatibility.
   The kernel probe covers cgroup versions 1 and 2, affinity, CPU sets, ancestor limits, and bounded GPU visibility checks.
   Hidden or malformed limits remain unknown and cannot qualify for automatic selection.

   **Open questions:** Which supported images expose enough hierarchy information for verified allocation?

4. The generic SSH onboarding skill, shared setup guide, and Runpod preparation guide are implemented.
   They use the same Azure VM attachment decisions after any explicit environment repair.
   Offline tests cover registration, personal state, allocation limits, home replacement, and selected task recovery.

   **Open questions:** Does supported cmux reread updated aliases on reconnect? Which agent launch options need explicit host-profile configuration?

5. Run separately authorized live acceptance after the offline checks pass.
   Record only sanitized public results and keep private operational captures outside the repository.

   **Open questions:** Who authorizes spending and owns lifecycle cleanup? Which supported images pass persistence, capacity, and agent-sandbox checks?

### SSH supplier work

No workgrove-specific change is required.
Continue providing ordinary SSH configuration and independently managing compute and trust.
Optional improvements can describe connection readiness, persistence, or endpoint refresh in the supplier's own documentation.
They must not introduce workgrove installation, startup callbacks, project-specific patterns, or a required shared export schema.

**Open questions:** Can the supplier keep its fragment path stable across endpoint changes? What storage guarantees should the user validate before choosing a root?
