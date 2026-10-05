-- MIT. Empty configuration for a shell owned by the native-window fixture.
local M = {}
function M.configure(_: unknown): {[string]: unknown}
    return {ok = true, delivery = {arguments = {}, files = {}}}
end
function M.unused(_: unknown): {[string]: unknown}
    return {ok = false, error = "the native-window fixture supplies its shell directly"}
end
return M
