local service = require("service")
return {handle = function(request: unknown): service.Reply return service.waiting(request) end}
