-- MIT. The pump's default forwarding sender: a fail-closed placeholder. The
-- independent Threads owner has no transport, so a composition that links no
-- sender leaves this in place and every delivery is reported unknown; the row
-- stays queued and its lease lapses. A host selects a real sender by
-- replacing the requirement parameter with its own sender entry.
local M = {}
type Outcome = {ok: boolean, value: unknown, error: unknown}
local function deliver(_: unknown, _: unknown): (Outcome?, string?)
    return nil, "no forwarding sender is linked on this node"
end
M.deliver = deliver
return M
