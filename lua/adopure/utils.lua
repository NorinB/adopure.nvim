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

--- Create pull_request_thread descriptive line
--- @param pull_request_thread adopure.Thread
--- @return string
function M.pull_request_thread_title(pull_request_thread)
    return table.concat({
        "[",
        pull_request_thread.id,
        " - ",
        pull_request_thread.status,
        "] ",
        pull_request_thread.comments[1].content,
    })
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
