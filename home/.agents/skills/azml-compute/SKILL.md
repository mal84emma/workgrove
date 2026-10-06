---
name: azml-compute
description: Put an Azure ML compute instance into the Mac's ~/.ssh/config with the azml-ssh-host helper, so it can be used like any other VM. Use when the user says "add compute instance X to my ssh config", "set up ssh to compute instance X", "which compute instances can I ssh to", or "remove compute instance X from ssh".
---

# Azure ML compute instances over ssh

Use this skill to add an Azure ML compute instance to the Mac's ssh config, list instances, or remove one.

Tool: `azml-ssh-host` (see `azml-ssh-host help`). The helper does these things:

1. It reads the instance from Azure Resource Manager.
2. It finds the matching private key in `~/.ssh`.
3. It writes one marked block into `~/.ssh/config`.
4. It verifies the login.

Use it only on the Mac, because the Mac's ssh config is what the task picker and VS Code read. For background, see `docs/azml-compute.md` in this repo.

## Commands

```bash
azml-ssh-host add <instance>     # write or update the Host block, then verify with one ssh login
azml-ssh-host list               # every SSH-enabled compute instance the account can see
azml-ssh-host rm <instance>      # remove the block again
```

`add` is idempotent, so you can run it again:

- If the block is unchanged, `add` prints `unchanged` and verifies the login again.
- If the IP changed, `add` writes the new IP in place.

## Rules

1. **Never edit `~/.ssh/config` by hand**, and never write a `Host` block for a compute instance yourself. The helper owns the region between `# >>> azml-ssh-host <instance>` and `# <<< azml-ssh-host <instance>`. It keeps this region at the top of the file, so nothing earlier can override it. It touches nothing else.
2. **Never run `az login` or `az account set` for the user.** If the helper says "not logged in" or that the instance is not in this subscription, report its error and stop. Logging in is the user's action.
3. **On "not found"** for the compute instance, run `azml-ssh-host list` once and show the instance names that it prints. Then stop. Do not loop over subscriptions.
4. **If `azml-ssh-host` is not found**, tell the user to run `wt update` on the Mac, then stop. `wt update` re-runs `install.sh` and links the helper. Do not install it yourself or call `az` by hand.
5. **If the helper says a `Host` block was not written by azml-ssh-host**, do these steps:
   1. Read the offending lines from `~/.ssh/config` and show them to the user. Do not edit the file: editing it is the user's action.
   2. Ask the user to delete that block and the comment lines above it. Ask the user to keep the alias unchanged.
   3. When the user says the block is gone, run `add` again.
6. **Stop on any non-zero exit.** Each error names the next command. Pass it on to the user instead of retrying.
7. **Report** these items:
   - The helper's summary line (`<instance>: <user>@<ip>:<port>, key ~/.ssh/<name>, config ~/.ssh/config`).
   - The host now appears in the ⌃⌥⌘T task picker (`wt task`).
   - The host now works with `wt -H <instance> …`, `ssh <instance>` and VS Code Remote-SSH.

## After it is added

The instance is a VM like any other in this setup. To run tasks on it, first set it up with `docs/new-vm.md`, and use `<instance>` as the alias. After that, `wt -H <instance> new -r <repo> -p "…"` works.
