-- MIT. Bee's saved driver profiles launch through the drivers' effective options.
local test = require("test")
local descriptors = require("descriptors")
local effective = require("effective")
local bounds = require("bounds")
local universal = require("universal")
local profiles = require("profiles")
local json = require("json")
local function define_tests()
    test.describe("Bee saved driver profiles", function()
        test.it("launches empty saved selections for every driver", function()
            for _, driver in ipairs({"agy", "grok", "opencode", "claude", "codex", "muse"}) do
                local ref = "bee.drivers." .. driver .. ".descriptor:cli"
                local cli = assert(descriptors.load(ref))
                local stored = assert(profiles.storage(assert(profiles.profile({schema_revision = profiles.SCHEMA,
                    name = "Empty", definition_ref = "bee.driver." .. driver .. ".profiles:default_window",
                    driver_binding_ref = "bee.drivers." .. driver .. ".binding:binding", provider = {}, bee = {}}))))
                local profile = assert(profiles.profile(json.decode(assert(json.encode(stored)))))
                local saved = assert(profiles.preferences(profile))
                local applied = assert(effective.apply({}, saved, cli))
                local options = assert(bounds.object(applied.prepare_options))
                options.profile_id, options.brief = "batch", "Fixture"
                options.option_provenance = applied.option_provenance
                local reply = assert(bounds.object(universal.prepare(ref)(options)))
                assert(reply.ok == true, driver .. ": " .. tostring(reply.error))
            end
        end)
    end)
end
return test.run_cases(define_tests)
