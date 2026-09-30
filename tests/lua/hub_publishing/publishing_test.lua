-- MIT. Person-approved Hub publication values: decoding, the approval body
-- a person decides on, ownership of a recorded request, the upload command
-- and the outcome a publish reply reports. Pure; no Hub, approval owner or
-- credential runs.
local test = require("test")
local publishing = require("publishing")
type Object = {[string]: unknown}
local DIGEST = string.rep("b", 64)
local CONTEXT = {binding_id = "binding-1", thread_id = "thread-1", action_id = "action-1", attempt_id = "attempt-1"}

local function measured(overrides: Object?): Object
    local value: Object = {component = "bee/publish-probe", version = "0.0.1-probe.1",
        digest = DIGEST, visibility = "private", organization = "bee", source = "/home/person/work/probe"}
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

local function define_tests()
    test.describe("Hub publication request", function()
        test.it("decodes a publish request strictly", function()
            local decoded = publishing.decode({component = "bee/publish-probe",
                version = "0.0.1-probe.1", visibility = "private", source = "/home/person/work/probe"})
            test.not_nil(decoded)
            if decoded then
                test.eq(decoded.component, "bee/publish-probe")
                test.eq(decoded.version, "0.0.1-probe.1")
                test.eq(decoded.visibility, "private")
            end
            test.is_nil(publishing.decode({component = "bee/publish-probe",
                version = "0.0.1-probe.1", visibility = "private"}))
            test.is_nil(publishing.decode({component = "probe",
                version = "0.0.1-probe.1", visibility = "private", source = "/home/person/work/probe"}))
            test.is_nil(publishing.decode({component = "bee/publish-probe",
                version = "^1.0", visibility = "private", source = "/home/person/work/probe"}))
            test.is_nil(publishing.decode({component = "bee/publish-probe",
                version = "0.0.1-probe.1", visibility = "internal", source = "/home/person/work/probe"}))
            test.is_nil(publishing.decode({component = "bee/publish-probe",
                version = "0.0.1-probe.1", visibility = "private", source = "relative/probe"}))
        end)

        test.it("measures the exact bytes the person approves", function()
            local first = publishing.plan_digest(measured())
            test.not_nil(first)
            test.is_false(first == publishing.plan_digest(measured({visibility = "public"})))
            test.is_false(first == publishing.plan_digest(measured({digest = string.rep("c", 64)})))
            test.is_nil(publishing.plan_digest(measured({digest = "short"})))
            test.is_nil(publishing.plan_digest(measured({organization = "other"})))
        end)

        test.it("builds one approval body showing module, version, digest and visibility", function()
            local digest = publishing.plan_digest(measured())
            if not digest then error("measure") end
            local proposal, prompt, problem = publishing.proposal(measured(), CONTEXT)
            test.is_nil(problem)
            test.not_nil(proposal)
            if not proposal then return end
            test.eq(prompt, "Publish bee/publish-probe 0.0.1-probe.1 (private)?")
            test.eq(proposal.ref, publishing.REF)
            test.eq(proposal.input_digest, digest)
            local payload = proposal.payload :: Object
            test.eq(payload.action, "publish")
            test.eq(payload.component, "bee/publish-probe")
            test.eq(payload.version, "0.0.1-probe.1")
            test.eq(payload.digest, DIGEST)
            test.eq(payload.visibility, "private")
            test.eq(payload.organization, "bee")
            test.eq(payload.source, "/home/person/work/probe")
            test.eq(payload.plan_digest, digest)
            test.eq(payload.binding_id, "binding-1")
            test.eq(payload.attempt_id, "attempt-1")
        end)

        test.it("keys a retried request to the same attempt and plan", function()
            local digest = publishing.plan_digest(measured())
            if not digest then error("measure") end
            local first = publishing.idempotency_key(CONTEXT, digest)
            test.eq(first, publishing.idempotency_key(CONTEXT, digest))
            test.is_false(first == publishing.idempotency_key(
                {binding_id = "binding-1", thread_id = "thread-1", action_id = "action-1", attempt_id = "attempt-2"}, digest))
        end)

        test.it("accepts only the asking agent's own recorded request", function()
            local proposal = publishing.proposal(measured(), CONTEXT)
            local view: Object = {requester_id = "agent", thread_id = "thread-1", workspace_id = "ws",
                policy = "hub-publication", proposal = proposal}
            local verified, problem = publishing.verify(view, "agent", "ws", "hub-publication", CONTEXT)
            test.is_nil(problem)
            test.not_nil(verified)
            if verified then
                test.eq(verified.request.component, "bee/publish-probe")
                test.eq(verified.request.digest, DIGEST)
            end
            test.is_nil((publishing.verify(view, "other", "ws", "hub-publication", CONTEXT)))
            local tampered: Object = {requester_id = "agent", thread_id = "thread-1", workspace_id = "ws",
                policy = "hub-publication", proposal = {ref = "bee.hub:apply", revision = "x",
                input_digest = "x", payload = (proposal :: Object).payload}}
            test.is_nil((publishing.verify(tampered, "agent", "ws", "hub-publication", CONTEXT)))
        end)

        test.it("builds the exact upload command without secrets", function()
            local digest = publishing.plan_digest(measured())
            if not digest then error("measure") end
            local proposal = publishing.proposal(measured(), CONTEXT)
            local view: Object = {requester_id = "agent", thread_id = "thread-1", workspace_id = "ws",
                policy = "hub-publication", proposal = proposal}
            local verified = publishing.verify(view, "agent", "ws", "hub-publication", CONTEXT)
            if not verified then error("verify") end
            local command = publishing.publish_command(verified, "/bin/wippy", "/stage/pack.wapp")
            local joined = table.concat(command, " ")
            test.eq(joined, "/bin/wippy publish --config /home/person/work/probe --wapp /stage/pack.wapp " ..
                "--version 0.0.1-probe.1 --create --protected --module-visibility private")
            for _, item in ipairs(command) do
                test.is_false((tostring(item)):find("token") ~= nil)
            end
        end)

        test.it("builds the exact dry-run command that stages the pack", function()
            local decoded = publishing.decode({component = "bee/publish-probe",
                version = "0.0.1-probe.1", visibility = "private", source = "/home/person/work/probe"})
            if not decoded then error("decode") end
            local joined = table.concat(publishing.plan_command(decoded, "/bin/wippy"), " ")
            test.eq(joined, "/bin/wippy publish --config /home/person/work/probe --version 0.0.1-probe.1 --dry-run")
        end)

        test.it("reads the staged pack path from dry-run output", function()
            local output = "\nModule: bee/publish-probe\n  Packing module...\n" ..
                "  Pack created: /tmp/stage/publish-probe-0.0.1-probe.1.wapp (751 B)\n" ..
                "  Digest: sha256:" .. DIGEST .. "\n  Dry run complete\n"
            test.eq(publishing.parse_pack_path(output), "/tmp/stage/publish-probe-0.0.1-probe.1.wapp")
            test.is_nil(publishing.parse_pack_path("no pack here"))
        end)

        test.it("reads the Hub digest from uploader output", function()
            test.eq(publishing.parse_digest("  Digest: sha256:" .. string.rep("d", 64) .. "\n"), "sha256:" .. string.rep("d", 64))
            test.is_nil(publishing.parse_digest("no digest here"))
            test.is_nil(publishing.parse_digest("  Digest: sha256:short\n"))
        end)

        test.it("reports the publish reply as the agent's outcome", function()
            local applied = publishing.status({ok = true,
                value = {state = "published", message = "Publication completed"}})
            test.eq(applied.status, "applied")
            local pending = publishing.status({ok = false, code = "UNCERTAIN", message = "still running"})
            test.eq(pending.status, "approved")
            local failed = publishing.status({ok = false, code = "DENIED", message = "refused"})
            test.eq(failed.status, "failed")
            test.eq(failed.code, "DENIED")
        end)

        test.it("keeps the status receipt without copying uploader output", function()
            local result = publishing.effect_result({ok = true, replayed = false,
                value = {state = "published", message = "Publication completed"}})
            test.eq(result.ok, true)
            test.eq((result.value :: Object).state, "published")
        end)
    end)
end

return test.run_cases(define_tests)
