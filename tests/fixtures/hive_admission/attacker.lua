-- SPDX-License-Identifier: MIT
-- Unprivileged attacker actor testing direct and context-bound spawn variants.
local process = require("process")
local protocol = require("protocol")

type VariantResult = {
    admitted: boolean,
    pid: string?,
    err_msg: string
}

type AttackerReport = {
    phase: integer,
    any_admitted: boolean,
    results: {[string]: VariantResult}
}

local function main(phase_arg: unknown): AttackerReport
    local phase_num: integer = 1
    if type(phase_arg) == "number" and phase_arg == math.floor(phase_arg) then
        phase_num = math.floor(phase_arg)
    end

    local target: string = "bee.hive_admission:probe"
    local host: string = "bee.hive_admission:supervisor_host"
    local results: {[string]: VariantResult} = {}
    local any_admitted: boolean = false

    local function run_variant(name: string, fn: () -> (unknown, unknown))
        local ok, r1, r2 = pcall(fn)
        local pid: string? = nil
        local err: unknown = nil
        if ok then
            if r1 ~= nil then
                pid = tostring(r1)
            else
                err = r2
            end
        else
            err = r1
        end

        local admitted: boolean = (pid ~= nil)
        if admitted then any_admitted = true end
        local err_str: string = tostring(err or "")

        results[name] = {
            admitted = admitted,
            pid = pid,
            err_msg = err_str
        }
    end

    -- 5 direct creation variants
    run_variant("spawn", function() return process.spawn(target, host) end)
    run_variant("spawn_monitored", function() return process.spawn_monitored(target, host) end)
    run_variant("spawn_linked", function() return process.spawn_linked(target, host) end)
    run_variant("spawn_linked_monitored", function() return process.spawn_linked_monitored(target, host) end)
    run_variant("exec", function() return process.exec(target, host) end)

    -- Context-bound variants
    run_variant("with_context", function()
        local ctx = process.with_context({})
        return ctx:spawn(target, host)
    end)
    run_variant("with_options", function()
        local opts = process.with_options({})
        return opts:spawn(target, host)
    end)

    return {
        phase = phase_num,
        any_admitted = any_admitted,
        results = results
    }
end

return {main = main}
