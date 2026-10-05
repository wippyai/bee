-- MIT.
local test = require("test")
local semver = require("semver")

local function define_tests()
    test.describe("Hub SemVer", function()
        test.it("parses strict v-prefixed SemVer and rejects malformed versions", function()
            local version = semver.parse("v1.2.3-rc.1+build.7")
            test.not_nil(version)
            if version then
                test.eq(version.major, "1")
                test.eq(version.minor, "2")
                test.eq(version.patch, "3")
                test.eq(version.prerelease[1], "rc")
                test.eq(version.prerelease[2], "1")
            end
            for _, raw in ipairs({"1.2", "01.2.3", "1.2.3-", "1.2.3-01", "1.2.3+bad..build", " v1.2.3"}) do
                test.is_nil(semver.parse(raw))
            end
        end)

        test.it("orders numeric fields and SemVer prerelease identifiers", function()
            test.eq(semver.compare("1.10.0", "1.9.0"), 1)
            test.eq(semver.compare("1.0.0-alpha.2", "1.0.0-alpha.10"), -1)
            test.eq(semver.compare("1.0.0-alpha", "1.0.0-alpha.1"), -1)
            test.eq(semver.compare("1.0.0-rc.1", "1.0.0"), -1)
            test.eq(semver.compare("v1.0.0+one", "1.0.0+two"), 0)
            local result, problem = semver.compare("broken", "1.0.0")
            test.is_nil(result)
            test.not_nil(problem)
        end)

        test.it("matches caret, tilde, intersections, alternatives and wildcards", function()
            test.is_true(semver.matches("1.8.0", "^1.2.3"))
            test.is_false(semver.matches("2.0.0", "^1.2.3"))
            test.is_true(semver.matches("0.2.9", "^0.2.3"))
            test.is_false(semver.matches("0.3.0", "^0.2.3"))
            test.is_true(semver.matches("1.2.9", "~1.2.3"))
            test.is_false(semver.matches("1.3.0", "~1.2.3"))
            test.is_true(semver.matches("1.7.0", ">=1.2.0, <2.0.0"))
            test.is_true(semver.matches("2.1.0", "^1.2.3 || >=2.1.0 <3.0.0"))
            test.is_true(semver.matches("1.9.9", "1.x"))
            test.is_false(semver.matches("2.0.0", "1.x"))
            test.is_true(semver.matches("1.2.9", "1.2.*"))
        end)

        test.it("excludes prereleases unless one set explicitly targets their core", function()
            test.is_false(semver.matches("1.2.0-beta.1", ">=1.0.0 <2.0.0"))
            test.is_true(semver.matches("1.2.0-beta.1", ">=1.2.0-beta.1 <1.3.0"))
            test.is_false(semver.matches("1.2.0-beta.1", "1.x"))
            test.is_true(semver.matches("1.2.0-beta.1", "1.2.0-beta.1"))
        end)

        test.it("rejects malformed and unsupported constraint syntax", function()
            for _, constraint in ipairs({"", "^", "1.2", "<1.x", ">= 1.2.3", "1.2.3 ||", "1.2.3 | 2.0.0", "@latest"}) do
                local matched, problem = semver.matches("1.2.3", constraint)
                test.is_nil(matched)
                test.not_nil(problem)
            end
        end)

        test.it("selects the highest version satisfying every requested constraint", function()
            local selected, problem = semver.select(
                {"v1.2.0", "1.9.0", "2.0.0", "1.10.0-beta.1", "1.10.0"},
                {"^1.2.0", ">=1.8.0"})
            test.is_nil(problem)
            test.eq(selected, "1.10.0")
            local missing, missing_problem = semver.select({"1.0.0", "2.0.0"}, {"^3.0.0"})
            test.is_nil(missing)
            test.not_nil(missing_problem)
            local malformed, malformed_problem = semver.select({"1.0.0"}, {"1.2"})
            test.is_nil(malformed)
            test.not_nil(malformed_problem)
        end)
    end)
end

return test.run_cases(define_tests)
