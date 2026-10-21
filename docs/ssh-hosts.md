# Register an SSH fragment

Use `wt-ssh-host` to register an existing SSH connection fragment for workgrove.
A fragment is a local file containing connection settings without a `Host` section.
The helper uses ordinary SSH and does not contact a cloud API.

Existing usable SSH aliases require no registration.
The helper manages only its own marked regions in the selected SSH configuration.
The [implementation](../lib/workgrove/ssh_host.py) defines validation, registration, and local status behavior.

## Prerequisites

Install workgrove, Bash 5, Python 3, and OpenSSH.
Obtain a trusted fragment from the person or tool that manages the host.
Keep that fragment at a stable local path outside workgrove's ownership.
Verify the host key through your chosen SSH setup procedure before registration.
The helper requires strict host-key verification and does not accept unknown keys automatically.

Keep SSH configuration, keys, trust files, and backups outside Git repositories.
The helper refuses configuration writes inside Git working trees and Git administrative directories.
It also refuses linked backups and files with multiple hard links.
A read-only reference to a fragment inside another checkout is permitted.

## Register and inspect

Register a fragment with an alias of your choice:

```bash
wt-ssh-host add <host> --fragment <fragment-path>
wt-ssh-host list --json
```

The helper prepends a literal `Host` region to `~/.ssh/config`.
Its final `Host *` line restores global scope for preexisting settings.
Workgrove's existing discovery can then find that alias.
After remote preparation, use the ordinary `wt hosts` and `wt -H <host> ...` interfaces.
Registration alone does not install remote tools or establish remote readiness.
See the [VM setup guide](new-vm.md) and the [integration plan](runpod-integration.md) for preparation requirements.

Use `-F` before the subcommand to select another configuration:

```bash
wt-ssh-host -F <config-path> add <host> --fragment <fragment-path>
wt-ssh-host -F <config-path> list --json
wt-ssh-host -F <config-path> rm <host>
```

An alternate configuration supports testing and separate SSH clients.
Explicit `-F` follows OpenSSH's alternate-configuration behavior and excludes system configuration.
Workgrove's ordinary discovery still reads `~/.ssh/config`.
The helper preserves an existing configuration symlink when its physical destination passes the repository checks.
It refuses a dangling configuration symlink.

The helper validates the fragment before invoking OpenSSH, including `ssh -G`.
It compares effective endpoint, identity, and trust settings against the isolated registration.
Default validation includes system configuration, as ordinary workgrove connections do.
Conflicting inherited settings cause `effective-config-conflict`.
The helper restores the previous configuration and preserves its backup when default validation fails after writing.
If another process changes the candidate configuration, the helper refuses to overwrite that change.
The helper preserves unrelated configuration bytes and refuses explicit alias conflicts in the selected file.
Included user configuration retains normal OpenSSH semantics; effective settings must still pass comparison.

A changed configuration replaces `<config-path>.bak` with the previous configuration.
The helper writes configurations and backups atomically with mode `600`.
It creates missing parent directories with mode `700` and retains a private sibling lock file.
An unchanged registration leaves the configuration and backup untouched.
Alias comparisons ignore letter case and retain the registered spelling.

After writing, the helper makes one noninteractive SSH connection and runs `true`.
A successful command reports `registered and SSH verified`.
A failed connection reports `registered-but-unavailable`, returns a nonzero status, and retains the registration.
Check trust, credentials, endpoint readiness, and ordinary SSH separately before retrying.
The helper suppresses captured SSH diagnostics because they can contain confidential configuration.

## Supported fragment grammar

Use one directive per line, with one value per directive.
Keywords are case-insensitive; duplicate keywords are invalid.
Separate a keyword and value with whitespace or `=`.
Use double quotes for values containing spaces.
Comments begin with `#` outside double quotes.
Single quotes do not delimit values; literal apostrophes are permitted inside double-quoted paths.
Backslash escapes are unsupported in directive values.

| Directive | Accepted value |
|---|---|
| `HostName` | Required literal hostname or address; letters, digits, `.`, `_`, `:`, `@`, `+`, and `-`. |
| `User` | A literal username using the same characters as `HostName`. |
| `HostKeyAlias` | An opaque literal using those characters plus `/`, `[` and `]`. |
| `IdentityFile`, `UserKnownHostsFile` | One absolute path or a path starting with `~/`; quoted spaces are permitted. |
| `StrictHostKeyChecking` | `yes` only; the managed region also sets `yes` before the fragment. |
| `IdentitiesOnly`, `HashKnownHosts` | `yes` or `no`. |
| `Port` | An integer from 1 through 65535. |
| `ServerAliveInterval`, `ServerAliveCountMax`, `ConnectTimeout`, `ConnectionAttempts` | An integer from 0 through 86400. |
| `HostKeyAlgorithms` | A comma-separated algorithm list, optionally starting with `+`, `-`, or `^`; OpenSSH validates algorithm support. |

Encode a literal percent sign in a path as `%%`.
Other token expansion, environment expansion, glob patterns, and multiple path values are unsupported.
Paths cannot contain double quotes or backslashes.
`Host`, `Match`, nested `Include`, command directives, and unknown directives are invalid.
These limits keep the import grammar independent of any SSH supplier.

The fragment supplies file references; the helper never reads private keys or edits trust files itself.
OpenSSH can read those files during verification and apply the approved configuration's ordinary trust behavior.
The helper compares inherited identity and trust policy, including additional identity files and known-hosts commands.
Existing user-owned `Match exec` sections can execute during OpenSSH processing after fragment validation.
Only register trusted local configuration.

## Refresh, list, and remove

A supplier can update the fragment in place when an endpoint changes.
Run the same `add` command again to validate current settings and verify the connection.
A supplied `HostKeyAlias` becomes an opaque pin in the managed region.
A changed or removed pin requires independent identity verification, registration removal, and explicit registration again.
Adding a pin to a registration without one requires the same procedure.

An explicit `add` permits other validated connection-policy changes, including trust-file references.
Review supplier changes before registration.
Existing inherited policy must still match the approved fragment's effective policy.
A registration does not permanently validate future fragment revisions.
Ordinary SSH clients continue to consume the supplier's current file.
Workgrove revalidates imported fragments before remote commands, host inventory, and native SSH row creation.
It checks the selected managed alias's effective settings before each new connection.
Ordinary existing aliases retain normal OpenSSH behavior.
Independent SSH clients and an already reconnecting native transport remain outside this validation boundary.
Use `wt-ssh-host check <host>` for the same local check without connecting.

`list --json` returns an array containing `alias`, `fragment`, and `status`.
It reads local files only and never invokes SSH or enumerates a cloud account.
Possible status values are `configured`, `missing`, `invalid`, `unreadable`, and `identity-changed`.
`configured` means local validation passed; it does not establish reachability or remote readiness.
Treat aliases, fragment paths, and backups as confidential operational information.

Remove only the helper's registration:

```bash
wt-ssh-host rm <host>
```

Removal works even when the fragment is missing or invalid.
It preserves the fragment, keys, trust files, remote tasks, and compute.
A missing registration returns `unregistered-alias` without replacing the configuration.

## Offline verification

Run the registration tests:

```bash
bash test/ssh-host-smoke.sh
```

The [fixtures](../test/ssh_host_test.py) use synthetic settings, temporary configurations, and an SSH wrapper.
The wrapper delegates only `ssh -G` to OpenSSH and intercepts every connection attempt.
The tests make no network connections and do not use personal SSH configuration.
They cover fragment validation, effective policy, identity changes, atomic edits, repository boundaries, and confidential diagnostic suppression.
