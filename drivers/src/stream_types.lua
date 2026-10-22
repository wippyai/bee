local framing = require("framing")

type Decoder = {framer: framing.Framer, index: integer}
type Envelope = {index: integer, value: {[string]: unknown}}
type Problem = {index: integer, message: string, sample: string}

return {}
