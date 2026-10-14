# Minimal Bee starter app

Copy this complete JSON array to entries.json in overlay hello. Replace all app.hello prefixes if you rename the overlay. The UI lives in .app, behaviour in .model and tests in .tests. It needs no extra capabilities. The source is the typed Lua fixture that Bee lints; the greeting tests exercise the same library the app uses. Follow docs/build_bee_app to freeze, preflight, deliver, approve and run the installed tests.

## entries.json

```json
[
  {
    "id": "app.hello.app:app",
    "kind": "process.lua",
    "data": {
      "source": "local tty = require(\"tty\")\nlocal process = require(\"process\")\nlocal channel = require(\"channel\")\nlocal client = require(\"client\")\nlocal frame = require(\"frame\")\nlocal appearance = require(\"appearance\")\nlocal greeting = require(\"greeting\")\nlocal function main(value: unknown)\n    local launch = assert(client.launch(value))\n    local input = assert(tty.events())\n    local lifecycle = assert(process.events())\n    local states = assert(process.listen(\"bee.appearance.state\", {message = true}))\n    assert(tty.start())\n    local output = assert(tty.surface())\n    local width, height = tty.screen_size()\n    local preferences = appearance.defaults()\n    local function paint()\n        local painter = frame.new(width, height, preferences)\n        frame.header(painter, \"HELLO BEE\", \"A tiny app\")\n        if height >= 4 then frame.line(painter, 2, greeting.message(\"Bee\"), painter.theme.text) end\n        frame.footer(painter, \"Ready\", \"Esc closes\", nil, {})\n        assert(output:present(frame.rows(painter)))\n    end\n    assert(process.send(launch.broker_pid, \"bee.appearance.request\", {version = 1,\n        request_id = launch.instance_id, op = \"state\"}))\n    paint()\n    client.ready(launch)\n    while true do\n        local event = channel.select({input:case_receive(), lifecycle:case_receive(), states:case_receive()})\n        if not event.ok then break end\n        if event.channel == lifecycle then\n            if event.value.kind == process.event.CANCEL then break end\n        elseif event.channel == states then\n            local message = event.value\n            local data: unknown = message:payload():data()\n            if message:from() == launch.broker_pid and type(data) == \"table\" and data.version == 1 then\n                local decoded = appearance.decode(data)\n                if decoded then preferences = decoded; paint() end\n            end\n        else\n            local data = event.value\n            if data.type == \"close\" then break end\n            if data.type == \"resize\" then width, height = data.width, data.height; paint() end\n            if data.type == \"key\" and data.action == \"press\" and (data.key_type == \"escape\" or data.key_type == \"esc\") then break end\n        end\n    end\n    process.unlisten(states)\n    output:close()\n    tty.stop()\nend\nreturn {main = main}\n",
      "method": "main",
      "modules": [
        "tty",
        "process",
        "channel"
      ],
      "imports": {
        "client": "bee.app:client",
        "appearance": "bee.ui:appearance",
        "frame": "bee.ui:frame",
        "greeting": "app.hello.model:greeting"
      }
    },
    "meta": {
      "type": "bee.app",
      "application": {
        "api_version": 1,
        "lifetime": "view",
        "revision": "1",
        "title": "Hello Bee",
        "instance_policy": "multiple",
        "restart_policy": "never",
        "menus": [
          "bee.shell:apps_menu"
        ]
      }
    }
  },
  {
    "id": "app.hello.model:greeting",
    "kind": "library.lua",
    "data": {
      "source": "local M = {}\nfunction M.message(name: string): string\n    local cleaned = name:match(\"^%s*(.-)%s*$\") or \"\"\n    if cleaned == \"\" then cleaned = \"Bee\" end\n    return \"Hello, \" .. cleaned\nend\nreturn M\n"
    }
  },
  {
    "id": "app.hello.tests:greeting_test",
    "kind": "function.lua",
    "data": {
      "source": "local test = require(\"test\")\nlocal greeting = require(\"greeting\")\nlocal function define_tests()\n    test.describe(\"greeting\", function()\n        test.it(\"uses Bee for an empty name\", function()\n            test.eq(greeting.message(\"   \"), \"Hello, Bee\")\n        end)\n        test.it(\"trims the requested name\", function()\n            test.eq(greeting.message(\"  Ada  \"), \"Hello, Ada\")\n        end)\n    end)\nend\nlocal cases = test.run_cases(define_tests)\nreturn {run = function(options: unknown) return cases(options) end}\n",
      "method": "run",
      "imports": {
        "test": "wippy.test:test",
        "greeting": "app.hello.model:greeting"
      }
    },
    "meta": {
      "type": "test",
      "suite": "hello"
    }
  }
]
```
