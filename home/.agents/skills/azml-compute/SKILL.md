---
name: azml-compute
description: Put an Azure ML compute instance into the Mac's ~/.ssh/config with the azml-ssh-host helper, so it can be used like any other VM. Use when the user says "add compute instance X to my ssh config", "set up ssh to compute instance X", "which compute instances can I ssh to", or "remove compute instance X from ssh".
---

# Azure ML compute instances over ssh

Tool: `azml-ssh-host` (see `azml-ssh-host help`). It reads the instance from Azure Resource Manager, finds the matching private key in `~/.ssh`, writes one marked block into `~/.ssh/config` and verifies the login. Mac only: this is the machine that holds the ssh config the picker and VS Code read. Background: `docs/azml-compute.md` in this repo.

## Commands

```bash
azml-ssh-host add <instance>     # write or update the Host block, then verify with one ssh login
azml-ssh-host list               # every SSH-enabled compute instance the account can see
azml-ssh-host rm <instance>      # remove the block again
```

`add` is idempotent: an unchanged block prints `unchanged` and re-verifies, a changed IP is written in place.

## Rules

1. **Never edit `~/.ssh/config` by hand**, and never write a `Host` block for a compute instance yourself. The helper owns the region between `# >>> azml-ssh-host <instance>` and `# <<< azml-ssh-host <instance>`, keeps it at the top of the file so nothing earlier can override it, and touches nothing else.
2. **Never run `az login` or `az account set` for the user.** If the helper says "not logged in" or that the instance is not in this subscription, report its error and stop. Logging in is the user's action.
3. **On "not found"**, run `azml-ssh-host list` once and show the instance names it prints, then stop. Do not loop over subscriptions.
4. **Stop on any non-zero exit.** Each error names the next command; pass it on rather than retrying.
5. **Report** the helper's summary line (`<instance>: <user>@<ip>:<port>, key ~/.ssh/<name>, config ~/.ssh/config`), and that the host now appears in the ⌃⌥⌘T task picker (`wt task`) and works with `wt -H <instance> …`, `ssh <instance>` and VS Code Remote-SSH.

## After it is added

The instance is a VM like any other in this setup. To run tasks on it, set it up with `docs/new-vm.md` first, using `<instance>` as the alias; after that `wt -H <instance> new -r <repo> -p "…"` works.
