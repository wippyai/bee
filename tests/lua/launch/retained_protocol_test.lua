-- MIT. Retained supervisor response decoding tests.
local test = require("test")
local retained_protocol = require("retained_protocol")
local workspaces = require("workspaces")

local workspace = "0123456789abcdef0123456789abcdef"
local desktop = "fedcba9876543210fedcba9876543210"
local other = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

local function define_tests()
    test.describe("Retained workspace names", function()
        test.it("keys the owner route and bridge by the workspace selection", function()
            local classic = assert(workspaces.key(workspaces.classic()))
            test.eq(#classic, 32)
            test.eq(workspaces.key({root_ref = "bee:workspace_root", subpath = ""}), classic)
            local other_root = assert(workspaces.key({root_ref = "bee:workspace_root", subpath = "projects/one"}))
            local by_id = assert(workspaces.key({workspace_id = workspace}))
            test.neq(other_root, classic)
            test.neq(by_id, classic)
            test.eq(retained_protocol.owner_name(classic), "bee.retained.owner/" .. classic)
            test.eq(retained_protocol.bridge_name(by_id), "bee.retained.bridge/" .. by_id)
            test.neq(retained_protocol.owner_name(classic), retained_protocol.owner_name(other_root))
            test.is_nil(workspaces.key({workspace_id = "short"}))
            test.is_nil(workspaces.key({root_ref = "bee:workspace_root"}))
            test.is_nil(retained_protocol.owner_name("bee.retained.owner"))
            test.is_nil(retained_protocol.bridge_name(string.rep("G", 32)))
        end)
    end)
    test.describe("Retained supervisor protocol", function()
        test.it("keeps literal command arguments and rejects foreign or ambiguous launch envelopes", function()
            local value = {version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "launch-1", recipient = "node:bee.client:native:actor", name = "terminal",
                arguments = {"printf", "a b", "$(not-a-shell)", ""}}
            local decoded = retained_protocol.launch(value, workspace, desktop)
            if not decoded then error("Valid internal launch refused") end
            test.eq(decoded.arguments[2], "a b")
            test.eq(decoded.arguments[3], "$(not-a-shell)")
            test.eq(decoded.arguments[4], "")
            value.arguments[2] = "changed"
            test.eq(decoded.arguments[2], "a b")
            test.is_nil(retained_protocol.launch(value, other, desktop))
            test.is_nil(retained_protocol.launch(value, workspace, other))
            test.is_nil(retained_protocol.launch({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "launch-1", recipient = "actor", name = "terminal", arguments = {}, scope = "admin"}, workspace, desktop))
            test.is_nil(retained_protocol.launch({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "launch-1", recipient = "actor", name = "terminal", arguments = {[2] = "gap"}}, workspace, desktop))
            value.arguments = {string.rep("x", 1025)}
            test.is_nil(retained_protocol.launch(value, workspace, desktop))
            value.arguments = {"line\nfeed"}
            test.is_nil(retained_protocol.launch(value, workspace, desktop))
            value.arguments = {}
            value.name = "terminal;id"
            test.is_nil(retained_protocol.launch(value, workspace, desktop))
        end)

        test.it("requires broker identities for successful launch results and qualifies replies", function()
            local success = {version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "launch-1", id = "view-1", instance_id = "instance-1", error_code = "", error = ""}
            test.not_nil(retained_protocol.launch_result(success, workspace, desktop))
            test.is_nil(retained_protocol.launch_result(success, other, desktop))
            success.instance_id = ""
            test.is_nil(retained_protocol.launch_result(success, workspace, desktop))
            success.error_code = "DENIED"
            success.error = "Controller required"
            test.is_nil(retained_protocol.launch_result(success, workspace, desktop))
            success.id = ""
            test.not_nil(retained_protocol.launch_result(success, workspace, desktop))
        end)

        test.it("decodes valid ready announcement and rejects invalid keys and identities", function()
            local valid = {version = 1, workspace_id = workspace, desktop_id = desktop}
            local decoded = retained_protocol.ready(valid)
            test.not_nil(decoded)
            test.eq(assert(decoded).workspace_id, workspace)
            test.eq(assert(decoded).desktop_id, desktop)

            -- Identity mismatch and malformed durable ids
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = "bad", desktop_id = desktop}))
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = workspace, desktop_id = "bad"}))
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = string.rep("z", 32), desktop_id = desktop}))
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = workspace, desktop_id = "0123456789ABCDEF0123456789ABCDEF"}))
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = workspace .. "\n", desktop_id = desktop}))

            -- Missing and null-equivalent fields
            test.is_nil(retained_protocol.ready(nil))
            test.is_nil(retained_protocol.ready("ready"))
            test.is_nil(retained_protocol.ready(123))
            test.is_nil(retained_protocol.ready({workspace_id = workspace, desktop_id = desktop}))
            test.is_nil(retained_protocol.ready({version = 2, workspace_id = workspace, desktop_id = desktop}))
            test.is_nil(retained_protocol.ready({version = 1, desktop_id = desktop}))
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = workspace}))

            -- Unknown keys and wrong types
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = workspace, desktop_id = desktop, extra = "val"}))
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = 123, desktop_id = desktop}))
            test.is_nil(retained_protocol.ready({version = 1, workspace_id = workspace, desktop_id = false}))
        end)

        test.it("validates qualified workspace and desktop matching on results", function()
            local valid = {version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = ""}
            test.not_nil(retained_protocol.result(valid, workspace, desktop))

            -- Mismatched arguments
            test.is_nil(retained_protocol.result(valid, other, desktop))
            test.is_nil(retained_protocol.result(valid, workspace, other))

            -- Unqualified arguments
            test.is_nil(retained_protocol.result(valid, "unqualified", desktop))
            test.is_nil(retained_protocol.result(valid, workspace, "unqualified"))
            test.is_nil(retained_protocol.result(valid, workspace .. "\n", desktop))

            -- Mismatched payload fields
            test.is_nil(retained_protocol.result({version = 1, workspace_id = other, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = other,
                request_id = "req-1", mount = "view/1", error_code = "", error = ""}, workspace, desktop))
        end)

        test.it("rejects missing, unknown, wrong-type and control-char fields on results", function()
            -- Non-table values
            test.is_nil(retained_protocol.result(nil, workspace, desktop))
            test.is_nil(retained_protocol.result("result", workspace, desktop))
            test.is_nil(retained_protocol.result(123, workspace, desktop))

            -- Missing and wrong version
            test.is_nil(retained_protocol.result({workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 2, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = "1", workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = ""}, workspace, desktop))

            -- Missing fields
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = ""}, workspace, desktop))

            -- Unknown keys
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = "", op = "attach"}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = "", extra = 1}, workspace, desktop))

            -- Wrong types
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = 123, mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = false, error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = 500, error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = {}}, workspace, desktop))

            -- Control characters in identifiers
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req\n1", mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req" .. string.char(1) .. "1", mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "", error_code = "busy\ncode", error = "busy"}, workspace, desktop))

            -- Bounds and empty checks
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "", mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = string.rep("a", 81), mount = "view/1", error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = string.rep("m", 4097), error_code = "", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "", error_code = string.rep("e", 81), error = "err"}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "", error_code = "err", error = string.rep("x", 4097)}, workspace, desktop))
        end)

        test.it("enforces success and failure envelope combinations", function()
            -- Successful envelope (error_code == "") requires error == ""
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "", error = "unexpected error"}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "", error_code = "", error = "unexpected error"}, workspace, desktop))

            -- Failed envelope (error_code ~= "") requires mount == "" and error nonempty
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "busy", error = "Desktop busy"}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "", error_code = "busy", error = ""}, workspace, desktop))
            test.is_nil(retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-1", mount = "view/1", error_code = "busy", error = ""}, workspace, desktop))
        end)

        test.it("decodes valid attach, detach and failure outcomes", function()
            -- Valid attach outcome
            local attach_raw = {version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-attach", mount = "wts://desktop/view-1", error_code = "", error = ""}
            local attach_res = retained_protocol.result(attach_raw, workspace, desktop)
            test.not_nil(attach_res)
            test.eq(assert(attach_res).request_id, "req-attach")
            test.eq(assert(attach_res).mount, "wts://desktop/view-1")
            test.eq(assert(attach_res).error_code, "")
            test.eq(assert(attach_res).error, "")

            -- Valid detach outcome (mount is empty)
            local detach_raw = {version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-detach", mount = "", error_code = "", error = ""}
            local detach_res = retained_protocol.result(detach_raw, workspace, desktop)
            test.not_nil(detach_res)
            test.eq(assert(detach_res).request_id, "req-detach")
            test.eq(assert(detach_res).mount, "")
            test.eq(assert(detach_res).error_code, "")
            test.eq(assert(detach_res).error, "")

            -- Valid failure outcome
            local fail_raw = {version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-fail", mount = "", error_code = "mode_conflict", error = "Detach observer before controlling"}
            local fail_res = retained_protocol.result(fail_raw, workspace, desktop)
            test.not_nil(fail_res)
            test.eq(assert(fail_res).request_id, "req-fail")
            test.eq(assert(fail_res).mount, "")
            test.eq(assert(fail_res).error_code, "mode_conflict")
            test.eq(assert(fail_res).error, "Detach observer before controlling")

            -- Valid failure outcome with multiline error
            local multiline_raw = {version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "req-fail-ml", mount = "", error_code = "monitor_failed", error = "line 1\nline 2"}
            local multiline_res = retained_protocol.result(multiline_raw, workspace, desktop)
            test.not_nil(multiline_res)
            test.eq(assert(multiline_res).error, "line 1\nline 2")

            -- Valid bounded extremes
            local max_res = retained_protocol.result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = string.rep("a", 80), mount = string.rep("m", 4096), error_code = "", error = ""}, workspace, desktop)
            test.not_nil(max_res)
            test.eq(#assert(max_res).request_id, 80)
            test.eq(#assert(max_res).mount, 4096)
        end)

        test.it("decodes display switch requests and answers strictly", function()
            local request = retained_protocol.switch({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "switch-1", target_workspace_id = other}, workspace)
            test.eq(request and request.target_workspace_id, other)
            test.eq(request and request.desktop_id, desktop)
            test.is_nil(retained_protocol.switch({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "switch-1", target_workspace_id = other}, other))
            test.is_nil(retained_protocol.switch({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "switch-1", target_workspace_id = "short"}, workspace))
            test.is_nil(retained_protocol.switch({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "switch-1", target_workspace_id = other, recipient = "pid"}, workspace))
            local done = retained_protocol.switch_result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "switch-1", error_code = "", error = ""}, workspace)
            test.eq(done and done.error_code, "")
            local refused = retained_protocol.switch_result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "switch-1", error_code = "BUSY", error = "pending"}, workspace)
            test.eq(refused and refused.error, "pending")
            test.is_nil(retained_protocol.switch_result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "switch-1", error_code = "", error = "silent failure"}, workspace))
            test.is_nil(retained_protocol.switch_result({version = 1, workspace_id = workspace, desktop_id = desktop,
                request_id = "switch-1", error_code = "BUSY", error = ""}, workspace))
        end)

        test.it("preserves existing request decoder behavior", function()
            local attach_req = {version = 1, workspace_id = workspace, desktop_id = desktop,
                op = "attach", request_id = "req-1", recipient = "proc-1", mode = "control"}
            local decoded = retained_protocol.request(attach_req, workspace, desktop)
            test.not_nil(decoded)
            test.eq(assert(decoded).op, "attach")
            test.eq(assert(decoded).mode, "control")

            local detach_req = {version = 1, workspace_id = workspace, desktop_id = desktop,
                op = "detach", request_id = "req-2", recipient = "proc-1"}
            local decoded_detach = retained_protocol.request(detach_req, workspace, desktop)
            test.not_nil(decoded_detach)
            test.eq(assert(decoded_detach).op, "detach")

            -- Invalid request rejected
            test.is_nil(retained_protocol.request({version = 1, workspace_id = workspace, desktop_id = desktop,
                op = "detach", request_id = "req-2", recipient = "proc-1", mode = "control"}, workspace, desktop))
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
