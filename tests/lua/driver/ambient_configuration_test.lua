-- MIT. Bee's placement materializer composes a driver's rendered option files
-- with the retained ambient configuration they declare as their base.
local configuration_types = require("configuration_types")
local test = require("test")
local render = require("render")
local configuration = require("configuration")
local materializer = require("materializer")
local bounds = require("bounds")
local json = require("json")
local toml = require("toml")
local hash = require("hash")
type Object = {[string]: unknown}
local function field(format: string, path: {string}, merge: string): Object
    return {render = {{kind = "config", contexts = {"first_turn"}, file = "provider/config." .. format,
        format = format, path = path, merge = merge, value = {field = "provider.options.settings"}}}}
end
local function define_tests()
    test.describe("Descriptor option materialization", function()
        test.it("composes selected options with retained ambient configuration", function()
            for _, format in ipairs({"json", "toml"}) do
                local empty = assert(hash.sha256(""))
                local path = "provider/config." .. format
                local base: configuration_types.Configuration = {revision = "test@1", path = path, content = "", digest = empty,
                    provider_ref = configuration.LOGIN_PROVIDER_REF, composition = {kind = "copy", base_path = "provider/base." .. format}}
                local files = assert(render.files({settings = field(format, {"agent", "guidance"}, "append")}, {settings = "new"}, "first_turn", {base}))
                local decoded = assert(configuration.decode_file(files[1]))
                local original = format == "json" and '{"agent":{"guidance":"old"},"retained":true}' or 'retained = true\n[agent]\nguidance = "old"\n'
                local result = assert(materializer.render(decoded, {}, nil, original))
                local document = assert(bounds.object(format == "json" and json.decode(result) or toml.decode(result)))
                test.eq(document.retained, true)
                test.eq(assert(bounds.object(document.agent)).guidance, "old\n\nnew")
            end
        end)
    end)
end
return test.run_cases(define_tests)
