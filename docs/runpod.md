# Use a Runpod host for remote tasks

A Runpod host uses workgrove's ordinary SSH task interface after explicit remote preparation.
Workgrove requires no provider-specific registry, launcher import, or connection export schema.
Use the [shared SSH registration guide](ssh-hosts.md) and [portable setup procedure](remote-setup.md).

## Prepare the existing host

Obtain the alias or a stable SSH fragment path from the person or tool managing the host.
That supplier owns compute lifecycle, billing, endpoint refresh, credentials, and host trust.
Workgrove never calls the provider API or reads private launcher state.

If an outer SSH alias is missing, register the supplied fragment:

```bash
wt-ssh-host add <host> --fragment <fragment-path>
```

Select persistent storage whose retention policy you have independently verified.
`/workspace` is a useful root only when the expected persistent storage is actually mounted there.
Do not treat a directory's name as evidence of persistence.
Use `--storage volume` with the actual mount path for a persistent volume.
Use `--storage os-disk` only when the underlying operating-system disk has the required retention guarantee.
If volume permissions fail, follow the generic [personal volume policy](remote-setup.md#trust-a-personal-volume).
Explicit acceptance applies only to the selected mount and belongs in the private profile.

Run the shared setup command with a reviewed public workgrove source and full revision:

```bash
wt -H <host> setup --root <root> --storage volume --mount <mount> \
  --source <public-workgrove-https-url> --revision <full-commit> \
  --persist-agents --with-tmux-conf
wt -H <host> doctor --json
wt hosts --json
```

Complete personal agent authentication and native-row verification through the shared setup guide.
Resolve conflicting personal configuration privately; do not copy credentials into project worktrees or tracked files.
Use the same personal identities that the user established for SSH, Git, and their agents.

## Use ordinary tasks

The host retains the same interfaces as an Azure VM or Azure ML compute instance:

```bash
wt -H <host> repos --porcelain
wt -H <host> new <task> -r <repo> -a codex --no-workspace --prompt-stdin < <brief-file>
wt -H <host> attach <task> -r <repo>
wt -H <host> show <task> -r <repo> --json
wt -H <host> open <task> -r <repo>
```

Rows use the normal task title and `@<host> · <repo>` description.
The picker, deferred uploads, saved agents and models, scoped removal, and VM-side editor requests retain their existing procedures.
For hardware selection, use fresh inventory and the [task-driver skill](../home/.agents/skills/task-driver/SKILL.md).
Unknown or hidden container allocation cannot qualify for automatic hardware selection.
An explicit alias remains usable independently of that selection decision.

## Recover after stop/start

A disconnect, a host restart, and deletion are different recovery events.
A disconnect can leave tmux and agents alive; inspect their state before choosing recovery.
A host restart can preserve files while losing processes, packages, and home-directory links.
Deletion or persistent-storage loss cannot be repaired through `wt attach`.
Verify lifecycle and storage guarantees through the supplier's documentation.

After an authorized stop/start, follow the [shared VM recovery checklist](remote-setup.md#restore-after-a-host-restart).
Refresh SSH first, check doctor, and repair only missing environment.
Use restore-only when compatibility links were lost; use full setup when prerequisites were also lost.
Then inspect and attach selected tasks using the ordinary Azure VM attachment decisions.

Do not add installation commands to container entrypoints, supplier startup hooks, or shell startup files.
Do not restart every saved task automatically.
Keep relay sockets and native terminal identities on runtime storage.

## Verification status

Offline tests cover generic SSH registration, explicit restoration, allocation limits, and task recovery with synthetic fixtures.
The following live results come from one active Pod on 2026-10-21, using workgrove revision `265acbd`.
Paths, host aliases, identities, and private operational captures are omitted.

| Check | Result |
|---|---|
| SSH registration and discovery | Passed isolated validation, authorized registration, ordinary discovery, and strict SSH verification. |
| Hardware inventory | The visible GPU matched `nvidia-smi`. Hidden cgroup mounts left CPU and RAM unknown and prevented automatic capacity selection. |
| Persistent setup | Passed with explicit personal volume acceptance. The FUSE filesystem reports mode `777` despite `chmod 700`. |
| Idempotence and update | Repeated setup preserved configuration. A reviewed `wt update` preserved authentication and task files. |
| Readiness and restoration | Doctor detected a deliberately removed compatibility link. Explicit restore-only repaired it and preserved 11 saved identity, configuration, and task files. |
| Deferred tasks and uploads | Both agent tasks retained their briefs and verified uploaded files before attachment. |
| Native rows and reconnection | Both rows connected. Their original tmux sessions survived a Wi-Fi interruption. |
| Codex task | Produced the exact requested file and passed its Python assertion using individual command approvals. |
| Reattachment and status | The same Codex process survived row closure and plain attach. Its response, Idle status, and completion notification reached the replacement row. |
| Replacement row title | One replacement showed an unexpected title. Separate native SSH and tmux replacement checks did not reproduce it; its cause remains unverified. |
| Editor requests | Mac-side open and VM-side relay opened the correct connected VS Code windows. |
| Scoped removal | Removed a separate clean task's worktree, branch, and sidecar while preserving both original tasks and sessions. |
| Claude task completion | Pending because the account reached its usage limit. Authentication, fullscreen startup, and Needs input status passed. |
| Agent sandboxing | Blocked. Codex 0.163.0 could not create its sandbox namespaces; a no-op sandbox probe failed. |
| Actual stop/start and endpoint refresh | Unverified. No provider API or lifecycle action ran. |

Codex required the supported `--no-daemon` launch option because its control socket rejected the volume's directory permissions.
That option preserved sandbox policy; individual approvals ran the acceptance commands outside the failed sandbox.
Follow the [agent runtime compatibility checks](remote-setup.md#check-agent-runtime-compatibility) before treating an installation as ready for unattended agent work.
The personal volume exception does not change agent sandbox requirements.

Actual lifecycle acceptance requires separate authorization and a bounded compute budget.
It must verify retained task files, endpoint refresh, environment repair, and explicit restart of selected lost agents.
