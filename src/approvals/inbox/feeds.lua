-- MIT. A transport-independent approval adapter for the shared sync protocol.
-- Every UI identity is qualified by the host-selected owner; requests keep their
-- real identity only on the route back to that owner.
local bounds = require("bounds")
local sync = require("sync")
local caller = require("caller")
local source_config = require("source_config")
local M = {}
type Object = {[string]: unknown}
type Source = source_config.Source
type Call = (Source, string, unknown) -> (unknown, string?)
type Address = {source: Source, approval_id: string}
type AddressBook = {[string]: Address}
type Catchup = {reply: caller.Reply, reset: boolean}
type Client = {
    workspaces: {string}, sources: {[string]: Source}, addresses: {[string]: Address},
    states: {[string]: sync.State}, refreshes: {[string]: integer}, call: Call,
    invoke: (Client, string, unknown) -> caller.Reply?,
}
local function failure(code: string, message: string): caller.Reply
    return {ok = false, error = {code = code, message = message}, value = nil, replayed = false}
end
local function decode_view(value: unknown): (unknown?, string?)
    local view = bounds.object(value)
    if not view or not bounds.id(view.approval_id) or not bounds.id(view.owner_node) or not bounds.id(view.workspace_id)
        or not bounds.id(view.requester_id) or not bounds.id(view.policy) or not bounds.id(view.proposal_digest)
        or not bounds.count(view.revision) or view.revision == 0 or not bounds.object(view.proposal)
        or not bounds.object(view.prompt) then return nil, "approval projection has invalid required fields" end
    if view.state ~= "pending" and view.state ~= "decided" and view.state ~= "expired" and view.state ~= "withdrawn" then
        return nil, "approval projection has invalid state"
    end
    return view, nil
end
local function view_for(self: Client, source: Source, raw: unknown, addresses: AddressBook?): (Object?, string?)
    local decoded, err = decode_view(raw)
    if not decoded then return nil, err end
    local original = decoded :: Object
    if original.owner_node ~= source.node_id or original.workspace_id ~= source.workspace_id then return nil, "approval projection belongs to another owner" end
    local real_id = original.approval_id :: string
    local ui_id = source.local_owner and real_id or source_config.remote_id(source.id, real_id)
    local result: Object = {}
    for key, value in pairs(original) do result[key] = value end
    result.approval_id, result.workspace_id = ui_id, source.id
    result.source_approval_id, result.source_workspace_id = real_id, source.workspace_id
    local address_book = addresses or self.addresses
    address_book[ui_id] = {source = source, approval_id = real_id}
    return result, nil
end
local function invoke_owner(self: Client, source: Source, target: string, request: unknown): caller.Reply?
    local raw, err = self.call(source, target, request)
    if err then return nil end
    return caller.decode(raw)
end
local function purge_source(self: Client, source: Source)
    self.states[source.id], self.refreshes[source.id] = nil, nil
    for key, address in pairs(self.addresses) do
        if address.source.id == source.id then self.addresses[key] = nil end
    end
end
local function reject_source(self: Client, source: Source, reply: caller.Reply): caller.Reply
    local code = reply.error and reply.error.code or "INTERNAL"
    if code == "RESET_REQUIRED" or code == "DENIED" then purge_source(self, source) end
    return reply
end
local function decode_event_payload(value: unknown): (unknown?, string?)
    local payload = bounds.object(value)
    if not payload then return nil, "approval event payload is not an object" end
    local extra = bounds.fields(payload, {"schema_revision", "request"})
    if extra then return nil, extra end
    if payload.schema_revision ~= "bee.approval-projection@1" then return nil, "approval event payload schema is unsupported" end
    local request, request_error = decode_view(payload.request)
    if not request then return nil, request_error or "approval event request is invalid" end
    return {request = request}, nil
end
local function snapshot(self: Client, source: Source): caller.Reply
    -- Stage a complete snapshot away from the visible cache. An interrupted or
    -- invalid page never exposes a partial snapshot or advances its cursor.
    local next_state = sync.new(source.node_id, source.feed)
    for page_number = 1, 8 do
        local request: Object = {workspace_id = source.workspace_id, limit = 64}
        if next_state.snapshot_after then
            request.after_key = next_state.snapshot_after
            request.expected_cursor = next_state.snapshot_cursor
            request.expected_scope_revision = next_state.scope_revision
        end
        local reply = invoke_owner(self, source, "bee.approvals.binding:feed_snapshot", request)
        if not reply then return failure("UNAVAILABLE", "approval owner did not answer") end
        if not reply.ok then return reject_source(self, source, reply) end
        local page, decode_error = sync.snapshot(reply.value, source.node_id, source.feed, decode_view)
        if not page then
            purge_source(self, source)
            return failure("RESET_REQUIRED", decode_error or "invalid snapshot")
        end
        for _, item in ipairs(page.items) do
            if item.tombstone then
                if item.value ~= nil then
                    purge_source(self, source)
                    return failure("RESET_REQUIRED", "approval tombstone has a value")
                end
            else
                local body = bounds.object(item.value)
                if not body or body.owner_node ~= source.node_id or body.workspace_id ~= source.workspace_id
                or body.approval_id ~= item.key or body.revision ~= item.revision then
                    purge_source(self, source)
                    return failure("RESET_REQUIRED", "approval snapshot identity mismatch")
                end
            end
        end
        local changed, fold_error = sync.apply_snapshot(next_state, page)
        if changed == nil then
            purge_source(self, source)
            return failure("RESET_REQUIRED", fold_error or "snapshot changed")
        end
        if page.complete then
            local changes: {Object} = {}
            local staged: AddressBook = {}
            local count = 0
            for _, item in pairs(next_state.projections) do
                if not item.tombstone then
                    count = count + 1
                    if count > 256 then return failure("CAPACITY_EXHAUSTED", "inbox source exceeds 256 visible requests") end
                    local view, view_error = view_for(self, source, item.value, staged)
                    if not view then return failure("INVALID_REPLY", view_error or "invalid request") end
                    changes[#changes + 1] = {seq = item.sequence, request = view}
                end
            end
            purge_source(self, source)
            for key, address in pairs(staged) do self.addresses[key] = address end
            self.states[source.id] = next_state
            self.refreshes[source.id] = 0
            return {ok = true, value = {changes = changes, next_seq = next_state.cursor, more = false, replace_source = true}, replayed = false}
        end
    end
    return failure("CAPACITY_EXHAUSTED", "inbox snapshot exceeds eight pages")
end
local function catchup(self: Client, source: Source, state: sync.State): Catchup
    if not state.scope_revision then return {reply = failure("RESET_REQUIRED", "approval feed has no visibility scope"), reset = true} end
    local reply = invoke_owner(self, source, "bee.approvals.binding:feed_read_after", {workspace_id = source.workspace_id,
        cursor = state.cursor, limit = 64, expected_scope_revision = state.scope_revision})
    if not reply then return {reply = failure("UNAVAILABLE", "approval owner did not answer"), reset = false} end
    if not reply.ok then
        local code = reply.error and reply.error.code or "INTERNAL"
        if code == "RESET_REQUIRED" then return {reply = reply, reset = true} end
        return {reply = reject_source(self, source, reply), reset = false}
    end
    local page, decode_error = sync.page(reply.value, source.node_id, source.feed, decode_event_payload)
    if not page then return {reply = failure("RESET_REQUIRED", decode_error or "invalid approval feed page"), reset = true} end
    local changes: {Object} = {}
    local staged: AddressBook = {}
    local changed, fold_error = sync.apply_page(state, page, function(current: sync.State, event: sync.Event): (boolean?, string?)
        if event.tombstone then return nil, "approval feed does not carry tombstones" end
        local payload = event.payload :: Object
        local request = payload.request
        local body, view_error = decode_view(request)
        if not body then return nil, view_error or "approval feed request is invalid" end
        local original = body :: Object
        if original.approval_id ~= event.projection_key or original.revision ~= event.revision then return nil, "approval feed revision does not match event" end
        local projection: sync.Projection = {owner_id = event.owner_id, feed = event.feed, key = event.projection_key,
            revision = event.revision, value = original, tombstone = false, sequence = event.sequence, updated_at = event.committed_at}
        local did_change = sync.fold_projection(current, projection)
        if did_change then
            local view, convert_error = view_for(self, source, original, staged)
            if not view then return nil, convert_error or "approval feed identity mismatch" end
            changes[#changes + 1] = {seq = event.sequence, request = view}
        end
        return did_change, nil
    end)
    if changed == nil then return {reply = failure("RESET_REQUIRED", fold_error or "approval feed changed"), reset = true} end
    for key, address in pairs(staged) do self.addresses[key] = address end
    return {reply = {ok = true, value = {changes = changes, next_seq = state.cursor, more = page.more}, replayed = false}, reset = false}
end
local function reset_and_snapshot(self: Client, source: Source): caller.Reply
    purge_source(self, source)
    local rebuilt = snapshot(self, source)
    if rebuilt.ok or (rebuilt.error and rebuilt.error.code == "DENIED") then return rebuilt end
    -- The old cache has already lost its scope. Tell the model to remove it
    -- even when the fresh snapshot is temporarily unavailable.
    return failure("RESET_REQUIRED", "approval feed reset; fresh snapshot is unavailable")
end
local function refresh(self: Client, source: Source): caller.Reply
    local state = self.states[source.id]
    local count = self.refreshes[source.id] or 0
    if state and count < 8 then
        local caught = catchup(self, source, state)
        if caught.reset then
            return reset_and_snapshot(self, source)
        end
        if caught.reply.ok then self.refreshes[source.id] = count + 1 end
        return caught.reply
    end
    return snapshot(self, source)
end
local function invoke(self: Client, target: string, value: unknown): caller.Reply?
    local request = bounds.object(value)
    if not request then return failure("INVALID", "request must be an object") end
    if target == "bee.approvals.binding:inbox" then
        local workspace = bounds.id(request.workspace_id)
        local source = workspace and self.sources[workspace] or nil
        if not source then return failure("DENIED", "inbox source is not admitted") end
        return refresh(self, source)
    end
    if target ~= "bee.approvals.binding:read" and target ~= "bee.approvals.binding:decide" and target ~= "bee.approvals.binding:withdraw" then
        return failure("DENIED", "operation is not an inbox action")
    end
    local ui_id = bounds.id(request.approval_id)
    local address = ui_id and self.addresses[ui_id] or nil
    if not address then return failure("DENIED", "approval owner is not known") end
    local outbound: Object = {}
    for key, item in pairs(request) do outbound[key] = item end
    outbound.approval_id = address.approval_id
    local answer = invoke_owner(self, address.source, target, outbound)
    if not answer then return nil end
    local body = bounds.object(answer.value)
    if body then
        local actual = body.request ~= nil and body.request or body
        if type(actual) == "table" and actual.approval_id ~= nil then
            local view, err = view_for(self, address.source, actual)
            if not view then return failure("INVALID_REPLY", err or "invalid owner reply") end
            if body.request ~= nil then
                local copied: Object = {}
                for key, item in pairs(body) do copied[key] = item end
                copied.request = view
                return {ok = answer.ok, error = answer.error, value = copied, replayed = answer.replayed}
            end
            return {ok = answer.ok, error = answer.error, value = view, replayed = answer.replayed}
        end
    end
    return answer
end
function M.new(configured: source_config.Config, call: Call): Client
    local self: Client = {workspaces = configured.workspaces, sources = configured.sources, addresses = {}, states = {}, refreshes = {}, call = call, invoke = invoke}
    return self
end
return M
