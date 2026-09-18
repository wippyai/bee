-- MIT. A real guest reads only its admitted filesystem mount.
local funcs = require("funcs")
local logger = require("logger")
local function main()
    local read, read_error = funcs.call("bee.governance_wasm_probe:probe", 0)
    logger:info("WASM_FS_READ", {result = tostring(read), error = tostring(read_error)})
    assert(not read_error and read == 1109, "WASM admitted read failed: " .. tostring(read_error) .. " / " .. tostring(read))
    for mode = 1, 3 do
        local result, call_error = funcs.call("bee.governance_wasm_probe:probe", mode)
        logger:info("WASM_FS_REFUSAL", {mode = mode, result = tostring(result), error = tostring(call_error)})
        assert(not call_error, tostring(call_error))
        assert(type(result) == "number" and result > 0 and result < 1000, "WASM write or containment refusal missing for mode " .. tostring(mode) .. ": " .. tostring(result))
    end
    logger:info("GOVERNANCE_WASM_FS_PASS")
end
return {main = main}
