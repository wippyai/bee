-- MIT. Destination audience table: the host-owned list of the peers each
-- listed open operation admits. An unlisted operation stays as exposed as
-- its ceiling; a listed one admits its local callers and its peers.
local bounds = require("bounds")
local M = {}
M.ENTRY = "bee.hive.supervisor:exposure_audiences"
M.ENTRY_TYPE = "bee.hive.exposure_audiences"
M.MAX_OPERATIONS = 64
M.MAX_PEERS = 16
type Audience = {operation_ref: string, peers: {[string]: boolean}}
type Audiences = {list: {Audience}, by_operation: {[string]: Audience}}
local function decode_row(item: unknown, position: integer): (Audience?, string?)
    local row = bounds.object(item)
    if not row then return nil, "audiences[" .. tostring(position) .. "] must be an object" end
    local unknown_field = bounds.fields(row, {"operation_ref", "peers"})
    if unknown_field then return nil, "audiences[" .. tostring(position) .. "]: " .. unknown_field end
    local operation_ref = bounds.id(row.operation_ref)
    if not operation_ref or not operation_ref:match("^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+$") then
        return nil, "audiences[" .. tostring(position) .. "] operation_ref is not an operation reference"
    end
    if type(row.peers) ~= "table" then return nil, "audiences[" .. tostring(position) .. "] peers must be a list" end
    local peers: {[string]: boolean} = {}
    local count = 0
    for _, raw in ipairs(row.peers :: {unknown}) do
        if type(raw) ~= "string" or not (raw :: string):match("^[A-Za-z][A-Za-z0-9_.-]*$") or peers[raw :: string] then
            return nil, "audiences[" .. tostring(position) .. "] peer is invalid or repeated"
        end
        peers[raw :: string] = true
        count = count + 1
    end
    if count == 0 or count > M.MAX_PEERS then
        return nil, "audiences[" .. tostring(position) .. "] peers list is empty or exceeds bound"
    end
    return {operation_ref = operation_ref, peers = peers}, nil
end
function M.decode(value: unknown): (Audiences?, string?)
    local object = bounds.object(value)
    if not object then return nil, "exposure audiences must be an object" end
    local unknown_field = bounds.fields(object, {"audiences"})
    if unknown_field then return nil, unknown_field end
    if type(object.audiences) ~= "table" then return nil, "audiences must be a list" end
    local raw = object.audiences :: {unknown}
    if #raw > M.MAX_OPERATIONS then return nil, "audiences exceeds " .. tostring(M.MAX_OPERATIONS) .. " operations" end
    local list: {Audience} = {}
    local by_operation: {[string]: Audience} = {}
    for position, item in ipairs(raw) do
        local row, row_error = decode_row(item, position)
        if not row then return nil, row_error end
        if by_operation[row.operation_ref] then return nil, "audiences repeats " .. row.operation_ref end
        by_operation[row.operation_ref] = row
        list[#list + 1] = row
    end
    return {list = list, by_operation = by_operation}, nil
end
-- admits: a listed operation admits the owner's own callers and its peers;
-- an unlisted one is unrestricted by audiences. The caller passes the
-- authenticated principal issuer and caller node, never bare request values.
function M.admits(audiences: Audiences, operation_ref: string, owner_node: string, caller_node: string, issuer: string): boolean
    if issuer == owner_node then return true end
    local row = audiences.by_operation[operation_ref]
    if not row then return true end
    return row.peers[caller_node] == true
end
return M
