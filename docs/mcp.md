# MCP host — future design

MCP is a planned native capability after the plugin runtime, jobs, permissions, and remote HTTP surface are stable. It is not part of `kiwios_api = "1"`, and API 1 plugins cannot register or invoke MCP servers.

The intended role is narrow: KiwiOS supervises explicitly configured local MCP servers, health-checks remote servers, and exposes an optional tailnet-only gateway. KiwiOS is not an agent runtime, model provider, general cloud-MCP marketplace, or owner of another application's MCP configuration.

## Intended boundaries

- One configured server ID maps to one supervised stdio process or one remote HTTP endpoint.
- Local processes use the same trusted-code, setup-mode, bounded-log, restart-backoff, and named-secret rules as plugins.
- The PWA shows server health and tool names by default, not message bodies or credentials.
- Remote clients must present a Serve-supplied human identity through the same fail-closed KiwiOS/Tailscale boundary; reachability alone is not authentication.
- Tools with side effects require an explicit allowlist and KiwiOS confirmation policy.
- KiwiOS may export client configuration snippets; it does not rewrite client files.

Before implementation, define and version a separate MCP registration/gateway contract, threat-model prompt injection and confused-deputy behavior, and add audit/redaction tests. Do not reserve speculative plugin manifest fields before that work.
