-- MIT. Lease envelope construction and ceiling containment are pure.
local test = require("test")
local lease_model = require("lease_model")
local capability_model = require("capability_model")

type Object = {[string]: unknown}

local function grant(capability: string, operation: string, resource: string, scope: Object, revision: integer?): capability_model.Grant
    return {capability = capability, template_revision = revision or 1, operation = operation,
        resource = resource, scope = scope, parameters = scope}
end

local function vocabulary(): capability_model.Vocabulary
    -- A minimal but well-formed catalog entry, decoded the same way the host
    -- capability catalog is, so M.render's template checks are exercised for
    -- real rather than bypassed.
    return assert(capability_model.decode({id = "bee:capability_catalog", kind = "registry.entry",
        meta = {type = "bee.capability_catalog"}, data = {revision = 1, never = {}, capabilities = {
            {id = "workspace.files.write", revision = 1, confirm = "standard",
                parameters = {subpath = "relative_subpath"}, text = "Write workspace files under {subpath}",
                policies = {{operation = "files.write", resource = "workspace", scope = {subpath = "$subpath"}}},
                resources = {{kind = "fs.directory", mode = "readwrite", source = "$subpath"}}},
        }}}))
end

local function define_tests()
    test.describe("Lease envelope model", function()
        test.it("builds a deduplicated envelope from installed grants and validated extras", function()
            local vocab = vocabulary()
            local installed = {grant("workspace.files.write", "files.write", "workspace", {subpath = "alpha"})}
            local extra = grant("workspace.files.write", "files.write", "workspace", {subpath = "beta"})
            local envelope = assert(lease_model.envelope(vocab, installed, {extra, extra}))
            test.eq(#envelope, 2)
        end)
        test.it("refuses an extra that does not match its host template", function()
            local vocab = vocabulary()
            local bogus = grant("workspace.files.write", "files.write", "workspace", {subpath = "alpha"}, 99)
            local envelope, err = lease_model.envelope(vocab, {}, {bogus})
            test.is_nil(envelope)
            test.is_true(err ~= nil)
        end)
        test.it("refuses an empty envelope", function()
            local vocab = vocabulary()
            local envelope, err = lease_model.envelope(vocab, {}, {})
            test.is_nil(envelope)
            test.is_true(err ~= nil)
        end)
        test.it("covers a narrower or equal proposed grant and refuses a wider one", function()
            local wide = grant("workspace.files.write", "files.write", "workspace", {subpath = "alpha"})
            local narrow = grant("workspace.files.write", "files.write", "workspace", {subpath = "alpha/child"})
            local sibling = grant("workspace.files.write", "files.write", "workspace", {subpath = "beta"})
            test.is_true(lease_model.covers({wide}, {narrow}))
            test.is_true(lease_model.covers({wide}, {wide}))
            test.is_false(lease_model.covers({wide}, {sibling}))
        end)
        test.it("requires every proposed grant to be covered, not only the changed ones", function()
            local covered = grant("workspace.files.write", "files.write", "workspace", {subpath = "alpha"})
            local uncovered = grant("contract.call", "contract.call", "app:binding", {methods = {"get"}})
            test.is_false(lease_model.covers({covered}, {covered, uncovered}))
        end)
        test.it("requires an expiry, a use limit, or both", function()
            local expires, max, err = lease_model.bounded(nil, nil)
            test.is_nil(expires)
            test.is_nil(max)
            test.is_true(err ~= nil)
            local e2, m2 = lease_model.bounded(3600, nil)
            test.eq(e2, 3600)
            test.is_nil(m2)
            local e3, m3 = lease_model.bounded(nil, 5)
            test.is_nil(e3)
            test.eq(m3, 5)
        end)
        test.it("reuses super_edit's bounded duration grammar", function()
            local value, err = lease_model.duration("2h")
            test.eq(value, "2h")
            test.is_nil(err)
            local bad, bad_err = lease_model.duration("48h")
            test.is_nil(bad)
            test.is_true(bad_err ~= nil)
        end)
    end)
end
return test.run_cases(define_tests)
