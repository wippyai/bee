-- MIT. A Hive invite admits exactly one node, once, before it expires, and only
-- with the secret it was minted with; used, revoked, expired and unknown
-- invites are refused without changing their record.
local test = require("test")
local invites = require("invites")

local ID = string.rep("a", 32)
local OTHER = string.rep("b", 32)
local DIGEST = string.rep("c", 64)
local WRONG = string.rep("d", 64)
local EXPIRES = "2026-09-23T12:15:00.000Z"

local function define_tests()
    test.describe("Hive invites", function()
        test.it("redeems a pending invite once for the presented node", function()
            local state = invites.new()
            local minted, mint_error = invites.mint(state, ID, DIGEST, 1000, EXPIRES)
            test.is_nil(mint_error)
            if not minted then error("mint failed") end
            test.eq(minted.status, "pending")
            test.eq(minted.expires_at, EXPIRES)

            local redeemed, code = invites.redeem(state, ID, DIGEST, "node-b", 2000)
            test.is_nil(code)
            if not redeemed then error("redeem failed") end
            test.eq(redeemed.status, "used")
            test.eq(redeemed.node_id, "node-b")

            local again, again_code, again_message = invites.redeem(state, ID, DIGEST, "node-c", 3000)
            test.is_nil(again)
            test.eq(again_code, "CONFLICT")
            test.eq(again_message, "invite was already used")
            test.eq(invites.list(state, 3000)[1].node_id, "node-b")
        end)

        test.it("refuses a wrong secret and keeps the invite redeemable", function()
            local state = invites.new()
            invites.mint(state, ID, DIGEST, 0, EXPIRES)
            local refused, code, message = invites.redeem(state, ID, WRONG, "node-b", 10)
            test.is_nil(refused)
            test.eq(code, "DENIED")
            test.eq(message, "invite secret does not match")
            test.eq(invites.list(state, 10)[1].status, "pending")
            test.not_nil(invites.redeem(state, ID, DIGEST, "node-b", 20))
        end)

        test.it("refuses unknown, revoked and expired invites", function()
            local state = invites.new()
            local _, unknown_code = invites.redeem(state, OTHER, DIGEST, "node-b", 0)
            test.eq(unknown_code, "NOT_FOUND")

            invites.mint(state, ID, DIGEST, 0, EXPIRES)
            local revoked = invites.revoke(state, ID, 5)
            if not revoked then error("revoke failed") end
            test.eq(revoked.status, "revoked")
            local _, revoked_code = invites.redeem(state, ID, DIGEST, "node-b", 6)
            test.eq(revoked_code, "DENIED")
            local _, twice_code, twice_message = invites.revoke(state, ID, 7)
            test.eq(twice_code, "INVALID_STATE")
            test.eq(twice_message, "invite is already revoked")

            invites.mint(state, OTHER, DIGEST, 100, EXPIRES)
            local _, expired_code = invites.redeem(state, OTHER, DIGEST, "node-b", 100 + invites.LIFETIME_MS)
            test.eq(expired_code, "DEADLINE_EXCEEDED")
            local listed = invites.list(state, 100 + invites.LIFETIME_MS)
            test.eq(#listed, 2)
            test.eq(listed[1].status, "revoked")
            test.eq(listed[2].status, "expired")
        end)

        test.it("bounds records and never evicts a pending invite", function()
            local state = invites.new()
            for index = 1, invites.CAP do
                local id = string.format("%032x", index)
                local minted = invites.mint(state, id, DIGEST, 0, EXPIRES)
                if not minted then error("mint " .. tostring(index) .. " failed") end
            end
            local _, full = invites.mint(state, OTHER, DIGEST, 0, EXPIRES)
            test.eq(full, "pending invite capacity reached")
            invites.revoke(state, string.format("%032x", 1), 1)
            test.not_nil(invites.mint(state, OTHER, DIGEST, 2, EXPIRES))
            local listed = invites.list(state, 2)
            test.eq(#listed, invites.CAP)
            test.eq(listed[1].invite_id, string.format("%032x", 2))
            test.eq(listed[#listed].invite_id, OTHER)
            local _, duplicate = invites.mint(state, OTHER, DIGEST, 3, EXPIRES)
            test.eq(duplicate, "invite_id is already recorded")
        end)

        test.it("decodes exact operation input", function()
            test.not_nil(invites.decode(invites.INVITE, {}))
            local _, extra = invites.decode(invites.LIST, {all = true})
            test.eq(extra, "unknown field all")
            local revoke = invites.decode(invites.REVOKE, {invite_id = ID})
            if not revoke then error("revoke input refused") end
            test.eq(revoke.invite_id, ID)
            local _, upper = invites.decode(invites.REVOKE, {invite_id = string.upper(ID)})
            test.eq(upper, "invite_id must be 32 lowercase hexadecimal characters")
            local redeem = invites.decode(invites.REDEEM, {invite_id = ID, secret = DIGEST, node_id = "node-b"})
            if not redeem then error("redeem input refused") end
            test.eq(redeem.secret, DIGEST)
            local _, short = invites.decode(invites.REDEEM, {invite_id = ID, secret = "abc", node_id = "node-b"})
            test.eq(short, "secret must be 64 lowercase hexadecimal characters")
            local _, unknown = invites.decode("bee.hive.join:other", {})
            test.eq(unknown, "unknown invite operation")
        end)
    end)
end

local cases = test.run_cases(define_tests)
return {run = function(options) return cases(options) end}
