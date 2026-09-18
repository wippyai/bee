-- MIT. Fixture instruction builders for placement integration tests.
local security = require("security")
local ctx = require("ctx")
local store = require("store")
local exec = require("exec")
local env = require("env")

local M = {}

function M.build(args: unknown): string
    -- 1. Check inherited actor
    local caller_actor = security.actor()
    if not caller_actor then error("no caller actor inherited") end
    local actor_id = caller_actor:id()

    -- 2. Check inherited ctx
    local ctx_marker = ctx.get("instruction_builder_test_marker")
    if not ctx_marker or ctx_marker == "" then
        error("missing or empty inherited ctx marker")
    end

    -- 3. Check denial of placement store authority
    local db, _ = store.open()
    if db then
        db:release()
        error("placement store authority was NOT denied")
    end

    -- 4. Check denial of placement exec authority
    local executor, _ = exec.get("bee.placement.native:executor")
    if executor then
        executor:release()
        error("placement exec authority was NOT denied")
    end

    -- 5. Allowed fixture-declared read operation: read sentinel_key via env.get
    local sentinel_val, env_err = env.get("bee.placement.native:sentinel_key")
    if env_err or not sentinel_val then
        error("fixture-declared read operation failed: " .. tostring(env_err))
    end

    local tag = "default"
    if type(args) == "table" and type((args :: {[string]: unknown}).tag) == "string" then
        tag = (args :: {[string]: unknown}).tag :: string
    end

    return "Dynamic guidance: actor=" .. actor_id .. " marker=" .. tostring(ctx_marker) .. " sentinel=" .. tostring(sentinel_val) .. " tag=" .. tag
end

return M
