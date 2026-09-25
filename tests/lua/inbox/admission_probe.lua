-- MIT. A process run under the exact scope the broker composes for the
-- inbox application, reporting what that scope lets it reach: the
-- approval store directly, the owner's methods, unlisted owner operations
-- and the store again after an owner call. Test support only.
local sql = require("sql")
local funcs = require("funcs")
type Object = {[string]: unknown}
local function attempt_store(): string
    local db, err = sql.get("bee.approvals:db")
    if db then
        db:release()
        return "opened"
    end
    return "denied: " .. tostring(err)
end
local function call(target: string, request: unknown): string
    local raw, err = funcs.new():call(target, request)
    if err then return "error: " .. tostring(err) end
    if type(raw) ~= "table" then return "no reply" end
    local reply = raw :: Object
    if reply.ok == true then return "ok" end
    local fault = type(reply.error) == "table" and reply.error :: Object or {}
    return "refused: " .. tostring(fault.code)
end
local function main(value: unknown): Object
    local input = type(value) == "table" and value :: Object or {}
    local workspace = tostring(input.workspace_id or "")
    local approval_id = tostring(input.approval_id or "")
    local decision = tostring(input.decision or "approved")
    local report: Object = {}
    report.store_before = attempt_store()
    report.inbox = call("bee.approvals.binding:inbox", {workspace_id = workspace})
    local inbox_raw = funcs.new():call("bee.approvals.binding:inbox", {workspace_id = workspace})
    local visible = 0
    if type(inbox_raw) == "table" and (inbox_raw :: Object).ok == true then
        local page = (inbox_raw :: Object).value :: Object
        for _ in ipairs(page.changes :: {unknown}) do visible = visible + 1 end
    end
    report.visible = visible
    report.read = call("bee.approvals.binding:read", {approval_id = approval_id})
    report.list = call("bee.approvals.binding:list", {workspace_id = workspace})
    report.consume = call("bee.approvals.binding:consume", {approval_id = approval_id, proposal_digest = string.rep("a", 64), effect_key = "e1", owner_incarnation = 1})
    report.service = call("bee.approvals:service", {})
    report.store_after = attempt_store()
    if input.decide == true then
        local read_raw = funcs.new():call("bee.approvals.binding:read", {approval_id = approval_id})
        local digest, revision = "", 1
        if type(read_raw) == "table" and (read_raw :: Object).ok == true then
            local view = (read_raw :: Object).value :: Object
            digest, revision = tostring(view.proposal_digest), math.floor(tonumber(view.revision) or 1)
        end
        local decision_request: Object = {approval_id = approval_id, expected_revision = revision, decision = decision, proposal_digest = digest}
        if input.forge == true then
            -- Request payload metadata is untrusted and cannot stand in for
            -- the authenticated process actor's host-issued definition.
            decision_request.metadata = {definition_id = "bee.approvals.inbox:app"}
        end
        report.decide = call("bee.approvals.binding:decide", decision_request)
        report.store_after_decide = attempt_store()
    end
    return report
end
return {main = main}
