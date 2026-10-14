-- MIT. Keyboard help: the desktop's keys and mouse actions as an app window.
-- view owns geometry.
local tty = require("tty")
local channel = require("channel")
local process = require("process")
local appearance = require("appearance")
local frame = require("frame")
local view = require("view")
local manuals = require("manuals")
local markdown = require("markdown")

local function main(options: unknown)
    local input = assert(tty.events())
    local menu = frame.menu()
    local lifecycle = assert(process.events())
    local changes = assert(process.listen(appearance.TOPIC, {message = true}))
    assert(tty.start())
    local output = assert(tty.surface())
    local screen_width, screen_height = tty.screen_size()
    local width, height = math.floor(screen_width), math.floor(screen_height)
    local preferences = appearance.chosen(options)
    local pane: view.Pane = "desktop"
    local offset = 0
    local browser: view.Manuals = {documents = {}, selected = 1, query = "", searching = false, status = ""}
    local loaded = false
    local hits: {frame.Hit} = {}
    local running, dirty = true, true

    local function scroll(amount: integer)
        local count = #view.lines(pane)
        if pane == "manuals" and browser.opened then count = #markdown.lines(browser.opened.content, math.floor(math.max(0, width - 2))) end
        local last = math.floor(math.max(0, count - view.capacity(width, height)))
        offset = math.floor(math.max(0, math.min(last, offset + amount)))
        dirty = true
    end
    local function choose(next_pane: view.Pane)
        pane = next_pane
        if pane == "manuals" and not loaded then
            local documents, err = manuals.load()
            browser.documents = documents or {}
            browser.status = err or ""
            loaded = documents ~= nil
        end
        offset = 0; dirty = true
    end
    local function open_manual()
        local documents = manuals.search(browser.documents, browser.query)
        browser.opened = documents[browser.selected]
        browser.searching = false; offset = 0; dirty = true
    end
    local function move(amount: integer)
        if pane == "manuals" and not browser.opened then
            local count = #manuals.search(browser.documents, browser.query)
            browser.selected = math.floor(math.max(1, math.min(count, browser.selected + amount)))
            dirty = true
        else scroll(amount) end
    end
    local function switch(step: integer)
        local index = 1
        for position, item in ipairs(view.PANES) do if item == pane then index = position end end
        choose(view.PANES[(index - 1 + step + #view.PANES) % #view.PANES + 1])
        offset = 0
        dirty = true
    end

    while running do
        if dirty then
            local drawn = view.draw(width, height, preferences, pane, offset, browser)
            frame.render(drawn, menu, preferences)
            hits = drawn.hits
            assert(output:present(drawn.rows, {cursor = {x = 1, y = 1, visible = false}}))
            dirty = false
        end
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), changes:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then running = false end
        elseif event.channel == changes then
            preferences = appearance.chosen(event.value:payload():data())
            dirty = true
        else
            local data, handled = frame.route(menu, event.value, pane == "manuals" and browser.searching)
            if handled then dirty = true end
            if data then
                if data.type == "close" then running = false
                elseif data.type == "resize" then
                    width, height = math.floor(data.width), math.floor(data.height)
                    scroll(0)
                elseif data.type == "key" and data.action ~= "release" then
                    local key = data.key_type
                    if pane == "manuals" and (key == "esc" or key == "escape") then
                        if browser.opened then browser.opened = nil; offset = 0
                        elseif browser.searching then browser.searching = false
                        elseif browser.query ~= "" then browser.query = ""; browser.selected = 1
                        else choose("desktop") end
                        dirty = true
                    elseif pane == "manuals" and key == "enter" then
                        if browser.opened then browser.opened = nil; offset = 0; dirty = true
                        elseif browser.searching then browser.searching = false; dirty = true else open_manual() end
                    elseif pane == "manuals" and browser.searching and key == "backspace" then
                        browser.query = browser.query:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
                        browser.selected = 1; dirty = true
                    elseif pane == "manuals" and type(data.key) == "string" and data.key ~= "" and browser.searching then
                        if #browser.query + #data.key <= 256 then browser.query = browser.query .. data.key end
                        browser.selected = 1; dirty = true
                    elseif pane == "manuals" and data.key == "/" and not browser.opened then
                        browser.searching = true; dirty = true
                    elseif key == "up" then move(-1)
                    elseif key == "down" then move(1)
                    elseif key == "pgup" then move(-view.capacity(width, height))
                    elseif key == "pgdown" then move(view.capacity(width, height))
                    elseif key == "tab" then switch(data.shift == true and -1 or 1)
                    elseif key == "left" then switch(-1)
                    elseif key == "right" then switch(1) end
                elseif data.type == "mouse" then
                    if data.action == "wheel" then
                        move((data.button == "wheel_up" or data.button == "up") and -1 or 1)
                    elseif data.action == "press" and data.button == "left" then
                        local hit = frame.hit(hits, math.floor(tonumber(data.x) or 1), math.floor(tonumber(data.y) or 1))
                        if hit then
                            if hit.kind == "manual" then browser.selected = hit.index; open_manual()
                            elseif hit.kind == "manuals_open" then open_manual()
                            elseif (hit.kind == "manuals_search" or hit.kind == "field") then browser.searching = true; dirty = true
                            elseif hit.kind == "manuals_back" then browser.opened = nil; offset = 0; dirty = true end
                            for _, item in ipairs(view.PANES) do
                                if hit.kind == item then choose(item) end
                            end
                        end
                    end
                end
            end
        end
    end
    output:close()
    tty.stop()
end
return {main = main}
