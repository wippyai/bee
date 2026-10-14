-- MIT. Candidate transfer describes a frozen copy and never creates activation authority.
local test = require("test")
local candidate = require("candidate")
local workspace = require("workspace")
local hash = require("hash")

local function frozen(): workspace.Snapshot
    local value, err = workspace.freeze({workspace_id = "author/demo", revision = 3,
        files = {{path = "app/main.lua", content = "return 'hello'"}, {path = "assets/icon.bin", content = "\0\255"}}})
    if not value then error(tostring(err)) end
    return value
end

local function define_tests()
    test.describe("Governance transfer candidate", function()
        test.it("binds a frozen snapshot to exactly one destination", function()
            local snapshot = frozen()
            local first = assert(candidate.create("node-a", "node-b", "team/demo", snapshot))
            local second = assert(candidate.create("node-a", "node-b", "team/demo", snapshot))
            test.eq(first.digest, second.digest)
            test.is_false(first.digest == assert(candidate.create("node-a", "node-c", "team/demo", snapshot)).digest)
            test.is_true(assert(candidate.verify(first, snapshot.files)))
        end)
        test.it("refuses altered bytes, omitted files, and altered manifest metadata", function()
            local snapshot = frozen()
            local transfer = assert(candidate.create("node-a", "node-b", "team/demo", snapshot))
            test.is_false(candidate.verify(transfer, {{path = "app/main.lua", content = "changed"}, {path = "assets/icon.bin", content = "\0\255"}}))
            test.is_false(candidate.verify(transfer, {{path = "app/main.lua", content = "return 'hello'"}}))
            transfer.destination_workspace = "other"
            test.is_false(candidate.verify(transfer, snapshot.files))
        end)
        test.it("refuses a changed file manifest even when the frozen digest is retained", function()
            local snapshot = frozen()
            local item, item_error = candidate.create("source", "destination", "target", snapshot)
            if not item then error(tostring(item_error)) end
            item.files[1].path = "different.lua"
            local accepted = candidate.verify(item, snapshot.files)
            test.is_false(accepted)
        end)
        test.it("round trips canonical candidate bytes and rejects byte tampering", function()
            local snapshot = frozen()
            local item = assert(candidate.create("source", "destination", "target", snapshot))
            local bytes = assert(candidate.encode(item))
            local digest = assert(hash.sha256(bytes))
            local decoded = assert(candidate.decode(bytes, digest))
            test.eq(decoded.digest, item.digest)
            test.is_nil(candidate.decode(bytes .. " ", digest))
        end)
        test.it("refuses a mutable or malformed source description", function()
            local snapshot = frozen()
            snapshot.files[1].content = "changed"
            test.is_nil(candidate.create("node-a", "node-b", "team/demo", snapshot))
            test.is_nil(candidate.create("", "node-b", "team/demo", frozen()))
        end)
    end)
end

return test.run_cases(define_tests)
