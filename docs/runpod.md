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
The following live results come from one active Pod on 2026-10-21.
The remote installation reached workgrove revision `265acbd` through the tested update procedure.
Replacement row checks also used shared adapter revision `02e1564` on the Mac.
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
| Replacement row title | Focused creation reproduced an unexpected generated title. The shared adapter fix preserved the task title by creating unfocused before explicit selection. |
| Editor requests | Mac-side open and VM-side relay opened the correct connected VS Code windows. |
| Scoped removal | Removed a separate clean task's worktree, branch, and sidecar while preserving both original tasks and sessions. |
| Claude task completion | Pending because the account reached its usage limit. Authentication, fullscreen startup, and Needs input status passed. |
| Agent sandboxing | Blocked. Codex 0.163.0 could not create its sandbox namespaces; a no-op sandbox probe failed. |
| Actual stop/start and endpoint refresh | Unverified. No provider API or lifecycle action ran. |

Codex required the supported `--no-daemon` launch option because its control socket rejected the volume's directory permissions.
That option preserved sandbox policy; individual approvals ran the acceptance commands outside the failed sandbox.
Follow the [agent runtime compatibility checks](remote-setup.md#check-agent-runtime-compatibility) before treating an installation as ready for unattended agent work.
The personal volume exception does not change agent sandbox requirements.

### Sandbox compatibility check

Further live checks reproduced the failure with Codex 0.163.0 and system Bubblewrap 0.9.0.
All ten Codex probes failed before their test commands started.
They used only disposable canary files and made no model requests.

| Check | Result |
|---|---|
| Existing and clean Codex configuration | Four startup probes failed across the persistent task directory and temporary storage. |
| Explicit `:workspace` and `:read-only` profiles | Six write probes failed across persistent and ordinary operating-system storage before executing their child commands. |
| Direct system Bubblewrap | A read-only no-op invocation failed independently of Codex and workgrove. |
| Namespace creation | User, mount, process, and network namespace probes each returned `Operation not permitted`. |
| Storage controls | The container root, temporary directory, and home cache used overlay storage. Namespace creation failed on overlay storage and the persistent FUSE volume. |
| No-op system call | `unshare(0)` returned `EPERM` without requesting namespace changes or filesystem operations. |
| Kernel settings | Unprivileged user namespaces were enabled, their configured limit was nonzero, and the AppArmor unprivileged-user-namespace restriction was disabled. |
| Container controls | Seccomp system-call filtering was active, and the system-administration capability (`CAP_SYS_ADMIN`) was absent. The blocking runtime rule remains unverified. |
| Unsandboxed controls | Disposable canary writes passed. Personal Codex configuration remained unchanged. |

The failure reproduces outside workgrove's launcher and outside the persistent volume.
It prevents testing both successful workspace writes and rejection of writes outside the workspace.
Unchanged outside canaries do not establish protection when the sandbox never starts.

This Pod therefore does not pass Codex sandbox acceptance.
The execution-environment owner must provide compatible namespace support before those boundary checks can pass.
The [official sandbox prerequisites](https://learn.chatgpt.com/docs/sandboxing) describe Bubblewrap's user-namespace requirement.
These checks changed no container policy, kernel setting, personal sandbox setting, or agent process.

### Remediation investigation

An independent agent reviewed the runtime evidence, public provider documentation, and the installed Codex version's source.
The shared persistent volume does not explain the namespace failure.
The separate control-socket permission failure explains the `--no-daemon` option.
Moving persistent files cannot repair the reproduced namespace denial on overlay storage.

The outer container's system-call filter is the leading explanation; the exact blocking rule remains unverified.
[Docker's seccomp documentation](https://docs.docker.com/engine/security/seccomp/) lists namespace operations among its default restrictions.
The no-op `unshare(0)` denial strengthens this explanation without identifying the actual host policy.
The host owner must inspect its runtime configuration or audit records to identify that policy.

The [public Pod API](https://docs.runpod.io/api-reference/pods/POST/pods) documents no seccomp, AppArmor, or capability override.
No supported self-service runtime-policy control was established by this investigation.
This documentation gap does not prove that the supplier cannot provide a compatible environment.
The [template start command](https://docs.runpod.io/pods/templates/manage-templates) changes container command execution, not the outer runtime's security policy.
Linux preserves inherited filters across child processes and executable changes; see [seccomp(2)](https://man7.org/linux/man-pages/man2/seccomp.2.html).

Ask the supplier whether this Pod class supports Bubblewrap's nested namespaces under a restricted runtime policy.
Provide sanitized no-op failures and request identification of the denying host rule.
If supported, validate a narrowly reviewed policy before changing the host's production setup.
Repeat startup, permitted task writes, prohibited outside writes, and network-policy checks after that repair.
Keep the persistent storage layout unchanged while investigating runtime compatibility.

Codex 0.163.0 cannot use its deprecated Landlock option for filesystem-restricted execution.
Its [versioned implementation](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/linux-sandbox/src/linux_run_main.rs#L382-L388) explicitly rejects that combination.
Installing Bubblewrap again or changing an already permissive user-namespace setting would not address the observed denial.
Disabling agent isolation or granting broad container privileges changes the security model; it does not establish the required sandbox behavior.

If the supplier cannot provide compatible namespace support, run Codex in a verified compatible environment and use the Pod for GPU commands.
That alternative changes the execution location; it does not validate Codex isolation inside the Pod.

### Optional lifecycle validation

Stop/start recovery is optional follow-up validation for this integration.
Actual lifecycle acceptance requires separate authorization and a bounded compute budget.
It must verify retained task files, endpoint refresh, environment repair, and explicit restart of selected lost agents.
