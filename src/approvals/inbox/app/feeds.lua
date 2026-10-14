-- MIT. A transport-independent approval adapter for the shared sync protocol.
-- Every UI identity is qualified by the host-selected owner; requests keep their
-- real identity only on the route back to that owner.
local bounds = require("bounds")
local sync = require("sync")
local source_config = require("source_config")
local model = require("model")
local M = {}
type Object = {[string]: unknown}
type Source = source_config.Source
type ApprovalView = model.ApprovalView
type Call = (Source, string, unknown) -> (unknown, string?)
type Address = {source: Source, approval_id: string}
type AddressBook = {[string]: Address}
type Catchup = {reply: model.Reply, reset: boolean}
type Client = {
    lease: (Client, string, unknown) -> unknown?,
    workspaces: {string}, sources: {[string]: Source}, addresses: {[string]: Address},
    states: {[string]: sync.State}, refreshes: {[string]: integer}, call: Call,
    invoke: (Client, string, unknown) -> model.Reply?,
}
local function failure(code: string, message: string, purged: boolean?): model.Reply
    return {kind = "failure", code = code, message = message, replayed = false, purged = purged}
end
local function view_for(self: Client, source: Source, raw: unknown, addresses: AddressBook?): (ApprovalView?, string?)
    local decoded, err = model.decode_view(raw)
    if not decoded then return nil, err end
    if decoded.owner_node ~= source.node_id or decoded.workspace_id ~= source.workspace_id then return nil, "approval projection belongs to another owner" end
    local real_id = decoded.approval_id
    local ui_id = source.local_owner and real_id or source_config.remote_id(source.id, real_id)
    local result: Object = {}
    for key, value in pairs(decoded) do result[key] = value end
    result.approval_id, result.workspace_id = ui_id, source.id
    result.source_approval_id, result.source_workspace_id = real_id, source.workspace_id
    local qualified, qualify_error = model.decode_view(result)
    if not qualified then return nil, qualify_error end
    local address_book = addresses or self.addresses
    address_book[ui_id] = {source = source, approval_id = real_id}
    return qualified, nil
end
local function invoke_owner(self: Client, source: Source, target: string, request: unknown): model.Reply?
    local raw, err = self.call(source, target, request)
    if err then return failure("UNKNOWN_OUTCOME", err) end
    local reply = model.decode_reply(raw)
    if not reply then return failure("INVALID_REPLY", "approval owner returned a malformed reply") end
    return reply
end
local function purge_source(self: Client, source: Source)
    self.states[source.id], self.refreshes[source.id] = nil, nil
    for key, address in pairs(self.addresses) do
        if address.source.id == source.id then self.addresses[key] = nil end
    end
end
local function fault_code(reply: model.Reply): string?
    if reply.kind == "failure" then return reply.code end
    if reply.kind == "reset" then return reply.code end
    if reply.kind == "conflict" then return reply.code end
    if reply.kind == "settled" then return reply.code end
    return nil
end
local function reject_source(self: Client, source: Source, reply: model.Reply): model.Reply
    if reply.kind ~= "success" and (reply.code == "RESET_REQUIRED" or reply.code == "DENIED") then
        purge_source(self, source)
        reply.purged = true
    end
    return reply
end
local function decode_event_payload(value: unknown): (unknown?, string?)
    local payload = bounds.object(value)
    if not payload then return nil, "approval event payload is not an object" end
    local extra = bounds.fields(payload, {"schema_revision", "request"})
    if extra then return nil, extra end
    if payload.schema_revision ~= "bee.approval-projection@1" then return nil, "approval event payload schema is unsupported" end
    local request, request_error = model.decode_view(payload.request)
    if not request then return nil, request_error or "approval event request is invalid" end
    return {request = request}, nil
end
local function snapshot(self: Client, source: Source): model.Reply
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
        if reply.kind ~= "success" then return reject_source(self, source, reply) end
        local page, decode_error = sync.snapshot(reply.value, source.node_id, source.feed, model.decode_view)
        if not page then
            purge_source(self, source)
            return failure("UNAVAILABLE", decode_error or "invalid snapshot", true)
        end
        for _, item in ipairs(page.items) do
            if item.tombstone then
                if item.value ~= nil then
                    purge_source(self, source)
                    return failure("UNAVAILABLE", "approval tombstone has a value", true)
                end
            else
                local body = model.decode_view(item.value)
                if not body or body.owner_node ~= source.node_id or body.workspace_id ~= source.workspace_id
                or body.approval_id ~= item.key or body.revision ~= item.revision then
                    purge_source(self, source)
                    return failure("UNAVAILABLE", "approval snapshot identity mismatch", true)
                end
            end
        end
        local changed, fold_error = sync.apply_snapshot(next_state, page)
        if changed == nil then
            purge_source(self, source)
            return failure("UNAVAILABLE", fold_error or "snapshot changed", true)
        end
        if page.complete then
            local changes: {{seq: integer, request: ApprovalView}} = {}
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
            table.sort(changes, function(left, right) return left.seq < right.seq end)
            purge_source(self, source)
            for key, address in pairs(staged) do self.addresses[key] = address end
            self.states[source.id] = next_state
            self.refreshes[source.id] = 0
            return {kind = "success", value = {changes = changes, next_seq = next_state.cursor, more = false, replace_source = true}, replayed = false}
        end
    end
    return failure("CAPACITY_EXHAUSTED", "inbox snapshot exceeds eight pages")
end
local function catchup(self: Client, source: Source, state: sync.State): Catchup
    if not state.scope_revision then return {reply = failure("RESET_REQUIRED", "approval feed has no visibility scope"), reset = true} end
    local reply = invoke_owner(self, source, "bee.approvals.binding:feed_read_after", {workspace_id = source.workspace_id,
        cursor = state.cursor, limit = 64, expected_scope_revision = state.scope_revision})
    if not reply then return {reply = failure("UNAVAILABLE", "approval owner did not answer"), reset = false} end
    if reply.kind ~= "success" then
        local code = fault_code(reply)
        if code == "RESET_REQUIRED" then return {reply = reply, reset = true} end
        return {reply = reject_source(self, source, reply), reset = false}
    end
    local page, decode_error = sync.page(reply.value, source.node_id, source.feed, decode_event_payload)
    if not page then return {reply = failure("RESET_REQUIRED", decode_error or "invalid approval feed page"), reset = true} end
    local changes: {{seq: integer, request: ApprovalView}} = {}
    local staged: AddressBook = {}
    local incoming: {[string]: boolean} = {}
    local visible = 0
    for _, projection in pairs(state.projections) do
        if not projection.tombstone then incoming[projection.key] = true; visible = visible + 1 end
    end
    for _, event in ipairs(page.events) do
        if event.tombstone then return {reply = failure("RESET_REQUIRED", "approval feed does not carry tombstones"), reset = true} end
        local payload = bounds.object(event.payload)
        local view = payload and model.decode_view(payload.request) or nil
        if not view or view.owner_node ~= source.node_id or view.workspace_id ~= source.workspace_id
            or view.approval_id ~= event.projection_key or view.revision ~= event.revision then
            return {reply = failure("RESET_REQUIRED", "approval feed identity or revision mismatch"), reset = true}
        end
        if not incoming[view.approval_id] then
            incoming[view.approval_id] = true
            visible = visible + 1
        end
    end
    if visible > 256 then return {reply = failure("CAPACITY_EXHAUSTED", "inbox source exceeds 256 visible requests"), reset = false} end
    local changed, fold_error = sync.apply_page(state, page, function(current: sync.State, event: sync.Event): (boolean?, string?)
        local payload = bounds.object(event.payload)
        if not payload then return nil, "approval event payload is invalid" end
        local body, view_error = model.decode_view(payload.request)
        if not body then return nil, view_error or "approval feed request is invalid" end
        local original = body
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
    return {reply = {kind = "success", value = {changes = changes, next_seq = state.cursor, more = page.more}, replayed = false}, reset = false}
end
local function reset_and_snapshot(self: Client, source: Source): model.Reply
    purge_source(self, source)
    local rebuilt: model.Reply = snapshot(self, source)
    if rebuilt.kind == "success" then return rebuilt end
    rebuilt.purged = true
    return rebuilt
end
local function refresh(self: Client, source: Source): model.Reply
    local state = self.states[source.id]
    local count = self.refreshes[source.id] or 0
    if state and count < 8 then
        local caught = catchup(self, source, state)
        if caught.reset then
            return reset_and_snapshot(self, source)
        end
        if caught.reply.kind == "success" then self.refreshes[source.id] = count + 1 end
        return caught.reply
    end
    return snapshot(self, source)
end
-- A batch is one owner transaction, so every request must route to the same
-- owner; each UI identity is translated back to the owner's own before the call.
local function decide_batch(self: Client, request: Object): model.Reply?
    local items = bounds.dense_list(request.decisions, 16, "decisions")
    if not items or #items == 0 then return failure("INVALID_ARGUMENT", "decisions must list 1 to 16 requests") end
    local owner: Source? = nil
    local outbound: {Object} = {}
    for _, raw in ipairs(items) do
        local item = bounds.object(raw)
        local address = item and bounds.id(item.approval_id) and self.addresses[bounds.id(item.approval_id)] or nil
        if not item or not address then return failure("DENIED", "approval owner is not known") end
        if owner and owner.id ~= address.source.id then return failure("INVALID_ARGUMENT", "a batch decides requests of one owner") end
        owner = address.source
        local copied: Object = {}
        for key, value in pairs(item) do copied[key] = value end
        copied.approval_id = address.approval_id
        outbound[#outbound + 1] = copied
    end
    if not owner then return failure("INVALID_ARGUMENT", "decisions must list 1 to 16 requests") end
    local answer = invoke_owner(self, owner, "bee.approvals.binding:decide_batch", {decisions = outbound, window_ttl_ms = request.window_ttl_ms})
    if not answer then return nil end
    if answer.kind ~= "success" then return answer end
    local body = bounds.object(answer.value)
    local views = body and body.decisions
    if type(views) ~= "table" then return failure("INVALID_REPLY", "approval owner returned no decisions") end
    local converted: {unknown} = {}
    for _, raw in ipairs(views) do
        local view, view_error = view_for(self, owner, raw)
        if not view then return failure("INVALID_REPLY", view_error or "invalid owner reply") end
        converted[#converted + 1] = view
    end
    return {kind = "success", value = {decisions = converted}, replayed = answer.replayed}
end
local function invoke(self: Client, target: string, value: unknown): model.Reply?
    local request = bounds.object(value)
    if not request then return failure("INVALID_ARGUMENT", "request must be an object") end
    if target == "bee.approvals.binding:inbox" then
        local workspace = bounds.id(request.workspace_id)
        local source = workspace and self.sources[workspace] or nil
        if not source then return failure("DENIED", "inbox source is not admitted") end
        return refresh(self, source)
    end
    if target == "bee.approvals.binding:grant" then
        if not bounds.member(request.operation, {"list", "read", "history", "revoke"}) then
            return failure("DENIED", "operation is not a grant management action")
        end
        local source: Source? = nil
        if request.workspace_id ~= nil then
            local workspace = bounds.id(request.workspace_id)
            source = workspace and self.sources[workspace] or nil
        else
            for _, workspace in ipairs(self.workspaces) do
                local candidate = self.sources[workspace]
                if candidate and candidate.local_owner then source = candidate; break end
            end
        end
        if not source or not source.local_owner then
            return failure("DENIED", "grants belong to the local authoritative node")
        end
        return invoke_owner(self, source, target, request)
    end
    if target == "bee.approvals.binding:grant_window" then
        local workspace = bounds.id(request.workspace_id)
        local source = workspace and self.sources[workspace]
        if not source or not source.local_owner then return failure("DENIED", "approval windows belong to the local authoritative node") end
        local outbound: Object = {}
        for key, item in pairs(request) do outbound[key] = item end
        outbound.workspace_id = source.workspace_id
        return invoke_owner(self, source, target, outbound)
    end
    if target == "bee.approvals.binding:decide_batch" then return decide_batch(self, request) end
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
    if answer.kind == "conflict" then
        local view, view_error = view_for(self, address.source, answer.request)
        if not view then return failure("INVALID_REPLY", view_error or "invalid owner reply") end
        return {kind = "conflict", code = answer.code, message = answer.message, request = view, replayed = answer.replayed}
    end
    if answer.kind == "settled" then
        local view, view_error = view_for(self, address.source, answer.request)
        if not view then return failure("INVALID_REPLY", view_error or "invalid owner reply") end
        return {kind = "settled", code = answer.code, message = answer.message, request = view, replayed = answer.replayed}
    end
    if answer.kind ~= "success" then return answer end
    local body = bounds.object(answer.value)
    if body and body.request ~= nil then
        local view, view_error = view_for(self, address.source, body.request)
        if not view then return failure("INVALID_REPLY", view_error or "invalid owner reply") end
        if body.withdrawn ~= nil and type(body.withdrawn) ~= "boolean" then return failure("INVALID_REPLY", "withdrawal result is malformed") end
        local copied: Object = {}
        for key, item in pairs(body) do copied[key] = item end
        copied.request = view
        return {kind = "success", value = copied, replayed = answer.replayed}
    end
    if body and body.approval_id ~= nil then
        local view, view_error = view_for(self, address.source, body)
        if not view then return failure("INVALID_REPLY", view_error or "invalid owner reply") end
        return {kind = "success", value = view, replayed = answer.replayed}
    end
    return failure("INVALID_REPLY", "approval owner returned no request view")
end
-- Lease operations belong to the governance owner of a local workspace; the
-- reply keeps governance's own result shape.
local function lease(self: Client, source_id: string, value: unknown): unknown?
    local source = self.sources[source_id]
    local request = bounds.object(value)
    if not source or not source.local_owner or not request then return nil end
    local outbound: Object = {}
    for key, item in pairs(request) do outbound[key] = item end
    outbound.workspace_id = source.workspace_id
    local raw, err = self.call(source, "bee.gov.binding:destination_call", outbound)
    if err then return nil end
    return raw
end
function M.new(configured: source_config.Config, call: Call): Client
    local self: Client = {workspaces = configured.workspaces, sources = configured.sources, addresses = {}, states = {}, refreshes = {}, call = call, invoke = invoke, lease = lease}
    return self
end
return M
