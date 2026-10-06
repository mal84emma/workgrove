# Azure ML compute instances over ssh

This page tells you how to use an Azure ML compute instance as an ordinary ssh host.

An Azure ML compute instance that was created with SSH enabled is an ordinary Linux host. It has:

- one public IP address
- a port of its own
- an admin user
- one public key

All four are fixed when the instance is created. A `Host` block in `~/.ssh/config` can replace everything that the
VS Code Azure ML extension does when it connects. With that block, these all work, because they all read that
one file:

- `ssh <instance>`
- VS Code Remote-SSH
- the task picker (`wt task`, ⌃⌥⌘T)
- `wt -H <instance> …`

`bin/azml-ssh-host` writes that block for you. It:

1. reads the facts from Azure Resource Manager (ARM)
2. matches the registered key against the keys in `~/.ssh`
3. writes its own marked region of the config
4. verifies the result with one non-interactive login

## Prerequisites

| Requirement | Why | Check |
|---|---|---|
| `azml-ssh-host` on PATH | The helper itself; `install.sh` links it into `~/.local/bin` | `command -v azml-ssh-host` (see below if it is missing) |
| Azure CLI, logged in | The helper reads the compute resource with `az rest` | `az account show` |
| Reader on the workspace, and the workspace visible in the subscription | The helper finds the workspace and then reads the instance (see below) | See [The Reader role](#the-reader-role) |
| `jq` | Parses the ARM response | `jq --version` |
| OpenSSH (`ssh`, `ssh-keygen`) | Connects, and compares key fingerprints | `ssh -V` |
| A local private key | Its public half must be the one registered on the instance | The key sits in `~/.ssh` |
| SSH enabled at creation | Cannot be turned on afterwards | `sshSettings.sshPublicAccess` is `Enabled` |

### Before you create an instance

Create the instance with SSH enabled and with a public key whose private half is already in `~/.ssh`. You cannot
turn on SSH or change the key afterwards.

### If `azml-ssh-host` is missing

Run `wt update`. It re-runs `install.sh`, which links the helper.

### The Reader role

The helper finds workspaces with `az resource list` and then reads the instance under one of them. Without the
Reader role, the workspace is invisible and the helper's ARM GET request returns a 403. To check this requirement:

- `az resource list --resource-type Microsoft.MachineLearningServices/workspaces -o table` lists the workspace.
- `azml-ssh-host list` shows the instance.

### Where `jq` and the Azure CLI come from

On the Mac, `jq` comes from the `Brewfile`. The `Brewfile` also has a `brew "azure-cli"` line, but that line is
commented out. The reason is that this helper is the only thing in the repo that needs the Azure CLI. To install the Azure CLI, do one of these:

- Uncomment that line and rerun `brew bundle --file ~/repos/workgrove/Brewfile`.
- Run `brew install azure-cli`.

Then run `az login`, which is one of the logins in [new-mac.md](new-mac.md).

On an Azure ML compute instance itself, az is preinstalled. Its own guard skips the Azure install in block 4 of
[new-vm.md](new-vm.md), so that step only logs in.

## Usage

```bash
azml-ssh-host add <instance>     # write or update the block, then verify
azml-ssh-host list               # every SSH-enabled compute instance the account can see
azml-ssh-host rm <instance>      # remove the block again
azml-ssh-host help
```

To point the helper at another ssh config, put `-F <file>` before the subcommand.

A first run looks like this:

```
$ azml-ssh-host add ci-example
wrote Host ci-example to ~/.ssh/config
connected as azureuser on ci-example
ci-example: azureuser@203.0.113.10:50000, key ~/.ssh/azml-key, config ~/.ssh/config
now: wt task (⌃⌥⌘T) -> ci-example, or wt -H ci-example …
```

The `connected as …` line shows that the verification login worked.

When you run it again, the first line becomes `unchanged: Host ci-example is already correct in ~/.ssh/config`.
The same verification follows. If the instance was rebuilt with a different IP, the helper rewrites the block at
the top of the file.

## What it writes

```
# >>> azml-ssh-host <instance>
# Azure ML compute instance <instance> in workspace <workspace>, resource group <resource group>
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

### Why the block is at the top

The block sits at the top of the file so that nothing earlier can override it. The ssh client keeps the first
value that it gets for each setting. If the block were lower, a `Host *` or `Match host …` line above it would
decide the user or the port.

### How the helper changes the file

- The markers enclose the only region that the helper ever changes. Everything else stays byte for byte as it was.
- `rm` restores the content exactly as `add` found it.
- The helper normalizes the mode to 600 whenever it writes the file. So a config that was 644 comes back 600.
- The helper builds the new file in full beside the target and then renames it onto the target.
- Before it renames the new file onto the target, the helper copies the file that it replaces to
  `~/.ssh/config.bak`, also with mode 600.
- The helper never truncates the file in place. So an interrupt or a failed write costs you neither the config nor
  a line of it. What is there is either the old file or the new one.
- The helper refuses a `Host` or `Match` line that names the instance outside the markers. It does not edit it.
- The helper refuses markers that do not pair. It does not repair them.

### `IdentitiesOnly`, `UseKeychain` and `AddKeysToAgent`

- `IdentitiesOnly yes` stops ssh from offering every agent key first.
- `UseKeychain yes` is the only macOS-only line. Linux OpenSSH rejects it, so the helper writes it only on a Mac.
- `AddKeysToAgent` is valid on both and the helper always writes it.

## Migrating a hand-written block

If `~/.ssh/config` already holds a `Host <instance>` block that you wrote yourself, `add` refuses to edit it:

```
azml-ssh-host: Host ci-example is already in ~/.ssh/config and was not written by azml-ssh-host.
  Delete that Host block and the comment above it, keep the alias, then re-run: azml-ssh-host add ci-example
```

### Replace the block

The helper does not edit the file for you. Do these steps:

1. Delete the block and any comment lines above it. This includes a note about the instance at the very top of the
   file. The helper inserts the managed block at line 1, so those lines would end up describing it.
2. Keep the alias exactly as it was. It is the Azure resource name that the lookup uses. It is also the name that
   the task picker, `wt -H <instance> …` and VS Code Remote-SSH already know.
3. Run `azml-ssh-host add <instance>`.

### What you gain

You gain the two keepalive lines, `ServerAliveInterval 30` and `ServerAliveCountMax 6`. A hand-written block
usually does not have them.

- **Without them**, an idle session that carries tmux or VS Code Remote-SSH hangs silently when a NAT or a router
  drops the connection. The client stays there with a dead socket.
- **With them**, the client gives up after about three minutes. VS Code then reconnects on its own. cmux usually
  reconnects after sleep or a brief dropout.

After a Wi-Fi network switch, a cmux row can stay suspended, because its old server-side SSH session still holds
the row's relay port. The relay is cmux's channel from a VM row back to the Mac. To recover a task row, run
`wt -H <instance> attach -r <repo> <name>` (see [Recover a VM row](../README.md#recover-a-vm-row) in the README).

## Gotchas

### Finding the instance

- Compute instances are not VMs. `az vm list` never shows them. They live under the workspace, as
  `Microsoft.MachineLearningServices/workspaces/<workspace>/computes/<instance>`.
- An instance name is unique only inside its workspace. So the helper tries every workspace that it can see in the
  current subscription and takes the first that answers.
- When the instance lives in another subscription, run `az account set -s <other>` yourself.
- The port is per instance and is not 22. It comes from `sshSettings.sshPort`.
- The IP is fixed for the life of the instance and survives a stop and start in practice. But only the Azure
  resource is a reliable source for the IP. If `ssh <instance>` stops connecting, run
  `azml-ssh-host add <instance>` again.

### Host keys

- The helper accepts, without a prompt, the first host key that an instance offers (trust on first use). The
  verification login connects with `StrictHostKeyChecking=accept-new`. So ssh records the key in
  `~/.ssh/known_hosts`, and the login goes through.
  - The reason: compute instances are created and destroyed constantly. A fresh one always presents a key that
    nothing has seen before. A prompt at every `add` would only teach you to answer yes without reading it.
  - The cost is the usual one: someone who can intercept that first connection could give you their key instead.
  - ssh still refuses a key that changes afterwards (see the next item).
- A recreated instance with the same name gets a new host key, and ssh then refuses to connect. To fix this, run
  the line that the helper prints: `ssh-keygen -R '[<ip>]:<port>'`. After that, `add` works again.

### Errors

- A 403, an expired token and a name that does not exist all show as the same "not found". The helper
  does not distinguish them.
- If `azml-ssh-host list` prints nothing at all, the problem is permissions or the subscription, not the instance
  name.
- The registered key comes from `sshSettings.adminPublicKey` in the ARM GET. If it is absent, the helper says so.
  It also prints the exact `az rest --method get --url …` call that it made, so you can look at the response
  yourself.

### Logins and subscriptions

- To use another directory (tenant), log in again: `az login --tenant <tenant>`.
- `az account list -o table` shows what you are logged into. `az account set -s <subscription>` switches between
  the subscriptions in that list.

### API calls

- The helper does not use the `az ml` extension, because that extension can send an unsupported api-version.
  Every call goes through `az resource list` and `az rest`, with the version written out.

### The instance key

You cannot change the key on an existing instance (see [Before you create an instance](#before-you-create-an-instance)).

## In this setup

After `add` has verified the login, the instance is a VM like any other in this setup. Follow
[new-vm.md](new-vm.md) to set it up as a fresh VM. Put `WT_HOST=<instance>` on its install line. After that:

- It appears in the task picker (⌃⌥⌘T).
- `wt -H <instance> new -r <repo> -p "…"` starts tasks on it, with their rows on the Mac.
