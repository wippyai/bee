-- MIT. Bee packs declare native needs as package metadata: native
-- requirements on their definitions, or the native identity manifest of the
-- binary they were built with. A pack set without either is Lua only and runs
-- on any binary. Only the running executable's identity, supplied by the
-- caller, is evidence for the binary; a pack set with native needs is refused
-- without it.
local bounds = require("bounds")
local semver = require("semver")
local binary_identity = require("binary_identity")
local M = {}

local function module_version(modules: {[string]: string}, package_name: string): string?
    local selected, version = "", nil
    for module, candidate in pairs(modules) do
        if (package_name == module or package_name:sub(1, #module + 1) == module .. "/") and #module > #selected then
            selected, version = module, candidate
        end
    end
    return version
end

function M.check(packages: {{component: string, entries: {{id: string, kind: string, meta: {[string]: unknown}}}}}, baked: binary_identity.Baked?): string?
    local needed: {{component: string, package: string, version: string}} = {}
    for _, package in ipairs(packages) do
        for _, entry in ipairs(package.entries) do
            if entry.kind == "ns.definition" then
                local requirements = entry.meta.native_requirements
                if requirements ~= nil then
                    local rows, rows_error = bounds.dense_list(requirements, 64, "native requirements")
                    if not rows then return entry.id .. ": " .. tostring(rows_error) end
                    local seen: {[string]: boolean} = {}
                    for _, raw_requirement in ipairs(rows) do
                        local requirement = bounds.object(raw_requirement)
                        local name = requirement and bounds.line(requirement.package, 256)
                        local version = requirement and bounds.line(requirement.version, 128)
                        if not name or not name:match("^[%w_./-]+$") or not version or not semver.parse(version) or seen[name] then
                            return entry.id .. ": invalid native requirement"
                        end
                        seen[name] = true
                        needed[#needed + 1] = {component = package.component, package = name, version = version}
                    end
                end
            end
        end
    end
    local target_identity, target_error = binary_identity.read_packages(packages)
    if target_error then return "bee/bee: invalid binary identity: " .. target_error end
    if not target_identity and #needed == 0 then return nil end
    local running = baked
    if not running then
        return "needs a newer Bee binary: running binary native manifest is unavailable"
    end
    if target_identity and target_identity.runtime_commit ~= running.runtime_commit then
        return "needs a newer Bee binary: bee/bee pack set targets runtime commit " .. target_identity.runtime_commit
            .. "; this binary has " .. running.runtime_commit
    end
    for _, component in ipairs(target_identity and target_identity.native_components or {}) do
        local current = module_version(running.native_modules, component.package)
        local compared = current and semver.compare(current, component.version) or nil
        if not current or not compared or compared < 0 then
            return "needs a newer Bee binary: bee/bee pack set requires native component " .. component.package
                .. " " .. component.version .. "; this binary has " .. (current or "none")
        end
    end
    for _, requirement in ipairs(needed) do
        local current = module_version(running.native_modules, requirement.package)
        local compared = current and semver.compare(current, requirement.version) or nil
        if not current or not compared or compared < 0 then
            return "needs a newer Bee binary: " .. requirement.component .. " requires native component "
                .. requirement.package .. " " .. requirement.version .. "; this binary has " .. (current or "none")
        end
    end
    return nil
end

return M
