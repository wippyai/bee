-- MIT. Exercise the production Hub reader with one public artifact and prove
-- that its exact caller scope cannot turn inspection into publication.
local hub = require("hub")
local inspect = require("inspect")
local logger = require("logger")
local registry = require("registry")

local COMPONENT = "userspace/docker"
local VERSION = "0.5.12"

local function reject_unknown_authority()
    for _, field in ipairs({"registry", "token", "path"}) do
        local result, err = inspect.read({component = COMPONENT, version = VERSION, [field] = "caller-selected"})
        assert(not result and err and err:find("unknown field " .. field, 1, true), "accepted caller authority field " .. field)
    end
end

local function main()
    local initial, initial_error = registry.snapshot()
    assert(initial, tostring(initial_error))
    local initial_version = initial:version():id()

    reject_unknown_authority()
    local result, inspect_error = inspect.read({component = COMPONENT, version = VERSION})
    assert(result, tostring(inspect_error))
    assert(result.component == COMPONENT, "inspector changed component identity")
    assert(result.version:gsub("^v", "") == VERSION, "inspector changed exact version")
    assert(type(result.digest) == "string" and result.digest:match("^[0-9a-f]+$") and #result.digest == 64,
        "inspector omitted the measured SHA-256 digest")

    -- Permission is evaluated before a Hub request, so this is a real module
    -- identity without another public download or a broader scope.
    local foreign, foreign_error = hub.versions.open("wippy/test", "0.4.17")
    if foreign then
        foreign:close()
        logger:error("HUB_INSPECT_FOREIGN_OPENED")
    end
    assert(not foreign and foreign_error and foreign_error:kind() == "PermissionDenied",
        "another module must fail specifically at authorization")

    local changes, changes_error = initial:changes()
    assert(changes, tostring(changes_error))
    local staged, stage_error = changes:create({
        id = "bee.hub_inspect_probe:must_not_publish",
        kind = "registry.entry",
        data = {value = "not-authorized"},
    })
    if staged then
        local published, publish_error = changes:apply()
        assert(not published and publish_error and publish_error:kind() == "PermissionDenied",
            "registry publication must fail specifically at authorization")
    else
        assert(stage_error and stage_error:kind() == "PermissionDenied", "registry staging failed outside authorization")
    end
    local final, final_error = registry.snapshot()
    assert(final, tostring(final_error))
    assert(final:version():id() == initial_version, "inspection or denied publication changed registry history")
    assert(not final:get("bee.hub_inspect_probe:must_not_publish"), "denied publication changed registry contents")
    logger:info("HUB_INSPECT_PASS digest=" .. result.digest)
end

return {main = main}
