type Entry = {[string]: unknown}
type Digest = {entry: string, scope: "entry"}
-- permission reports proof eligibility apart from compatibility: eligible
-- means the profile pins an adapter the snapshot measures; acceptance is a
-- host record checked at admission, never inferred from a fixture name.
type Permission = {mode: string, adapter_ref: string?, adapter_digest: string?, proof_fixture: string?, eligible: boolean}
type Profile = {id: string, mode: string, protocol: string, protocol_revision: string, supported: boolean, private_home: boolean, permission: Permission}
type Binding = {
    binding_id: string,
    driver_id: string,
    title: string,
    implementation_version: string,
    profiles_ref: string,
    binding_digest: Digest,
    profile_digest: Digest,
    default_profile: string,
    profiles: {Profile},
    methods: {[string]: string},
    state: "compatible" | "incompatible",
    activated: boolean,
    diagnostics: {string},
}

return {}
