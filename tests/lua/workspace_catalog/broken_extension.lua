-- MIT. A workspace extension that always refuses, for the catalog's isolation of failing extensions.
local function handle(_: unknown): {[string]: unknown}
    return {ok = false, error = {code = "BROKEN", message = "this extension fails deliberately"}}
end
return {handle = handle}
