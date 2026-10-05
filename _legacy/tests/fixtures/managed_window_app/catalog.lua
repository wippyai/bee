local bounds = require("bounds")
-- Fixture-only sessions catalog owner.
local registry = require("registry")
local M = {}

-- The sessions catalog owner of the fixture composition: the selector
-- definition is listed while its Start-menu presentation is visible.
function M.catalog(_: unknown): {[string]: unknown}
    local entry = registry.get("bee.managed.window.fixture:selector_definition")
    local data = entry and assert(bounds.object(entry.data)) or {}
    local presentation = bounds.object(data.presentation)
    local items: {{[string]: unknown}} = {}
    if presentation and presentation.start_menu == true then
        items[1] = {ref = "bee.managed.window.fixture:selector_definition", kind = "definition", title = tostring(data.title),
            status = "ready", checked_at = "2026-01-01T00:00:00.000Z", reasons = {}, features = {"presentation:start_menu"}, actions = {}}
    end
    return {ok = true, value = {items = items, complete = true, unavailable_count = 0, diagnostics = {}}}
end

return M
