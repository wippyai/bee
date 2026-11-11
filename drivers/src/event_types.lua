local record_types = require("record_types")

type Fault = {code: string, message: string, retryable: boolean}
type Content = {text: string?, artifact_ref: string?}
type Observation = {[string]: unknown}
type Usage = record_types.Usage
type ModelUsage = record_types.ModelUsage
type RateLimits = record_types.RateLimits
type RateLimitWindow = record_types.RateLimitWindow
type LimitStatus = record_types.LimitStatus

return {}
