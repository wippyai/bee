-- MIT. Exercise package resources through Bee's reader, never an installed package.
local base64 = require("base64")
local logger = require("logger")
local preview = require("preview")
local registry = require("registry")

local COMPONENT = "keeper/keeper"
local VERSION = "0.5.83"
local RESOURCE = "keeper.components:ui_static_fs"

local function bytes(value: string): string
    local decoded, problem = base64.decode(value)
    assert(decoded and not problem, "preview returned invalid base64")
    return decoded
end

local function verify()
    local initial, initial_error = registry.snapshot()
    assert(initial, tostring(initial_error))
    local initial_version = initial:version():id()

    local state, state_error = preview.read("state", {component = COMPONENT, version = VERSION})
    assert(state and #state.resources == 3, tostring(state_error))
    assert(type(state.digest) == "string" and state.digest:match("^[0-9a-f]+$") and #state.digest == 64,
        "preview omitted the artifact digest")

    local root, root_error = preview.read("files", {component = COMPONENT, version = VERSION,
        resource = RESOURCE, expected_digest = state.digest})
    assert(root and #root.files >= 2, tostring(root_error))
    local nested, nested_error = preview.read("files", {component = COMPONENT, version = VERSION,
        resource = RESOURCE, path = "assets", expected_digest = state.digest})
    assert(nested and #nested.files > 0, tostring(nested_error))

    local first, first_error = preview.read("read_file", {component = COMPONENT, version = VERSION,
        resource = RESOURCE, path = "app.html", limit = 32, expected_digest = state.digest})
    assert(first and first.next_offset == 32 and first.eof == false, tostring(first_error))
    assert(#bytes(first.content_base64) == 32, "preview changed the first file chunk")
    local second, second_error = preview.read("read_file", {component = COMPONENT, version = VERSION,
        resource = RESOURCE, path = "app.html", offset = first.next_offset, limit = 32, expected_digest = state.digest})
    assert(second and #bytes(second.content_base64) > 0, tostring(second_error))
    local eof, eof_error = preview.read("read_file", {component = COMPONENT, version = VERSION,
        resource = RESOURCE, path = "app.html", offset = first.size, expected_digest = state.digest})
    assert(eof and eof.eof == true and eof.content_base64 == "", tostring(eof_error))

    local traversal, traversal_error = preview.read("files", {component = COMPONENT, version = VERSION,
        resource = RESOURCE, path = "../app.html", expected_digest = state.digest})
    assert(not traversal and traversal_error == "package path must be relative", "preview accepted traversal")
    local mismatch, mismatch_error = preview.read("files", {component = COMPONENT, version = VERSION,
        resource = RESOURCE, expected_digest = string.rep("0", 64)})
    assert(not mismatch and mismatch_error == "artifact changed; reopen its state", "preview accepted a changed artifact")

    local final, final_error = registry.snapshot()
    assert(final, tostring(final_error))
    assert(final:version():id() == initial_version, "preview changed registry history")
    assert(not final:get("keeper.components:ui_static_fs"), "preview installed the public package")
    logger:info("HUB_PREVIEW_PASS digest=" .. state.digest)
end

local function main()
    local ok, problem = pcall(verify)
    if not ok then
        logger:error("HUB_PREVIEW_FAILURE " .. tostring(problem))
        error(tostring(problem))
    end
end

return {main = main}
