-- MIT. Read what a freshly booted host composes for the delivered
-- application: the reviewed definition itself and the effective admission
-- catalog the application broker reads. Boot recovery re-establishes the
-- owner-local overlay asynchronously, so observe until it settles.
local registry = require("registry")
local time = require("time")
local logger = require("logger")
local env = require("env")
local catalog = require("catalog")
local bounds = require("bounds")

local DEFINITION_ID = "bee.app_journey_demo:app"

local function admitted_title(workspace_id: string): string?
    for _, item in ipairs(catalog.read(workspace_id).items) do
        if item.definition_id == DEFINITION_ID then return item.title end
    end
    return nil
end

local function main()
    local workspace_id = bounds.id(env.get("bee.app.journey.probe:destination_workspace"))
    if not workspace_id then error("destination workspace identity is unavailable") end
    local entry: unknown = nil
    local title: string? = nil
    for attempt = 1, 60 do
        entry = registry.get(DEFINITION_ID)
        title = entry and admitted_title(workspace_id) or nil
        if entry and title then break end
        if attempt < 60 then time.sleep("250ms") end
    end
    logger:info("APP_JOURNEY_COMPOSED", {entry_present = entry ~= nil, admitted_title = title or ""})
    if not entry then error("booted host does not compose the applied definition") end
    if not title then error("booted host does not admit the applied definition") end
end

return {main = main}
