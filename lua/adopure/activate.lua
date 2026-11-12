local M = {}

---@param state adopure.AdoState
local function open_in_viewer(state)
    local merge_base = require("adopure.git").get_merge_base(state.active_pull_request)
    local review, err = require("adopure.viewer").open(merge_base)
    if err or not review then
        vim.notify("AdoPure: " .. (err or "failed to open diff viewer;"), vim.log.levels.ERROR)
        return
    end
    state.review = review
end

---@param state adopure.AdoState
local function confirm_open_in_viewer(state)
    local open_viewer = require("adopure.config.internal").open_viewer
    if open_viewer == "never" then
        return
    end
    local name = require("adopure.viewer").available_viewer()
    if not name then
        vim.notify("AdoPure: no diff viewer available; install diffview.nvim or diffbandit.nvim;", vim.log.levels.WARN)
        return
    end
    if open_viewer == "always" then
        vim.schedule(function()
            open_in_viewer(state)
        end)
        return
    end
    vim.ui.input({ prompt = "Open in " .. name .. "? <CR> / <ESC>" }, function(input)
        if input then
            open_in_viewer(state)
        end
    end)
end

---@param state adopure.AdoState
local function buffer_marker_autocmd(state)
    local augroup = vim.api.nvim_create_augroup("adopure.nvim", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter" }, {
        group = augroup,
        callback = function(args)
            if state.pull_request_threads and args.file ~= "" then
                require("adopure.marker").clear_removed_comment_marks(args.buf, state.pull_request_threads)
                require("adopure.marker").create_new_comment_marks(args.buf, state, args.file)
            end
        end,
    })
end

function M.disabled_buffer_marker_autocmd()
    local augroup = vim.api.nvim_create_augroup("adopure.nvim", { clear = true })
    local namespace = vim.api.nvim_create_namespace("adopure-marker")
    vim.api.nvim_buf_clear_namespace(0, namespace, 0, -1)
    vim.api.nvim_create_autocmd({ "BufEnter" }, {
        group = augroup,
        callback = function(args)
            vim.api.nvim_buf_clear_namespace(args.buf, namespace, 0, -1)
        end,
    })
end

---Track the pull request in buffers without checking it out or opening the diff viewer.
---@param state adopure.AdoState
function M.enable_comment_marks(state)
    require("adopure.marker").clear_removed_comment_marks(0, state.pull_request_threads)
    buffer_marker_autocmd(state)
end

---@param state adopure.AdoState
function M.activate_pull_request_context(state)
    require("adopure.marker").clear_removed_comment_marks(0, state.pull_request_threads)
    require("adopure.checkout").checkout_and_open(state.active_pull_request, function()
        state.root_path = require("adopure.git").get_root() or state.root_path
        confirm_open_in_viewer(state)
    end)
    buffer_marker_autocmd(state)
end
return M
