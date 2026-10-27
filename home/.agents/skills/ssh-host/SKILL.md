---
name: ssh-host
description: Register a supplied SSH fragment or prepare an existing SSH host for workgrove's portable remote task workflow.
---

# Prepare an existing SSH host

Use this skill for supplied SSH fragments and portable host preparation, including Runpod hosts.
Compute creation, lifecycle operations, provider logins, and private launcher state remain outside this procedure.
For Azure ML endpoint registration, use the azml-compute skill; portable preparation can follow registration.

Read [SSH registration](../../../../docs/ssh-hosts.md) when an outer alias is missing.
Read [portable setup](../../../../docs/remote-setup.md) before installing or restoring a profile.
For Runpod storage and restart notes, read [the Runpod guide](../../../../docs/runpod.md).

1. Establish the authorized scope: registration, full preparation, or recovery under the [portable restore policy](../../../.claude/TASKS.md#portable-restore-only).
   Obtain the chosen alias and any supplied fragment path from the user or existing SSH configuration.
   Use an already usable alias directly; do not create a second provider registry.
2. When registration is requested, run `wt-ssh-host add <host> --fragment <path>`.
   Never edit SSH configuration by hand or bypass unknown or changed host keys.
   A verification failure can leave a registered alias; inspect it before retrying.
3. Before full preparation, obtain the persistent root, storage policy, public revision, and remote user's personal identity source.
   Confirm the actual mount for a volume policy.
   Confirm whether the user selects personal agent configuration persistence and workgrove's tmux settings.
   Do not infer these choices from an alias or private checkout layout.
   If volume permissions fail, obtain the user's acceptance before selecting `--trust-personal-volume` for that mount.
   Existing authorization for the same volume remains valid; read-only probes and restore-only cannot grant new acceptance.
4. When preparation is authorized, run the shared `wt -H <host> setup` procedure.
   Preserve redirected agent roots and stop on conflicting personal configuration.
   Never merge sign-ins, select shared identities, or place secrets in tracked files or task-copy hooks.
5. Run `wt -H <host> doctor --json` and fresh `wt hosts --json`.
   Report preparation separately from project authentication, agent sign-ins, hook trust, and native-row verification.
   Unknown allocation cannot satisfy hardware requirements.
6. Create or recover tasks only within the user's authorized scope.
   Use the task-driver skill for the ordinary remote task interface and hardware selection.
   Follow the [recovery policy](../../../.claude/TASKS.md#vm-task-recovery) before attach recovery or either explicit recovery flag.

After a host restart, refresh SSH through its supplier and follow the shared VM recovery procedure.
When doctor identifies lost setup, follow the [portable restore policy](../../../.claude/TASKS.md#portable-restore-only).
Missing task files require storage investigation; never create a replacement task as automatic recovery.
