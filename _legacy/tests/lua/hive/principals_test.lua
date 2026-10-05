-- MIT. The destination principal table, pure: exact decoding, one actor
-- per issuer and subject in the member namespace, unknown pairs resolving
-- to nothing, two subjects of one issuer kept apart, and a mapping change
-- affecting resolution only.
local test = require("test")
local types = require("types")
local function decoded_of(value: unknown): types.PrincipalMappings
    local decoded, err = types.decode_principal_mappings(value)
    if not decoded then error(tostring(err)) end
    return decoded
end
local function subject(node: string, number: string): string
    return "{" .. node .. "@bee:workers|0x" .. number .. "}"
end
local function define_tests()
    test.describe("Principal mappings", function()
        test.it("decodes an exact table and refuses actors outside the member namespace, repeated pairs and foreign subjects", function()
            local decoded, err = types.decode_principal_mappings({mappings = {
                {issuer = "node-a", subject_id = subject("node-a", "1"), policies = {"bee.security.threads:thread_observe_policy"}},
                {issuer = "node-a", subject_id = subject("node-a", "2")},
            }})
            if not decoded then error(tostring(err)) end
            test.eq(#decoded.list, 2)
            test.eq(decoded.list[1].actor_id, types.principal_actor("node-a", subject("node-a", "1")))
            test.eq(decoded.list[1].actor_id:sub(1, #types.MEMBER_ACTOR_PREFIX), types.MEMBER_ACTOR_PREFIX)
            test.neq(decoded.list[1].actor_id, decoded.list[2].actor_id)
            -- The host names no actor: a pair's actor is a function of the pair.
            local _, named_error = types.decode_principal_mappings({mappings = {{issuer = "node-a", subject_id = subject("node-a", "1"), actor_id = "bee.local"}}})
            test.eq(named_error, "mappings[1]: unknown field actor_id")
            local _, repeat_error = types.decode_principal_mappings({mappings = {
                {issuer = "node-a", subject_id = subject("node-a", "1")},
                {issuer = "node-a", subject_id = subject("node-a", "1"), policies = {"bee.security.threads:thread_observe_policy"}},
            }})
            test.is_true(tostring(repeat_error):find("repeats issuer node-a", 1, true) ~= nil)
            local _, foreign_error = types.decode_principal_mappings({mappings = {{issuer = "node-a", subject_id = subject("node-z", "1")}}})
            test.eq(foreign_error, "mappings[1] subject is outside the issuer's namespace")
            local _, unknown_error = types.decode_principal_mappings({mappings = {{issuer = "node-a", subject_id = subject("node-a", "1"), scope = "x"}}})
            test.eq(unknown_error, "mappings[1]: unknown field scope")
            test.neq(types.principal_actor("node-a", subject("node-a", "1")), types.principal_actor("node-b", subject("node-a", "1")))
            local _, shape_error = types.decode_principal_mappings({mappings = "many"})
            test.eq(shape_error, "mappings must be a dense list of at most 256 entries")
        end)
        test.it("resolves only the pair the host named and keeps two subjects of one issuer apart", function()
            local decoded = decoded_of({mappings = {
                {issuer = "node-a", subject_id = subject("node-a", "1")},
                {issuer = "node-a", subject_id = subject("node-a", "2")},
            }})
            local alpha = types.resolve_principal(decoded, {issuer = "node-a", subject_id = subject("node-a", "1")})
            local beta = types.resolve_principal(decoded, {issuer = "node-a", subject_id = subject("node-a", "2")})
            test.eq(alpha and alpha.actor_id, types.principal_actor("node-a", subject("node-a", "1")))
            test.eq(beta and beta.actor_id, types.principal_actor("node-a", subject("node-a", "2")))
            test.is_nil(types.resolve_principal(decoded, {issuer = "node-z", subject_id = subject("node-a", "1")}))
            test.is_nil(types.resolve_principal(decoded, {issuer = "node-a", subject_id = subject("node-a", "3")}))
            -- A later table keeps every admitted pair's actor and only changes which pairs are admitted and under which policies.
            local changed = decoded_of({mappings = {{issuer = "node-a", subject_id = subject("node-a", "2"), policies = {"bee.security.threads:thread_observe_policy"}}}})
            test.is_nil(types.resolve_principal(changed, {issuer = "node-a", subject_id = subject("node-a", "1")}))
            test.eq((types.resolve_principal(changed, {issuer = "node-a", subject_id = subject("node-a", "2")}) or {}).actor_id, beta and beta.actor_id)
        end)
    end)
end
return test.run_cases(define_tests)
