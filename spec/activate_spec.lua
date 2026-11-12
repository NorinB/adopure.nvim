local assert = require("luassert.assert")

describe("activate pull request context", function()
    local config = require("adopure.config.internal")
    local git = require("adopure.git")
    local viewer = require("adopure.viewer")
    local real = {
        system = vim.system,
        input = vim.ui.input,
        notify = vim.notify,
        get_merge_base = git.get_merge_base,
        available_viewer = viewer.available_viewer,
        open = viewer.open,
    }
    local source_commit = "1111111111111111111111111111111111111111"
    local prompts, notifications, opened, opened_with

    ---@param head_commit string
    ---@param head_branch string
    ---@param rev_list table|nil
    local function mock_head(head_commit, head_branch, rev_list)
        vim.system = function(command) ---@diagnostic disable-line: duplicate-set-field
            local result = { code = 128, stdout = "" }
            if command[2] == "rev-list" then
                result = rev_list or result
            elseif command[3] == "HEAD" then
                result = { code = 0, stdout = head_commit .. "\n" .. head_branch .. "\n" }
            end
            return {
                wait = function()
                    return result
                end,
            }
        end
    end

    local function fake_state()
        return {
            root_path = "/repository",
            pull_request_threads = {},
            active_pull_request = {
                sourceRefName = "refs/heads/feature/overview",
                lastMergeSourceCommit = { commitId = source_commit },
                lastMergeTargetCommit = { commitId = "2222222222222222222222222222222222222222" },
            },
        }
    end

    local function activate()
        local state = fake_state()
        require("adopure.activate").activate_pull_request_context(state)
        vim.wait(50)
        return state
    end

    before_each(function()
        prompts, notifications, opened = {}, {}, 0
        vim.ui.input = function(opts, _) ---@diagnostic disable-line: duplicate-set-field
            table.insert(prompts, opts.prompt)
        end
        vim.notify = function(message) ---@diagnostic disable-line: duplicate-set-field
            table.insert(notifications, message)
        end
        git.get_merge_base = function()
            return "merge-base"
        end
        viewer.available_viewer = function()
            return "diffbandit"
        end
        viewer.open = function(merge_base, root_path)
            opened = opened + 1
            opened_with = { merge_base, root_path }
            return { viewer = "diffbandit", handle = {}, tabpage = vim.api.nvim_get_current_tabpage() }, nil
        end
    end)

    after_each(function()
        config.open_viewer = "ask"
        vim.system, vim.ui.input, vim.notify = real.system, real.input, real.notify
        git.get_merge_base, viewer.available_viewer, viewer.open = real.get_merge_base, real.available_viewer, real.open
        require("adopure.activate").disabled_buffer_marker_autocmd()
    end)

    it("asks to checkout when on another branch", function()
        mock_head("3333333333333333333333333333333333333333", "master")
        activate()
        assert.are.same({ "Try to checkout pull request source branch? <CR> / <ESC>" }, prompts)
    end)

    it("skips the checkout question when the source commit is checked out", function()
        mock_head(source_commit, "HEAD")
        activate()
        assert.are.same({ "Open in diffbandit? <CR> / <ESC>" }, prompts)
        assert.are.same({}, notifications)
    end)

    local other_commit = "3333333333333333333333333333333333333333"
    for _, case in ipairs({
        { name = "behind", rev_list = { code = 0, stdout = "0\t2\n" }, message = "is 2 commits behind" },
        { name = "ahead", rev_list = { code = 0, stdout = "1\t0\n" }, message = "is 1 commit ahead of" },
        { name = "diverged", rev_list = { code = 0, stdout = "1\t2\n" }, message = "(1 ahead, 2 behind)" },
        { name = "not fetched", rev_list = nil, message = "is not available locally" },
    }) do
        it("skips the checkout question on the source branch and warns when " .. case.name, function()
            mock_head(other_commit, "feature/overview", case.rev_list)
            activate()
            assert.are.same({ "Open in diffbandit? <CR> / <ESC>" }, prompts)
            assert.are.same(1, #notifications)
            assert.is_truthy(notifications[1]:find(case.message, 1, true))
            assert.is_truthy(notifications[1]:find("the pull request head 11111111", 1, true))
        end)
    end

    it("opens the viewer without asking when open_viewer is always", function()
        config.open_viewer = "always"
        mock_head(source_commit, "HEAD")
        local state = activate()
        assert.are.same({}, prompts)
        assert.are.same(1, opened)
        assert.are.same({ "merge-base", "/repository" }, opened_with)
        assert.are.same("diffbandit", state.review.viewer)
    end)

    it("returns to the open review instead of opening a second one", function()
        config.open_viewer = "always"
        mock_head(source_commit, "HEAD")
        local state = activate()
        local review_tabpage = state.review.tabpage
        vim.cmd("tabnew")
        require("adopure.activate").activate_pull_request_context(state)
        vim.wait(50)
        assert.are.same(1, opened)
        assert.are.same(review_tabpage, vim.api.nvim_get_current_tabpage())
        vim.cmd("tabonly")
    end)

    it("never opens the viewer when open_viewer is never", function()
        config.open_viewer = "never"
        mock_head(source_commit, "HEAD")
        local state = activate()
        assert.are.same({}, prompts)
        assert.are.same(0, opened)
        assert.is_nil(state.review)
    end)
end)
