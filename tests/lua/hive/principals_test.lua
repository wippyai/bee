-- MIT. The destination principal table, pure: exact decoding, one actor
-- per issuer and subject in the member namespace, unknown pairs resolving
-- to nothing, two subjects of one issuer kept apart, and a mapping change
-- affecting resolution only.
local test = require("test")
local principals = require("principals")
local function decoded_of(value: unknown): principals.Mappings
    local decoded, err = principals.decode(value)
    if not decoded then error(tostring(err)) end
    return decoded
end
local function subject(node: string, number: string): string
    return "{" .. node .. "@bee:workers|0x" .. number .. "}"
end
local function define_tests()
    test.describe("Principal mappings", function()
        test.it("decodes an exact table and refuses actors outside the member namespace, repeated pairs and foreign subjects", function()
            local decoded, err = principals.decode({mappings = {
                {issuer = "node-a", subject_id = subject("node-a", "1"), policies = {"bee:thread_observe_policy"}},
                {issuer = "node-a", subject_id = subject("node-a", "2")},
            }})
            if not decoded then error(tostring(err)) end
            test.eq(#decoded.list, 2)
            test.eq(decoded.list[1].actor_id, principals.actor_of("node-a", subject("node-a", "1")))
            test.eq(decoded.list[1].actor_id:sub(1, #principals.ACTOR_PREFIX), principals.ACTOR_PREFIX)
            test.neq(decoded.list[1].actor_id, decoded.list[2].actor_id)
            -- The host names no actor: a pair's actor is a function of the pair.
            local _, named_error = principals.decode({mappings = {{issuer = "node-a", subject_id = subject("node-a", "1"), actor_id = "bee.local"}}})
            test.eq(named_error, "mappings[1]: unknown field actor_id")
            local _, repeat_error = principals.decode({mappings = {
                {issuer = "node-a", subject_id = subject("node-a", "1")},
                {issuer = "node-a", subject_id = subject("node-a", "1"), policies = {"bee:thread_observe_policy"}},
            }})
            test.is_true(tostring(repeat_error):find("repeats issuer node-a", 1, true) ~= nil)
            local _, foreign_error = principals.decode({mappings = {{issuer = "node-a", subject_id = subject("node-z", "1")}}})
            test.eq(foreign_error, "mappings[1] subject is outside the issuer's namespace")
            local _, unknown_error = principals.decode({mappings = {{issuer = "node-a", subject_id = subject("node-a", "1"), scope = "x"}}})
            test.eq(unknown_error, "mappings[1]: unknown field scope")
            test.neq(principals.actor_of("node-a", subject("node-a", "1")), principals.actor_of("node-b", subject("node-a", "1")))
            local _, shape_error = principals.decode({mappings = "many"})
            test.eq(shape_error, "mappings must be a list")
        end)
        test.it("resolves only the pair the host named and keeps two subjects of one issuer apart", function()
            local decoded = decoded_of({mappings = {
                {issuer = "node-a", subject_id = subject("node-a", "1")},
                {issuer = "node-a", subject_id = subject("node-a", "2")},
            }})
            local alpha = principals.resolve(decoded, {issuer = "node-a", subject_id = subject("node-a", "1")})
            local beta = principals.resolve(decoded, {issuer = "node-a", subject_id = subject("node-a", "2")})
            test.eq(alpha and alpha.actor_id, principals.actor_of("node-a", subject("node-a", "1")))
            test.eq(beta and beta.actor_id, principals.actor_of("node-a", subject("node-a", "2")))
            test.is_nil(principals.resolve(decoded, {issuer = "node-z", subject_id = subject("node-a", "1")}))
            test.is_nil(principals.resolve(decoded, {issuer = "node-a", subject_id = subject("node-a", "3")}))
            -- A later table keeps every admitted pair's actor and only changes which pairs are admitted and under which policies.
            local changed = decoded_of({mappings = {{issuer = "node-a", subject_id = subject("node-a", "2"), policies = {"bee:thread_observe_policy"}}}})
            test.is_nil(principals.resolve(changed, {issuer = "node-a", subject_id = subject("node-a", "1")}))
            test.eq((principals.resolve(changed, {issuer = "node-a", subject_id = subject("node-a", "2")}) or {}).actor_id, beta and beta.actor_id)
        end)
    end)
end
return test.run_cases(define_tests)
