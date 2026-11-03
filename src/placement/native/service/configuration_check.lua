-- SPDX-License-Identifier: MIT
-- The launch's admission of a person's provider configuration file, applied
-- to the file as the selected placement delivers it. Configuration setup runs
-- it before asking the person, so a file the launch refuses is never offered
-- for approval.
local registry = require("registry")
local bounds = require("bounds")
local formats = require("formats")
local types = require("types")
local provider_projection = require("provider_projection")
local profile_values = require("profile_values")
local placement_profiles = require("placement_profiles")
local effective_schema = require("effective_schema")
local docker_spec = require("docker_spec")
local M = {}
type Object = {[string]: unknown}
type Context = {binding_ref: string, policy_ref: string, placement_profile_ref: string?, options: Object}
function M.decode(raw: unknown): (Context?, string?)
    local object = bounds.object(raw)
    if not object or bounds.fields(object, {"binding_ref", "policy_ref", "placement_profile_ref", "options"}) then return nil, "Configuration check context is invalid." end
    local binding_ref, policy_ref = bounds.id(object.binding_ref), bounds.id(object.policy_ref)
    local placement_ref = object.placement_profile_ref ~= nil and bounds.id(object.placement_profile_ref) or nil
    local options = bounds.object(object.options == nil and {} or object.options)
    if not binding_ref or not policy_ref or not options or (object.placement_profile_ref ~= nil and not placement_ref) then
        return nil, "Configuration check needs the launch binding, policy, placement and options."
    end
    return {binding_ref = binding_ref, policy_ref = policy_ref, placement_profile_ref = placement_ref, options = options}, nil
end
local function container_home(provider: string, raw: unknown): types.ProviderHome
    local files: {types.ProviderHomeFile} = {}
    for _, item in ipairs(bounds.array((bounds.object(raw) or {}).files, 16) or {}) do
        local file = bounds.object(item) or {}
        local source_path, path = bounds.text(file.source_path, 512), bounds.text(file.path, 512)
        if file.kind == "config" and source_path and path then
            files[#files + 1] = {source_path = source_path, path = path, kind = "config", optional = file.optional == true, write_back = false,
                container_content = bounds.text(file.container_content, 8192), container_omit = bounds.ids(file.container_omit, true)}
        end
    end
    return {provider = provider, private = true, variable = nil, directory = nil, files = files}
end
-- check returns why the launch refuses content, the person's file at
-- source_path delivered into the session as base_path.
function M.check(context: Context, base_path: string, source_path: string, content: string): string?
    local descriptor, _, descriptor_error = profile_values.schema(context.binding_ref)
    if descriptor_error then return descriptor_error end
    if not descriptor then return nil end
    local policy_entry = registry.get(context.policy_ref)
    local policy = policy_entry and bounds.object(policy_entry.data) or {}
    local placement, placement_error = placement_profiles.placement(context.placement_profile_ref)
    if not placement then return placement_error or "The agent's placement is unavailable." end
    local delivered = content
    if placement.kind == "container" then
        local roots: {string} = {docker_spec.HOME}
        if context.placement_profile_ref then
            local mounted, roots_error = provider_projection.roots(context.placement_profile_ref)
            if not mounted then return roots_error or "Container configuration roots are unavailable." end
            for _, root in ipairs(mounted) do roots[#roots + 1] = root end
        end
        local selected: formats.Format = {schema_revision = formats.REVISION, environments = {}, file = {
            path = "configuration-admission", content_format = "opaque", initialize = {
                {path = base_path, source_path = source_path, content = content, on_missing_login = true}}}}
        local projected, projection_error = provider_projection.container(container_home(descriptor.provider, descriptor.provider_home), selected, roots)
        local file = projected and projected.file
        if not file or not file.initialize[1] then return projection_error or "The configuration could not be prepared for this placement." end
        delivered = file.initialize[1].content
    end
    return effective_schema.check_config(descriptor, policy, base_path, delivered, placement, context.options)
end
return M
