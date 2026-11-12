local M = {}

---@private
---@class adopure.ReviewView
---@field viewer string
---@field handle any
---@field tabpage number

---@private
---@class adopure.Viewer
---@field module string
---@field open fun(merge_base: string, root_path: string|nil): any|nil, number|nil, string|nil
---@field close fun(review: adopure.ReviewView)
---@field left_file_path fun(bufnr: number): string|nil

---@type table<string, adopure.Viewer>
local viewers = {
    diffview = {
        module = "diffview",
        open = function(merge_base, root_path)
            local in_root = root_path and (" -C" .. vim.fn.fnameescape(root_path)) or ""
            vim.cmd(":DiffviewOpen " .. merge_base .. in_root)
            local view = require("diffview.lib").get_current_view()
            if not view then
                return nil, nil, "Failed to open diffview;"
            end
            return view, view.tabpage, nil
        end,
        close = function(review)
            local lib = require("diffview.lib")
            review.handle:close()
            lib.dispose_view(review.handle)
        end,
        left_file_path = function(bufnr)
            local file_path = vim.api.nvim_buf_get_name(bufnr)
            if not file_path:match("^diffview://") then
                return nil
            end
            local left_path = file_path:gsub("^diffview://.+/.git/[^/]+(.*)$", "%1")
            return left_path
        end,
    },
    diffbandit = {
        module = "diffbandit",
        open = function(merge_base, root_path)
            local session, err = require("diffbandit").git_panel({
                mode = "all",
                base = merge_base,
                root = root_path,
                include_untracked = false,
                read_only = true,
            })
            if not session then
                return nil, nil, tostring(err or "Failed to open diffbandit;")
            end
            return session, session.tabpage or vim.api.nvim_get_current_tabpage(), nil
        end,
        close = function(review)
            local session = require("diffbandit.state").sessions[review.tabpage]
            if session then
                session:close()
            end
        end,
        left_file_path = function(bufnr)
            local diffbandit_state = package.loaded["diffbandit.state"]
            if not diffbandit_state then
                return nil
            end
            for _, session in pairs(diffbandit_state.sessions or {}) do
                if session.left_buf == bufnr and session.left and session.left.git_relpath then
                    return "/" .. session.left.git_relpath
                end
            end
            return nil
        end,
    },
}

---@return string|nil
function M.available_viewer()
    for _, name in ipairs(require("adopure.config.internal").viewers) do
        local viewer = viewers[name]
        if viewer and pcall(require, viewer.module) then
            return name
        end
    end
    return nil
end

---Open the diff against merge_base in the repository at root_path.
---The root is passed on explicitly, since viewers otherwise look for the repository at the current buffer.
---@param merge_base string
---@param root_path string|nil
---@return adopure.ReviewView|nil review, string|nil err
function M.open(merge_base, root_path)
    local name = M.available_viewer()
    if not name then
        return nil, "No diff viewer available; install diffview.nvim or diffbandit.nvim;"
    end
    local handle, tabpage, err = viewers[name].open(merge_base, root_path)
    if err or not handle or not tabpage then
        return nil, err or ("Failed to open " .. name .. ";")
    end
    return { viewer = name, handle = handle, tabpage = tabpage }, nil
end

---@param review adopure.ReviewView
function M.close(review)
    local ok, err = pcall(viewers[review.viewer].close, review)
    if not ok then
        vim.notify("AdoPure: failed to close " .. review.viewer .. ": " .. tostring(err), vim.log.levels.WARN)
    end
end

---@param review adopure.ReviewView|nil
---@param view any diffview view, tabpage number or nil for the current tabpage.
---@return boolean
function M.is_review(review, view)
    if not review or not vim.api.nvim_tabpage_is_valid(review.tabpage) then
        return false
    end
    if view == nil then
        return review.tabpage == vim.api.nvim_get_current_tabpage()
    end
    if type(view) == "number" then
        return review.tabpage == view
    end
    return review.handle == view
end

---Repository path, prefixed with "/", of the file shown when bufnr is the left (base) side of a viewer.
---@param bufnr number
---@return string|nil
function M.left_file_path(bufnr)
    for _, viewer in pairs(viewers) do
        local path = viewer.left_file_path(bufnr)
        if path then
            return path
        end
    end
    return nil
end

return M
