local M = {}
local buffer_counter = 0

local namespace = vim.api.nvim_create_namespace("adopure-render")
local FLOAT_MIN_INPUT_LINES = 5

---@param height number
---@return vim.api.keyset.win_config
local function float_geometry(height)
    local border_size = 2
    local max_width = math.max(vim.o.columns - border_size - 2, 1)
    local max_height = math.max(math.floor(vim.o.lines * 0.8), 1)
    local width = math.min(math.max(math.floor(vim.o.columns * 0.6), 80), max_width)
    height = math.min(math.max(height, 1), max_height)
    return {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(math.floor((vim.o.lines - height - border_size) / 2), 0),
        col = math.max(math.floor((vim.o.columns - width - border_size) / 2), 0),
    }
end

local function rightsize_window()
    local extmarks = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, { details = true })
    local line_count = 0
    for _, extmark in pairs(extmarks) do
        local details = extmark[4]
        if details["virt_lines"] then
            line_count = line_count + #details["virt_lines"]
        end
    end

    if vim.api.nvim_win_get_config(0).relative ~= "" then
        local input_line_count = math.max(vim.api.nvim_buf_line_count(0), FLOAT_MIN_INPUT_LINES)
        vim.api.nvim_win_set_config(0, float_geometry(line_count + input_line_count))
    elseif vim.api.nvim_win_get_height(0) < line_count + 2 then
        vim.cmd("horizontal resize " .. line_count + 2)
    end
    vim.fn.winrestview({ topfill = line_count })
end

---@param bufname string
local function open_float(bufname)
    local bufnr = vim.fn.bufadd(bufname)
    vim.bo[bufnr].buflisted = true
    local win_config = float_geometry(FLOAT_MIN_INPUT_LINES)
    win_config.style = "minimal"
    if vim.fn.exists("+winborder") == 0 or vim.o.winborder == "" then
        win_config.border = "rounded"
    end
    vim.api.nvim_open_win(bufnr, true, win_config)
end

---Open thread window as configured: a split below, or a floating window
---@param bufname string
---@return number bufnr
local function open_new_window(bufname)
    if require("adopure.config.internal").thread_window == "float" then
        open_float(bufname)
    else
        vim.cmd("below new " .. bufname)
    end
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = 0 })
    buffer_counter = buffer_counter + 1
    vim.cmd(":setlocal wrap")

    vim.api.nvim_create_autocmd({ "BufEnter" }, {
        buffer = 0,
        callback = function()
            rightsize_window()
        end,
    })

    return vim.api.nvim_get_current_buf()
end

local function split_long_lines(line)
    local t = {}
    local width = vim.fn.winwidth(0) * 0.9
    for i = 1, #line, width do
        table.insert(t, string.sub(line, i, i + width - 1))
    end
    return t
end

---@param lines table<string, string>[][]
---@param prompt_type string
local function add_prompt_lines(lines, prompt_type)
    for _, prompt in pairs({

        { { "", "@text.literal" } },
        { { "________________", "@text.literal" } },
        { { "Write a " .. prompt_type .. ":", "@text.emphasis" } },
        { { "----------------", "@text.literal" } },
    }) do
        table.insert(lines, prompt)
    end
    return lines
end

---@param new_bufname string
---@return number bufnr
local function convert_ado_window(new_bufname)
    local bufnr = vim.api.nvim_get_current_buf()
    for _, extmark in pairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})) do
        local extmark_id = extmark[1]
        vim.api.nvim_buf_del_extmark(bufnr, namespace, extmark_id)
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, {})

    vim.api.nvim_buf_set_name(0, new_bufname)
    return bufnr
end

---@param new_bufname string
---@return number bufnr
local function new_or_convert_window(new_bufname)
    local bufparts = vim.split(vim.api.nvim_buf_get_name(0), "/")
    local bufname = bufparts[#bufparts]
    if bufname:find("%[adopure %- new %-") or bufname == new_bufname then
        return convert_ado_window(new_bufname)
    end
    return open_new_window(new_bufname)
end

M.icons = {
    active = " ",
    byDesign = " ",
    closed = " ",
    fixed = " ",
    pending = " ",
    unknown = " ",
    wontFix = "󰅜 ",
}

---Render pull request thread
---@param pull_request_thread adopure.Thread
---@return number, number: bufnr, mark_id
function M.render_reply_thread(pull_request_thread)
    local bufnr = new_or_convert_window("[adopure - thread - " .. pull_request_thread.id .. "]")
    local lines = {
        { { "Comment thread: ", "@text.strong" }, { tostring(pull_request_thread.id), "@text.reference" } },
        {
            { "Status: ", "@text.strong" },
            {
                M.icons[pull_request_thread.status]
                    .. " - ["
                    .. require("adopure.utils").thread_status_display(pull_request_thread.status)
                    .. "]",
                "@text.reference",
            },
        },
        { { "", "@text.literal" } },
        { { "Comments: ", "@text.strong" } },
    }

    for _, comment in ipairs(pull_request_thread.comments) do
        if not comment.isDeleted then
            table.insert(lines, { { comment.author.displayName, "@text.reference" } })

            for _, split_code_blocks in pairs(vim.split(comment.content, string.char(10))) do
                for _, line in pairs(split_long_lines(split_code_blocks)) do
                    table.insert(lines, { { line, "@text.literal" } })
                end
            end
        end
    end
    lines = add_prompt_lines(lines, "reply")

    local mark_id = vim.api.nvim_buf_set_extmark(0, namespace, 0, 0, {
        id = pull_request_thread.id,
        virt_lines = lines,
        virt_lines_above = true,
    })
    rightsize_window()
    return bufnr, mark_id
end

---Render new pull request thread
---@param selection string[]
---@return number, number: bufnr, mark_id
function M.render_new_thread(selection)
    local bufnr = open_new_window("[adopure - new - " .. buffer_counter .. "]")
    local lines = {
        { { "Comment thread: ", "@text.strong" }, { "<new>", "@text.reference" } },
        { { "Status: ", "@text.strong" }, { "<new>", "@text.reference" } },
        { { "Selection:", "@text.strong" } },
    }
    for _, selection_line in pairs(selection) do
        table.insert(lines, { { selection_line, "@text.literal" } })
    end
    lines = add_prompt_lines(lines, "comment")

    local mark_id = vim.api.nvim_buf_set_extmark(0, namespace, 0, 0, {
        virt_lines = lines,
        virt_lines_above = true,
    })
    rightsize_window()
    vim.cmd(":startinsert")
    return bufnr, mark_id
end

return M
