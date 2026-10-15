local driver_types = require("driver_types")

type Outcome = "succeeded" | "failed" | "cancelled" | "uncertain"
-- stopped: the child ended after its placement was asked to stop it.
type Exit = {code: integer?, signal: integer?, uncertain: boolean, stopped: boolean?}
type Settlement = {outcome: Outcome, answer: string?, resume_ref: string?, reason: string, exit_reconciled: boolean}
-- stream_ended: the terminal was derived from the end of stdout rather
-- than read from an envelope.
type Evidence = {terminal: driver_types.Terminal?, stream_ended: boolean, exit: Exit?, drained: boolean, exit_codes_trustworthy: boolean}

return {}
