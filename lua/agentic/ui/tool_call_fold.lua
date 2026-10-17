local Config = require("agentic.config")

local NS_AGENT_WORK = vim.api.nvim_create_namespace("agentic_agent_work_folds")

--- @class agentic.ui.ToolCallFold
local Fold = {}

--- @class agentic.ui.ToolCallFold.ShouldFoldOpts
--- @field bufnr integer
--- @field start_row integer 0-indexed inclusive
--- @field end_row integer 0-indexed inclusive
--- @field status? agentic.acp.ToolCallStatus
--- @field is_diff boolean

--- @return integer|nil threshold nil when folding is disabled
function Fold.threshold()
    local cfg = Config.folding and Config.folding.tool_calls
    if not cfg or not cfg.enabled then
        return nil
    end
    return math.max(0, cfg.threshold or 0)
end

--- @return boolean enabled
function Fold.agent_work_enabled()
    local cfg = Config.folding and Config.folding.agent_work
    return cfg ~= nil and cfg.enabled == true
end

--- @param status agentic.acp.ToolCallStatus|nil
--- @return boolean should_fold
function Fold.should_auto_fold(status)
    if status == "completed" then
        return true
    end

    if status == "failed" then
        local cfg = Config.folding and Config.folding.tool_calls
        return cfg ~= nil and cfg.fold_on_error == true
    end

    return false
end

--- @param opts agentic.ui.ToolCallFold.ShouldFoldOpts
--- @return boolean should_fold
function Fold.should_fold(opts)
    if opts.is_diff then
        return false
    end

    if not Fold.should_auto_fold(opts.status) then
        return false
    end

    local threshold = Fold.threshold()
    if threshold == nil then
        return false
    end

    if opts.start_row > opts.end_row then
        return false
    end

    local wins = vim.fn.win_findbuf(opts.bufnr)

    if #wins == 0 then
        return false
    end

    local ok, result = pcall(vim.api.nvim_win_text_height, wins[1], {
        start_row = opts.start_row,
        end_row = opts.end_row,
    })

    if not ok or type(result) ~= "table" then
        return false
    end

    return result.all > threshold
end

--- @return string
function Fold.foldtext()
    local folded = vim.v.foldend - vim.v.foldstart + 1
    local bufnr = vim.api.nvim_get_current_buf()
    local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        NS_AGENT_WORK,
        { vim.v.foldstart - 1, 0 },
        { vim.v.foldstart - 1, -1 },
        { details = true }
    )
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details and details.end_row == vim.v.foldend then
            return string.format(
                "  %d lines of agent work folded - `zo` open | `zO` open all | `zc` close",
                folded
            )
        end
    end
    return string.format("  %d lines folded - `zo` open | `zc` close", folded)
end

local FOLDTEXT_EXPR = "v:lua.require'agentic.ui.tool_call_fold'.foldtext()"

--- @param winid integer
--- @param _bufnr integer
function Fold.setup_window(winid, _bufnr)
    if Fold.threshold() == nil and not Fold.agent_work_enabled() then
        return
    end
    if vim.wo[winid].foldmethod ~= "manual" then
        vim.wo[winid][0].foldmethod = "manual"
    end
    if vim.wo[winid].foldlevel ~= 0 then
        vim.wo[winid][0].foldlevel = 0
    end
    vim.wo[winid][0].foldenable = true
    vim.wo[winid][0].foldtext = FOLDTEXT_EXPR
end

--- @param bufnr integer
--- @param start_lnum integer 1-indexed inclusive
--- @param end_lnum integer 1-indexed inclusive
--- @return boolean closed
function Fold:_close_range(bufnr, start_lnum, end_lnum)
    if start_lnum > end_lnum then
        return false
    end
    local wins = vim.fn.win_findbuf(bufnr)
    if #wins == 0 then
        return false
    end
    vim.api.nvim_win_call(wins[1], function()
        vim.cmd(
            string.format("silent! noautocmd %d,%dfold", start_lnum, end_lnum)
        )
    end)
    return true
end

--- @param bufnr integer
--- @param start_lnum integer 1-indexed inclusive
--- @param end_lnum integer 1-indexed inclusive
function Fold.close_range(bufnr, start_lnum, end_lnum)
    if Fold.threshold() == nil then
        return
    end
    Fold:_close_range(bufnr, start_lnum, end_lnum)
end

--- @param bufnr integer
--- @param start_lnum integer 1-indexed inclusive
--- @param end_lnum integer 1-indexed inclusive
function Fold.close_agent_work_range(bufnr, start_lnum, end_lnum)
    if not Fold.agent_work_enabled() then
        return
    end
    if not Fold:_close_range(bufnr, start_lnum, end_lnum) then
        return
    end
    vim.api.nvim_buf_set_extmark(bufnr, NS_AGENT_WORK, start_lnum - 1, 0, {
        end_row = end_lnum,
        end_col = 0,
        right_gravity = false,
        end_right_gravity = false,
    })
end

return Fold
