-- MIT. Interactive terminal application process for Files.
-- Renders workspace file tree and syntax highlighted preview on the shared frame.
-- Handles mouse and keyboard events, responsive layout, search, jump, and agent navigation.
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local fs = require("fs")
local client = require("client")
local appearance = require("appearance")
local protocol = require("protocol")
local model = require("model")
local view = require("view")

local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then
        error("Invalid application launch")
    end

    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local appearance_sub = assert(process.listen("bee.appearance.state", {message = true}))
    local close_sub = assert(process.listen("bee.application.close", {message = true}))
    local nav_sub = assert(process.listen("bee.files.navigate", {message = true}))

    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local preferences = appearance.defaults()

    -- Acquire the workspace root volume
    local volume, vol_err = fs.get("bee.env:workspace_root")

    local state: model.State = model.new(volume, "", launch.arguments)
    client.ready(launch, {negotiate_close = true})

    if state.current_path then
        client.title(launch, "Files · " .. state.current_path)
    end

    local dirty = true
    local running = true
    local hits: {frame.Hit} = {}

    local function redraw()
        local rendered = view.render(state, width, height, preferences)
        output:present(rendered.rows)
        hits = rendered.hits
        dirty = false
    end

    local function handle_action(kind: string)
        if kind == "open" then
            model.activate(state)
            if state.current_path then
                client.title(launch, "Files · " .. state.current_path)
            end
            dirty = true
        elseif kind == "search" then
            model.open_modal(state, "search")
            dirty = true
        elseif kind == "jump" then
            model.open_modal(state, "jump")
            dirty = true
        elseif kind == "pane" then
            model.switch_pane(state)
            dirty = true
        elseif kind == "more" then
            model.open_modal(state, "more")
            dirty = true
        elseif kind == "help" then
            model.open_modal(state, "help")
            dirty = true
        end
    end

    redraw()

    while running do
        local selected = channel.select({
            input:case_receive(),
            lifecycle:case_receive(),
            appearance_sub:case_receive(),
            close_sub:case_receive(),
            nav_sub:case_receive(),
        })

        if not selected.ok then
            break
        end

        if selected.channel == lifecycle then
            if selected.value.kind == process.event.CANCEL then
                break
            end
        elseif selected.channel == close_sub then
            local payload = selected.value:payload():data()
            local request = client.close_request(launch, tostring(selected.value:from()), payload)
            if request then
                client.close_reply(launch, request.request_id, {
                    action = "confirm",
                    title = "Close Files?",
                    message = "Close the file tree and preview?",
                    accept = "Close Files",
                })
            end
        elseif selected.channel == appearance_sub then
            local updated = appearance.decode(selected.value:payload():data())
            if updated then
                preferences = updated
                dirty = true
            end
        elseif selected.channel == nav_sub then
            -- Agent navigation request: {path = "...", line = 42, end_line = 50}
            local payload = selected.value:payload():data()
            if type(payload) == "table" and type(payload.path) == "string" then
                local range = nil
                if type(payload.line) == "number" then
                    range = {start_line = math.floor(payload.line), end_line = math.floor(payload.end_line or payload.line)}
                end
                model.open_file(state, payload.path, range)
                client.title(launch, "Files · " .. state.current_path)
                dirty = true
            end
        elseif selected.channel == input then
            local event = selected.value

            if event.type == "resize" then
                width = event.width
                height = event.height
                dirty = true
            elseif event.type == "close" then
                break
            elseif event.type == "key" then
                local key = event.key or ""
                local key_type = event.key_type or ""

                if state.modal == "help" then
                    model.close_modal(state)
                    dirty = true
                elseif state.modal == "more" then
                    if key_type == "escape" or key == "q" or key == "Esc" then
                        model.close_modal(state)
                        dirty = true
                    elseif key_type == "up" or key == "k" then
                        model.more_move(state, -1)
                        dirty = true
                    elseif key_type == "down" or key == "j" then
                        model.more_move(state, 1)
                        dirty = true
                    elseif key_type == "enter" or key == "\r" or key == "\n" then
                        local sel = state.more_selected
                        model.close_modal(state)
                        if sel == 1 then model.open_modal(state, "search")
                        elseif sel == 2 then model.open_modal(state, "jump")
                        elseif sel == 3 then model.switch_pane(state)
                        elseif sel == 4 then model.open_modal(state, "help")
                        end
                        dirty = true
                    end
                elseif state.modal == "search" then
                    if key_type == "escape" then
                        model.close_modal(state)
                        dirty = true
                    elseif key_type == "enter" then
                        -- Open current selected match
                        model.close_modal(state)
                        model.activate(state)
                        if state.current_path then
                            client.title(launch, "Files · " .. state.current_path)
                        end
                        dirty = true
                    elseif key_type == "up" then
                        model.move(state, -1)
                        dirty = true
                    elseif key_type == "down" then
                        model.move(state, 1)
                        dirty = true
                    elseif key_type == "backspace" then
                        if #state.search_query > 0 then
                            model.set_search_query(state, state.search_query:sub(1, -2))
                            dirty = true
                        end
                    elseif key ~= "" and not key:find("[%c]") then
                        model.set_search_query(state, state.search_query .. key)
                        dirty = true
                    end
                elseif state.modal == "jump" then
                    if key_type == "escape" then
                        model.close_modal(state)
                        dirty = true
                    elseif key_type == "enter" then
                        local n = tonumber(state.jump_input)
                        model.close_modal(state)
                        if n then
                            model.jump_to_line(state, math.floor(n), height - 4)
                        end
                        dirty = true
                    elseif key_type == "backspace" then
                        model.jump_backspace(state)
                        dirty = true
                    elseif key:match("^%d$") then
                        model.jump_append(state, key)
                        dirty = true
                    end
                else
                    -- Normal navigation
                    if key_type == "up" or key == "k" then
                        model.move(state, -1)
                        dirty = true
                    elseif key_type == "down" or key == "j" then
                        model.move(state, 1)
                        dirty = true
                    elseif key_type == "page_up" then
                        model.page(state, -1, height - 4)
                        dirty = true
                    elseif key_type == "page_down" then
                        model.page(state, 1, height - 4)
                        dirty = true
                    elseif key_type == "tab" then
                        model.switch_pane(state)
                        dirty = true
                    elseif key_type == "enter" or key == "\r" or key == "\n" then
                        handle_action("open")
                    elseif key == "/" then
                        handle_action("search")
                    elseif key == "g" or key == "G" then
                        handle_action("jump")
                    elseif key == "m" or key == "M" or key_type == "f10" then
                        handle_action("more")
                    elseif key == "?" then
                        handle_action("help")
                    elseif key_type == "escape" or key == "q" then
                        if state.current_path and state.active_pane == "preview" then
                            model.switch_pane(state)
                            dirty = true
                        else
                            break
                        end
                    end
                end
            elseif event.type == "mouse" then
                if event.action == "press" then
                    local mx, my = event.x, event.y
                    for _, hit in ipairs(hits) do
                        if mx >= hit.x and mx < hit.x + hit.width and my >= hit.y and my < hit.y + hit.height then
                            if hit.kind == "open" or hit.kind == "search" or hit.kind == "jump" or hit.kind == "pane" or hit.kind == "more" or hit.kind == "help" then
                                handle_action(hit.kind)
                            elseif hit.kind == "tree" then
                                model.select_tree(state, hit.index)
                                handle_action("open")
                            elseif hit.kind == "preview_line" then
                                model.select_preview(state, hit.index)
                                dirty = true
                            elseif hit.kind == "tab" then
                                if hit.key == "tree" then
                                    model.set_tab(state, "tree")
                                    dirty = true
                                elseif hit.key == "preview" then
                                    model.set_tab(state, "preview")
                                    dirty = true
                                end
                            end
                            break
                        end
                    end
                end
            end
        end

        if dirty then
            redraw()
        end
    end

    process.unlisten(appearance_sub)
    process.unlisten(close_sub)
    process.unlisten(nav_sub)
    tty.stop()
end

return {main = main}
