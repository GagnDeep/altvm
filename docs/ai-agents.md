---
title: Sandboxed VMs for AI agents — MCP server and computer use on macOS
description: Give Claude Code, Claude Desktop or any MCP client a full Linux or macOS computer to work in. AltVM exposes screenshots, mouse, keyboard, exec, files and snapshots through a built-in MCP server and computer-use API.
---

# AI agents, MCP and computer use

AltVM turns any VM into a **sandboxed computer for AI agents**. An agent can see the screen, move the mouse,
type, run commands, read and write files, and take or restore snapshots. Everything happens inside a VM that is isolated
from your Mac and reversible with one command.

There are three ways to use it:

1. **[MCP server](#mcp-server):** `avm mcp`, for Claude Code, Claude Desktop and any MCP client.
2. **[Computer-use CLI and REST API](#computer-use-cli-and-rest-api):** `avm screenshot`, `click`, `type` and the other actions, for your own scripts and agents.
3. **[Built-in agent](#built-in-claude-agent):** `avm agent <vm> "task"`, a ready-made Claude computer-use loop.

All three work headless on Linux and macOS guests and need **no software inside the guest** for screen, mouse and
keyboard. They use the VM's display server through a native RFB client.

## Set up a safe sandbox VM

```bash
avm create sandbox --catalog ubuntu-24.04 --isolated --start   # no NAT, shared folders, clipboard, mic or USB
avm snapshot create sandbox clean                              # known-good state to return to
```

Leave out `--isolated` if the agent needs internet access. Use `--disposable` to make every boot start from a clean baseline.

## MCP server

`avm mcp` speaks the Model Context Protocol over stdio and exposes 21 tools:

| Group | Tools |
|---|---|
| Discover | `list_vms`, `vm_info` |
| Lifecycle | `create_vm`, `clone_vm`, `delete_vm` (removed by `--no-lifecycle`) |
| Power | `start_vm`, `stop_vm`, `suspend_vm` |
| Snapshots | `snapshot`, `list_snapshots`, `restore_snapshot` |
| Guest | `exec`, `read_file`, `write_file` |
| Computer use | `screenshot` (returned as an image), `click`, `move_mouse`, `drag`, `scroll`, `type_text`, `press_keys` |

**Scoping:**
- `--vms a,b` limits the server to the named VMs.
- `--no-lifecycle` removes create, clone and delete.

### Claude Code

```bash
claude mcp add altvm -- avm mcp --vms sandbox --no-lifecycle
```

Then ask, for example: *"Use the sandbox VM to install nginx, open its default page in Firefox and screenshot it."*

### Claude Desktop and other MCP clients

Add this to the client's MCP configuration (for Claude Desktop, `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "altvm": {
      "command": "/usr/local/bin/avm",
      "args": ["mcp", "--vms", "sandbox", "--no-lifecycle"]
    }
  }
}
```

## Computer-use CLI and REST API

```bash
avm screenshot sandbox shot.png --max 1280   # PNG, scaled down to fit 1280 px
avm click sandbox 640 400                    # also double-click and right-click
avm move sandbox 100 100
avm drag sandbox 100 100 400 300
avm scroll sandbox 640 400 --dy 5
avm type sandbox "hello from the host"
avm key sandbox ctrl+alt+t                   # chords; on macOS guests: cmd+space, cmd+tab …
```

Over REST (`avm serve` prints the URL and token):

```bash
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8484/api/v1/vms/sandbox/screenshot -o shot.png
curl -H "Authorization: Bearer $TOKEN" -X POST http://127.0.0.1:8484/api/v1/vms/sandbox/computer \
     -d '{"action":"click","x":640,"y":400}'
```

Actions: `screenshot`, `click`, `double_click`, `right_click`, `middle_click`, `move`, `drag`, `scroll`, `key`, `type`,
`button_down`, `button_up`, `keys_down`, `keys_up` and `size`. Pass `"scaled": true` to use coordinates from the last scaled screenshot.

## Built-in Claude agent

```bash
export ANTHROPIC_API_KEY=…                  # or ANTHROPIC_AUTH_TOKEN; ANTHROPIC_BASE_URL is honoured
avm agent sandbox "Open a terminal, create ~/report.txt listing the 5 largest files in /usr, then open it in a text editor"
```

- **Rollback snapshot first:** a snapshot is taken before the agent starts. Undo the run with `avm snapshot restore`. Turn it off with `--no-snapshot`.
- **Tools:** the agent uses Claude's computer-use tools, plus a bash tool on Linux guests that runs through the guest agent.
- **Options:**
  - `--model` (default `claude-opus-5-5`)
  - `--effort` (default `high`)
  - `--max-steps` (default 60)
- **Exit codes:**
  - `0` done
  - `4` Claude declined the task
  - `5` step limit reached
  - `1` error

> Status: the agent loop has been validated against a contract-checking mock of the API; please report any issues you
> hit with the live API.

## Safety checklist

- Give agents a **dedicated VM**, not one holding your credentials or source code.
- Use `--isolated` unless network access is needed. Shared folders are off in isolated mode.
- Scope MCP with `--vms` and `--no-lifecycle`.
- Take a snapshot before risky tasks. `avm agent` does this automatically.
- Remote display and computer use can be disabled fleet-wide with the signed policy setting `allowRemoteDisplay: false`.
  Every display session is recorded in the audit log.
