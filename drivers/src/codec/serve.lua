-- MIT. One codec as a function a host finds by meta.codec: each entry binds
-- this source to its own codec library.
local codec = require("codec")
local normalizer = require("normalizer")
return {handle = normalizer.serve(codec)}
