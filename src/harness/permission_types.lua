
type Object = {[string]: unknown}
type Fields = {correlation: string, tool: string, input: string, prompt: string?, acknowledgment: string?}
type Response = {correlation_kind: string?, envelope: Object, correlation_field: string?, decision_field: string, allow_value: string, deny_value: string, reason_field: string?, response_field: string?}
type Acknowledgment = {mode: string, event_type: string?, field: string?}
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
