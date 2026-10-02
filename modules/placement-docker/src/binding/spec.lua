-- SPDX-License-Identifier: MIT
local profiles = require("profiles")
local types = require("types")
local bounds = require("bounds")
local M = {}
M.BINDING = "bee.placement.docker.binding:binding"
M.HOME = "/home/bee"
type Spec = {profile_ref: string, profile_digest: string, image: string, user: string, network: string, limits: profiles.Limits,
    mounts: {profiles.Mount}, interactive_route_ref: string?, attempt_id: string}
type Observation = {backend_ref: string, state: string, attempt_id: string, home_source: string, observed_image_digest: string, exit_code: integer?}
function M.admit(profile: profiles.Resolved, request: types.LaunchRequest): string?
    local value = profile.profile
    if value.placement_binding ~= M.BINDING or not value.user or not value.network or not value.limits then
        return "profile does not select Docker placement"
    end
    if request.placement_profile_ref ~= profile.ref or request.placement_profile_digest ~= profile.digest then return "placement profile changed since admission" end
    if request.environment_refs.HOME or request.environment.HOME then return "Docker requires a private provider home" end
    if request.launch.provider_home and not request.launch.provider_home.private then return "Docker requires private provider projection" end
    local granted: {[string]: types.ResourceGrant} = {}
    for _, grant in ipairs(request.resources) do granted[grant.name] = grant end
    for _, mount in ipairs(value.mounts) do
        local grant = granted[mount.resource]
        if not grant or (mount.access == "write" and grant.access ~= "write") then return "Docker mount has no admitted resource grant: " .. mount.resource end
    end
    return nil
end
function M.resolve(profile: profiles.Resolved, request: types.LaunchRequest, admitted_digest: string?, resolved_image: string?, resolved_route: string?): (Spec?, string?)
    local reason = M.admit(profile, request)
    if reason then return nil, reason end
    local value = profile.profile
    if not value.image_ref and not resolved_image then return nil, "runtime image is not prepared" end
    return {profile_ref = profile.ref, profile_digest = profile.digest, image = value.image_ref or assert(resolved_image), user = assert(value.user), network = assert(value.network),
        limits = assert(value.limits), mounts = value.mounts, attempt_id = request.attempt_id, interactive_route_ref = value.interactive_route_ref or resolved_route}, nil
end
function M.decode(value: unknown, request: types.LaunchRequest, admitted_digest: string?): (Spec?, string?)
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"profile_ref", "profile_digest", "image", "user", "network", "limits", "mounts", "interactive_route_ref", "attempt_id"}) then return nil, "stored Docker specification is malformed" end
    local profile, profile_error = profiles.decode({schema_revision = profiles.SCHEMA, placement_binding = M.BINDING,
        image_ref = raw.image, user = raw.user, network = raw.network, limits = raw.limits, mounts = raw.mounts, interactive_route_ref = raw.interactive_route_ref})
    if not profile then return nil, profile_error end
    local ref, digest = bounds.id(raw.profile_ref), bounds.line(raw.profile_digest, 64)
    if not ref or not digest or ref ~= request.placement_profile_ref then return nil, "stored Docker profile has another identity" end
    local decoded, decode_error = M.resolve({ref = ref, digest = digest, profile = profile}, request, admitted_digest)
    if not decoded then return nil, decode_error end
    if raw.attempt_id ~= request.attempt_id then return nil, "stored Docker attempt has another identity" end
    return decoded, nil
end
function M.container_id(value: unknown): string?
    local ref = bounds.line(value, 64)
    if not ref or #ref ~= 64 or not ref:match("^[0-9a-f]+$") then return nil end
    return ref
end
function M.attempt(value: unknown): (string?, string?)
    local raw = bounds.object(value)
    local config = raw and bounds.object(raw.Config) or nil
    local environment = config and bounds.array(config.Env, 256) or nil
    if not environment then return nil, "container environment is malformed" end
    local found: string? = nil
    for _, item in ipairs(environment) do
        if type(item) ~= "string" then return nil, "container environment is malformed" end
        if item:sub(1, 15) == "BEE_ATTEMPT_ID=" then
            if found then return nil, "container has duplicate attempt identity" end
            found = bounds.id(item:sub(16))
            if not found then return nil, "container has invalid attempt identity" end
        end
    end
    return found, nil
end
function M.inspect(value: unknown, spec: Spec, home_source: string, image_id: string): (Observation?, string?)
    local raw = bounds.object(value)
    local config = raw and bounds.object(raw.Config) or nil
    local state = raw and bounds.object(raw.State) or nil
    if not raw or not config or not state or config.Image ~= spec.image or raw.Image ~= image_id then
        return nil, "container inspection differs from the admitted image digest"
    end
    local ref = M.container_id(raw.Id)
    if not ref then return nil, "Docker observation requires an immutable container ID" end
    local attempt, attempt_error = M.attempt(raw)
    if attempt_error or attempt ~= spec.attempt_id then return nil, attempt_error or "container has another attempt identity" end
    local mounts = bounds.array(raw.Mounts, 32)
    if not mounts then return nil, "container mounts are malformed" end
    local found = false
    for _, value in ipairs(mounts) do
        local mount = bounds.object(value)
        if not mount then return nil, "container mount is malformed" end
        if mount.Destination == M.HOME then
            if found or mount.Type ~= "bind" or mount.Source ~= home_source or mount.RW ~= true then
                return nil, "container has another provider home mount"
            end
            found = true
        end
    end
    if not found then return nil, "container has no provider home mount" end
    local status = bounds.member(state.Status, {"created", "running", "exited"})
    if not status then return nil, "container has an unsupported state" end
    local observed: Observation = {backend_ref = ref, state = status, attempt_id = spec.attempt_id, home_source = home_source,
        observed_image_digest = image_id}
    if status == "exited" then
        local code = bounds.integer(state.ExitCode)
        if not code then return nil, "container inspection has no valid exit code" end
        observed.exit_code = code
    end
    return observed, nil
end
return M
