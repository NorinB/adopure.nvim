---@mod adopure.pull_request
local M = {}

local namespace = vim.api.nvim_create_namespace("adopure-pull-request")
vim.treesitter.language.register("markdown", "adopure")
local MAX_SNIPPET_LINES = 12
local DIVIDER = "---"
local HINT = "<CR> open thread · R refresh · ]] [[ next/previous thread"

---Parameters for the pull request overview.
---@class adopure.OpenPullRequestOpts
---Supports the same filters as the thread picker:
---hide_system: Hides system threads in the timeline.
---hide_closed: Hides closed threads in the timeline.
---@field thread_filters string[]|nil

---@private
---@class adopure.PullRequestBuffer
---@field state adopure.AdoState
---@field opts adopure.OpenPullRequestOpts
---@field line_threads table<number, adopure.AdoThread>
---@field thread_lines number[]

---@private
---@class adopure.PullRequestContent
---@field lines string[]
---@field line_threads table<number, adopure.AdoThread>
---@field thread_lines number[]

---@type table<number, adopure.PullRequestBuffer>
local buffers = {}

---@type table<string, string[]|false>
local file_cache = {}

---@param value any
---@return string|nil
local function text(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

---@param value any
---@return adopure.Position|nil
local function position(value)
    if type(value) == "table" and type(value.line) == "number" then
        return value
    end
    return nil
end

---@param value string
---@return string[]
local function split_lines(value)
    return vim.split((value:gsub("\r", "")), "\n")
end

---@param iso_str any
---@return string
local function local_timestamp(iso_str)
    local year, month, day, hour, minute, second = tostring(iso_str):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not year then
        return ""
    end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    local shift = math.floor((14 - month) / 12)
    local shifted_year = year + 4800 - shift
    local shifted_month = month + 12 * shift - 3
    local julian_day = day
        + math.floor((153 * shifted_month + 2) / 5)
        + 365 * shifted_year
        + math.floor(shifted_year / 4)
        - math.floor(shifted_year / 100)
        + math.floor(shifted_year / 400)
        - 32045
    local epoch = (julian_day - 2440588) * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
    return tostring(os.date("%Y-%m-%d %H:%M", epoch))
end

---@param ref_name any
---@return string
local function branch_name(ref_name)
    return (tostring(ref_name):gsub("^refs/heads/", ""))
end

---@param thread adopure.Thread
---@return adopure.Comment[]
local function visible_comments(thread)
    return vim.iter(thread.comments or {})
        :filter(function(comment) ---@param comment adopure.Comment
            return not comment.isDeleted and text(comment.content) ~= nil
        end)
        :totable()
end

---@param comments adopure.Comment[]
---@return boolean
local function is_system_event(comments)
    return comments[1].commentType ~= "text"
end

---@param thread adopure.Thread
---@return boolean
local function is_open(thread)
    return thread.status == "active" or thread.status == "pending"
end

---@param lines string[]
---@param title string
local function add_section(lines, title)
    vim.list_extend(lines, { DIVIDER, "", "## " .. title, "" })
end

---@param lines string[]
---@param state adopure.AdoState
local function render_header(lines, state)
    local pull_request = state.active_pull_request
    local open_count, closed_count = 0, 0
    for _, thread in ipairs(state.pull_request_threads or {}) do
        local comments = visible_comments(thread)
        if #comments > 0 and not is_system_event(comments) then
            if is_open(thread) then
                open_count = open_count + 1
            else
                closed_count = closed_count + 1
            end
        end
    end

    local status = tostring(pull_request.status)
    if pull_request.isDraft == true then
        status = status .. " (draft)"
    end
    local details = { { "Status", status } }
    if text(pull_request.mergeStatus) then
        table.insert(details, { "Merge", pull_request.mergeStatus })
    end
    table.insert(details, { "Created", local_timestamp(pull_request.creationDate) })
    table.insert(details, { "Threads", string.format("%d active · %d closed", open_count, closed_count) })
    if text(state.repository.webUrl) then
        table.insert(
            details,
            { "Link", state.repository.webUrl .. "/pullrequest/" .. tostring(pull_request.pullRequestId) }
        )
    end

    table.insert(lines, "# " .. split_lines(tostring(pull_request.title))[1])
    table.insert(lines, "")
    table.insert(
        lines,
        string.format(
            "!%s · %s wants to merge `%s` into `%s`",
            tostring(pull_request.pullRequestId),
            pull_request.createdBy.displayName,
            branch_name(pull_request.sourceRefName),
            branch_name(pull_request.targetRefName)
        )
    )
    table.insert(lines, "")
    for _, detail in ipairs(details) do
        table.insert(lines, string.format("- **%s:** %s", detail[1], detail[2]))
    end
    table.insert(lines, "")
end

---@param lines string[]
---@param pull_request adopure.PullRequest
local function render_reviewers(lines, pull_request)
    local reviewers = pull_request.reviewers
    if type(reviewers) ~= "table" or vim.tbl_isempty(reviewers) then
        return
    end
    local review = require("adopure.review")
    add_section(lines, "Reviewers")
    for _, reviewer in ipairs(reviewers) do
        local vote = review.get_vote_from_value(reviewer.vote) or "no vote"
        local required = reviewer.isRequired == true and " (required)" or ""
        table.insert(
            lines,
            string.format("- %s**%s** · %s%s", review.vote_icons[vote], reviewer.displayName, vote, required)
        )
    end
    table.insert(lines, "")
end

---@param lines string[]
---@param pull_request adopure.PullRequest
local function render_description(lines, pull_request)
    add_section(lines, "Description")
    local description = text(pull_request.description)
    if not description then
        table.insert(lines, "_No description provided._")
    else
        vim.list_extend(lines, split_lines(description))
    end
    table.insert(lines, "")
end

---@param root_path string
---@param commit string
---@param path string
---@return string[]|nil
local function file_lines(root_path, commit, path)
    local key = commit .. ":" .. path
    if file_cache[key] == nil then
        local result = vim.system({ "git", "-C", root_path, "show", key }, { text = true }):wait()
        file_cache[key] = result.code == 0 and split_lines(result.stdout or "") or false
    end
    return file_cache[key] or nil
end

---@param state adopure.AdoState
---@param context adopure.ThreadContext
---@return string[]
local function snippet(state, context)
    local commit_key = "sourceRefCommit"
    local start_position, end_position = position(context.rightFileStart), position(context.rightFileEnd)
    if not start_position then
        commit_key = "commonRefCommit"
        start_position, end_position = position(context.leftFileStart), position(context.leftFileEnd)
    end
    local commit = vim.tbl_get(state.active_pull_request_iteration or {}, commit_key, "commitId")
    if not start_position or not text(commit) then
        return {}
    end

    local path = context.filePath:sub(2)
    local source = file_lines(state.root_path, commit, path)
    local first = start_position.line
    local last = math.max(first, (end_position or start_position).line)
    if not source or first < 1 or last > #source then
        return {}
    end

    local selected = vim.list_slice(source, first, math.min(last, first + MAX_SNIPPET_LINES - 1))
    local longest_backtick_run = 2
    for run in table.concat(selected, "\n"):gmatch("`+") do
        longest_backtick_run = math.max(longest_backtick_run, #run)
    end
    local fence = string.rep("`", longest_backtick_run + 1)

    local lines = { fence .. (vim.filetype.match({ filename = path }) or "") }
    vim.list_extend(lines, selected)
    table.insert(lines, fence)
    local hidden = last - first + 1 - #selected
    if hidden > 0 then
        table.insert(lines, string.format("_… %d more lines_", hidden))
    end
    return lines
end

---@param context adopure.ThreadContext|nil
---@return string
local function thread_location(context)
    if not context then
        return "General comment"
    end
    local start_position, end_position = position(context.rightFileStart), position(context.rightFileEnd)
    local side = ""
    if not start_position then
        start_position, end_position = position(context.leftFileStart), position(context.leftFileEnd)
        side = " (base)"
    end
    local location = context.filePath:sub(2)
    if start_position then
        location = location .. ":" .. start_position.line
        if end_position and end_position.line > start_position.line then
            location = location .. "-" .. end_position.line
        end
    end
    return location .. side
end

---@param content adopure.PullRequestContent
---@param state adopure.AdoState
---@param thread adopure.AdoThread
---@param comments adopure.Comment[]
local function render_thread(content, state, thread, comments)
    local lines = content.lines
    local context = thread:thread_context()
    local first_line = #lines + 1
    table.insert(content.thread_lines, first_line)
    table.insert(
        lines,
        string.format(
            "### %s%s · %s",
            require("adopure.render").icons[thread.status] or "",
            thread_location(context),
            require("adopure.utils").thread_status_display(thread.status)
        )
    )
    local code = context and snippet(state, context) or {}
    if #code > 0 then
        table.insert(lines, "")
        vim.list_extend(lines, code)
    end
    for _, comment in ipairs(comments) do
        local edited = ""
        if text(comment.lastContentUpdatedDate) and comment.lastContentUpdatedDate ~= comment.publishedDate then
            edited = " (edited)"
        end
        table.insert(lines, "")
        table.insert(
            lines,
            string.format(
                "> **%s** · %s%s",
                comment.author.displayName,
                local_timestamp(comment.publishedDate),
                edited
            )
        )
        for _, line in ipairs(split_lines(comment.content)) do
            table.insert(lines, line == "" and ">" or "> " .. line)
        end
    end
    for line = first_line, #lines do
        content.line_threads[line] = thread
    end
end

---@param lines string[]
---@param comments adopure.Comment[]
local function render_events(lines, comments)
    for _, comment in ipairs(comments) do
        local event = { local_timestamp(comment.publishedDate) }
        local author = comment.author.displayName
        if not comment.content:find(author, 1, true) then
            table.insert(event, author)
        end
        table.insert(event, (comment.content:gsub("%s+", " ")))
        table.insert(lines, "- " .. table.concat(event, " · "))
    end
end

---@param content adopure.PullRequestContent
---@param state adopure.AdoState
---@param opts adopure.OpenPullRequestOpts
local function render_timeline(content, state, opts)
    local lines = content.lines
    local threads = require("adopure.utils").filter_threads(state.pull_request_threads or {}, opts.thread_filters)
    threads = vim.list_slice(threads)
    table.sort(threads, function(left, right)
        return tostring(left.publishedDate) < tostring(right.publishedDate)
    end)

    add_section(lines, "Timeline")
    local previous_was_event
    for _, thread in ipairs(threads) do
        local comments = visible_comments(thread)
        if #comments > 0 then
            local is_event = is_system_event(comments)
            if previous_was_event ~= nil and not (is_event and previous_was_event) then
                vim.list_extend(lines, { "", DIVIDER, "" })
            end
            if is_event then
                render_events(lines, comments)
            else
                render_thread(content, state, thread, comments)
            end
            previous_was_event = is_event
        end
    end
    if previous_was_event == nil then
        table.insert(lines, "_No threads._")
    end
end

---@param state adopure.AdoState
---@param opts adopure.OpenPullRequestOpts
---@return adopure.PullRequestContent
local function build_content(state, opts)
    ---@type adopure.PullRequestContent
    local content = { lines = {}, line_threads = {}, thread_lines = {} }
    render_header(content.lines, state)
    render_reviewers(content.lines, state.active_pull_request)
    render_description(content.lines, state.active_pull_request)
    render_timeline(content, state, opts)
    return content
end

---@param state adopure.AdoState
---@return string
local function buffer_name(state)
    return table.concat({
        "adopure://",
        state.repository.name,
        "/pullrequest/",
        tostring(state.active_pull_request.pullRequestId),
    })
end

---Rebind the buffer when its pull request has been loaded again into a new state.
---@param bufnr number
---@param buffer adopure.PullRequestBuffer
local function follow_loaded_state(bufnr, buffer)
    local ok, state = pcall(require("adopure").get_loaded_state)
    if ok and state ~= buffer.state and buffer_name(state) == vim.api.nvim_buf_get_name(bufnr) then
        buffer.state = state
    end
end

---@param bufnr number
local function render(bufnr)
    local buffer = buffers[bufnr]
    if not buffer then
        return
    end
    follow_loaded_state(bufnr, buffer)
    local content = build_content(buffer.state, buffer.opts)
    buffer.line_threads = content.line_threads
    buffer.thread_lines = content.thread_lines
    if not vim.deep_equal(content.lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) then
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content.lines)
        vim.bo[bufnr].modifiable = false
    end
    vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
        id = 1,
        virt_text = { { HINT, "Comment" } },
        virt_text_pos = "right_align",
    })
end

---@param bufnr number
---@return adopure.PullRequestBuffer|nil
local function loaded_buffer(bufnr)
    local buffer = buffers[bufnr]
    if buffer then
        follow_loaded_state(bufnr, buffer)
    end
    local ok, state = pcall(require("adopure").get_loaded_state)
    if not buffer or not ok or state ~= buffer.state then
        vim.notify(
            "AdoPure: this pull request is no longer loaded; run AdoPure load context;",
            vim.log.levels.WARN
        )
        return nil
    end
    return buffer
end

---@param state adopure.AdoState
---@param thread adopure.AdoThread
local function jump_to_thread(state, thread)
    local context = thread:thread_context()
    if context then
        local file_path = vim.fs.joinpath(state.root_path, context.filePath:sub(2))
        if vim.fn.filereadable(file_path) == 1 then
            vim.cmd.edit(vim.fn.fnameescape(file_path))
            local start_position = position(context.rightFileStart)
            if start_position then
                pcall(vim.api.nvim_win_set_cursor, 0, { start_position.line, math.max(start_position.offset - 1, 0) })
            end
        else
            vim.notify("AdoPure: no such file: " .. file_path, vim.log.levels.WARN)
        end
    end
    require("adopure.thread").open_thread_window(state, { thread_id = thread.id })
end

---@param bufnr number
local function open_thread_at_cursor(bufnr)
    local buffer = loaded_buffer(bufnr)
    if not buffer then
        return
    end
    local thread = buffer.line_threads[vim.api.nvim_win_get_cursor(0)[1]]
    if not thread then
        vim.notify("AdoPure: no comment thread under cursor;", vim.log.levels.WARN)
        return
    end
    jump_to_thread(buffer.state, thread)
end

---@param bufnr number
---@param direction number
local function goto_thread(bufnr, direction)
    local buffer = buffers[bufnr]
    if not buffer then
        return
    end
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local thread_lines = vim.iter(buffer.thread_lines)
    local target
    if direction > 0 then
        target = thread_lines:find(function(line)
            return line > cursor_line
        end)
    else
        target = thread_lines:rev():find(function(line)
            return line < cursor_line
        end)
    end
    if target then
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
end

---@param bufnr number
local function refresh(bufnr)
    local buffer = loaded_buffer(bufnr)
    if not buffer then
        return
    end
    local state = buffer.state
    local pull_request, err = require("adopure.api").get_pull_request(state.active_pull_request)
    if err or not pull_request then
        vim.notify("AdoPure: " .. (err or "failed to retrieve pull request;"), vim.log.levels.ERROR)
        return
    end
    for key, value in pairs(pull_request) do
        state.active_pull_request[key] = value
    end
    local ok, load_err = pcall(state.load_pull_request_threads, state, {})
    if not ok then
        vim.notify("AdoPure: " .. tostring(load_err), vim.log.levels.ERROR)
        return
    end
    file_cache = {}
    render(bufnr)
end

---@param name string
---@return number|nil
local function find_buffer(name)
    return vim.iter(vim.api.nvim_list_bufs()):find(function(bufnr)
        return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name
    end)
end

---@param name string
---@return number bufnr
local function create_buffer(name)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.bo[bufnr].buftype = "nowrite"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.bo[bufnr].filetype = "adopure"
    vim.bo[bufnr].modifiable = false
    pcall(vim.treesitter.start, bufnr, "markdown")

    local function map(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = "AdoPure: " .. desc })
    end
    map("<CR>", function()
        open_thread_at_cursor(bufnr)
    end, "open comment thread under cursor")
    map("R", function()
        refresh(bufnr)
    end, "refresh pull request from Azure DevOps")
    map("]]", function()
        goto_thread(bufnr, 1)
    end, "next comment thread")
    map("[[", function()
        goto_thread(bufnr, -1)
    end, "previous comment thread")

    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = bufnr,
        callback = function()
            render(bufnr)
        end,
    })
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            vim.api.nvim_set_option_value("wrap", true, { scope = "local", win = 0 })
            vim.api.nvim_set_option_value("linebreak", true, { scope = "local", win = 0 })
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        callback = function()
            buffers[bufnr] = nil
        end,
    })
    return bufnr
end

---Open the active pull request in a read-only overview buffer.
---Shows title, branches, status, reviewer votes, description and a timeline of all comment threads.
---The buffer follows the loaded state; it re-renders whenever it is entered.
---It has filetype adopure with the markdown parser; add that filetype to markdown plugins to style it.
---Buffer keymaps:
---     <CR>: Jump to the code of the comment thread under the cursor and open its thread window.
---     R: Fetch pull request and comment threads from Azure DevOps again.
---     ]] and [[: Jump to the next or previous comment thread.
---@param state adopure.AdoState
---@param opts adopure.OpenPullRequestOpts
---@return number bufnr
function M.open(state, opts)
    local name = buffer_name(state)
    local bufnr = find_buffer(name) or create_buffer(name)
    buffers[bufnr] = { state = state, opts = opts or {}, line_threads = {}, thread_lines = {} }
    render(bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    return bufnr
end

return M
