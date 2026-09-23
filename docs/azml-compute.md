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
| `azml-ssh-host` on PATH | The helper itself; `install.sh` links it into `~/.local/bin` | `command -v azml-ssh-host`, and if it is missing run `wt update`, which re-runs `install.sh` and links it |
| Azure CLI, logged in | The helper reads the compute resource with `az rest` | `az account show` |
| Reader on the workspace, and the workspace visible in the subscription | The helper finds workspaces with `az resource list` and then reads the instance under one of them; without the role the workspace is invisible and the GET is a 403 | `az resource list --resource-type Microsoft.MachineLearningServices/workspaces -o table` lists it, and `azml-ssh-host list` shows the instance |
| `jq` | Parses the ARM response | `jq --version` |
| OpenSSH (`ssh`, `ssh-keygen`) | Connects, and compares key fingerprints | `ssh -V` |
| A local private key | Its public half must be the one registered on the instance | The key sits in `~/.ssh` |
| SSH enabled at creation | Cannot be turned on afterwards | `sshSettings.sshPublicAccess` is `Enabled` |

`jq` comes from the `Brewfile` on the Mac. The Azure CLI does not, quite: its `brew "azure-cli"` line is
commented out, because this helper is the only thing in the repo that needs it. Uncomment it and rerun
`brew bundle --file ~/repos/workgrove/Brewfile`, or just `brew install azure-cli`. Then `az login`, which is
one of the logins in [new-mac.md](new-mac.md). On an Azure ML compute instance itself az is preinstalled:
the VM page's install block is skipped by its own guard, so it only logs in.

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

Run it again and the first line becomes `unchanged: Host ci-example is already correct in ~/.ssh/config`,
followed by the same verification. If the instance was rebuilt with a different IP, the block is rewritten at the top of the file.

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

The block sits at the top of the file so that nothing earlier can override it: ssh keeps the first value it is
given for each setting, so a `Host *` or `Match host …` further up would otherwise decide the user or the port.
The markers delimit the only region the helper ever changes. Everything else stays byte for byte as it was, and
`rm` restores the content exactly as `add` found it; the mode is normalised to 600 whenever the file is written,
so a config that was 644 comes back 600. The new file is built in full beside the target and then renamed onto
it, and the file it replaces is first copied to `~/.ssh/config.bak`, also 600. Nothing is ever truncated in
place, so an interrupt or a failed write costs you neither the config nor a line of it: what is there is either
the old file or the new one. A `Host` or `Match` line naming the instance outside the markers is refused rather
than edited, and markers that do not pair are refused rather than repaired.
`IdentitiesOnly yes` stops ssh offering every agent key first. `UseKeychain yes` is the only macOS-only line.

## Migrating a hand-written block

If `~/.ssh/config` already holds a `Host <instance>` block you wrote yourself, `add` refuses rather than edits it:

```
azml-ssh-host: Host ci-example is already in ~/.ssh/config and was not written by azml-ssh-host.
  Delete that Host block and the comment above it, keep the alias, then re-run: azml-ssh-host add ci-example
```

Editing the file is yours to do. Delete the block and any comment lines above it, including a note about the
instance at the very top of the file, because the managed block is inserted at line 1 and those lines would end
up describing it. Keep the alias exactly as it was: it is the Azure resource name the lookup uses, and it is
also the name the ⌃⌥⌘T picker, `wt -H <instance> …` and VS Code Remote-SSH already know. Then run
`azml-ssh-host add <instance>`.

What you gain is the two keepalive lines, `ServerAliveInterval 30` and `ServerAliveCountMax 6`, which a
hand-written block usually lacks. Without them an idle session carrying tmux or VS Code Remote-SSH hangs
silently the moment a NAT or a router drops the connection: the client sits there with a dead socket. With
them the client gives up after about three minutes, and cmux or VS Code reconnects on its own.

## Gotchas

- Compute instances are not VMs. `az vm list` never shows them. They live under the workspace, as
  `Microsoft.MachineLearningServices/workspaces/<workspace>/computes/<instance>`.
- An instance name is unique only inside its workspace, so the helper tries every workspace it can see in the
  current subscription and takes the first that answers. Use `az account set -s <other>` yourself when the
  instance lives in another subscription.
- The port is per instance and is not 22. It comes from `sshSettings.sshPort`.
- The IP is fixed for the life of the instance and survives a stop and start in practice, but the resource is
  the only authority. If `ssh <instance>` stops connecting, run `azml-ssh-host add <instance>` again.
- The first host key an instance offers is accepted without a prompt: the verification login connects with
  `StrictHostKeyChecking=accept-new`, so the key is recorded in `~/.ssh/known_hosts` and the login goes
  through. Compute instances are created and destroyed constantly and a fresh one always presents a key
  nothing has seen before, so a prompt at every `add` would only teach you to answer yes without reading it.
  The cost is the usual one: someone able to intercept that first connection could hand you their key instead.
  A key that changes afterwards is still refused, which is the next gotcha.
- A recreated instance with the same name gets a new host key, and ssh then refuses to connect. The helper
  prints the line to run: `ssh-keygen -R '[<ip>]:<port>'`, after which `add` works again.
- `UseKeychain` is a macOS option; Linux OpenSSH rejects it, so the helper writes it only on a Mac.
  `AddKeysToAgent` is valid on both and is always written.
- A 403, an expired token and a genuinely missing name all surface as the same "not found", because the helper
  does not distinguish them. If `azml-ssh-host list` prints nothing at all, the problem is permissions or the
  subscription, not the instance name.
- Another directory needs another login: `az login --tenant <tenant>`. `az account list -o table` shows what
  you are logged into, and `az account set -s <subscription>` switches between subscriptions in it.
- The registered key comes from `sshSettings.adminPublicKey` in the ARM GET. If it is absent, the helper says
  so and prints the exact `az rest --method get --url …` call it made, so you can look at the response yourself.
- The `az ml` extension is not used: it can send an unsupported api-version, so every call goes through
  `az resource list` and `az rest` with the version written out.
- The key cannot be changed on an existing instance. Create instances with a public key whose private half is
  already in `~/.ssh`.

## In this setup

Once `add` has verified the login, the instance is a VM like any other here: give it the same treatment as a
fresh VM with [new-vm.md](new-vm.md), with `WT_HOST=<instance>` on its install line. After that it appears in
the ⌃⌥⌘T picker, and `wt -H <instance> new -r <repo> -p "…"` starts tasks on it with their rows on the Mac.
