local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")
local spy = require("tests.helpers.spy")
local StatusAnimation = require("agentic.ui.status_animation")

describe("agentic.ui.StatusAnimation", function()
    local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

    local bufnr
    local animation

    --- Handle set, not a count: `tabclose!` closes the CURRENT tab, and the
    --- cross-tab cases end on the original one, so a count-based loop shuts the
    --- baseline tab and leaves the test-created one alive.
    --- @type table<integer, true>
    local base_tabs

    --- Tracked so `after_each` closes them even when an assertion throws.
    --- Deleting a buffer only swaps the window to another buffer, so buffer
    --- teardown cannot substitute for closing a float.
    --- @type integer[]
    local extra_wins

    --- @param winid integer
    --- @return integer winid
    local function track_win(winid)
        extra_wins[#extra_wins + 1] = winid
        return winid
    end

    before_each(function()
        base_tabs = {}
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            base_tabs[tab] = true
        end
        extra_wins = {}
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two" })
        animation = StatusAnimation:new(bufnr)
    end)

    after_each(function()
        animation:stop()
        animation = nil

        for _, winid in ipairs(extra_wins) do
            if vim.api.nvim_win_is_valid(winid) then
                pcall(vim.api.nvim_win_close, winid, true)
            end
        end

        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            if not base_tabs[tab] and vim.api.nvim_tabpage_is_valid(tab) then
                pcall(function()
                    vim.api.nvim_set_current_tabpage(tab)
                    vim.cmd("tabclose!")
                end)
            end
        end

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    --- @return table extmarks
    local function extmarks()
        return vim.api.nvim_buf_get_extmarks(
            bufnr,
            NS_ANIMATION,
            0,
            -1,
            { details = true }
        )
    end

    --- Animation row of the rendered extmark, nil when nothing is drawn.
    --- @return table|nil chunks
    local function animation_chunks()
        local marks = extmarks()
        if #marks == 0 then
            return nil
        end
        local virt_lines = marks[1][4].virt_lines
        return virt_lines and virt_lines[2]
    end

    describe("frame scheduling", function()
        --- @type TestStub
        local defer_stub
        local scheduled

        before_each(function()
            scheduled = {}
            defer_stub = spy.stub(vim, "defer_fn")
            defer_stub:invokes(function(callback)
                scheduled[#scheduled + 1] = callback
                return nil
            end)
        end)

        after_each(function()
            defer_stub:revert()
        end)

        it("drops a stale frame instead of scheduling a successor", function()
            animation:start("generating")
            assert.equal(1, #scheduled)

            local stale_frame = scheduled[1]

            -- `stop` inside `start` cannot un-queue an already-fired timer, so
            -- this callback still runs. Without the epoch it passes the `_state`
            -- check and starts a second chain at double the frame rate.
            animation:start("generating")
            assert.equal(2, #scheduled)

            stale_frame()

            assert.equal(2, #scheduled)
        end)

        it("leaves exactly one live chain after two starts", function()
            animation:start("generating")
            animation:start("thinking")

            local stale_frame = scheduled[1]
            local live_frame = scheduled[2]

            stale_frame()
            assert.equal(2, #scheduled)

            live_frame()
            assert.equal(3, #scheduled)
        end)

        it("stops rescheduling once stopped", function()
            animation:start("generating")
            local frame = scheduled[1]

            animation:stop()
            frame()

            assert.equal(1, #scheduled)
        end)

        it("bails without scheduling for an invalid buffer", function()
            vim.api.nvim_buf_delete(bufnr, { force = true })

            animation:start("generating")

            assert.equal(0, #scheduled)
        end)
    end)

    describe("rendering", function()
        it("renders an extmark on start", function()
            animation:start("generating")

            assert.equal(1, #extmarks())
        end)

        it("clears the extmark and the state on stop", function()
            animation:start("generating")
            assert.equal(1, #extmarks())

            animation:stop()

            assert.equal(0, #extmarks())
            assert.is_nil(animation._state)
        end)

        it(
            "renders for a buffer whose only window is in another tab",
            function()
                vim.cmd("tabnew")
                vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
                vim.cmd("tabprevious")

                animation:start("generating")

                local chunks = animation_chunks()
                assert.is_not_nil(chunks)
                ---@cast chunks table
                -- Padding + spinner text: window measured despite living in
                -- another tabpage.
                assert.equal(2, #chunks)
            end
        )

        it("renders without padding when no window shows the buffer", function()
            animation:start("generating")

            local chunks = animation_chunks()
            assert.is_not_nil(chunks)
            ---@cast chunks table
            assert.equal(1, #chunks)
            assert.is_true(chunks[1][1]:find("generating") ~= nil)
        end)

        it("ignores a hidden float when measuring padding", function()
            track_win(vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                row = 1,
                col = 1,
                width = 40,
                height = 3,
                focusable = false,
                hide = true,
            }))

            animation:start("generating")

            local chunks = animation_chunks()
            assert.is_not_nil(chunks)
            ---@cast chunks table
            assert.equal(1, #chunks)
        end)
    end)

    describe("viewport", function()
        local child = Child:new()

        before_each(function()
            child.setup()
            child.api.nvim_ui_attach(60, 20, { rgb = true })
            child.lua([[
                vim.o.laststatus = 0
                vim.wo[0][0].scrolloff = 4
                local lines = {}
                for i = 1, 100 do
                    lines[i] = "history " .. i
                end
                vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
                animation = require("agentic.ui.status_animation"):new(
                    vim.api.nvim_get_current_buf()
                )

                function hint_visible(state)
                    vim.cmd("redraw!")
                    for row = 1, vim.o.lines - 1 do
                        local text = ""
                        for col = 1, vim.o.columns do
                            text = text .. vim.fn.screenstring(row, col)
                        end
                        if text:find(state, 1, true) then
                            return true
                        end
                    end
                    return false
                end
            ]])
        end)

        after_each(function()
            child.stop()
        end)

        for _, case in ipairs({
            { state = "thinking", last_line = "history 100" },
            { state = "generating", last_line = "history 100" },
            {
                state = "generating",
                last_line = string.rep("streamed output ", 12),
                suffix = " with wrapped output",
            },
        }) do
            local state = case.state
            it(
                "reveals "
                    .. state
                    .. " after scrolling back to the bottom"
                    .. (case.suffix or ""),
                function()
                    child.lua(
                        [[
                    local state, last_line = ...
                    vim.api.nvim_buf_set_lines(0, -2, -1, false, { last_line })
                    animation:start(state)
                    vim.cmd("normal! G0zb")
                ]],
                        { state, case.last_line }
                    )
                    assert.is_true(
                        child.lua_get("hint_visible(...)", { state })
                    )

                    child.cmd("normal! gg")
                    local reading_view = child.fn.winsaveview()
                    child.lua("animation:_render_frame(animation._epoch)")
                    assert.equal(reading_view, child.fn.winsaveview())
                    assert.is_false(
                        child.lua_get("hint_visible(...)", { state })
                    )

                    child.cmd("normal! G")
                    child.lua("animation:_render_frame(animation._epoch)")
                    assert.is_true(
                        child.lua_get("hint_visible(...)", { state })
                    )
                    assert.equal(100, child.fn.line("."))
                    assert.equal(case.last_line, child.fn.getline("$"))

                    local bottom_view = child.fn.winsaveview()
                    child.lua("animation:_render_frame(animation._epoch)")
                    assert.equal(bottom_view, child.fn.winsaveview())
                end
            )
        end

        it(
            "reveals a background hint without changing the active window",
            function()
                child.lua([[
                animation:start("generating")
                vim.cmd("normal! G0zb")
                vim.cmd("normal! gg")
                vim.cmd("normal! G")
                vim.cmd("tabnew")
            ]])
                local current_win = child.api.nvim_get_current_win()
                local current_tab = child.api.nvim_get_current_tabpage()

                child.lua("animation:_render_frame(animation._epoch)")

                assert.equal(current_win, child.api.nvim_get_current_win())
                assert.equal(current_tab, child.api.nvim_get_current_tabpage())
                child.cmd("tabprevious")
                assert.is_true(child.lua_get([[hint_visible("generating")]]))
            end
        )
    end)
end)
