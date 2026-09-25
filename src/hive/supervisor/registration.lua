-- MIT. Supervisor name publication decision. The eventual name is how a local
-- client discovers this supervisor, so it is published whenever the node has a
-- native identity and independently of the desktop bridge: a bridge failure must
-- not remove the only discovery path. This is a pure decision; the caller owns
-- the registry write.
local M = {}
type Decision = {publish: boolean, name: string, reason: string?}
-- decide returns whether this supervisor publishes its eventual name. A node
-- without a native identity cannot be addressed by a remote client, so it stays
-- local-only; everything else publishes, with or without a desktop bridge.
function M.decide(native_node: string, distributed_name: string): Decision
    if native_node == "" then
        return {publish = false, name = distributed_name, reason = "no native node identity"}
    end
    return {publish = true, name = distributed_name}
end
return M
