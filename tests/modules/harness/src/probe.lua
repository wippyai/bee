-- MIT. Static harness closure and host-link refusal, without desktop services.
local registry = require("registry")
local admission = require("admission")
local catalog = require("catalog")
local io = require("io")
local function main()
    local definition = registry.get("bee.harness:definition")
    assert(definition and definition.kind == "ns.definition", "harness definition missing")
    local snapshot, snapshot_error = catalog.snapshot()
    if not snapshot then error(tostring(snapshot_error)) end
    assert(snapshot.complete and #snapshot.bindings == 0, "empty host must activate no drivers")
    local reference = registry.get("bee.harness:carrier_host_ref")
    local linked = reference and type(reference.data) == "table" and reference.data.host_ref == "bee:workers"
    -- Invalid request deliberately reaches host validation first; no admission
    -- services exist here, so a missing host cannot accidentally cause effects.
    local reply = admission.start({})
    assert(not reply.ok and reply.error, "invalid launch must refuse")
    if linked then
        assert(reply.error.code == "INVALID", "linked host must reach request validation")
        io.print("harness closure: linked host; request refused before effects")
    else
        assert(reply.error.code == "UNAVAILABLE", "unlinked host must refuse before admission")
        assert(reply.error.message == "carrier process host is not linked", "unexpected host refusal")
        io.print("harness closure: unlinked host refused before effects")
    end
end
return {main = main}
