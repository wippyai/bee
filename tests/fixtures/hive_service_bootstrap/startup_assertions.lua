-- MIT. Injected only into the staged supervisor, before production startup.
-- These checks observe the actual lifecycle frame without replacing its scope.
    local security = require("security")
    local actor = security.actor()
    assert(actor and actor:id() == "bee.hive.supervisor", "wrong service actor")
    assert(security.can("process.registry.register", "bee.hive.supervisor"), "missing own-name authority")
    assert(security.can("funcs.call", "bee.hive.supervisor:execute"), "missing dispatch authority")
    assert(not security.can("process.registry.register", "unrelated.name"), "foreign-name authority")
    -- The supervisor composes the retained desktop bridge, so it holds exactly
    -- the desktop host authority: the retained launcher on the worker host.
    assert(security.can("process.host", "bee:workers"), "missing desktop bridge host authority")
    assert(security.can("process.spawn", "bee.launch:retained"), "missing desktop bridge spawn authority")
    assert(security.can("security.scope.create", "scope"), "missing desktop bridge scope authority")
    assert(security.can("funcs.call", "bee.client:list_desktops"), "missing display catalog authority")
    assert(security.can("bee.client.desktops.read", "bee:client_db"), "missing display read authority")
    assert(security.can("bee.workspaces.read", "bee:workspace_catalog"), "missing workspace catalog authority")
    assert(security.can("funcs.call", "bee.workspace.catalog:list"), "missing workspace catalog call authority")
    assert(not security.can("process.host", "bee.hive:supervisor_host"), "unexpected supervisor host authority")
    assert(not security.can("process.spawn", "bee.hive.supervisor:main"), "unexpected spawn authority")
    assert(not security.can("funcs.call", "unrelated:operation"), "unrelated function authority")
    assert(not security.can("db.get", "bee:workspace_db"), "unexpected database authority")
