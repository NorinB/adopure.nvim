local M = {}
local AWAIT_TIMEOUT_MS = 10000
local AWAIT_INTERVAL_MS = 200
---@class adopure.JobResult
---@field stdout string[]
---@field stderr string[]

--- Await result of plenary job
---@diagnostic disable-next-line: undefined-doc-name
---@param job Job
---@return adopure.JobResult
function M.await_result(job)
    local stdout, stderr
    for _ = 1, AWAIT_TIMEOUT_MS / AWAIT_INTERVAL_MS do
        if (stdout and stdout[1]) or (stderr and stderr[1]) then
            return {
                stdout = stdout,
                stderr = stderr,
            }
        end
        vim.wait(AWAIT_INTERVAL_MS, function()
            ---@diagnostic disable-next-line: missing-return,undefined-field
            stdout = job:result()
            ---@diagnostic disable-next-line: missing-return,undefined-field
            stderr = job:stderr_result()
        end)
    end
    -- A job that writes to neither stream never satisfies the loop above; let callers
    -- report the empty result instead of blocking the editor forever.
    return {
        stdout = stdout or {},
        stderr = stderr or {},
    }
end

-- Azure DevOps names the resolved thread state "fixed" on the wire; only the label differs.
local status_display_names = {
    fixed = "resolved",
}

--- Human readable name for an Azure DevOps thread status
--- @param status string|nil
--- @return string
function M.thread_status_display(status)
    if not status then
        return ""
    end
    return status_display_names[status] or status
end

--- Create pull_request_thread descriptive line
--- @param pull_request_thread adopure.Thread
--- @return string
function M.pull_request_thread_title(pull_request_thread)
    return table.concat({
        "[",
        pull_request_thread.id,
        " - ",
        M.thread_status_display(pull_request_thread.status),
        "] ",
        pull_request_thread.comments[1].content,
    })
end

local thread_filters = {
    ---@param thread adopure.Thread
    hide_system = function(thread)
        return thread.comments[1].commentType == "text"
    end,
    ---@param thread adopure.Thread
    hide_closed = function(thread)
        return thread.status == "active" or thread.status == "pending"
    end,
}

--- Apply named thread filters; unknown filter names are reported and skipped
--- @param pull_request_threads adopure.Thread[]
--- @param filter_names string[]|nil
--- @return adopure.Thread[] pull_request_threads
function M.filter_threads(pull_request_threads, filter_names)
    if not filter_names then
        return pull_request_threads
    end
    local thread_iter = vim.iter(pull_request_threads)
    for _, filter_name in ipairs(filter_names) do
        if thread_filters[filter_name] then
            thread_iter = thread_iter:filter(thread_filters[filter_name])
        else
            vim.notify("Invalid thread filter provided: " .. filter_name, 3)
        end
    end
    return thread_iter:totable()
end

local hex_to_char = function(x)
    return string.char(tonumber(x, 16))
end

---@param input string
M.url_decode = function(input)
    if input == nil then
        return
    end
    input = input:gsub("+", " ")
    input = input:gsub("%%(%x%x)", hex_to_char)
    return input
end

return M
