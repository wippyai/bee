# Typed Lua tests

Run `make lint` for production and `make fixture-lint` for the disposable unit
composition; both enable strict-any. `make test` runs Python checks and every
registered Lua unit entry in four isolated processes.

Construct fixtures as complete typed records. Keep invalid inputs explicitly
`unknown` and pass them to the production decoder or operation under test.
Use production decoders for returned values and narrow optional fields before
using them. Keep every behavioral assertion when changing a fixture's types.

Shared support lives in `tests/lua/principals/bound.lua` (production caller
envelopes and bounded lists), `tests/lua/threads/harness.lua` (Threads replies,
async calls and SQL rows), `tests/lua/sessions/fake_owner.lua` (typed client,
Session and Work constructors), and `tests/lua/harness/carrier_faulted.lua`
(carrier request fixtures). List decoders return new lists: write a modified
list back to its fixture field. Object guards retain the original record.

The acceptance resolver in `fixtures/hive_replica/coordinator.lua` retains one
cast between recursive resolver receiver types that go-lua 1.6.2 cannot assign.
Its minimal reproduction and diagnostic are recorded in the lane report.
