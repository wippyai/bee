# Typed Lua tests

Run `make lint` for production and `make fixture-lint` for the disposable unit
composition and the window hook acceptance inventory, including the gateway
claim source substituted by the Go harness; both enable strict-any.
`make test` runs Python checks and every registered Lua unit entry in four
isolated processes.

`make persist-migration-check` exercises workspace, client and sync migrations
against real SQLite: concurrent opens, interrupted upgrades and immutable ledger
replay. With startup progress active, native statement and rollback failures
retain their operation context and never announce migration completion.

Construct fixtures as complete typed records. Keep invalid inputs explicitly
`unknown` and pass them to the production decoder or operation under test.
Use production decoders for returned values and narrow optional fields before
using them. Check the boolean returned by `channel.receive()` explicitly and
assert it with a message before using the received value. Keep every behavioral
assertion when changing a fixture's types. Window readiness announces its
presenter before native launch finishes; await the checkpoint event under the
acceptance harness deadline before testing recovery.

Shared support lives in `tests/lua/principals/bound.lua` (production caller
envelopes and bounded lists), `tests/lua/threads/harness.lua` (Threads replies,
async calls and SQL rows), `tests/lua/sessions/fake_owner.lua` (typed client,
Session and Work constructors), and `tests/lua/harness/carrier_faulted.lua`
(carrier request fixtures). List decoders return new lists: write a modified
list back to its fixture field. Object guards retain the original record.

Governance staging and activation share `bee.gov.delivery:resolver.Resolver`; the Hub
and overlay implementations and typed fixtures use the same receiver interface.

Carrier recovery, stream bursts and post-exit drain cases run as separate entries
with the existing 180-second limit. Their monitored-exit collector drains queued
exits before reporting a deadline, including exits delivered as the timer wins.
The unit composition stages `fixtures/gateway_clock` and grants the gateway
read access to its fixture instant. The expiry test selects the binding's exact
expiry after the child presents its credential, then restores the clock; it
uses the real HTTP authentication and placement enforcement paths.

After `make standalone`, run `make hub-self-update-standalone-check
BEE_DEPLOYMENT=dist/portable-deployment` for independent component management,
exact core approval and receipt replay, native Modules apply, and offline
restart. The fixture packer refreshes code declarations from their current
owner indexes while retaining sealed resource assets. Core updates preserve
the selected Settings code; a separate Settings update verifies its renderer
marker and changed application code fingerprint. The native proof retains
Settings/About across the core update and restarts from the same saved state
with external networking disabled.

To reuse built fixtures, select the baseline with `BEE_DEPLOYMENT`, the target
with `BEE_SELF_UPDATE_TARGET_DEPLOYMENT`, and the independent core artifact set
with `BEE_SELF_UPDATE_EXPLICIT_DEPLOYMENT`. `BEE_SELF_UPDATE_BINARY` selects the
baseline executable; the harness verifies its digest and exact embedded pack
set before launching it.
