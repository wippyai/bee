-- MIT. A person's removal is the destination's activate action: an application that
-- holds the Library's delivery operations may ask for it, one that only reads may not.
local test = require("test")
local funcs = require("funcs")
local security = require("security")
local bounds = require("bounds")
local app_scope = require("app_scope")

type Object = {[string]: unknown}

local WORKSPACE = "0123456789abcdef0123456789abcdef"

local function call(policies: {string}, request: Object): Object
    local actor = assert(security.new_actor("bee.application:" .. WORKSPACE .. ":revert-test", {workspace_id = WORKSPACE}))
    local raw, err = funcs.new():with_actor(actor):with_scope(app_scope.boundary(policies))
        :call("bee.gov.binding:destination_call", request)
    test.is_nil(err, tostring(err))
    return assert(bounds.object(raw))
end

local function code(reply: Object): string
    return tostring(assert(bounds.object(reply.error)).code)
end

local function define_tests()
    test.describe("Library removal", function()
        test.it("reaches the destination under the Library's delivery operations", function()
            local reply = call({"bee.apps.library:destination_client", "bee.apps.library:delivery_operations"},
                {operation = "revert", workspace_id = WORKSPACE, source_workspace = "notes", receipt_key = "revert-1"})
            test.is_false(reply.ok == true)
            test.eq(code(reply), "NOT_FOUND")
            local gone = call({"bee.apps.library:destination_client", "bee.apps.library:delivery_operations"},
                {operation = "uninstall", workspace_id = WORKSPACE, source_workspace = "notes", receipt_key = "remove-1"})
            test.eq(code(gone), "NOT_FOUND")
            local malformed = call({"bee.apps.library:destination_client", "bee.apps.library:delivery_operations"},
                {operation = "revert", workspace_id = WORKSPACE, source_workspace = "notes", receipt_key = "revert-1", extra = true})
            test.eq(code(malformed), "INVALID")
        end)

        test.it("refuses an application that may only read deliveries", function()
            local reply = call({"bee.apps.library:destination_client", "bee.tests.apps.library:read_only"},
                {operation = "revert", workspace_id = WORKSPACE, source_workspace = "notes", receipt_key = "revert-2"})
            test.is_false(reply.ok == true)
            test.eq(code(reply), "DENIED")
            local removal = call({"bee.apps.library:destination_client", "bee.tests.apps.library:read_only"},
                {operation = "uninstall", workspace_id = WORKSPACE, source_workspace = "notes", receipt_key = "remove-2"})
            test.eq(code(removal), "DENIED")
            local listing = call({"bee.apps.library:destination_client", "bee.tests.apps.library:read_only"},
                {operation = "activations", workspace_id = WORKSPACE})
            test.is_true(listing.ok == true)
        end)
    end)
end

return test.run_cases(define_tests)
