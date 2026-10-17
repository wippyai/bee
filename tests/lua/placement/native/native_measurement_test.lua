-- MIT. Executable measurements are taken once per file version and recorded
-- with the file identity; a start compares the planned identity with a fresh
-- stat, and an identity the OS cannot pin falls back to hashing.
local test = require("test")
local hash = require("hash")
local time = require("time")
local json = require("json")
local measurements = require("measurements")
local native_fixture = require("native_fixture")

local REVISION = "bee.executable-measurement@1"

local function measure(path: string): {[string]: unknown}
    return native_fixture.value(native_fixture.call(native_fixture.OWNER, "measure_executable", {path = path}))
end

local function records(path: string): {{[string]: unknown}}
    local db = assert(measurements.open())
    local rows, err = db:query("SELECT key_digest, measurement FROM bee_placement_executable_measurements WHERE path = ?", {path})
    db:release()
    assert(rows, tostring(err))
    return rows
end

local function script(name: string, body: string): (string, string)
    local cwd = native_fixture.shell("pwd"):gsub("%s+$", "")
    local path = cwd .. "/.wippy/" .. native_fixture.fresh(name) .. ".sh"
    local content = "#!/bin/sh\n" .. body .. "\n"
    native_fixture.shell("printf '%s' '" .. content .. "' > " .. path .. " && chmod +x " .. path)
    return path, content
end

-- A plan carries the measurement as planning decoded it from the reply.
local function planned(measured: {[string]: unknown}): {[string]: unknown}
    return {revision = measured.revision, kind = measured.kind, digest = measured.digest, identity = measured.identity}
end

local function start(path: string, executable: {[string]: unknown}): (string, string)
    local request = native_fixture.launch({path}, "direct_process")
    request.executable = executable
    local prepared = native_fixture.attempt_of(native_fixture.call(native_fixture.OWNER, "prepare", request))
    local started = native_fixture.call(native_fixture.OWNER, "start", {attempt_id = prepared.attempt_id})
    assert(started.ok, "start replies")
    return prepared.attempt_id, tostring(native_fixture.attempt_of(started).execution_state)
end

local function detail(attempt_id: string, kind: string): string?
    local page = native_fixture.value(native_fixture.call(native_fixture.OWNER, "evidence", {attempt_id = attempt_id, limit = 64}))
    for _, item in ipairs(page.evidence :: {{[string]: unknown}}) do
        if item.kind == kind then return tostring(item.detail) end
    end
    return nil
end

local function exited(attempt_id: string): boolean
    return native_fixture.wait_for(function()
        return (native_fixture.value(native_fixture.call(native_fixture.OWNER, "status", {attempt_id = attempt_id})).attempt).execution_state == "exited"
    end, 8000)
end

local function measurement_tests()
    test.describe("Native placement executable measurements", function()
        test.it("reports no pinned identity for a stat without device, inode and change time", function()
            local windows = measurements.observed({size = 12, mtime_ns = 1700000000000000000})
            test.not_nil(windows)
            test.is_nil(measurements.pinned(windows))
            test.is_nil(measurements.observed({size = 12}))
            test.is_nil(measurements.pinned(nil))
            local settled = measurements.observed({size = 12, dev = 2049, ino = "18446744073709551000", ctime_ns = 1700000000000000000, mtime_ns = 1700000000000000000})
            local pinned = assert(measurements.pinned(settled))
            test.eq(pinned.dev, "2049")
            test.eq(pinned.ino, "18446744073709551000")
            test.eq(pinned.ctime_ns, "1700000000000000000")
        end)

        test.it("hashes a file changed within the stamp granularity on every measurement and start, and records nothing", function()
            local path, content = script("fresh", "echo fresh")
            local measured = measure(path)
            test.eq(measured.digest, (hash.sha256(content)))
            test.is_nil(measured.identity)
            test.eq(#records(path), 0)
            local stale = {revision = REVISION, kind = "script", digest = string.rep("0", 64)}
            local refused, state = start(path, stale)
            test.eq(state, "start_failed")
            test.is_true(native_fixture.has(native_fixture.kinds(refused), "executable.changed"))
            native_fixture.shell("rm -f " .. path)
        end)

        test.it("measures a settled executable once, reuses the recorded measurement across launches and starts by identity", function()
            local once, once_content = script("once", "echo once")
            local rewritten, rewritten_content = script("rewritten", "echo first")
            local renamed, renamed_content = script("renamed", "echo first")
            time.sleep(math.floor(measurements.GRANULE_NS / 1000000) + 200 .. "ms")

            local first = measure(once)
            test.eq(first.digest, (hash.sha256(once_content)))
            local identity = assert(first.identity) :: {[string]: unknown}
            test.eq(identity.size, #once_content)
            test.eq(type(identity.dev), "string")
            test.eq(type(identity.ino), "string")
            local rows = records(once)
            test.eq(#rows, 1)
            local recorded = assert(json.decode(tostring(rows[1].measurement))) :: {[string]: unknown}
            test.eq(recorded.digest, first.digest)
            -- The recorded measurement is the one a later launch receives:
            -- a marker digest written into the record comes back unread.
            local marker = string.rep("a", 64)
            recorded.digest = marker
            local db = assert(measurements.open())
            local _, update_error = db:execute("UPDATE bee_placement_executable_measurements SET measurement = ? WHERE key_digest = ?",
                {json.encode(recorded), rows[1].key_digest})
            db:release()
            test.is_nil(update_error)
            local again = measure(once)
            test.eq(again.digest, marker)
            test.eq(#records(once), 1)
            local unchanged, state = start(once, planned(first))
            test.eq(state, "running")
            test.is_true(exited(unchanged))
            test.is_true(tostring(detail(unchanged, "executable.measured")):find("file identity unchanged", 1, true) ~= nil)

            local before_rewrite = measure(rewritten)
            test.eq(before_rewrite.digest, (hash.sha256(rewritten_content)))
            local replacement = rewritten_content:gsub("first", "again")
            native_fixture.shell("printf '%s' '" .. replacement .. "' > " .. rewritten)
            local refused_rewrite, rewrite_state = start(rewritten, planned(before_rewrite))
            test.eq(rewrite_state, "start_failed")
            test.is_true(native_fixture.has(native_fixture.kinds(refused_rewrite), "executable.changed"))
            test.eq(measure(rewritten).digest, (hash.sha256(replacement)))

            local before_rename = measure(renamed)
            test.eq(before_rename.digest, (hash.sha256(renamed_content)))
            local successor = renamed_content:gsub("first", "later")
            native_fixture.shell("printf '%s' '" .. successor .. "' > " .. renamed .. ".next && chmod +x " .. renamed .. ".next && mv " .. renamed .. ".next " .. renamed)
            local refused_rename, rename_state = start(renamed, planned(before_rename))
            test.eq(rename_state, "start_failed")
            test.is_true(native_fixture.has(native_fixture.kinds(refused_rename), "executable.changed"))
            test.eq(measure(renamed).digest, (hash.sha256(successor)))
            native_fixture.shell("rm -f " .. once .. " " .. rewritten .. " " .. renamed)
        end)
    end)
end

return {measurement = native_fixture.suite(measurement_tests)}
