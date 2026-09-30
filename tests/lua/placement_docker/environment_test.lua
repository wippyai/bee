-- SPDX-License-Identifier: MIT
local test = require("test")
local environment = require("environment")
local M = {}
function M.run()
    test.describe("Docker first-use environment admission", function()
        local function port(decision: string)
            local effects: {string} = {}
            local receipt: environment.Receipt? = nil
            local io: environment.IO = {
                load = function() return receipt, nil end,
                save = function(value) receipt = value; effects[#effects + 1] = "record"; return nil end,
                request = function(_selected: environment.Selection): (environment.Approval?, string?) effects[#effects + 1] = "request"; return {approval_id = "approval", proposal_digest = string.rep("a", 64), owner_incarnation = 1}, nil end,
                await = function(_approval: environment.Approval): (string?, string?) return decision, nil end,
                consume = function(_approval: environment.Approval): string? effects[#effects + 1] = "consume"; return nil end,
                provision = function(_selected: environment.Selection): (string?, string?) effects[#effects + 1] = "provision"; return "172.29.0.1:0", nil end,
                activate = function(_receipt: environment.Receipt): string? effects[#effects + 1] = "activate"; return nil end,
                progress = function(_text: string) end,
            }
            return io, effects
        end
        local selection: environment.Selection = {workspace = "workspace", profile = "profile", digest = string.rep("b", 64), network = "bee-coding", policy = "docker-environment"}
        test.it("asks once, consumes before provisioning, records and reuses the approved environment", function()
            local io, effects = port("approved")
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(reason); test.eq(receipt and receipt.state, "approved")
            test.eq(table.concat(effects, ","), "request,record,consume,provision,record,activate")
            local again = environment.prepare(io, selection)
            test.eq(again and again.approval_id, "approval")
            test.eq(table.concat(effects, ","), "request,record,consume,provision,record,activate,provision,record,activate")
        end)
        test.it("records a person's decline without creating a network or listener", function()
            local io, effects = port("denied")
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(receipt); test.is_true(reason and reason:find("declined", 1, true) ~= nil)
            test.eq(table.concat(effects, ","), "request,record,record")
            environment.prepare(io, selection)
            test.eq(table.concat(effects, ","), "request,record,record")
        end)
        test.it("refuses a revoked receipt and an approval bound to another profile digest", function()
            local io, effects = port("approved")
            environment.prepare(io, selection)
            io.save({state = "revoked", approval_id = "approval", proposal_digest = string.rep("a",64), owner_incarnation = 1, selection_digest = selection.digest})
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(receipt); test.is_true(reason and reason:find("revoked",1,true) ~= nil)
            local changed: environment.Selection = {workspace = selection.workspace, profile = selection.profile, digest = string.rep("c",64), network = selection.network, policy = selection.policy}
            local other, failure = environment.prepare(io, changed)
            test.is_nil(other); test.is_true(failure and failure:find("changed",1,true) ~= nil)
        end)
        test.it("reports expiry separately from a person's decline", function()
            local io, effects = port("expired")
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(receipt); test.is_true(reason and reason:find("expired",1,true) ~= nil)
            test.is_true(reason and reason:find("declined",1,true) == nil)
            test.eq(table.concat(effects, ","), "request,record")
        end)
        test.it("does not provision when approval consumption fails", function()
            local io, effects = port("approved")
            io.consume = function(_approval: environment.Approval): string? return "approval is no longer valid" end
            local receipt, reason = environment.prepare(io, selection)
            test.is_nil(receipt); test.eq(reason, "approval is no longer valid")
            test.eq(table.concat(effects, ","), "request,record")
        end)
    end)
end
return test.run_cases(M.run)
