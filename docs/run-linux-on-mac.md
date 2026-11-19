---
title: How to run Linux on an M1, M2, M3 or M4 Mac (free, in 10 seconds)
description: Run Ubuntu or Debian Linux in a virtual machine on an Apple silicon Mac for free. AltVM provisions an ARM64 Linux VM with your user, SSH keys, shared folders and Rosetta in about 10 seconds.
---

# How to run Linux on an Apple silicon Mac (M1, M2, M3, M4, M5)

The fastest way to run Linux on a Mac with Apple silicon is a native **ARM64 Linux virtual machine** on Apple's
hypervisor. AltVM does this for free in one command and provisions the VM for you:

```bash
avm create dev --catalog ubuntu-24.04 --start     # or debian-13 / debian-12
avm ssh dev
```

About 10 seconds after the image download, you have:

- **Ubuntu 24.04 LTS** or **Debian 12/13** running at native speed, with no emulation
- **your macOS username** with your SSH public keys already authorized
- **shared folders** from your Mac at `/mnt/mac` (virtio-fs)
- **Rosetta**, to run x86-64 Linux binaries inside the ARM64 VM
- a **guest agent**, so `avm exec dev -- <cmd>` works even without networking

Not installed yet? Follow the [getting started guide](getting-started.md).

## Ubuntu Desktop or another distribution

Use an installer ISO for a graphical desktop or any other ARM64 distribution:

```bash
avm create ubuntu-desktop --catalog ubuntu-24.04-desktop
avm start ubuntu-desktop --gui                      # the installer opens in a window
avm create fedora --iso ~/Downloads/Fedora-Workstation-Live-aarch64.iso
avm start fedora --gui
avm eject fedora                                    # after installation finishes
```

Install images must be **ARM64 / aarch64**. Linux x86 ISOs can't boot on Apple silicon, but x86-64 *programs* run inside an ARM64
VM through Rosetta.

## Common tasks

| Task | Command |
|---|---|
| More CPU or RAM | `avm set dev cpus=6 memory=12G` (applies on next boot) |
| Bigger disk | `avm disk resize dev 128` |
| Snapshot before an upgrade | `avm snapshot create dev before-upgrade` |
| Throwaway copy | `avm clone dev dev-test` (instant, copy-on-write) |
| Pause work and free RAM | `avm suspend dev` (resume with `avm start dev` in about 0.65 s) |
| Private network between VMs | `avm switch create lab` then `avm create a --catalog debian-13 --switch lab` |
| Simulate a slow network | `avm switch set lab --preset 3g` |

## Why not Docker Desktop?

Containers share one Linux kernel. A VM gives you a full Linux system with systemd, kernel modules, a desktop
and a separate network, and isolates it from your Mac. Many people run their container engine inside a AltVM VM.

## FAQ

**Is it really free?** Yes. AltVM is open source under the MIT license.

**Does it work on M1?** Yes, on every Apple silicon Mac (M1 through M5). Nested virtualization needs M3 or newer.

**How fast is it?** CPU-bound work runs at near-native speed on Apple's hypervisor. Cold boot to a ready guest agent takes about 4–5 s.

**Can I use a GUI?** Yes. Run `avm start dev --gui` or use the app. Desktop distributions get HiDPI and live resize.
