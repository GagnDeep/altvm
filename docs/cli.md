---
title: avm CLI reference — AltVM virtual machine command line for macOS
description: Complete reference for avm, the AltVM command-line tool for creating, running, snapshotting, automating and securing Linux and macOS virtual machines on Apple silicon.
---

# `avm` CLI reference

`avm` controls every feature of AltVM. Run `avm help` for the built-in summary.
Every VM runs in its own `avm run` process, and every command talks to it through a per-VM control socket.

**Environment:** `ALTVM_HOME` overrides the library location (default `~/Library/Application Support/AltVM`).

## Lifecycle

| Command | Description |
|---|---|
| `avm list [--json]` | List machines with state, OS, CPU, RAM, disk use, snapshots and flags |
| `avm create <name> --catalog <id>` | Create from the catalog (`avm catalog` lists ids) |
| `avm create <name> --iso <file>` | Create from an ARM64 installer ISO |
| `avm create <name> --image <file.avmimg\|url>` | Deploy a signed golden image |
| `avm create <name> --macos [--ipsw <file>]` | Create a macOS VM (latest supported IPSW by default) |
| `avm create <name> --blank` | Empty VM |
| `avm start <vm> [--gui] [--discard-state]` | Start in the background, or with a window. A suspended VM resumes |
| `avm run <vm> [--headless\|--console]` | Run in the foreground |
| `avm stop <vm> [--force]` | Graceful shutdown (agent → ACPI → force after a timeout) |
| `avm suspend\|pause\|resume\|restart <vm>` | Suspend to disk, pause in memory, resume, restart |
| `avm info <vm> [--json]` | Configuration and live status |
| `avm set <vm> key=value…` | Change settings (see below) |
| `avm clone <vm> <new>` | Instant copy-on-write clone with a fresh identity |
| `avm rename <vm> <new>` · `avm delete <vm> --yes` | Rename or delete |
| `avm disk resize <vm> <GiB>` · `avm disk compact <vm>` | Grow the disk, or reclaim unused space |
| `avm memory <vm> <size>` | Live memory target through the balloon (e.g. `2G`) |
| `avm repair <vm>` | Force a file-system check on the next boot |
| `avm eject <vm>` | Detach installer media after an ISO install |

**`create` options:**
- `--profile productivity|development|design|gaming|server|travel`
- `--cpus N`, `--memory 8G`, `--disk 64`
- `--user U`, `--password P`, `--no-share`
- `--isolated`, `--disposable`, `--secure-boot`
- `--switch <net>`, `--package <pkg>` (repeatable), `--label key=value`
- `--start`

**`set` keys:**
- Resources: `cpus`, `memory`, `profile`, `adaptive`
- Modes: `isolated`, `disposable`
- Integration: `clipboard`, `rosetta`, `audio`, `mic`, `agent`
- Boot and disk: `boot=efi|fast`, `disk.sync=full|fast`
- Metadata: `notes`, `label.K=V`
- Shared folders: `share+=name:path`, `share-=name`

## Guest

| Command | Description |
|---|---|
| `avm exec <vm> [-i] -- <cmd…>` | Run a command through the vsock guest agent. Exit codes are propagated; `-i` forwards stdin |
| `avm ip <vm>` · `avm ssh <vm> [args]` | IP address and SSH |
| `avm usb attach <vm> <image> [--read-write]` · `avm usb detach <vm> <id>` | Hot-plug a disk image or ISO as a USB stick |

## Computer use

| Command | Description |
|---|---|
| `avm screenshot <vm> [out.png] [--max 1280]` | Screenshot as PNG |
| `avm click\|double-click\|right-click <vm> X Y` | Mouse clicks |
| `avm move <vm> X Y` · `avm drag <vm> X Y X2 Y2` · `avm scroll <vm> X Y --dy 3` | Pointer movement, drag and scroll |
| `avm type <vm> <text…>` · `avm key <vm> cmd+space` | Typing and key chords |
| `avm vnc <vm> [--print]` | Open the display in Screen Sharing, or print the URL |
| `avm mcp [--vms a,b] [--no-lifecycle]` | MCP server over stdio ([guide](ai-agents.md)) |
| `avm agent <vm> "<task>" [--model M] [--effort E] [--max-steps N] [--no-snapshot]` | Built-in Claude computer-use agent |

## Snapshots

| Command | Description |
|---|---|
| `avm snapshot create <vm> <name> [--note N]` | Live snapshot with RAM if the VM is running; copy-on-write either way |
| `avm snapshot list\|tree <vm>` | List snapshots |
| `avm snapshot restore <vm> <snap>` · `avm snapshot delete <vm> <snap>` | Restore or delete |

## Networks

| Command | Description |
|---|---|
| `avm switch create <name> [--subnet 10.77.5]` · `list` · `run <name>` | Userspace L2 switches with built-in DHCP |
| `avm switch set <name> --preset 3g` | Network condition presets |
| `avm switch set <name> --latency MS --jitter MS --loss PCT --bandwidth KBPS` | Custom network conditions |

## Enterprise

| Command | Description |
|---|---|
| `avm image pack <vm> <out.avmimg> [--sign key] [--version V] [--description D]` | Build a signed golden image |
| `avm image inspect <file>` · `avm image deploy <file\|url> <name>` | Inspect or deploy an image |
| `avm apply <fleet.json> [--dry-run]` | Declarative VMs as code, with plan and apply ([example](https://github.com/GagnDeep/altvm/blob/main/examples/fleet.json)) |
| `avm keys generate <name> [--trust] [--escrow]` · `avm keys trust <file.pub>` | Signing and escrow keys |
| `avm policy init <org>` · `sign <policy.json> --key <k>` · `install <signed.json>` · `show` · `check <vm>` | Signed policies ([example](https://github.com/GagnDeep/altvm/blob/main/examples/policy.json)) |
| `avm encrypt <vm> [--keychain]` · `unlock` · `lock` · `recover <vm> --escrow-key <file>` | Encrypted VMs with IT escrow |
| `avm audit show [--n 50]` · `verify` · `export` | Hash-chained audit log |
| `avm serve [--port 8484] [--listen 127.0.0.1]` | REST API, web console and `/metrics` (token auth) |

## Host

| Command | Description |
|---|---|
| `avm host` | Host capabilities and limits |
| `avm catalog` | Available images |
| `avm metrics` | Prometheus metrics to stdout |
| `avm macos-latest` | Latest macOS IPSW supported by this Mac |
| `avm rosetta install` | Install Rosetta for Linux guests |
| `avm version` | Version information |
