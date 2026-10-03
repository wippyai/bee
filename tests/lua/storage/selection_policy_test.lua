-- SPDX-License-Identifier: MIT
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local binding = require("binding")

local function select(kind: unknown, resource: unknown): {id: string?, error: string?}
    if kind ~= "workspace" and kind ~= "client" then error("invalid test store kind") end
    local id, err = binding.database(kind, resource)
    if id then assert(security.can("db.get", id)) end
    return {id = id, error = err}
end

local function run()
    test.describe("Host store selection policies", function()
        for _, kind in ipairs({"workspace", "client"}) do
            test.it("reads the " .. kind .. " descriptor under its exact storage grant", function()
                local policy = assert(security.policy("bee.security.storage:" .. kind .. "_storage_policy"))
                local probe = assert(security.policy("bee.storage:selection_probe_policy"))
                local caller = assert(funcs.new():with_scope(security.new_scope({policy, probe})))
                local result, err = caller:call("bee.storage:selection_probe", kind, nil)
                test.is_nil(err)
                if type(result) ~= "table" then error("invalid store selection reply") end
                test.is_nil(result.error)
                test.eq(result.id, "bee.env:" .. kind .. "_db")
                local other = kind == "workspace" and "bee.env:client_db" or "bee.env:workspace_db"
                local refused, refusal = caller:call("bee.storage:selection_probe", kind, other)
                test.is_nil(refusal)
                if type(refused) ~= "table" then error("invalid refused store selection reply") end
                test.is_nil(refused.id)
                test.eq(refused.error, "Read database selection " .. other .. ": not allowed to access entry: " .. other)
            end)
        end
    end)
end

local cases = test.run_cases(run)
return {run = function(options: unknown) return cases(options) end, select = select}
