type Object = {[string]: unknown}
-- acknowledgment names the request field the harness echoes back when
-- it acts, where that differs from the response correlation.
type Fields = {correlation: string, tool: string, input: string, prompt: string?, acknowledgment: string?}
type Response = {correlation_kind: string?, envelope: Object, correlation_field: string?, decision_field: string, allow_value: string, deny_value: string, reason_field: string?, response_field: string?}
-- correlation_echo names the observation type and the field that carries
-- the request's correlation back; continued_output claims only that the
-- harness produced something afterwards.
type Acknowledgment = {mode: string, event_type: string?, field: string?}
-- A denial is acknowledged only by a terminal denial the adapter names; an
-- adapter that cannot name one reports denial dispatch as accepted by the
-- input transport with harness acknowledgment unproven.
type DenyAcknowledgment = {mode: string, event_type: string?, field: string?, value: string?, correlation_field: string?}
type Adapter = {
    adapter_id: string,
    schema_revision: string,
    event_name: string,
    event_revision: string,
    request: Fields,
    response: Response,
    acknowledgment: Acknowledgment,
    deny_acknowledgment: DenyAcknowledgment,
    cancellation: string,
    proof_fixture: string,
    digest: string,
}
type Request = {permission_request_id: string, correlation_id: string, acknowledgment_id: string, tool_name: string, input_digest: string, input: Object, prompt: string}
type Attempt = {action_id: string, attempt_id: string, plan_digest: string}
type Identity = {owner_id: string, attempt_id: string, permission_request_id: string}

return {}
