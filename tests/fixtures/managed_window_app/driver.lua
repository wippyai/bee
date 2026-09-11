local M = {}
function M.prepare(_: unknown): {[string]: unknown}
    return {ok = true, launch = {executable = "sh", argv = {"-c", "IFS= read -r line; printf 'MANAGED:%s\\n' \"$line\"; stty size; sleep 5"}, environment = {}, readiness = "none"}}
end
function M.dispatch(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture window never dispatches a structured turn"}
end
function M.normalize(_: unknown): {[string]: unknown}
    return {ok = false, error = "fixture window has no stream normalizer"}
end
function M.configure(_: unknown): {[string]: unknown}
    return {ok = true, configuration = nil}
end
return M
