---
title: How to create a macOS virtual machine on Apple silicon (free)
description: Run macOS in a VM on your M1–M5 Mac for testing, CI or a clean dev environment. AltVM downloads the latest macOS from Apple, installs it and creates the user automatically.
---

# Create a macOS virtual machine on Apple silicon

AltVM creates **macOS virtual machines** on Apple silicon Macs with one command. It downloads the newest macOS
your Mac supports straight from Apple, installs it, then creates the user account and enables SSH automatically.

```bash
avm macos-latest                    # which macOS version and build your Mac supports
avm create mac --macos --start      # download (about 15–25 GB), install and provision
avm start mac --gui                 # use it in a window
```

Have an IPSW already? Run `avm create mac --macos --ipsw ~/Downloads/UniversalMac_….ipsw`.

## What you get

- Apple's **paravirtualized Metal GPU**, Retina displays, and a Mac keyboard and trackpad
- **Snapshots** before risky changes: `avm snapshot create mac clean`
- **Instant clones** for parallel test runs: `avm clone mac mac-ci-1`
- **Suspend and resume**: `avm suspend mac`
- **Automation**: SSH, plus screenshot, mouse and keyboard control (`avm screenshot`, `avm key mac cmd+space`) for UI tests and [AI agents](ai-agents.md)
- **Golden images**: `avm image pack mac base.avmimg --sign <key>`, deployable to other Macs in seconds

## Use cases

- **Test apps** on a clean macOS, or on a beta, without touching your Mac
- **CI runners:** clone a prepared VM per job and throw it away afterwards
- **Isolation** for untrusted software or experiments
- **AI computer-use agents** working in a real macOS desktop

## Notes

- Apple's macOS license allows up to **two additional macOS instances** per Mac.
- Saved states of macOS VMs are sealed by the Mac's **Secure Enclave**. Resume a suspended macOS VM while your Mac is
  unlocked, or use `avm start mac --discard-state` to cold boot.
- The guest's macOS version can't be newer than what Virtualization.framework on your Mac supports. `avm macos-latest` shows it.
