local fs = require("fs")
local json = require("json")
local system = require("system")
local bounds = require("bounds")
local resources = require("resources")
local registry = require("registry")
local legacy = require("legacy")
return require("migration").define(function()
    migration("Move persistent Docker consent to common Grants",function()
        database("sqlite",function()
            up(function(db)
                local root, root_error = resources.root()
                if not root then error(root_error) end
                local volume = assert(fs.get(root))
                if not volume:stat("/images/environment.json") then return end
                local receipt = assert(bounds.object(json.decode(assert(volume:readfile("/images/environment.json")))))
                if receipt.state ~= "approved" and receipt.state ~= "revoked" then return end
                local id = assert(bounds.id(receipt.approval_id))
                local source_rows = assert(db:query("SELECT owner_node,workspace_id,requester_id,decider_id,decided_at,proposal_json FROM bee_approval_requests WHERE approval_id = ?",{id}))
                local source = #source_rows == 1 and bounds.object(source_rows[1]) or nil
                if source then source.proposal = json.decode(assert(bounds.text(source.proposal_json,8192))) end
                local entries = assert(registry.find({["meta.type"] = "bee.docker_environment"}))
                assert(#entries == 1,"Docker provisioning configuration is ambiguous")
                local configuration = assert(bounds.object(entries[1].data))
                local node = assert(system.node.id())
                local record, err = legacy.import(db,node,receipt,source,assert(bounds.id(configuration.network)))
                if not record then error(err) end
            end)
        end)
    end)
end)
