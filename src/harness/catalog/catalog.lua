-- MIT. The harness catalog: one immutable registry snapshot, every driver
-- binding with its profiles and methods read from that same snapshot,
-- classified as compatible or not, and marked activated only when the
-- host's activation entry in the same snapshot names it. Discovery proves
-- neither activation nor launch permission.
local registry = require("registry")
local bounds = require("bounds")
local classify = require("classify")
local M = {}
M.ACTIVATION_ENTRY = "bee:harness_activation"
M.BINDING_TYPE = "harness.driver"
M.MAX_BINDINGS = 64
type Entry = {[string]: unknown}
type Snapshot = {generation: integer, complete: boolean, bindings: {classify.Binding}, diagnostics: {string}}
type Pinned = registry.Snapshot
local function generation(pinned: Pinned): (integer?, string?)
    local version = pinned:version()
    if not version then return nil, "read snapshot version" end
    local number: unknown = version:id()
    if type(number) ~= "number" then return nil, "registry version is not numeric" end
    return math.floor(number), nil
end
local function entry(pinned: Pinned, id: string): Entry?
    local found, err = pinned:get(id)
    if err or not found then return nil end
    return bounds.object(found)
end
-- The host's activation list: identifiers under data.bindings, or nothing.
local function activation(pinned: Pinned, diagnostics: {string}): {[string]: boolean}
    local active: {[string]: boolean} = {}
    local declared = entry(pinned, M.ACTIVATION_ENTRY)
    if not declared then return active end
    local data = bounds.object(declared.data) or {}
    local list, list_error = bounds.ids(data.bindings or {}, true)
    if not list then
        diagnostics[#diagnostics + 1] = M.ACTIVATION_ENTRY .. ": bindings: " .. tostring(list_error)
        return active
    end
    for _, id in ipairs(list) do active[id] = true end
    return active
end
-- The permission adapters the declaration's profiles pin, read from the
-- same pinned snapshot so a profile cannot enable an unmeasured adapter.
local function adapter_entries(pinned: Pinned, declaration: Entry?): {[string]: Entry?}
    local adapters: {[string]: Entry?} = {}
    if not declaration then return adapters end
    local data = bounds.object(declaration.data) or {}
    local driver = bounds.object(data.driver) or {}
    local profiles = driver.profiles
    if type(profiles) ~= "table" then return adapters end
    for _, raw in ipairs(profiles :: {unknown}) do
        local item = bounds.object(raw) or {}
        local exchange = bounds.object(item.permission_exchange) or {}
        local adapter_ref = bounds.id(exchange.adapter_ref)
        if adapter_ref and adapters[adapter_ref] == nil then adapters[adapter_ref] = entry(pinned, adapter_ref) end
    end
    return adapters
end
local function method_targets(pinned: Pinned, candidate: Entry): {[string]: Entry?}
    local methods: {[string]: Entry?} = {}
    local data = bounds.object(candidate.data) or {}
    local contracts: unknown = data.contracts
    if type(contracts) ~= "table" then return methods end
    for _, item in ipairs(contracts :: {unknown}) do
        local declared = bounds.object(item)
        if declared then
            local mapping = bounds.object(declared.methods) or {}
            for _, target in pairs(mapping) do
                local target_id = bounds.id(target)
                if target_id then methods[target_id] = entry(pinned, target_id) end
            end
        end
    end
    return methods
end
-- Reads the catalog from one pinned registry snapshot. A limit below the
-- number of bindings leaves the catalog incomplete: an unseen binding could
-- share a driver_id with a visible one, so uniqueness is not certified.
function M.read(pinned: Pinned, limit: integer?): (Snapshot?, string?)
    local current, generation_error = generation(pinned)
    if not current then return nil, generation_error end
    local cap = limit or M.MAX_BINDINGS
    local snapshot: Snapshot = {generation = current, complete = true, bindings = {}, diagnostics = {}}
    local active = activation(pinned, snapshot.diagnostics)
    local found, find_error = pinned:find({[".kind"] = "contract.binding", ["meta.type"] = M.BINDING_TYPE})
    if find_error or not found then return nil, "read driver bindings" end
    local count = 0
    for _, raw in ipairs(found) do
        local candidate = bounds.object(raw)
        if candidate and candidate.kind == "contract.binding" then
            local meta = bounds.object(candidate.meta)
            if meta and meta.type == M.BINDING_TYPE then
                count = count + 1
                if count > cap then
                    snapshot.complete = false
                    snapshot.diagnostics[#snapshot.diagnostics + 1] = "more than " .. tostring(cap) .. " driver bindings; the catalog is incomplete"
                    break
                end
                local binding_id = bounds.id(candidate.id) or ""
                local declaration: Entry? = nil
                local profiles_ref = bounds.id(meta.profiles_ref)
                if profiles_ref then declaration = entry(pinned, profiles_ref) end
                snapshot.bindings[#snapshot.bindings + 1] = classify.binding({binding = candidate, declaration = declaration,
                    methods = method_targets(pinned, candidate), adapters = adapter_entries(pinned, declaration), activated = active[binding_id] == true})
            end
        end
    end
    table.sort(snapshot.bindings, function(left: classify.Binding, right: classify.Binding): boolean return left.binding_id < right.binding_id end)
    classify.disambiguate(snapshot.bindings)
    return snapshot, nil
end
-- Pins the current registry and reads it.
function M.snapshot(): (Snapshot?, string?)
    local pinned, pin_error = registry.snapshot()
    if pin_error or not pinned then return nil, "pin the registry" end
    return M.read(pinned, nil)
end
-- pin: the immutable registry a caller reads everything from, so a plan
-- measures its policy, adapter and acceptance at one generation.
function M.pin(): (Pinned?, string?)
    local pinned, pin_error = registry.snapshot()
    if pin_error or not pinned then return nil, "pin the registry" end
    return pinned, nil
end
function M.entry(pinned: Pinned, id: string): Entry?
    return entry(pinned, id)
end
-- Compatible and activated bindings only: what a launch may resolve. An
-- incomplete catalog resolves nothing.
function M.usable(snapshot: Snapshot): ({classify.Binding}?, string?)
    if not snapshot.complete then return nil, "the catalog is incomplete; uniqueness is not certified" end
    local result: {classify.Binding} = {}
    for _, item in ipairs(snapshot.bindings) do
        if item.state == "compatible" and item.activated then result[#result + 1] = item end
    end
    return result, nil
end
return M
