local assert = require("luassert.assert")

describe("thread window", function()
    local config = require("adopure.config.internal")
    local render = require("adopure.render")
    local thread = {
        id = 7,
        status = "active",
        comments = {
            { id = 1, content = "First comment", isDeleted = false, author = { displayName = "Author" } },
        },
    }

    local function is_floating()
        return vim.api.nvim_win_get_config(0).relative ~= ""
    end

    after_each(function()
        config.thread_window = "split"
        vim.cmd("stopinsert")
        vim.cmd("silent! only")
        vim.cmd("silent! %bwipeout!")
    end)

    it("opens as a split by default", function()
        render.render_new_thread({ "selected code" })
        assert.is_false(is_floating())
        assert.are.same(2, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it("opens floating when configured", function()
        config.thread_window = "float"
        local bufnr = render.render_reply_thread(thread)
        assert.is_true(is_floating())
        assert.are.same(bufnr, vim.api.nvim_get_current_buf())
        assert.are.same("nofile", vim.bo[bufnr].buftype)
        assert.is_true(vim.api.nvim_win_get_height(0) >= 6)
    end)

    it("converts a floating new thread window in place", function()
        config.thread_window = "float"
        render.render_new_thread({ "selected code" })
        local window = vim.api.nvim_get_current_win()
        render.render_reply_thread(thread)
        assert.are.same(window, vim.api.nvim_get_current_win())
        assert.is_true(is_floating())
        assert.is_truthy(vim.api.nvim_buf_get_name(0):find("[adopure - thread - 7]", 1, true))
    end)

    it("reopens a closed floating thread", function()
        config.thread_window = "float"
        local bufnr = render.render_reply_thread(thread)
        vim.cmd("close")
        assert.are.same(bufnr, (render.render_reply_thread(thread)))
        assert.is_true(is_floating())
    end)
end)
