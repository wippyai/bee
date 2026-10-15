local driver_types = require("driver_types")

type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
type Exit = {code: integer?, signal: integer?, uncertain: boolean, stopped: boolean?}
type Settlement = {outcome: Outcome, answer: string?, resume_ref: string?, reason: string, exit_reconciled: boolean}
type Evidence = {terminal: driver_types.Terminal?, stream_ended: boolean, exit: Exit?, drained: boolean, exit_codes_trustworthy: boolean}

return {}
