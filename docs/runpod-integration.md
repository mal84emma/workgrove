# Runpod hosts through ordinary SSH

This document explains the design boundaries and acceptance limits for Runpod hosts through ordinary SSH.
The [SSH registration guide](ssh-hosts.md), [portable setup procedure](remote-setup.md), and [Runpod guide](runpod.md) own the operational procedures.
Existing VMs retain the [VM setup procedure](new-vm.md) until the user explicitly selects a portable root.

## Scope and evidence

An SSH supplier is the person or tool that provides and maintains a host's SSH configuration.
The supplier needs no knowledge of workgrove, its installation, or its task workflow.
No supplier changes are required.

A host must provide ordinary remote-command SSH and storage with an understood persistence policy.
A running container does not establish package availability, process survival across stop/start, or storage retention after deletion.
Those properties require supplier documentation and separately authorized acceptance checks.
The [verification status](runpod.md#verification-status) distinguishes offline coverage, live results, and remaining limits.

## Responsibility boundary

| Component | Responsibility |
|---|---|
| SSH supplier | Create, start, stop, and delete compute; maintain endpoint configuration, client credentials, and host trust. |
| Generic workgrove registration helper | Register a user-selected alias that includes the supplied fragment; verify ordinary SSH. |
| Workgrove remote setup | Install or restore portable tools, persistent configuration, environment, and compatibility links over SSH. |
| Workgrove task workflow | Create worktrees, open rows, attach sessions, report status, open editors, and remove tasks. |
| Workgrove capacity probe | Measure effective usable allocation and support the existing hardware-selection rules. |
| User and agent instructions | Select explicit setup options, preserve personal identities, and separate compute lifecycle from task recovery. |

Ordinary SSH configuration is the interoperability contract.
Workgrove does not inspect supplier state, invoke supplier commands, or access supplier API credentials.
It requires no provider registry, metadata export, shared export schema, startup callback, or cloud-specific API client.
Optional supplier descriptions can help a person select an alias or root; they remain private inputs outside the runtime contract.

The supplier owns coherent replacement of its configuration and independent compute and trust management.
Workgrove treats a missing or invalid fragment as a connection problem and never repairs supplier state.
Supplier documentation can describe readiness, persistence, and endpoint refresh without adding workgrove installation or project-specific patterns.

## SSH registration

Registration and remote preparation remain separate, as in the Azure ML workflow.
An existing trusted alias needs no new format.
A literal outer alias stays in the main SSH configuration because workgrove discovery does not expand `Include` files.
The user supplies the alias and fragment path; workgrove does not search private layouts or encode provider identifiers.

[Registration and inspection](ssh-hosts.md#register-and-inspect) own command syntax, configuration precedence, atomic edits, backups, local modes, and verification outcomes.
The [fragment grammar](ssh-hosts.md#supported-fragment-grammar) owns typed directives, quoted paths, literal percent signs, and rejected syntax.
OpenSSH's [`Match exec`](https://man.openbsd.org/ssh_config#Match) can execute commands while reading configuration.
For imported fragments, independent validation must precede OpenSSH invocation, including `ssh -G`.

[Refresh, list, and removal](ssh-hosts.md#refresh-list-and-remove) own opaque identity pins, explicit policy updates, connection revalidation, and local fragment health.
Imported-fragment validation applies to helper-managed aliases; ordinary existing aliases retain OpenSSH semantics.
Supplier-managed fragments remain trusted local configuration shared with other clients.
Registration cannot permanently validate future revisions, independent SSH clients, or an already reconnecting native transport.

## Persistent storage

The [storage prerequisites](remote-setup.md#prerequisites) own root selection, mount evidence, ownership, permissions, and supported package adapters.
`/workspace` is a suggested root only when the expected persistent storage is mounted there.
An explicit absolute root supports other layouts without changing `HOME`, replacing the whole home directory, or assuming a login username.
Neither a directory name nor a mount proves the supplier's retention guarantee.
The [personal volume policy](remote-setup.md#trust-a-personal-volume) owns explicit permission exceptions; restore-only reuses saved acceptance without granting new trust.

The [persistent layout](remote-setup.md#persistent-layout) separates public tools, task data, private configuration, and confidential backups.
Rebuildable workgrove-owned caches belong under `<root>/.cache/`.
Processes, live locks, tmux sockets, temporary runtime status, and native terminal identities remain runtime state.
Persistent pathnames do not preserve running processes or lock ownership.
Readiness must describe the current container or operating-system instance, rather than trust an old completion file.

[Installation](remote-setup.md#install) owns persistent Git identity, required includes, credential-helper preservation, and `.worktrees/` exclusions.
[Agent configuration preservation](remote-setup.md#preserve-agent-configuration) owns redirected roots, migration conflicts, sign-ins, and backups.
Workgrove must not select credentials, merge sessions, replace a supplier's environment loader, or keep mutable personal files in its tracked checkout.

## Workgrove-owned remote preparation

### Implemented interface

[Installation](remote-setup.md#install) owns setup options, selected public revisions, bootstrap checks, and prerequisite installation.
[Readiness checks](remote-setup.md#check-readiness) own the read-only doctor interface and its limits.
The Mac supplies setup and doctor code over ordinary SSH because a new or restarted host can lack its remote `wt` executable.
Bootstrap delivery uses workgrove's existing safe argument quoting.

Do not create a row, tmux session, or task merely to prepare a host.
It must not create compute, authenticate project services, install project dependencies, or invoke project hooks.
Preparation must not require oh-my-zsh or impose optional shell preferences.

### Full setup and restore-only behavior

[Restoration](remote-setup.md#restore-after-a-host-restart) owns full-setup and restore-only decisions, minimal runtime requirements, validation, locks, and atomic writes.
Full setup can install missing prerequisites through a supported operating-system adapter with adequate privileges.
Prerequisites remain Bash 5, Git, tmux, jq, Python, rsync, process tools, core utilities, and terminal descriptions.
Restore-only uses the durable installation and Python's standard library without downloads, package installation, Git updates, logins, or agent restarts.
Missing restoration runtime requires explicit full setup; it must not trigger an automatic fallback.

Shell startup may source environment exports, but must not install packages or restore files.
Workgrove does not modify supplier startup commands, container entrypoints, project hooks, or template versions.

### Recover tasks after a host stop/start

The [shared restart procedure](remote-setup.md#restore-after-a-host-restart) owns SSH verification, doctor, environment repair, and task-file checks.
The [Runpod recovery guide](runpod.md#recover-after-stopstart) adds container storage and home-replacement limits.
The [VM recovery procedure](new-vm.md#recovering-a-vm-row) owns the common attachment decisions and terminal repair.

A disconnect can leave processes alive; stop/start can retain files while losing processes and runtime setup.
Deletion or persistent-storage loss requires supplier storage or backup recovery; attachment cannot reconstruct deleted files.
Environment repair must preserve checkouts, Git metadata, worktrees, sidecars, uncommitted files, branches, briefs, models, agents, and started markers.
Missing task files or Git metadata require investigation rather than automatic task recreation.
Read-only preflight failures report the generic preparation command without supplier calls or implicit repair.

Recovery requires the existing authorization policy and explicit flags when a started task has lost its agent.
Only selected tasks restart; environment repair must not restart every saved task.
`--restart-agent` uses current continuation behavior, without restoring process memory or promising automatic Codex conversation resume.
Refreshing a stale SSH transport must not kill a surviving tmux session or change task identity.
Automatic native endpoint rereading remains unverified in [#176](https://github.com/mal84emma/workgrove/issues/176).

### Updates and agents

The [persistent layout](remote-setup.md#persistent-layout) owns sticky options, direct command links, and reviewed updates from the owning installation.
[Agent configuration preservation](remote-setup.md#preserve-agent-configuration) owns foreign hooks, personal settings, trust, and explicit nonsecret launch arguments.
Interactive aliases cannot supply arguments when `wt run` invokes an executable by variable name.
[Terminal settings](remote-setup.md#preserve-terminal-settings-and-personal-instructions) remain explicit opt-ins, including `--with-tmux-conf`.

[Runtime compatibility](remote-setup.md#check-agent-runtime-compatibility) and [native-row checks](remote-setup.md#check-readiness) remain separate from basic readiness.
Native hooks use the agent's actual configuration directory and the existing task-scoped identity wrapper.
Successful SSH does not establish a native relay or the user's hook trust decisions.

## Readiness and effective capacity

CPU means central processing unit; GPU means graphics processing unit; RAM means random-access memory.
Control groups, or cgroups, are Linux resource controls.
MiB means mebibytes; one MiB contains 1,048,576 bytes.

The [capacity and readiness contract](wt-json.md#read-effective-host-capacity-and-readiness) owns inventory fields and hardware-selection rules.
`available` continues to mean successful SSH probing, independently of readiness and verified usable capacity.
Missing tools, incomplete restoration, unknown legacy capability, and unreachable SSH remain distinct states.
Inventory must not contain provider IDs, private project names, or supplier lifecycle state.

Container-aware measurement applies independently of alias spelling, registration helper, or provider identity.
Effective CPU capacity intersects online CPUs, process affinity, effective CPU sets, and applicable quotas.
Fractional quota capacity rounds down to whole CPUs, including zero for a verified allocation below one CPU.
Effective RAM is the smaller physical or applicable finite cgroup limit, rounded down to MiB.
The probe must handle cgroup versions 1 and 2, ancestor limits, unlimited values, malformed data, and hidden bounds.

Unknown effective values remain null and cannot qualify a container for automatic selection.
Requested hardware and optional supplier descriptions cannot replace measured allocation.
Ordinary VMs retain the full-host path when resource visibility supports it; legacy hosts retain their compatibility behavior.

GPU queries remain bounded and report visible allocated devices, with unknown memory remaining unknown.
GPU partitions and fractional sharing require separate validation before automatic selection.
Capacity is separate from current utilization and provides no scheduling reservations.
Verified sufficient capacity and applicable readiness do not replace repository and selected-agent preflight checks before task creation.

## Agent procedure and task interface

Use the [SSH registration guide](ssh-hosts.md#register-and-inspect) and [portable setup procedure](remote-setup.md#install) for onboarding.
The [Runpod task guide](runpod.md#use-ordinary-tasks) owns the ordinary task workflow after preparation.
Task creation does not resume old tasks or require every saved agent to restart first.
Prepared hosts retain the existing picker, task flags, paths, row descriptions, status, open relay, and removal safeguards.
The [task JSON contract](wt-json.md) owns task schemas.

Do not add a separate cloud picker.
Do not add remote forms for commands currently restricted to local execution.
Task removal never stops compute.

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

Use synthetic fixtures and fake-secret canaries in temporary directories.
Never create public snapshots from real home directories, private checkouts, supplier state, agent configuration, or task sidecars.
Keep integration state, credentials, agent directories, and backups out of `.wt-include` and project setup hooks.
The existing task-copy interface can copy ignored project settings, so publication checks must include task content too.

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

The [live results](runpod.md#verification-status) record installation, personal volume acceptance, updates, restoration, both agents, task separation, status, notifications, and native relay.
The [2026-10-27 restarts](runpod.md#restarts-on-2026-10-27) record refreshed endpoints, surviving task files, restore-only, and explicit agent restarts.
These results do not establish automatic endpoint rereading by an already reconnecting native transport; [#176](https://github.com/mal84emma/workgrove/issues/176) retains that check.

Codex sandbox namespace initialization failed; individual command approvals do not establish sandbox compatibility.
The exact denying runtime rule remains unverified; [#175](https://github.com/mal84emma/workgrove/issues/175) retains successful sandbox startup and boundary acceptance.
Claude's completed workflow does not establish operating-system sandbox isolation.
A replaced Pod on the same volume remains [optional, unverified lifecycle validation](runpod.md#optional-lifecycle-validation).
