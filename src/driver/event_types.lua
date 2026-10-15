local record_types = require("record_types")

type Fault = {code: string, message: string, retryable: boolean}
type Content = {text: string?, artifact_ref: string?}
type Observation = {[string]: unknown}
type Usage = record_types.Usage

return {}
