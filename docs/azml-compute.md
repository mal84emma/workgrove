# Azure ML compute instances over ssh

An Azure ML compute instance that was created with SSH enabled is an ordinary Linux host. It has one public
IP address, a port of its own, an admin user, and one public key, all fixed when the instance was created.
Everything the VS Code Azure ML extension does when it connects can be replaced by a `Host` block in
`~/.ssh/config`, after which `ssh <instance>`, VS Code Remote-SSH, the `wt task` picker and
`wt -H <instance> …` all work, because they all read that one file.

`bin/azml-ssh-host` writes that block for you: it reads the facts from Azure Resource Manager, matches the
registered key against the keys in `~/.ssh`, writes its own marked region of the config, and verifies the
result with one non-interactive login.

## Prerequisites

| Requirement | Why | Check |
|---|---|---|
| Azure CLI, logged in | The helper reads the compute resource with `az rest` | `az account show` |
| Reader on the workspace | Lets that GET return the resource instead of 403 | `azml-ssh-host list` shows the instance |
| `jq` | Parses the ARM response | `jq --version` |
| OpenSSH (`ssh`, `ssh-keygen`) | Connects, and compares key fingerprints | `ssh -V` |
| A local private key | Its public half must be the one registered on the instance | The key sits in `~/.ssh` |
| SSH enabled at creation | Cannot be turned on afterwards | `sshSettings.sshPublicAccess` is `Enabled` |

The Azure CLI and `jq` come from the `Brewfile` on the Mac, and `az login` is one of the logins in
[new-mac.md](new-mac.md). On an Azure ML compute instance itself az is preinstalled: the VM page's install line
is skipped by its own guard, so it only logs in.

## Usage

```bash
azml-ssh-host add <instance>     # write or update the block, then verify
azml-ssh-host list               # every SSH-enabled compute instance the account can see
azml-ssh-host rm <instance>      # remove the block again
azml-ssh-host help
```

`-F <file>` before the subcommand points the helper at another ssh config. A first run looks like this:

```
$ azml-ssh-host add ci-example
wrote Host ci-example to ~/.ssh/config
connected as azureuser on ci-example
ci-example: azureuser@203.0.113.10:50000, key ~/.ssh/azml-key, config ~/.ssh/config
now: wt task (⌃⌥⌘T) -> ci-example, or wt -H ci-example …
```

Run it again and the first line becomes `unchanged: Host ci-example is already correct`, followed by the same
verification. If the instance was rebuilt with a different IP, the block is rewritten at the top of the file.

## What it writes

```
# >>> azml-ssh-host <instance>
# Azure ML compute instance in workspace <workspace>
Host <instance>
  HostName <ip>
  Port <port>
  User <admin user>
  IdentityFile ~/.ssh/<key>
  IdentitiesOnly yes
  ServerAliveInterval 30
  ServerAliveCountMax 6
  AddKeysToAgent yes
  UseKeychain yes
# <<< azml-ssh-host <instance>
```

The block sits at the top of the file so that nothing earlier can override it: ssh keeps the first value it is
given for each setting, so a `Host *` or `Match host …` further up would otherwise decide the user or the port.
The markers delimit the only region the helper ever changes. Everything else stays byte for byte as it was, and
`rm` puts the file back exactly as `add` found it. A `Host` or `Match` line naming the instance outside the
markers is refused rather than edited, and markers that do not pair are refused rather than repaired.
`IdentitiesOnly yes` stops ssh offering every agent key first. `UseKeychain yes` is the only macOS-only line.

## Gotchas

- Compute instances are not VMs. `az vm list` never shows them. They live under the workspace, as
  `Microsoft.MachineLearningServices/workspaces/<workspace>/computes/<instance>`.
- An instance name is unique only inside its workspace, so the helper tries every workspace it can see in the
  current subscription and takes the first that answers. Use `az account set -s <other>` yourself when the
  instance lives in another subscription.
- The port is per instance and is not 22. It comes from `sshSettings.sshPort`.
- The IP is fixed for the life of the instance and survives a stop and start in practice, but the resource is
  the only authority. If `ssh <instance>` stops connecting, run `azml-ssh-host add <instance>` again.
- A recreated instance with the same name gets a new host key, and ssh then refuses to connect. The helper
  prints the line to run: `ssh-keygen -R '[<ip>]:<port>'`, after which `add` works again.
- `UseKeychain` is a macOS option; Linux OpenSSH rejects it, so the helper writes it only on a Mac.
  `AddKeysToAgent` is valid on both and is always written.
- The `az ml` extension is not used: it can send an unsupported api-version, so every call goes through
  `az resource list` and `az rest` with the version written out.
- The key cannot be changed on an existing instance. Create instances with a public key whose private half is
  already in `~/.ssh`.

## In this setup

Once `add` has verified the login, the instance is a VM like any other here: give it the same treatment as a
fresh VM with [new-vm.md](new-vm.md), using `<instance>` as the alias it asks for. After that it appears in
the ⌃⌥⌘T picker, and `wt -H <instance> new -r <repo> -p "…"` starts tasks on it with their rows on the Mac.
