-- SPDX-License-Identifier: MIT
local bounds = require("bounds")
local hash = require("hash")
local canonical = require("canonical")
local registry = require("registry")
local M = {}
M.DEFAULT = "bee.placement:native"
M.TYPE = "bee.placement_profile"
M.SCHEMA = "bee.placement-profile@1"
type Access = "read" | "write"
type Mount = {resource: string, target: string, access: "read" | "write"}
type Limits = {memory: integer, cpu: integer, pids: integer}
type Profile = {placement_binding: string, image_ref: string?, image_recipe_ref: string?, user: string?, network: string?, limits: Limits?,
    interactive_route_ref: string?, mounts: {Mount}}
type Resolved = {ref: string, digest: string, profile: Profile}
local function absolute(value: unknown): string?
    if type(value) ~= "string" or #value > 4096 or value:sub(1, 1) ~= "/" or value:find("[%z%c:]") then return nil end
    for segment in value:gmatch("[^/]+") do if segment == "." or segment == ".." then return nil end end
    if value:find("//", 1, true) or (#value > 1 and value:sub(-1) == "/") then return nil end
    return value
end
function M.decode(value: unknown): (Profile?, string?)
    local object = bounds.object(value)
    if not object then return nil, "placement profile must be an object" end
    local extra = bounds.fields(object, {"schema_revision", "placement_binding", "image_ref", "image_recipe_ref", "user", "network", "limits", "interactive_route_ref", "mounts"})
    if extra then return nil, "placement profile: " .. extra end
    if object.schema_revision ~= M.SCHEMA then return nil, "unsupported placement profile schema" end
    local binding = bounds.id(object.placement_binding)
    if not binding then return nil, "placement profile requires placement_binding" end
    if binding == "bee.placement.native.binding:binding" then
        for key in pairs(object) do
            if key ~= "schema_revision" and key ~= "placement_binding" then return nil, "native placement has no " .. key end
        end
        local mounts: {Mount} = {}
        return {placement_binding = binding, mounts = mounts}, nil
    end
    if binding ~= "bee.placement.docker.binding:binding" then return nil, "unsupported placement binding" end
    local image = bounds.line(object.image_ref, 512)
    local recipe = bounds.id(object.image_recipe_ref)
    if (image == nil) == (recipe == nil) then return nil, "Docker profile selects exactly one pinned image or runtime recipe" end
    if object.image_recipe_ref ~= nil and not recipe then return nil, "invalid runtime recipe reference" end
    local digest = image and (image:match("^sha256:([0-9a-f]+)$") or image:match("^[A-Za-z0-9_.:/%-]+@sha256:([0-9a-f]+)$")) or nil
    if image and (not digest or #digest ~= 64) then return nil, "Docker image must be digest-pinned" end
    local user = bounds.line(object.user, 64)
    if not user or not user:match("^[1-9][0-9]*:[1-9][0-9]*$") then return nil, "Docker user must be a non-root uid:gid" end
    local network = bounds.line(object.network, 128)
    if not network or not network:match("^[A-Za-z0-9][A-Za-z0-9_.%-]*$") or network == "host" or network == "default" or network == "bridge" then
        return nil, "Docker network must name a host-selected network or none"
    end
    local limits = bounds.object(object.limits)
    if not limits or bounds.fields(limits, {"memory", "cpu", "pids"}) then return nil, "Docker limits require memory, cpu and pids" end
    local memory, cpu, pids = bounds.integer(limits.memory), bounds.integer(limits.cpu), bounds.integer(limits.pids)
    if not memory or memory < 16777216 or not cpu or cpu < 1000 or not pids or pids < 1 then return nil, "Docker limits must be positive" end
    local route = bounds.id(object.interactive_route_ref)
    if object.interactive_route_ref ~= nil and not route then return nil, "interactive_route_ref must be an identifier" end
    local raw, array_error = bounds.array(object.mounts or {}, 16)
    if not raw then return nil, "Docker mounts: " .. tostring(array_error) end
    local mounts: {Mount} = {}
    local targets: {string} = {"/home/bee", "/tmp", "/proc", "/sys", "/dev", "/run", "/"}
    local names: {[string]: boolean} = {}
    for _, value in ipairs(raw) do
        local item = bounds.object(value)
        if not item or bounds.fields(item, {"resource", "target", "access"}) then return nil, "Docker mount requires resource, target and access" end
        local resource, target = bounds.id(item.resource), absolute(item.target)
        local access: Access? = nil
        if item.access == "read" then access = "read" elseif item.access == "write" then access = "write" end
        if not resource or not target or not access then return nil, "Docker mount is invalid" end
        if names[resource] then return nil, "Docker resource mounted twice" end
        for _, existing in ipairs(targets) do
            if target == existing or (existing ~= "/" and (target:sub(1, #existing + 1) == existing .. "/" or existing:sub(1, #target + 1) == target .. "/")) then
                return nil, "Docker mount target overlaps a reserved or admitted target"
            end
        end
        targets[#targets + 1] = target; names[resource] = true
        mounts[#mounts + 1] = {resource = resource, target = target, access = access}
    end
    return {placement_binding = binding, image_ref = image, image_recipe_ref = recipe, user = user, network = network,
        limits = {memory = memory, cpu = cpu, pids = pids}, interactive_route_ref = route, mounts = mounts}, nil
end
function M.tune(resolved: Resolved, value: unknown): (Resolved?, string?)
    if value == nil then return resolved, nil end
    local raw = bounds.object(value)
    if not raw or bounds.fields(raw, {"image", "user", "network_policy_ref", "limits", "mounts", "tmpfs", "working_directory", "environment_policy_ref"}) then return nil, "Docker overrides are malformed" end
    local base = resolved.profile
    if base.placement_binding ~= "bee.placement.docker.binding:binding" or not base.limits then return nil, "Docker overrides require a Docker profile" end
    if raw.image ~= nil then
        local image = bounds.object(raw.image)
        if not image or bounds.fields(image, {"kind", "ref"}) or not
            ((image.kind == "digest" and image.ref == base.image_ref) or (image.kind == "recipe" and image.ref == base.image_recipe_ref)) then
            return nil, "Image override is outside the host template"
        end
    end
    if raw.user ~= nil and raw.user ~= base.user then return nil, "User override is outside the host template" end
    if raw.network_policy_ref ~= nil or raw.tmpfs ~= nil or raw.working_directory ~= nil or raw.environment_policy_ref ~= nil then return nil, "This host template admits no network, tmpfs, directory or environment overrides" end
    local limits: Limits = {memory = base.limits.memory, cpu = base.limits.cpu, pids = base.limits.pids}
    if raw.limits ~= nil then
        local requested = bounds.object(raw.limits)
        if not requested or bounds.fields(requested, {"memory_bytes", "cpu_millicpus", "pids"}) then return nil, "Docker override limits are malformed" end
        for _, field in ipairs({"memory_bytes", "cpu_millicpus", "pids"}) do
            if requested[field] ~= nil then
                local amount = bounds.count(requested[field])
                if not amount or amount < 1 then return nil, "Docker " .. field .. " override must be positive" end
                if field == "memory_bytes" then
                    if amount < 16777216 or amount > base.limits.memory then return nil, "Docker memory override exceeds the host ceiling" end
                    limits.memory = amount
                elseif field == "cpu_millicpus" then
                    -- The Docker template uses quota microseconds in a 100ms period.
                    if amount < 10 or amount > math.floor(base.limits.cpu / 100) then return nil, "Docker CPU override exceeds the host ceiling" end
                    limits.cpu = amount * 100
                else
                    if amount > base.limits.pids then return nil, "Docker pid override exceeds the host ceiling" end
                    limits.pids = amount
                end
            end
        end
    end
    local mounts = base.mounts
    if raw.mounts ~= nil then
        local rows = bounds.array(raw.mounts, 16)
        if not rows then return nil, "Docker override mounts must be bounded" end
        local selected: {Mount} = {}
        for _, value in ipairs(rows) do
            local item = bounds.object(value)
            local found: Mount? = nil
            if not item or bounds.fields(item, {"resource", "subpath", "target", "access"}) or (item.subpath ~= nil and item.subpath ~= "") then return nil, "Docker override mount is malformed" end
            for _, admitted in ipairs(base.mounts) do
                if item.resource == admitted.resource and item.target == admitted.target and (item.access == "read" or item.access == admitted.access) then
                    found = {resource = admitted.resource, target = admitted.target, access = item.access == "read" and "read" or admitted.access}
                end
            end
            if not found then return nil, "Docker override mount is outside the host template" end
            selected[#selected + 1] = found
        end
        mounts = selected
    end
    local profile, err = M.decode({schema_revision = M.SCHEMA, placement_binding = base.placement_binding, image_ref = base.image_ref,
        image_recipe_ref = base.image_recipe_ref, user = base.user, network = base.network, limits = limits,
        interactive_route_ref = base.interactive_route_ref, mounts = mounts})
    if not profile then return nil, err end
    return {ref = resolved.ref, digest = resolved.digest, profile = profile}, nil
end
function M.resolve(pinned: registry.Snapshot, requested: string?): (Resolved?, string?)
    local ref = requested or M.DEFAULT
    if not bounds.id(ref) then return nil, "placement profile ref must be an identifier" end
    local entry, entry_error = pinned:get(ref)
    if entry_error or not entry or entry.kind ~= "registry.entry" then return nil, "placement profile is unavailable" end
    local meta = bounds.object(entry.meta)
    if not meta or meta.type ~= M.TYPE then return nil, "entry is not a placement profile" end
    local profile, decode_error = M.decode(entry.data)
    if not profile then return nil, decode_error end
    local encoded, encode_error = canonical.encode({ref = ref, profile = profile})
    if not encoded then return nil, encode_error end
    local digest, digest_error = hash.sha256(encoded)
    if not digest then return nil, tostring(digest_error) end
    return {ref = ref, digest = digest, profile = profile}, nil
end
return M
