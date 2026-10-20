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
