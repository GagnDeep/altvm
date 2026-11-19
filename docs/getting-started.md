---
title: Getting started — run Linux and macOS VMs on Apple silicon
description: Install AltVM, the free open-source Parallels Desktop alternative, and create your first Linux or macOS virtual machine on an M1, M2, M3, M4 or M5 Mac in minutes.
---

# Getting started with AltVM

This guide takes you from a fresh clone to running Linux and macOS virtual machines on your Apple silicon Mac,
with shared folders, snapshots and SSH.

**Contents:** [Install](#1-install) · [First Linux VM](#2-create-your-first-linux-vm) · [Use the VM](#3-use-the-vm) ·
[Shared folders](#4-share-folders-with-your-mac) · [Snapshots](#5-snapshots-clones-and-suspend) · [macOS VM](#6-create-a-macos-vm) ·
[App and window](#7-use-the-app-or-a-vm-window) · [Next steps](#next-steps) · [Troubleshooting](#troubleshooting)

## 1. Install

**You need:**
- a Mac with Apple silicon (M1 or newer)
- Xcode with the macOS 27 SDK, to build
- about 5 GB of free disk space per Linux VM (disks are sparse, so they use only what the guest writes)

```bash
git clone https://github.com/GagnDeep/altvm.git
cd altvm
./scripts/build.sh                          # → dist/AltVM.app and dist/avm, signed with the virtualization entitlement
sudo ln -sf "$PWD/dist/avm" /usr/local/bin/avm
cp -R dist/AltVM.app /Applications/          # optional: the native app
avm host                                     # shows what this Mac can run (cores, RAM, limits)
```

The `avm` binary must keep its code signature, because Virtualization.framework requires the
`com.apple.security.virtualization` entitlement. If you rebuild with `swift build`, re-sign it:

```bash
codesign -f -s - --entitlements Resources/avm.entitlements .build/debug/avm
```

## 2. Create your first Linux VM

```bash
avm catalog                                  # list available images
avm create dev --catalog debian-13 --start
```

AltVM downloads the official Debian cloud image, verifies its SHA-512 checksum and converts it to a sparse disk. It
then boots it with cloud-init, which creates **your macOS username** with your `~/.ssh/*.pub` keys and installs the guest
agent. All of this takes about 10 seconds after the first download.

Other images:

| Catalog id | What you get |
|---|---|
| `debian-13` | Debian 13 "trixie", unattended (cloud image) |
| `debian-12` | Debian 12 "bookworm", unattended (cloud image) |
| `ubuntu-24.04` | Ubuntu 24.04 LTS Server, unattended (cloud image) |
| `ubuntu-24.04-desktop` | Ubuntu 24.04 LTS Desktop installer ISO |
| `debian-13-installer` | Debian 13 netinst installer ISO |
| `macos` | The latest macOS supported by your Mac |

Size the VM yourself, or pick a workload profile:

```bash
avm create build --catalog ubuntu-24.04 --cpus 6 --memory 12G --disk 128 --start
avm create web   --catalog debian-13 --profile server --start
```

Profiles (`productivity`, `development`, `design`, `gaming`, `server`, `travel`) are sized from your Mac's real core and RAM
counts, and always leave the host at least 25% of its RAM.

## 3. Use the VM

```bash
avm list                                     # all VMs, state, resources
avm exec dev -- uname -a                     # run a command through the guest agent (no network or SSH needed)
echo hi | avm exec dev -i -- cat             # -i forwards stdin
avm ssh dev                                  # regular SSH session as your user
avm ip dev                                   # the VM's IP address
avm info dev                                 # details and live status
avm stop dev                                 # graceful shutdown (agent → ACPI → force after a timeout)
```

Run x86-64 Linux binaries with Rosetta:

```bash
avm rosetta install                          # once per Mac, if Rosetta isn't installed yet
avm exec dev -- ./some-x86_64-binary         # registered automatically in catalog VMs
```

## 4. Share folders with your Mac

Catalog VMs mount your shared folders at `/mnt/mac` over virtio-fs:

```bash
avm set dev share+=code:~/code               # share ~/code as /mnt/mac/code (applies on next boot)
avm set dev share-=code                      # remove it
avm create dev2 --catalog debian-13 --no-share   # create with no shared folders at all
```

## 5. Snapshots, clones and suspend

```bash
avm snapshot create dev clean                # live snapshot including RAM if the VM is running
avm snapshot tree dev
avm snapshot restore dev clean
avm clone dev dev-experiment                 # instant APFS copy-on-write clone, new identity
avm suspend dev                              # save RAM to disk and quit
avm start dev                                # resume in about 0.65 s, with the guest clock resynced
```

Disposable and isolated modes:

```bash
avm create scratch --catalog debian-13 --disposable --start   # every boot starts clean
avm create lab     --catalog debian-13 --isolated --start     # no NAT, shares, clipboard, mic or USB
```

## 6. Create a macOS VM

```bash
avm macos-latest                             # which macOS version your Mac supports
avm create mac --macos --start               # downloads the IPSW (about 15–25 GB) from Apple, installs and provisions it
avm start mac --gui                          # open it in a window
```

macOS guests get Apple's paravirtualized Metal GPU, a Mac keyboard and trackpad, and Retina displays. Apple's
macOS license allows up to two additional macOS instances per Mac.

Saved states of macOS VMs are sealed by your Mac's Secure Enclave, so resume a suspended macOS VM while your Mac is
unlocked. To throw the saved state away and cold boot instead, use `avm start mac --discard-state`.

## 7. Use the app or a VM window

- **App:** open `AltVM.app`. The sidebar lists every VM. **+** creates a VM from the catalog, an ISO or a golden image.
  The detail view edits CPU, memory, profile, displays, integration and shared folders, and manages snapshots.
  The menu bar item gives quick start and stop.
- **Window for one VM:** `avm start <vm> --gui`. Resize the window and the guest display follows. Closing the window suspends the VM.
- **Screen Sharing:** `avm vnc <vm>` opens macOS Screen Sharing with a one-time password.
- **Web console:** `avm serve`, then open the printed URL. It includes a REST API and Prometheus `/metrics`.

## Next steps

- [CLI reference](cli.md): every command.
- [AI agents & MCP](ai-agents.md): let Claude and other agents use a VM as a sandboxed computer.
- [Fleet example](https://github.com/GagnDeep/altvm/blob/main/examples/fleet.json) and [policy example](https://github.com/GagnDeep/altvm/blob/main/examples/policy.json) for teams.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `The process doesn't have the "com.apple.security.virtualization" entitlement` | Re-sign `avm` (see [Install](#1-install)) or use `dist/avm` from `scripts/build.sh`. |
| `… is already running in another process` | The VM is already open somewhere else (CLI, app or API). Use `avm stop <vm>` or control it from there. |
| Resume says the session is protected by the Secure Enclave | Unlock your Mac and retry, or run `avm start <vm> --discard-state`. |
| `avm exec` hangs waiting for input | Only use `-i` when you pipe stdin into the command. |
| A guest file system was damaged after a power cut | Run `avm repair <vm>` to force a fsck on the next boot. |
| The display is black during the boot menu | That's expected: firmware-stage graphics are not captured. The OS display appears once the guest boots. |
