-- MIT. The muse driver's codec with its descriptor's JSON paths, for its suites.
local codec_protocol = require("codec_protocol")
local codec = require("codec")
return codec_protocol.of(codec, "bee.drivers.muse.descriptor:cli")
