# Antigravity CLI (`agy`) Driver Component

This document records the design, contract compliance, and integration gates for the Bee Antigravity CLI harness child component (`bee.driver.agy`).

## Overview

The `agy` driver implements the four-method `bee.driver:driver` contract:
- `prepare`: Returns declarative launch specifications for fresh turns with expressible host-policy options.
- `dispatch`: Returns declarative launch specifications for continuation turns using `--conversation <uuid>`.
- `normalize`: Structurally validates incoming bounded state and booleans (`eof`, `resumed`), including every terminal answer, resume reference, usage and fault field; pins conversation identity on `init`, refuses conflicting envelope/body or later IDs, caps each response delta and retained answer at thread observation limits, and converts incoming NDJSON stream envelopes (`init`, `step_update`, `result`) into strictly typed `bee.threads.records:observation` records and terminal reports.
- `configure`: Processes gateway tool configuration into `.gemini/config/mcp_config.json` with environment expansion.

## Supported Launch Surfaces

### 1. Structured Print (`stream-json`)
- Launch arguments:
  ```
  --print= --input-format stream-json --output-format stream-json --disable-slash-commands
  ```
- Stdin:
  One canonically encoded NDJSON line per turn:
  ```json
  {"event":"user","message":{"content":"...","role":"user"}}
  ```
- Stdin lifecycle: `stdin_eof = true`.
- Readiness: `protocol:init`.
- Turn settlement: Only the terminal `result` envelope settles the turn as `succeeded`, `failed`, or `cancelled`. A stream closing without `result` is settled as `uncertain`. Malformed results must not succeed.

### 2. Native Interactive Terminal (`window`)
- Mode: `window`, protocol: `pty`, revision: `native-window-1`.
- Launch:
  ```
  agy [--model <model>] [--effort <effort>] [--mode <mode>] [--conversation <uuid>] [--prompt-interactive <brief>]
  ```
- Empty prompt opens the native interactive UI without prompt flags.
- Readiness: `terminal:attached`.

## Capability and Gate Status

- **Authentication**: Labeled `unproven`. Headless execution requires an established `HOME` profile. `GEMINI_API_KEY` is not a complete account session.
- **Hooks**: Labeled `unproven`. Agy CLI natively supports only local command execution hooks; HTTP gateway hooks are rejected, and unsupported hook capability claims are excluded from the profile.
- **MCP**: Labeled `unproven`. Gateway MCP configuration is generated declaratively for `.gemini/config/mcp_config.json` with environment expansion `${GATEWAY_TOKEN}` and client transports `stdio` and `streamable_http`, verified via `agy mcp help` and isolated fixture config. Live in-harness MCP operation is not yet verified through automated gates.

The nested `result` object is the terminal boundary. The normalizer requires a
string status and response text for successful results, decodes usage counters
and cost fields when present, and fails malformed terminal data conservatively.
Envelope and nested body conversation IDs must agree before either is trusted.

## Shared Integration Seam

In accordance with worktree boundaries, no shared files have been modified. The integration seams for parent review are:
1. `build/modules.json`: Addition of `bee.driver.agy` to `bee/driver.namespaces`.
2. Activation in `bee:harness_activation` and catalog entries for `agy`.
