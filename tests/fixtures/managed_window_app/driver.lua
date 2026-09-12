local M = {}
function M.prepare(value: unknown): {[string]: unknown}
    if type(value) ~= "table" or type(value.brief) ~= "string" then return {ok = false, error = "fixture brief missing"} end
    local brief = value.brief :: string
    return {ok = true, launch = {executable = "sh", argv = {"-c", "printf %s \"$1\" > \"$HOME/marker.txt\"; IFS= read -r line; printf 'MANAGED:%s\\n' \"$line\"; stty size; sleep 5", "fixture", brief}, environment = {}, readiness = "none"}}
end
function M.dispatch(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture window never dispatches a structured turn"}
end
function M.normalize(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture window has no stream normalizer"}
end
function M.configure(_: unknown): {[string]: unknown}
    return {ok = true, delivery = {arguments = {}, files = {}}}
end
return M
