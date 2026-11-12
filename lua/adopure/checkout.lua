---@mod adopure.checkout
---@brief [[
---Checking out a pull request is configured with checkout_methods and on_checkout.
---It happens when a pull request context is loaded and its source is not checked out yet.
---
---With one configured method, that method is used right away.
---With several, a prompt lets you choose one; cancelling it continues without a checkout.
---With an empty list, nothing is ever checked out.
---When checkout_methods is not set, a prompt asks whether to check out the source commit detached.
---A configured list replaces that default completely; include "detached" to keep it as a choice.
---
---A method is one of:
---     A builtin name: "detached" checks out the source commit, "switch" runs git switch on the source branch.
---     A table with a name and a command.
---     A function returning such a table, or a name and a command.
---     It is called when the methods are listed, so before one is chosen.
---
---A command is one of:
---     A string, run through the shell. Placeholders are shell escaped, so do not quote them.
---     A list of arguments, run without a shell.
---     A function returning a string, a list, or nil when it did the checkout itself.
---     It is called only once its method is chosen.
---
---Placeholders are {branch}, {target}, {commit}, {id} and {remote}.
---Functions receive the same values as an adopure.CheckoutContext.
---
---A failing checkout is reported and stops the pull request from being opened in the diff viewer.
---on_checkout runs after every successful checkout, for example to change into a new worktree.
---The repository root is read again afterwards.
--->lua
--- vim.g.adopure = {
---     checkout_methods = {
---         "switch",
---         { name = "worktree", command = "git worktree add ../{branch} {branch}" },
---     },
---     on_checkout = function(context)
---         if context.method == "worktree" then
---             vim.cmd.cd("../" .. context.branch)
---         end
---     end,
--- }
---<
---@brief ]]
local M = {}

---@class adopure.CheckoutContext
---@field pull_request adopure.PullRequest
---@field id number Pull request id.
---@field branch string Source branch, without refs/heads/.
---@field target string Target branch, without refs/heads/.
---@field commit string Source commit id.
---@field remote string|nil Name of the Azure DevOps git remote.
---@field method string|nil Name of the method used; only set for on_checkout.

---@alias adopure.CheckoutCommand string|string[]|fun(context: adopure.CheckoutContext): string|string[]|nil

---@class adopure.CheckoutMethod
---@field name string
---@field command adopure.CheckoutCommand|nil

---@type table<string, adopure.CheckoutMethod>
local builtin_methods = {
    detached = { name = "detached", command = { "git", "checkout", "{commit}" } },
    switch = { name = "switch", command = { "git", "switch", "{branch}" } },
}

---@param pull_request adopure.PullRequest
---@return adopure.CheckoutContext
local function build_context(pull_request)
    return {
        pull_request = pull_request,
        id = pull_request.pullRequestId,
        branch = (pull_request.sourceRefName:gsub("^refs/heads/", "")),
        target = (pull_request.targetRefName:gsub("^refs/heads/", "")),
        commit = pull_request.lastMergeSourceCommit.commitId,
        remote = require("adopure.git").get_remote_name(),
    }
end

---@param template string
---@param context adopure.CheckoutContext
---@param escape fun(value: string): string
---@return string
local function substitute(template, context, escape)
    return (
        template:gsub("{(%w+)}", function(key)
            local value = context[key]
            if type(value) ~= "string" and type(value) ~= "number" then
                return nil
            end
            return escape(tostring(value))
        end)
    )
end

---@param entry any
---@param context adopure.CheckoutContext
---@return adopure.CheckoutMethod|nil method, string|nil err
local function resolve_method(entry, context)
    if type(entry) == "string" then
        if not builtin_methods[entry] then
            return nil, "unknown checkout method: " .. entry .. ";"
        end
        return builtin_methods[entry], nil
    end
    if type(entry) == "function" then
        local ok, name, command = pcall(entry, context)
        if not ok then
            return nil, "checkout method failed: " .. tostring(name)
        end
        entry = type(name) == "table" and name or { name = name, command = command }
    end
    if type(entry) ~= "table" or type(entry.name) ~= "string" then
        return nil, "a checkout method needs a name;"
    end
    return entry, nil
end

---@param context adopure.CheckoutContext
---@return adopure.CheckoutMethod[]
local function resolve_methods(context)
    local entries = require("adopure.config.internal").checkout_methods
    if type(entries) ~= "table" or entries.name then
        entries = { entries }
    end
    local methods = {}
    for _, entry in ipairs(entries) do
        local method, err = resolve_method(entry, context)
        if method then
            table.insert(methods, method)
        else
            vim.notify("AdoPure: " .. err, vim.log.levels.WARN)
        end
    end
    return methods
end

---@param method adopure.CheckoutMethod
---@param context adopure.CheckoutContext
---@param on_exit fun(err: string|nil)
local function run_command(method, context, on_exit)
    local command = method.command
    if type(command) == "function" then
        local ok, result = pcall(command, context)
        if not ok then
            on_exit(tostring(result))
            return
        end
        command = result
    end
    if command == nil then
        on_exit(nil)
        return
    end

    local arguments
    if type(command) == "string" then
        arguments = { vim.o.shell, vim.o.shellcmdflag, substitute(command, context, vim.fn.shellescape) }
    else
        arguments = vim.tbl_map(function(argument)
            return substitute(tostring(argument), context, tostring)
        end, command)
    end
    local ok, err = pcall(
        vim.system,
        arguments,
        { text = true },
        vim.schedule_wrap(function(result)
            if result.code == 0 then
                on_exit(nil)
                return
            end
            local output = vim.trim(result.stderr or "")
            on_exit(output ~= "" and output or vim.trim(result.stdout or ""))
        end)
    )
    if not ok then
        on_exit(tostring(err))
    end
end

---@param method adopure.CheckoutMethod
---@param context adopure.CheckoutContext
---@param on_checked_out function
local function run_method(method, context, on_checked_out)
    run_command(method, context, function(err)
        if err then
            vim.notify("AdoPure: checkout with " .. method.name .. " failed: " .. err, vim.log.levels.ERROR)
            return
        end
        local on_checkout = require("adopure.config.internal").on_checkout
        if type(on_checkout) == "function" then
            local hook_context = vim.tbl_extend("force", context, { method = method.name })
            local ok, hook_err = pcall(on_checkout, hook_context)
            if not ok then
                vim.notify("AdoPure: on_checkout failed: " .. tostring(hook_err), vim.log.levels.ERROR)
            end
        end
        on_checked_out()
    end)
end

---Check out the pull request as configured, then call open_callable.
---Calls it right away when the pull request source is already checked out, or no checkout is wanted.
---Does not call it when the checkout fails.
---@param pull_request adopure.PullRequest
---@param open_callable function
function M.checkout_and_open(pull_request, open_callable)
    if require("adopure.git").is_checked_out(pull_request) then
        open_callable()
        return
    end
    if require("adopure.config.internal").checkout_methods == nil then
        vim.ui.input({ prompt = "Try to checkout pull request source branch? <CR> / <ESC>" }, function(input)
            if not input then
                open_callable()
                return
            end
            run_method(builtin_methods.detached, build_context(pull_request), open_callable)
        end)
        return
    end

    local context = build_context(pull_request)
    local methods = resolve_methods(context)
    if #methods <= 1 then
        if methods[1] then
            run_method(methods[1], context, open_callable)
        else
            open_callable()
        end
        return
    end
    vim.ui.select(methods, {
        prompt = "Check out pull request with:",
        format_item = function(method) ---@param method adopure.CheckoutMethod
            return method.name
        end,
    }, function(method) ---@param method adopure.CheckoutMethod|nil
        if not method then
            open_callable()
            return
        end
        run_method(method, context, open_callable)
    end)
end

return M
