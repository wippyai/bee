-- MIT. Call the entry the review surface reported as settled and applied.
-- A separate boot over the same registry history, the same simplification
-- tests/app_journey.py uses for its own deliver/inspect split, so the call
-- reaches only what governed apply actually persisted. Boot recovery
-- re-establishes the owner-local overlay asynchronously (see
-- tests/fixtures/app_journey/inspect.lua), so observe until it settles
-- before calling.
local funcs = require("funcs")
local registry = require("registry")
local time = require("time")
local logger = require("logger")

local READY_ENTRY = "bee.delivery_review_ready:probe"

local function main()
    local entry: unknown = nil
    for attempt = 1, 60 do
        entry = registry.get(READY_ENTRY)
        if entry then break end
        if attempt < 60 then time.sleep("250ms") end
    end
    if not entry then error("booted host does not compose the applied entry " .. READY_ENTRY) end
    local result, err = funcs.call(READY_ENTRY, {probe = "delivery-review"})
    if err then error(READY_ENTRY .. " call failed: " .. tostring(err)) end
    logger:info("DELIVERY_REVIEW_INVOKED", {result = result})
end

return {main = function(...)
    local ok, err = pcall(main, ...)
    if not ok then
        logger:info("DELIVERY_REVIEW_INVOKE_FAILED", {error = tostring(err)})
        error(err)
    end
end}
