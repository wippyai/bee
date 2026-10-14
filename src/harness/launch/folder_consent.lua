local funcs = require("funcs")
local security = require("security")
local ctx = require("ctx")
local uuid = require("uuid")
local time = require("time")
local bounds = require("bounds")
local admission = require("admission")
local profile_values = require("profile_values")
local definitions = require("definitions")
local resources = require("resources")
local trust = require("trust")
local database = require("database")
local grants = require("grants")
local profile_grants = require("profile_grants")
local authority = require("authority")
local M = {}
type Object = {[string]: unknown}
local function call(target: string, request: Object): (Object?, string?)
    local raw, err = funcs.call(target, request)
    local reply = bounds.object(raw)
    local fault = reply and bounds.object(reply.error)
    if err or not reply or reply.ok ~= true then return nil, tostring(err or (fault and fault.message) or "Folder consent owner did not answer") end
    return bounds.object(reply.value), nil
end
function M.run(plan: admission.Plan, workspace: string, workdir: string?, executor: funcs.Executor): string?
    local profile = plan.effective_profile
    local placement = profile and profile.placement
    if plan.mode ~= "window" or not plan.saved_profile_id or not placement or placement.kind ~= "native" or placement.home ~= "private" then return nil end
    local actor = security.actor()
    local meta = actor and bounds.object(actor:meta())
    if not meta or meta.definition_id ~= "bee.harness.app:app" or ctx.get("bee.gateway.binding") ~= nil
        or not security.can("bee.approvals.decide", workspace) then return nil end
    local descriptor, _, schema_error = profile_values.schema(plan.binding_ref)
    if schema_error then return schema_error end
    local fields = descriptor and bounds.object(descriptor.options.fields)
    local field = fields and bounds.object(fields.folder_trust)
    local mapping = field and bounds.object(field.trust)
    if not mapping or mapping.unsupported == true then return nil end
    local launch, launch_error = definitions.load(plan.definition_ref)
    if not launch then return launch_error end
    local name = workdir or (launch.workdir_policy.kind == "declared_resource" and launch.workdir_policy.resource_ref or nil)
    if not name then return nil end
    local raw, list_error = executor:call("bee.resources.binding:list", {workspace_id = workspace})
    local listed = bounds.object(raw)
    local value = listed and bounds.object(listed.value)
    local associations = value and bounds.array(value.associations, 128)
    if list_error or not listed or listed.ok ~= true or not associations then return "Folder consent resources are unavailable" end
    local root: string? = nil
    local path: string? = nil
    for _, item in ipairs(associations) do
        local association = bounds.object(item)
        local ref = association and bounds.id(association.root_ref)
        if association and association.name == name and ref then
            root = resources.directory(ref)
            path = bounds.subpath(association.subpath)
        end
    end
    if not root or not path then return "Folder consent requires an admitted working folder" end
    local native_executor, executor_error = resources.executor()
    if not native_executor then return executor_error end
    local physical, physical_error = trust.admit(root .. (path ~= "" and ("/" .. path) or ""), {root}, native_executor,
        mapping.repository_root == true, bounds.ids(mapping.project_config, true))
    if not physical then return physical_error end
    local saved, save_error = call("bee.harness.binding:call", {operation = "get", workspace_id = workspace, profile_id = plan.saved_profile_id})
    local parent_id = saved and bounds.id(saved.grant_id)
    if not saved or not parent_id or saved.revision ~= plan.saved_profile_revision then return save_error or "Selected profile changed" end
    local db, open_error = database.open()
    if not db then return open_error end
    local parent, parent_error = grants.read(db, parent_id)
    if not parent or parent_error then db:release(); return parent_error or "Profile consent is unavailable" end
    local active_error = profile_grants.live(db, parent)
    if active_error then db:release(); return active_error end
    local existing, existing_error = profile_grants.folder(db, parent, physical, plan.binding_ref)
    db:release()
    if existing_error then return existing_error end
    if existing then return nil end
    local target: Object = {parent_grant_id = parent_id, canonical_workdir = physical, driver_binding_ref = plan.binding_ref, folder_trust = "approved-workdir"}
    local requested, request_error = call("bee.approvals.binding:request", {contract_version = 2, workspace_id = workspace,
        idempotency_key = "folder-consent:" .. assert(uuid.v7()), request_kind = "permission", policy = "configuration-setup",
        presentation = "inbox", proposal = {kind = "operation", ref = "bee.approvals:confirmation", revision = "1",
            payload = {action = "profile.folder_trust", target = target}}, scope = {type = "exact", parameters = target},
        prompt = {text = "Trust this folder for " .. profile.name .. "?\n" .. physical .. "\nBee remembers your approval for this profile and folder until you revoke it."}})
    if not requested then return request_error end
    local approval = bounds.id(requested.approval_id)
    if not approval then return "Folder consent has no approval identity" end
    local view = requested
    while view.state == "pending" do
        time.after("100ms"):receive()
        local observed, read_error = call("bee.approvals.binding:read", {approval_id = approval})
        if not observed then return read_error end
        view = observed
    end
    if view.state ~= "decided" or view.decision ~= "approved" then return "Folder trust was not approved" end
    local claim: Object = {operation = "claim", approval_id = approval, proposal_digest = view.proposal_digest,
        effect_key = approval, owner_incarnation = view.owner_incarnation}
    local consumed, consume_error = call("bee.approvals.binding:effect", claim)
    if not consumed then return consume_error end
    local effect = bounds.object(consumed.effect)
    if not effect then return "Folder consent has no admitted effect" end
    local started, start_error = call("bee.approvals.binding:effect", {operation = "start", approval_id = approval,
        proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, effect_key = approval,
        owner_incarnation = effect.owner_incarnation, expected_revision = effect.revision})
    if not started then return start_error end
    db, open_error = database.open()
    if not db then return open_error end
    local tx, begin_error = db:begin()
    if not tx then db:release(); return tostring(begin_error) end
    local recorded, record_error = authority.save_folder(tx, parent, physical, plan.binding_ref, approval)
    if not recorded then tx:rollback(); db:release(); return record_error end
    local committed, commit_error = tx:commit()
    if not committed or commit_error then tx:rollback(); db:release(); return tostring(commit_error) end
    db:release()
    local completed, completion_error = call("bee.approvals.binding:effect", {operation = "complete", approval_id = approval,
        proposal_digest = view.proposal_digest, reviewed_digest = view.reviewed_digest, effect_key = approval,
        result = {ok = true, grant_id = recorded.grant_id}})
    if not completed then return completion_error end
    return nil
end
return M
