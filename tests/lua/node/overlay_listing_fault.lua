-- MIT. An overlay list whose first record owns the fixture overlay and whose second record names no overlay.
local function list(): {[string]: unknown}
    return {ok = true, value = {overlays = {{overlay_id = "runner_fixture"}, {overlay_id = 7}}}}
end
return {list = list}
