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
Check SSH first and ask the supplier to refresh the endpoint if needed.
Run `wt -H <host> doctor --json` without `--root` to discover a surviving volume root.
Discovery must report exactly one matching root; otherwise, the user supplies it.

`root_discovery.same_machine` compares the current machine name with the last setup or restore record.
The name can change after a restart; workgrove never prints the recorded name.
The [discovery limits](remote-setup.md#check-readiness) include a filesystem call blocked by uninterruptible I/O.

Run doctor with the chosen root to see the real state:

```bash
wt -H <host> doctor --root <root> --json
```

When only compatibility links and environment were lost, restore them:

```bash
wt -H <host> setup --root <root> --restore-only
wt -H <host> doctor --json
```

Restore refuses a different saved alias before changing the home folder.
Its stderr summary reports the active root, alias, personal state, sign-in file presence, and saved Git link.
Agents follow the [portable restore policy](../home/.claude/TASKS.md#portable-restore-only) before restoring without asking.
The user handles host keys, sign-ins, full setup, and task recovery flags.

Restore-only backs up regular files that the host's start command writes in the home folder, including `~/.gitconfig`.
This command keeps the saved storage policy and volume trust when the root and mount are unchanged.
It reports each displaced home path and its backup folder relative to `<root>`.
An identical newest backup of the same path prevents another copy.
Directories, foreign symbolic links, and regular files at root-side link locations still cause refusal before any file changes.

If doctor reports missing prerequisites, use full setup with the saved root and storage policy.
Then inspect and attach selected tasks using the ordinary Azure VM attachment decisions.

Do not add installation commands to container entrypoints, supplier startup hooks, or shell startup files.
Do not restart every saved task automatically.
Keep relay sockets and native terminal identities on runtime storage.

## Verification status

Offline tests cover generic SSH registration, explicit restoration, allocation limits, and task recovery with synthetic fixtures.
The [October 21, 2026 evidence](https://github.com/mal84emma/workgrove/pull/95#issuecomment-6775489089) preserves the live results, tested revisions, failed sandbox acceptance, and limits.
Historical checks do not establish acceptance for the current host or agent version.
Use the [agent runtime compatibility checks](remote-setup.md#check-agent-runtime-compatibility) before unattended agent work.
Personal volume acceptance does not change sandbox requirements, and Claude workflow completion does not establish operating-system isolation.

### Restart on 2026-10-22

Home replacement can remove links while persistent task files survive; ordinary home files can block older restore-only implementations.
[Issue #140](https://github.com/mal84emma/workgrove/issues/140) preserves the October 22, 2026 results and tested revision.
[PR #143](https://github.com/mal84emma/workgrove/pull/143) records that endpoint changes and recovery of tasks running before the stop were not tested.
Use the [current recovery procedure](#recover-after-stopstart) for restoration decisions.

### Restarts on 2026-10-27

Restoration preserves task files; lost agents require explicit restart, and Codex restart does not promise conversation resume.
[Issue #142's results](https://github.com/mal84emma/workgrove/issues/142#issuecomment-6441814307) preserve both October 27, 2026 cycles, versions, backup behavior, and unperformed checks.
These checks do not establish automatic endpoint rereading by an existing native transport; [#176](https://github.com/mal84emma/workgrove/issues/176) retains that question.

### Sandbox compatibility check

Namespace startup failure prevents sandbox boundary acceptance; unchanged outside canaries cannot establish enforcement when the sandbox never starts.
The [archived probe matrix](https://github.com/mal84emma/workgrove/pull/95#issuecomment-6775489089) preserves the failed Codex 0.163.0 and Bubblewrap 0.9.0 checks.
The exact denying runtime rule remains unverified; [#175](https://github.com/mal84emma/workgrove/issues/175) retains successful startup and boundary acceptance.

### Remediation investigation

The [historical investigation](https://github.com/mal84emma/workgrove/pull/95#issuecomment-6775489089) separates control-socket permissions from namespace denial and retains the system-call-filter hypothesis as unverified.
Moving persistent files cannot repair a namespace denial reproduced on ordinary operating-system storage.
The execution-environment owner must identify the denying policy and provide compatible namespace support.

The [official sandbox prerequisites](https://learn.chatgpt.com/docs/sandboxing) describe Bubblewrap's user-namespace requirement.
[Docker's seccomp documentation](https://docs.docker.com/engine/security/seccomp/) lists namespace operations among its default restrictions.
Inherited filters survive child processes and executable changes; see [seccomp(2)](https://man7.org/linux/man-pages/man2/seccomp.2.html).
A template start command cannot remove those outer runtime restrictions.

Ask the supplier whether the selected environment supports restricted nested namespaces.
Provide sanitized no-op failures and request identification of the denying host rule.
If supported, validate a narrowly reviewed policy before changing the host's production setup.
Repeat startup, permitted task writes, prohibited outside writes, and network-policy checks after that repair.
Keep the persistent storage layout unchanged while investigating runtime compatibility.

Codex 0.163.0 [rejects its deprecated Landlock option](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/linux-sandbox/src/linux_run_main.rs#L382-L388) for filesystem-restricted execution.
Installing Bubblewrap again cannot repair a denial that reproduces independently of its installation.
Disabling isolation or granting broad privileges changes the security model; it does not establish the required sandbox behavior.

If the supplier cannot provide compatible namespace support, run Codex in a verified compatible environment and use the Pod for GPU commands.
That alternative changes the execution location; it does not validate Codex isolation inside the Pod.

### Optional lifecycle validation

A replaced Pod on the same volume remains unverified in the [lifecycle evidence](https://github.com/mal84emma/workgrove/issues/142#issuecomment-6441814307).
Further lifecycle validation requires separate authorization and a bounded compute budget.
