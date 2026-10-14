-- MIT.
local source = require("source")
local inventory = require("inventory")
local function run(): integer
    local installed = assert(inventory.decode({entries = {}, resolution = {modules = {}}}, 1))
    local artifact = assert(source.new({entries = {}}, installed, "bee/bee").artifact("bee/bee", "0.2.0-alpha.7"))
    return #artifact.entries
end
return {run = run}
