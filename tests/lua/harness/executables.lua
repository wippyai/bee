-- MIT. Executable paths selected by the isolated test host.
local env = require("env")
local M = {}
function M.fixture_bin(): string
    local bin, err = env.get("bee.tests.harness:fixture_bin")
    if err or type(bin) ~= "string" or bin == "" then error("BEE_FIXTURE_BIN is not set for the test runtime") end
    return bin
end
function M.claude_bin(): string?
    local bin, err = env.get("bee.tests.harness:claude_bin")
    if err or type(bin) ~= "string" or bin == "" then return nil end
    return bin
end
function M.codex_bin(): string?
    local bin, err = env.get("bee.tests.harness:codex_bin")
    if err or type(bin) ~= "string" or bin == "" then return nil end
    return bin
end
return M
