-- MIT. Node names are the one thing the names read gives: the name each node
-- reports for itself, for callers that hold that action.
local test = require("test")
local funcs = require("funcs")
local system = require("system")
local bounds = require("bounds")

type Object = {[string]: unknown}

local function call(request: unknown): Object
    local raw, err = funcs.call("bee.node.binding:names", request)
    test.is_nil(err, tostring(err))
    return assert(bounds.object(raw))
end

local function define_tests()
    test.describe("node names", function()
        test.it("names this node by the folder it runs in and leaves out a node that does not answer", function()
            local node = assert(system.node.id())
            local reply = call({nodes = {node, "node-that-is-away"}})
            test.is_true(reply.ok == true)
            local names = assert(bounds.object(assert(bounds.object(reply.value)).names))
            test.is_true(type(names[node]) == "string" and #(names[node] :: string) > 0)
            test.is_nil(names["node-that-is-away"])
        end)

        test.it("refuses malformed requests", function()
            for _, request in ipairs({{}, {nodes = "x"}, {nodes = {7}}, {nodes = {"a"}, extra = true}}) do
                local reply = call(request)
                test.is_false(reply.ok == true)
                test.eq(assert(bounds.object(reply.error)).code, "INVALID")
            end
        end)
    end)
end

return test.run_cases(define_tests)
