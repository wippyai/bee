-- SPDX-License-Identifier: MIT
local test = require("test")
local inspection = require("inspection")

local container_id = string.rep("c", 64)
local image_id = "sha256:" .. string.rep("a", 64)
local expected = {container_id = container_id, image_id = image_id, apparmor = "docker-default", labels = {attempt = "one", owner = "bee"}}

local function inspect(status: string, started_at: string, exit_code: integer?): {[string]: unknown}
    return {Id = container_id, Image = image_id, AppArmorProfile = "docker-default", Config = {Labels = {attempt = "one", owner = "bee", extra = "ignored"}, Tty = true},
        State = {Status = status, StartedAt = started_at, ExitCode = exit_code or 0, Pid = 42}, Name = "/bee", Created = "irrelevant"}
end

local function assert_rejected(value: unknown, expectation: unknown)
    local observation, err = inspection.decode(value, expectation)
    test.is_nil(observation)
    test.is_true(err ~= nil)
end

local function define_tests()
    test.describe("Docker inspection decoding", function()
        test.it("decodes created without inventing an execution timestamp", function()
            local observation, err = inspection.decode(inspect("created", "0001-01-01T00:00:00Z"), expected)
            if not observation then error(tostring(err)) end
            test.eq(observation.state, "created")
            test.is_nil(observation.started_at)
            test.is_nil(observation.exit_code)
            test.eq(observation.labels.attempt, "one")
            test.is_nil(observation.labels.extra)
        end)
        test.it("preserves exact running and exited timestamps", function()
            local running_time = "2026-09-13T12:34:56.123456789-04:00"
            local running, running_error = inspection.decode(inspect("running", running_time), expected)
            if not running then error(tostring(running_error)) end
            test.eq(running.state, "running")
            test.eq(running.started_at, running_time)
            test.is_nil(running.exit_code)
            local exited_time = "2026-09-13T16:34:56Z"
            local exited, exited_error = inspection.decode(inspect("exited", exited_time, 17), expected)
            if not exited then error(tostring(exited_error)) end
            test.eq(exited.state, "exited")
            test.eq(exited.started_at, exited_time)
            test.eq(exited.exit_code, 17)
            local fenced, fence_error = inspection.decode(inspect("running", running_time), {
                container_id = container_id, image_id = image_id, apparmor = "docker-default",
                started_at = running_time, labels = expected.labels})
            if not fenced then error(tostring(fence_error)) end
            local changed = inspect("running", "2026-09-13T12:34:57Z")
            assert_rejected(changed, {container_id = container_id, image_id = image_id, apparmor = "docker-default",
                started_at = running_time, labels = expected.labels})
        end)
        test.it("fences IDs, expected labels, timestamps and lifecycle states", function()
            local cases: {unknown} = {}
            local wrong_container = inspect("running", "2026-09-13T12:34:56Z")
            wrong_container.Id = string.rep("d", 64)
            cases[#cases + 1] = wrong_container
            local wrong_image = inspect("running", "2026-09-13T12:34:56Z")
            wrong_image.Image = "sha256:" .. string.rep("b", 64)
            cases[#cases + 1] = wrong_image
            local wrong_label = inspect("running", "2026-09-13T12:34:56Z")
            local wrong_config = wrong_label.Config :: {[string]: unknown}
            local wrong_labels = wrong_config.Labels :: {[string]: unknown}
            wrong_labels.attempt = "two"
            cases[#cases + 1] = wrong_label
            local wrong_apparmor = inspect("running", "2026-09-13T12:34:56Z")
            wrong_apparmor.AppArmorProfile = ""
            wrong_apparmor.HostConfig = {SecurityOpt = {"apparmor=docker-default"}}
            cases[#cases + 1] = wrong_apparmor
            cases[#cases + 1] = inspect("paused", "2026-09-13T12:34:56Z")
            cases[#cases + 1] = inspect("running", "not-a-time")
            cases[#cases + 1] = inspect("running", "0001-01-01T00:00:00Z")
            for _, value in ipairs(cases) do assert_rejected(value, expected) end
            local sparse = inspect("running", "2026-09-13T12:34:56Z")
            local sparse_state = sparse.State :: {[string]: unknown}
            sparse_state[1] = "invalid"
            assert_rejected(sparse, expected)
            assert_rejected(nil, expected)
            assert_rejected(inspect("running", "2026-09-13T12:34:56Z"), {container_id = "short", image_id = image_id, apparmor = "docker-default", labels = {attempt = "one"}})
        end)
        test.it("rejects malformed values and does not treat transport errors as exited", function()
            assert_rejected({Id = container_id, Image = image_id, Config = {Labels = expected.labels}, State = {Status = "exited", StartedAt = "2026-09-13T12:34:56Z"}}, expected)
            assert_rejected({error = "connection closed"}, expected)
            assert_rejected(inspect("exited", "2026-09-13T12:34:56Z", -1), expected)
            assert_rejected(inspect("created", "2026-09-13T12:34:56Z"), expected)
            assert_rejected(inspect("running", "2026-02-29T12:34:56Z"), expected)
            assert_rejected(inspect("running", string.rep("a", 65)), expected)
            local malformed = inspect("running", "2026-09-13T12:34:56Z")
            local config = malformed.Config :: {[string]: unknown}
            config.Labels = {[1] = "not-an-object"}
            assert_rejected(malformed, expected)
        end)
    end)
end

return test.run_cases(define_tests)
