# Bee Wippy Driver

Native in-process agent harness driver for Wippy.

Runs a framework `agent.gen1` closure (resolved by `bee.harness.launch:agent_resolver`)
in-process with its traits, tools, and contracts, against an OpenAI-compatible chat
completions endpoint chosen by host config (no provider or key baked in; key by
credential reference).

Honors run/status/wait/cancel receipts, thread records via the carrier, inbox delivery
as new turns, and grant isolation.
