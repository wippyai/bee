-- MIT. Test-only carrier entry: the production run with a barrier that
-- stops the process after a named step, so recovery is proven from real
-- crash points. Excluded from packs.
local process = require("process")
local time = require("time")
local carrier = require("carrier_process")
local carrier_types = require("carrier_types")
local machine = require("machine")
local bounds = require("bounds")
local principals = require("principals")
local placement_types = require("placement_types")
local preferences_codec = require("preferences_codec")
local placement_request = require("placement_request")
-- crash_after ends the process at a step; pause_after holds it there until
-- the controller sends bee.carrier.continue, so a second carrier can act
-- in between. The controller hears bee.carrier.paused with the step name
-- once the process holds there. A comma-separated pause_after holds at each
-- named step in turn.
local function main(request: unknown, mode: string, controller: string?, crash_after: string?, batch: number?, pause_after: string?, slow_commit_ms: number?): {[string]: unknown}
    local chosen: "open" | "resume" = "open"
    if mode == "resume" then chosen = "resume" end
    if batch and batch >= 1 then machine.MAX_RECORDS_PER_COMMIT = math.floor(batch) end
    local continues = assert(process.listen("bee.carrier.continue", {message = true}))
    local pauses: {string} = {}
    for name in string.gmatch(pause_after or "", "[^,]+") do pauses[#pauses + 1] = name end
    local function after(step: string)
        if crash_after and step == crash_after then error("crash after " .. step) end
        if step == "committed" and slow_commit_ms and slow_commit_ms > 0 then time.sleep(tostring(math.floor(slow_commit_ms)) .. "ms") end
        if pauses[1] == step then
            table.remove(pauses, 1)
            if controller then process.send(controller, "bee.carrier.paused", step) end
            continues:receive()
        end
    end
    return carrier.run(request, chosen, controller, after)
end
local function optional_text(value: unknown): string?
    if value == nil then return nil end
    assert(type(value) == "string", "fixture optional text")
    return value
end
local function request(raw: unknown): machine.Request
    local value = assert(bounds.object(raw))
    assert(type(value.thread_id) == "string" and type(value.action_id) == "string" and type(value.attempt_id) == "string")
    assert(type(value.owner_id) == "string")
    local owner_incarnation = assert(bounds.integer(value.owner_incarnation))
    assert(type(value.binding_ref) == "string" and type(value.profile_id) == "string" and type(value.brief) == "string" and type(value.policy_ref) == "string")
    local resources: {placement_types.ResourceGrant} = {}
    for index, item in ipairs(principals.objects(value.resources)) do
        assert(type(item.name) == "string" and type(item.grant_ref) == "string" and type(item.root_ref) == "string" and type(item.subpath) == "string")
        local access: placement_types.Access
        if item.access == "read" then access = "read" elseif item.access == "write" then access = "write" else error("invalid fixture resource access") end
        local purpose: placement_types.Purpose
        if item.purpose == "project" then purpose = "project" elseif item.purpose == "session" then purpose = "session" elseif item.purpose == "cache" then purpose = "cache" elseif item.purpose == "output" then purpose = "output" else error("invalid fixture resource purpose") end
        resources[index] = {name = item.name, grant_ref = item.grant_ref, root_ref = item.root_ref, subpath = item.subpath, access = access, purpose = purpose}
    end
    local environment: {[string]: string} = {}
    for key, item in pairs(assert(bounds.object(value.environment))) do
        assert(type(item) == "string")
        environment[key] = item
    end
    local profile_grants: {carrier_types.ProfileGrant}? = nil
    if value.profile_grants ~= nil then
        local grants: {carrier_types.ProfileGrant} = {}
        for index, item in ipairs(principals.objects(value.profile_grants)) do
            assert(type(item.workspace_id) == "string" and type(item.name) == "string" and type(item.subpath) == "string" and type(item.grant_ref) == "string")
            local access: placement_types.Access
            if item.access == "read" then access = "read" elseif item.access == "write" then access = "write" else error("invalid fixture grant access") end
            grants[index] = {workspace_id = item.workspace_id, name = item.name, subpath = item.subpath, grant_ref = item.grant_ref, access = access}
        end
        profile_grants = grants
    end
    local projections: {string}? = nil
    if value.projections ~= nil then projections = principals.strings(value.projections) end
    local preferences: placement_types.Preferences? = nil
    if value.preferences ~= nil then preferences = assert(preferences_codec.decode(value.preferences)) end
    local options: placement_types.WorkdirOptions? = nil
    if value.options ~= nil then options = assert(placement_request.decode_options(value.options)) end
    local origin_view: {view_id: string, instance_id: string}? = nil
    if value.origin_view ~= nil then
        local view = assert(bounds.object(value.origin_view))
        assert(type(view.view_id) == "string" and type(view.instance_id) == "string")
        origin_view = {view_id = view.view_id, instance_id = view.instance_id}
    end
    local reauthorize: boolean? = nil
    if value.reauthorize ~= nil then
        assert(type(value.reauthorize) == "boolean")
        reauthorize = value.reauthorize
    end
    return {thread_id = value.thread_id, action_id = value.action_id, attempt_id = value.attempt_id,
        owner_id = value.owner_id, owner_incarnation = owner_incarnation, binding_ref = value.binding_ref,
        profile_id = value.profile_id, brief = value.brief, policy_ref = value.policy_ref, resources = resources, environment = environment,
        profile_grants = profile_grants, projections = projections, preferences = preferences, options = options, origin_view = origin_view,
        reauthorize = reauthorize, placement_profile_ref = optional_text(value.placement_profile_ref), placement_profile_digest = optional_text(value.placement_profile_digest),
        placement_binding_ref = optional_text(value.placement_binding_ref), placement_binding_digest = optional_text(value.placement_binding_digest),
        session_ref = optional_text(value.session_ref), previous_attempt_id = optional_text(value.previous_attempt_id), working_directory = optional_text(value.working_directory),
        workspace_id = optional_text(value.workspace_id), parent_action_id = optional_text(value.parent_action_id)}
end
return {main = main, request = request}
