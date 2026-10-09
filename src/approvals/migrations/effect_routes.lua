local resources = require("resources")
local json = require("json")
local bounds = require("bounds")
local canonical = require("canonical")
return require("migration").define(function()
    migration("Route existing effects through registered consumer metadata", function()
        database("sqlite", function()
            up(function(db)
                local _, kind_error = db:execute("UPDATE bee_approval_events SET kind = 'approval.decided' WHERE kind = 'approval.approved'")
                if kind_error then error("normalize legacy decision events") end
                local _, receipt_error = db:execute([[UPDATE bee_approval_effects SET state = 'failed'
                    WHERE state = 'succeeded' AND CASE WHEN json_valid(receipt_json)
                    THEN json_extract(receipt_json, '$.ok') = 0 ELSE 0 END]])
                if receipt_error then error("classify failed legacy effect receipts") end
                local consumers, consumer_error = resources.consumers()
                if not consumers then error(consumer_error) end
                local rows, query_error = db:query("SELECT r.approval_id, r.revision, r.proposal_json, r.consumed_effect, r.state, r.decision, r.effect_completed_at, r.requester_id, r.proposal_digest, r.owner_node, r.workspace_id, r.updated_at FROM bee_approval_requests r JOIN bee_approval_effects e ON e.approval_id = r.approval_id WHERE e.destination IS NULL")
                if not rows or query_error then error("read legacy effect routes") end
                for _, row in ipairs(rows) do
                    local matched = false
                    local proposal = type(row.proposal_json) == "string" and bounds.object(json.decode(row.proposal_json)) or nil
                    for _, consumer in ipairs(consumers) do
                        if proposal and proposal.ref == consumer.operation_ref then
                            if matched then error("legacy operation has multiple effect destinations") end
                            matched = true
                            local effect_id = row.consumed_effect or ((consumer.effect_prefix or "") .. tostring(row.approval_id))
                            local _, update_error = db:execute("UPDATE bee_approval_effects SET destination = ?, effect_id = ? WHERE approval_id = ?", {consumer.destination, effect_id, row.approval_id})
                            if update_error then error("route legacy effect") end
                            if row.state ~= "pending" then
                                local outcome = row.state == "decided" and (row.decision == "approved" and "decided" or "denied") or tostring(row.state)
                                local body = canonical.encode({contract_version = 1, approval_id = row.approval_id,
                                    owner_node = row.owner_node, workspace_id = row.workspace_id, revision = row.revision,
                                    state = row.state, decision = row.decision, reviewed_digest = row.proposal_digest,
                                    effect_id = effect_id, destination = consumer.destination, provenance = "legacy"})
                                if not body then error("encode legacy effect event") end
                                local _, event_error = db:execute("INSERT INTO bee_approval_events (event_id, approval_id, revision, kind, destination, body_json, acknowledged_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                    {tostring(row.approval_id) .. ":" .. tostring(row.revision) .. ":" .. consumer.destination, row.approval_id, row.revision, "approval." .. outcome, consumer.destination,
                                    body, row.effect_completed_at, row.updated_at})
                                if event_error then error("queue legacy effect event") end
                            end
                        end
                    end
                end
            end)
        end)
    end)
end)
