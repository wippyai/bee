-- MIT. Injected only into the staged supervisor, before production startup.
-- These checks observe the actual lifecycle frame without replacing its scope.
    local security = require("security")
    local actor = security.actor()
    assert(actor and actor:id() == "bee.hive.supervisor", "wrong service actor")
    assert(security.can("process.registry.register", "bee.hive.supervisor"), "missing own-name authority")
    assert(security.can("funcs.call", "bee.hive.supervisor:execute"), "missing dispatch authority")
    assert(not security.can("process.registry.register", "unrelated.name"), "foreign-name authority")
    assert(not security.can("process.host", "bee:workers"), "unexpected host authority")
    assert(not security.can("process.spawn", "bee.hive.supervisor:main"), "unexpected spawn authority")
    assert(not security.can("security.scope.create", "scope"), "unexpected scope authority")
    assert(not security.can("funcs.call", "unrelated:operation"), "unrelated function authority")
    assert(not security.can("db.get", "bee:workspace_db"), "unexpected database authority")
