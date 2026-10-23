# Read task status as JSON

Use `wt list --json` or `wt show <name> --json` to read task status in scripts.
Both commands accept `-r <repo>` and work over `wt -H <host>`.
Neither command fetches Git refs.

`wt list --json` returns an array of task objects, including `[]` when no tasks exist.
With `--all`, it combines tasks from every repository in `WT_REPOS_DIR` into one array.
`wt show <name> --json` returns one task object.

Both commands include these fields:

| Field | Type | Meaning |
|---|---|---|
| `name` | String | The task name. |
| `repo` | String | The absolute main checkout path. |
| `path` | String | The absolute task worktree path. |
| `branch` | String | The task branch used for comparisons. |
| `checkout_branch` | String or null | The current checkout branch, or null for a detached or unavailable checkout. |
| `base` | String | The effective comparison base. |
| `ahead`, `behind` | Integer or null | Commit counts for the task branch against the base, or null when unavailable. |
| `dirty` | Integer or null | The Git status entry count, or null when unavailable. This count includes setup output. |
| `last_commit_at` | String or null | The checkout HEAD commit's ISO 8601 committer timestamp with a timezone offset, or null when unavailable. |
| `merged` | String | The existing verdict: `yes`, `squash`, `no`, or `?`. |
| `why` | String | The merge explanation, or an empty string when none exists. |

Show also includes these string fields:

| Field | Meaning |
|---|---|
| `title` | The task's row title. |
| `task` | The first line of the saved brief. |
| `model` | The saved agent model. |

Missing brief and model values become empty strings. A missing title defaults to the task name.
Consumers must accept additional fields. The initial schema has no version field.

A successful command writes one JSON document to standard output.
Errors write diagnostics to standard error and return a nonzero exit status, without partial JSON.
An unreadable sidecar stops the command and names the file.
A missing sidecar uses the command defaults.
The `--json` and `--diff` flags cannot be combined.

New sidecars store `includes` and `setup` as arrays of `path:sha256` strings.
The reader also accepts older sidecars that store these records as newline-joined strings.

## Read installation versions

`wt version` returns one JSON object. `wt -H <host> version` returns the VM's object.
`commit` is the short repository commit, or `unknown` when the installation has no `.git`.
`protocol` is the highest supported task result version, currently the integer `1`.
Both commands accept no arguments.

`wt hosts --json` adds two flat fields to each host object:

| Field | Type | Meaning |
|---|---|---|
| `wt_commit` | String or null | The VM's reported commit, or null when unavailable. |
| `wt_protocol` | Integer or null | The VM's reported protocol number, or null when unavailable. |

An older VM without `wt version` can still have available hardware information.
Its version fields are null. An unreachable VM also has null version fields.
Version readers require exactly one JSON object with both correctly typed fields.
Malformed reports produce null values for both fields.
The Mac supplies the same validator to both VM probes.

## Read update records

Updates retain their existing output and add one JSON object per version report.
These objects are separate lines among ordinary output, rather than one JSON document.

| Field | Type | Meaning |
|---|---|---|
| `event` | String | Always `wt_update`. |
| `stage` | String | `before` or `after` the pull. |
| `side` | String | `local` for direct updates; `Mac` or `VM` for remote comparisons. |
| `commit` | String or null | The reported commit, `unknown` for a seed, or null when unavailable. |
| `protocol` | Integer or null | The reported protocol number, or null when unavailable. |

Remote updates report both sides before and after the remote update succeeds.
The VM's update can also print its own `local` records.
Older VMs without `wt version` have null commit and protocol values.
The Mac still runs their update command.
Failed or canceled updates can stop before the `after` records.
A final reporting failure preserves the successful update status and prints a diagnostic.
The VM's `after` record then has null commit and protocol values.
Consumers must accept additional fields in all version and update objects.

## Read effective host capacity and readiness

`wt hosts --json` retains `status: "available"` for successful remote-command SSH probes.
That status alone does not establish workgrove readiness or usable container allocation.
The Mac supplies the current public probes independently of the remote installation version.

| Field | Type | Meaning |
|---|---|---|
| `cpu_logical` | Integer or null | Whole usable logical CPUs after affinity, online CPU sets, and applicable cgroup quotas. A verified fractional allocation can produce zero. |
| `memory_mib` | Integer or null | The smaller physical or applicable cgroup memory limit, rounded down to MiB. |
| `capacity_verified` | Boolean or null | Whether the enhanced probe established both CPU and RAM allocation; null identifies a legacy report. |
| `capacity_issues` | Array of strings | Fixed issue codes for missing, malformed, or hidden kernel limit views. |
| `environment` | String | `host`, `container`, or `unknown`; independent of the SSH alias or supplier. |
| `workgrove_ready` | Boolean or null | Basic portable readiness; null means legacy or unavailable capability. |
| `readiness_status` | String | `ready`, `incomplete`, `legacy`, or `unknown`. |
| `readiness_issues` | Array of strings | Fixed preparation issue codes; these contain no personal configuration values. |
| `gpu_allocation_verified` | Boolean or null | Whether whole visible GPU allocation was verified; false excludes automatic GPU selection. |

The [kernel probe](../lib/workgrove/vm/capacity.py) reads cgroup versions 1 and 2 and their visible ancestors.
It uses hard memory limits, not current usage, requested cloud hardware, or cgroup memory throttling thresholds.
The Linux kernel documents [hierarchical limits and namespaces](https://docs.kernel.org/admin-guide/cgroup-v2.html).
A private cgroup namespace can hide stricter ancestor bounds.
Hidden bounds produce null effective values and `capacity_verified: false`.

The probe recognizes an exposed initial v2 root through controller availability and the absence of non-root limit interfaces.
The v1 probe requires the root-only `cgroup.sane_behavior` interface on each selected mount.
The [kernel's v1 file definitions](https://github.com/torvalds/linux/blob/v5.15/kernel/cgroup/cgroup-v1.c#L592-L595) restrict that interface to the initial root.
Non-root limit interfaces expose potentially hidden ancestors even when container markers are absent.
It refuses to certify a container's incomplete hierarchy as a full host allocation.
A malformed enhanced report also becomes unverified; physical host values never replace its unknown effective values.
Legacy reports without the enhanced protocol retain their previous CPU and RAM interpretation.

GPU inventory retains `gpu_status`, `gpus`, names, and nullable `memory_mib` values.
Enhanced NVIDIA queries check device UUIDs, partition mode, virtualization mode, and visible sharing indicators.
The [NVIDIA system management documentation](https://docs.nvidia.com/deploy/nvidia-smi/index.html) describes these read-only hardware queries.
Unambiguous visibility filters restrict the returned device list.
GPU partitions, ambiguous CUDA ordinals, or detected fractional sharing cannot qualify for automatic GPU selection.
A driver-visible inventory does not promise scheduling reservations or exclusive future access.

Hardware selection requires sufficient known capacity, `capacity_verified != false`, and `workgrove_ready != false`.
GPU requests additionally require `gpu_allocation_verified != false`.
Null or absent capability fields preserve legacy compatibility.
Repository and selected-agent checks still run immediately before task creation.

`wt -H <host> doctor --json` returns the read-only readiness object directly.
It can report missing remote tools or links without invoking the remote `wt` executable.

`compatibility-links-missing` identifies links that restore-only can repair, including regular files at home link locations.
`compatibility-links-conflict` identifies link locations that restore-only refuses: directories, foreign symbolic links, and regular root-side files.
Both codes can appear in `issues` and inventory's `readiness_issues` when different locations need different repairs.

Its `ready` value excludes separate personal sign-ins, native relay verification, and hook trust decisions.

`warnings` is an array of codes that do not change `ready`, `status`, `issues`, or the exit status.
It contains `agent-command-unavailable` when a saved, non-null `agent_commands` path does not resolve to an executable regular file.
A missing target, dangling symbolic link, directory, or non-executable file causes this warning.
Doctor checks the saved path without using PATH or running the command.
The warning contains no path.
Saved paths with executable regular-file targets, null entries, and a missing profile cause no warning.

Text output prints each warning, and the `--probe` readiness line includes `warnings`.
The `wt hosts --json` fields remain unchanged.

`storage_permission_policy` is `strict`, `trusted-personal-volume`, or null when no portable profile is available.
`storage_permission_warnings` contains `unix-mode-checks-relaxed` when the user accepted a personal volume exception; otherwise it is empty.
These fields describe the saved policy, including when other readiness checks fail.
Readiness under an accepted policy does not certify filesystem privacy or exclusive volume access.
See [portable setup](remote-setup.md#check-readiness) for the repair and verification procedure.
