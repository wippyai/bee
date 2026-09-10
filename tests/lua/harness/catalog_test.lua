-- MIT. The catalog reads one pinned generation: shipped bindings are
-- compatible and activated, fixture bindings are discovered but not
-- activated or not usable, and a replaced declaration moves the next
-- generation without touching the snapshot already taken.
local test = require("test")
local registry = require("registry")
local catalog = require("catalog")
local classify = require("classify")
local function find(snapshot: {bindings: {classify.Binding}}, id: string): classify.Binding
    for _, item in ipairs(snapshot.bindings) do
        if item.binding_id == id then return item end
    end
    error("binding " .. id .. " is not in the snapshot")
end
local function has(list: {string}, wanted: string): boolean
    for _, item in ipairs(list) do
        if item == wanted then return true end
    end
    return false
end
local function fake_profiles(): {[string]: unknown}
    local current, err = registry.get("bee.harness.catalog:fake_profiles")
    if err or not current then error("fixture profiles: " .. tostring(err)) end
    return current
end
local function define_tests()
    test.describe("Harness catalog", function()
        test.it("classifies shipped and fixture bindings in one generation", function()
            local snapshot, err = catalog.snapshot()
            if not snapshot then error(tostring(err)) end
            local version = registry.current_version()
            test.eq(snapshot.generation, math.floor(version:id()))
            test.eq(#snapshot.diagnostics, 0)
            local claude = find(snapshot, "bee.driver.claude:binding")
            test.eq(claude.state, "compatible")
            test.eq(claude.driver_id, "claude")
            test.is_true(claude.activated)
            test.eq(claude.default_profile, "session")
            test.eq(#claude.binding_digest.entry, 64)
            test.eq(#claude.profile_digest.entry, 64)
            local codex = find(snapshot, "bee.driver.codex:binding")
            test.eq(codex.state, "compatible")
            test.is_true(codex.activated)
            test.eq(codex.profiles[1].mode, "batch")
            local fake = find(snapshot, "bee.harness.catalog:fake_binding")
            test.eq(fake.state, "compatible")
            test.is_false(fake.activated)
            test.eq(fake.title, "Fake harness")
            local orphan = find(snapshot, "bee.harness.catalog:orphan_binding")
            test.eq(orphan.state, "incompatible")
            test.is_true(has(orphan.diagnostics, "profiles_ref bee.harness.catalog:missing_profiles does not exist"))
            test.is_true(snapshot.complete)
            local usable, usable_error = catalog.usable(snapshot)
            if not usable then error(tostring(usable_error)) end
            test.eq(#usable, 2)
            test.eq(usable[1].binding_id, "bee.driver.claude:binding")
            test.eq(usable[2].binding_id, "bee.driver.codex:binding")
            for index = 2, #snapshot.bindings do
                test.is_true(snapshot.bindings[index - 1].binding_id < snapshot.bindings[index].binding_id)
            end
        end)
        test.it("moves to the next generation on replacement and removal without mixing", function()
            local before, before_error = catalog.snapshot()
            if not before then error(tostring(before_error)) end
            local original = fake_profiles()
            local edited = fake_profiles()
            local data = edited.data :: {[string]: unknown}
            local driver = data.driver :: {[string]: unknown}
            driver.implementation_version = "0.2.0"
            local pinned, pinned_error = registry.snapshot()
            if not pinned then error(tostring(pinned_error)) end
            local changes = pinned:changes()
            changes:update(edited)
            local replaced, apply_error = changes:apply()
            if not replaced then error(tostring(apply_error)) end
            local after, after_error = catalog.snapshot()
            if not after then error(tostring(after_error)) end
            test.is_true(after.generation > before.generation)
            test.eq(after.generation, math.floor(replaced:id()))
            local was = find(before, "bee.harness.catalog:fake_binding")
            local now = find(after, "bee.harness.catalog:fake_binding")
            test.eq(was.implementation_version, "0.1.0")
            test.eq(now.implementation_version, "0.2.0")
            test.neq(now.profile_digest.entry, was.profile_digest.entry)
            test.eq(now.binding_digest.entry, was.binding_digest.entry)
            local removal = registry.snapshot():changes()
            removal:delete("bee.harness.catalog:fake_profiles")
            local removed, removal_error = removal:apply()
            if not removed then error(tostring(removal_error)) end
            local gone, gone_error = catalog.snapshot()
            if not gone then error(tostring(gone_error)) end
            test.is_true(gone.generation > after.generation)
            local orphaned = find(gone, "bee.harness.catalog:fake_binding")
            test.eq(orphaned.state, "incompatible")
            test.is_true(has(orphaned.diagnostics, "profiles_ref bee.harness.catalog:fake_profiles does not exist"))
            test.eq(find(after, "bee.harness.catalog:fake_binding").state, "compatible")
            local restore = registry.snapshot():changes()
            restore:create(original)
            local restored, restore_error = restore:apply()
            if not restored then error(tostring(restore_error)) end
            local final, final_error = catalog.snapshot()
            if not final then error(tostring(final_error)) end
            test.eq(find(final, "bee.harness.catalog:fake_binding").state, "compatible")
            test.eq(find(final, "bee.harness.catalog:fake_binding").profile_digest.entry, was.profile_digest.entry)
        end)
        test.it("reads bindings, declarations and activation from the pinned snapshot only", function()
            local pinned, pin_error = registry.snapshot()
            if not pinned then error(tostring(pin_error)) end
            local original = fake_profiles()
            local edited = fake_profiles()
            local data = edited.data :: {[string]: unknown}
            local driver = data.driver :: {[string]: unknown}
            driver.title = "Replaced between reads"
            local changes = registry.snapshot():changes()
            changes:update(edited)
            local applied, apply_error = changes:apply()
            if not applied then error(tostring(apply_error)) end
            local from_pinned, read_error = catalog.read(pinned, nil)
            if not from_pinned then error(tostring(read_error)) end
            test.eq(from_pinned.generation, math.floor(pinned:version():id()))
            test.eq(find(from_pinned, "bee.harness.catalog:fake_binding").title, "Fake harness")
            local current, current_error = catalog.snapshot()
            if not current then error(tostring(current_error)) end
            test.eq(current.generation, math.floor(applied:id()))
            test.eq(find(current, "bee.harness.catalog:fake_binding").title, "Replaced between reads")
            local restore = registry.snapshot():changes()
            restore:update(original)
            local restored, restore_error = restore:apply()
            if not restored then error(tostring(restore_error)) end
        end)
        test.it("marks a truncated catalog incomplete and resolves nothing from it", function()
            local pinned, pin_error = registry.snapshot()
            if not pinned then error(tostring(pin_error)) end
            local truncated, read_error = catalog.read(pinned, 1)
            if not truncated then error(tostring(read_error)) end
            test.is_false(truncated.complete)
            test.eq(#truncated.bindings, 1)
            test.is_true(has(truncated.diagnostics, "more than 1 driver bindings; the catalog is incomplete"))
            local usable, usable_error = catalog.usable(truncated)
            test.is_nil(usable)
            test.eq(usable_error, "the catalog is incomplete; uniqueness is not certified")
            local complete = catalog.read(pinned, 4)
            if not complete then error("complete read") end
            test.is_true(complete.complete)
            test.eq(#complete.bindings, 4)
        end)
        test.it("ignores activation lists that are not identifiers", function()
            local entry = registry.get("bee:harness_activation")
            if not entry then error("activation entry") end
            local list = (entry.data :: {[string]: unknown}).bindings :: {string}
            test.eq(#list, 2)
            test.is_true(has(list, "bee.driver.claude:binding"))
        end)
    end)
end
return test.run_cases(define_tests)
