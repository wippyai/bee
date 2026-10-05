-- SPDX-License-Identifier: MIT
-- Protocol definitions and typed boundary decoders for hive admission proof.
local M = {}

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

type ProbeReply = {
    version: integer,
    kind: string,
    host: string,
    token: string
}

type CoordinatorResult = {
    status: string,
    phases_completed: integer
}

function M.decode_probe_reply(value: unknown): ProbeReply?
    if type(value) ~= "table" then return nil end
    local v = value.version
    local k = value.kind
    local h = value.host
    local t = value.token
    if type(v) ~= "number" or v ~= 1 then return nil end
    if type(k) ~= "string" or k ~= "probe_ready" then return nil end
    if type(h) ~= "string" or #h < 1 or #h > 256 then return nil end
    if type(t) ~= "string" or #t < 1 or #t > 256 then return nil end
    local host_str: string = tostring(h)
    local token_str: string = tostring(t)
    return {
        version = 1,
        kind = "probe_ready",
        host = host_str,
        token = token_str
    }
end

function M.decode_attacker_report(value: unknown): AttackerReport?
    if type(value) ~= "table" then return nil end
    local phase = value.phase
    local any_admitted = value.any_admitted
    local results = value.results
    if type(phase) ~= "number" or phase ~= math.floor(phase) then return nil end
    if type(any_admitted) ~= "boolean" then return nil end
    if type(results) ~= "table" then return nil end

    local decoded_results: {[string]: VariantResult} = {}
    for k, v in pairs(results) do
        if type(k) == "string" and type(v) == "table" then
            local admitted = v.admitted
            local pid = v.pid
            local err_msg = v.err_msg
            if type(admitted) == "boolean" and type(err_msg) == "string" then
                local pid_val: string? = nil
                if type(pid) == "string" then pid_val = tostring(pid) end
                decoded_results[k] = {
                    admitted = admitted,
                    pid = pid_val,
                    err_msg = tostring(err_msg)
                }
            end
        end
    end

    return {
        phase = math.floor(phase),
        any_admitted = any_admitted,
        results = decoded_results
    }
end

function M.decode_coordinator_result(value: unknown): CoordinatorResult?
    if type(value) ~= "table" then return nil end
    local s = value.status
    local p = value.phases_completed
    if type(s) ~= "string" or s ~= "success" then return nil end
    if type(p) ~= "number" or p ~= math.floor(p) then return nil end
    return {
        status = "success",
        phases_completed = math.floor(p)
    }
end

function M.extract_pid_host(pid_str: string): string?
    local h = string.match(pid_str, "@([^|]+)|")
    if type(h) == "string" then return h end
    return nil
end

return M
