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

Follow the [Azure ML policy](../../../.claude/AGENTS.md#add-an-azure-ml-compute-instance).
For background, see [Azure ML setup](../../../../docs/azml-compute.md).

## Commands

```bash
azml-ssh-host add <instance>     # write or update the Host block, then verify with one ssh login
azml-ssh-host list               # every SSH-enabled compute instance the account can see
azml-ssh-host rm <instance>      # remove the block again
```

`add` is idempotent, so you can run it again:

- If the block is unchanged, `add` prints `unchanged` and verifies the login again.
- If the IP changed, `add` writes the new IP in place.

## Handle helper results

The helper owns the region between `# >>> azml-ssh-host <instance>` and `# <<< azml-ssh-host <instance>`.
It keeps this region first, so earlier settings cannot override it. It touches nothing else.

1. **On "not found"** for the compute instance, run `azml-ssh-host list` once and show the instance names that it prints. Then stop. Do not loop over subscriptions.
2. **If `azml-ssh-host` is not found**, tell the user to run `wt update` on the Mac, then stop. `wt update` re-runs `install.sh` and links the helper. Do not install it yourself or call `az` by hand.
3. **If the helper says a `Host` block was not written by azml-ssh-host**, do these steps:
   1. Read the offending lines from `~/.ssh/config` and show them to the user. Do not edit the file: editing it is the user's action.
   2. Ask the user to delete that block and the comment lines above it. Ask the user to keep the alias unchanged.
   3. When the user says the block is gone, run `add` again.
4. **Report** these items:
   - The helper's summary line (`<instance>: <user>@<ip>:<port>, key ~/.ssh/<name>, config ~/.ssh/config`).
   - The host now appears in the ⌃⌥⌘T task picker (`wt task`).
   - The host now works with `wt -H <instance> …`, `ssh <instance>` and VS Code Remote-SSH.

## After it is added

The instance is a VM like any other in this setup.
Follow [the VM setup guide](../../../../docs/new-vm.md) with `<instance>` as the alias.
Then use `wt -H <instance> new -r <repo> -p "…"`.
