---
description: "Call MCP servers via the mcporter CLI. Use when a task requires external service integration (GitHub, documentation lookup, NixOS package search, time operations) that isn't available as a native CLI."
---

# Skill: mcporter (MCP Bridge)

Use mcporter to call MCP servers from the command line. mcporter connects to
configured MCP servers and exposes their tools as CLI commands.

## When to Use

Use mcporter when you need:
- External service integration (GitHub issues, PRs, search)
- Library/package documentation (context7)
- NixOS package or option search (mcp-nixos)
- Time zone or date operations (time)

Prefer native CLIs (gh, git, nix search) when available. Use mcporter for
services that have richer tool schemas or auth-managed integrations.

## Discovery

```bash
# List all configured MCP servers
npx mcporter list

# List tools available from a specific server
npx mcporter list context7

# Show full parameter schemas
npx mcporter list github --schema
```

## Calling Tools

Two equivalent call syntaxes:

```bash
# Colon-delimited (shell-safe)
npx mcporter call context7.resolve-library-id libraryName:react

# Function-call style (matches list output exactly)
npx mcporter call 'context7.resolve-library-id(libraryName: "react")'
```

## Ad-hoc Connection (no config required)

To call an MCP server that isn't in the config:

```bash
# stdio-based (runs the server as a subprocess)
npx mcporter call --stdio "npx -y @modelcontextprotocol/server-github" \
  github.create_issue owner:org repo:name title:"title"

# HTTP endpoint
npx mcporter call --http-url https://mcp.example.com/mcp server.tool_name
```
