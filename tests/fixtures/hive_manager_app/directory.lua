-- MIT. Disposable live-directory double. The staging runner selects MODE only in
-- its temporary composition; production imports bee.hive_manager:directory.
local time = require("time")
local process = require("process")
local ctx = require("ctx")
local types = require("types")
local M = {}
M.MAX_NODES = 64
local MODE = "slow"
local NODE = "local"
local WORKSPACE = string.rep("a", 32)
local FIRST = string.rep("b", 32)
local SECOND = string.rep("c", 32)
type Reply = types.Reply
type Member = {node_id: string, is_local: boolean, addr: string, client_only: boolean?}
type Desktop = {workspace_id: string, desktop_id: string, label: string, controller: string?, observers: integer?}
type Catalog = {available: boolean, reason: string, owner_generation: string, desktops: {Desktop}}
type Mode = "control" | "observe"
type Attach = {node_id: string, workspace_id: string, desktop_id: string, owner_generation: string, mode: Mode, idempotency_key: string}
type Outcome = {ok: boolean, code: string, message: string, session_id: string?, mode: string?}
type Supervisor = {running: boolean, detail: string}
type Directory = {supervisor: (Directory) -> Supervisor, members: (Directory) -> ({Member}, string?), presence: (Directory, string) -> Reply, stats: (Directory, string) -> Reply, desktops: (Directory, string) -> Catalog, attach: (Directory, Attach) -> Outcome}
function M.live(_value: unknown): Directory
    local function supervisor(_: Directory): Supervisor
        if MODE == "unavailable" then return {running = false, detail = "test supervisor unavailable"} end
        return {running = true, detail = ""}
    end
    local function members(_: Directory): ({Member}, string?) return {{node_id = NODE, is_local = true, addr = ""}}, nil end
    local function presence(_: Directory, _node: string): Reply
        if MODE == "unavailable" then return types.reply_error("test", types.fault("UNAVAILABLE", "no supervisor to ask")) end
        return types.reply_ok("test", {role = "leader", cluster_size = 1})
    end
    local function stats(_: Directory, _node: string): Reply return types.reply_ok("test", {memory = {heap_alloc = 1}, goroutines = 1}) end
    local function desktops(_: Directory, _node: string): Catalog
        if MODE == "slow" then
            local owner = ctx.get("bee.workspace_owner")
            assert(type(owner) == "string" and owner ~= "", "missing fixture owner context")
            assert(process.send(owner, "bee.hive_manager_probe.slow_entered", {}))
            time.sleep("8s")
        end
        if MODE == "unavailable" then return {available = false, reason = "No supervisor is available", owner_generation = "", desktops = {}} end
        return {available = true, reason = "", owner_generation = "test-generation", desktops = {
            {workspace_id = WORKSPACE, desktop_id = FIRST, label = "main"}, {workspace_id = WORKSPACE, desktop_id = SECOND, label = "replacement"}}}
    end
    local function attach(_: Directory, _request: Attach): Outcome return {ok = false, code = "TEST_FAILURE", message = "stale confirmation dispatched"} end
    return {supervisor = supervisor, members = members, presence = presence, stats = stats, desktops = desktops, attach = attach}
end
return M
