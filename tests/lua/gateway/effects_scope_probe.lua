-- MIT. Exercise Gateway's real queue read and both effect dispatch paths.
local effects = require("effects")
local function run(): {pending: boolean, installation: boolean, publication: boolean}
    return {pending = effects.pending(), installation = effects.drain("installation"), publication = effects.drain("publication")}
end
return {run = run}
