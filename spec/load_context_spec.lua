local assert = require("luassert.assert")

describe("load context", function()
    local state_manager = require("adopure.types.state_manager")
    local activate = require("adopure.activate")
    local config = require("adopure.config.internal")
    local git = require("adopure.git")
    local real = {
        api = package.loaded["adopure.api"],
        picker = package.loaded["adopure.pickers.pull_request"],
        context_new = state_manager.AdoContext.new,
        set_state_by_choice = state_manager.StateManager.set_state_by_choice,
        activate_pull_request_context = activate.activate_pull_request_context,
        get_head = git.get_head,
        notify = vim.notify,
    }
    local head_commit = "1111111111111111111111111111111111111111"
    local fetch_count, picked, activated, pull_requests, load_count

    ---@param id number
    ---@param branch string
    ---@param commit string|nil
    local function pull_request(id, branch, commit)
        return {
            pullRequestId = id,
            title = "Pull request " .. id,
            status = "active",
            sourceRefName = "refs/heads/" .. branch,
            targetRefName = "refs/heads/master",
            creationDate = "2026-11-10T09:00:00Z",
            createdBy = { displayName = "Creator" },
            lastMergeSourceCommit = { commitId = commit or "2222222222222222222222222222222222222222" },
        }
    end

    ---@param fargs string[]
    local function ado_pure(fargs)
        require("adopure").ado_pure({ fargs = fargs })
    end

    before_each(function()
        fetch_count, picked, activated, load_count = 0, {}, {}, 0
        pull_requests = { pull_request(1, "feature/one"), pull_request(2, "feature/two") }
        ado_pure({ "unload" })
        vim.notify = function() end ---@diagnostic disable-line: duplicate-set-field
        package.loaded["adopure.api"] = {
            get_repository = function()
                return { name = "repo" }, nil
            end,
            get_pull_requests = function()
                fetch_count = fetch_count + 1
                return pull_requests, nil
            end,
        }
        package.loaded["adopure.pickers.pull_request"] = {
            choose = function(manager, on_choice)
                table.insert(picked, fetch_count)
                manager:set_state_by_choice(manager.pull_requests[1])
                on_choice(manager.state)
            end,
        }
        state_manager.AdoContext.new = function()
            return { root_path = "." }
        end
        state_manager.StateManager.set_state_by_choice = function(self, chosen)
            load_count = load_count + 1
            self.state = {
                root_path = ".",
                repository = self.repository,
                pull_request_threads = {},
                active_pull_request = chosen,
            }
        end
        activate.activate_pull_request_context = function(state)
            table.insert(activated, state.active_pull_request.pullRequestId)
        end
        git.get_head = function()
            return head_commit, "feature/two"
        end
    end)

    after_each(function()
        config.pull_request_from_branch = false
        package.loaded["adopure.api"] = real.api
        package.loaded["adopure.pickers.pull_request"] = real.picker
        state_manager.AdoContext.new = real.context_new
        state_manager.StateManager.set_state_by_choice = real.set_state_by_choice
        activate.activate_pull_request_context = real.activate_pull_request_context
        git.get_head = real.get_head
        ado_pure({ "unload" })
        vim.notify = real.notify
    end)

    it("fetches the pull requests again on every call", function()
        ado_pure({ "load", "context" })
        ado_pure({ "load", "context" })
        assert.are.same(2, fetch_count)
        assert.are.same({ 1, 2 }, picked)
        assert.are.same({ 1, 1 }, activated)
    end)

    it("takes the pull request of the checked out branch when configured", function()
        config.pull_request_from_branch = true
        ado_pure({ "load", "context" })
        assert.are.same({}, picked)
        assert.are.same({ 2 }, activated)
    end)

    it("takes the pull request whose source commit is checked out", function()
        config.pull_request_from_branch = true
        pull_requests = { pull_request(1, "feature/one"), pull_request(3, "feature/three", head_commit) }
        git.get_head = function()
            return head_commit, "HEAD"
        end
        ado_pure({ "load", "context" })
        assert.are.same({}, picked)
        assert.are.same({ 3 }, activated)
    end)

    it("prompts when the checked out branch has no or several pull requests", function()
        config.pull_request_from_branch = true
        git.get_head = function()
            return head_commit, "master"
        end
        ado_pure({ "load", "context" })
        pull_requests = { pull_request(2, "feature/two"), pull_request(4, "feature/two") }
        git.get_head = function()
            return head_commit, "feature/two"
        end
        ado_pure({ "load", "context" })
        assert.are.same({ 1, 2 }, picked)
    end)

    it("prompts when asked to, or when not configured", function()
        ado_pure({ "load", "context" })
        config.pull_request_from_branch = true
        ado_pure({ "load", "context", "{pick=true}" })
        assert.are.same({ 1, 2 }, picked)
    end)

    it("chooses a pull request when opening the overview without one loaded", function()
        config.pull_request_from_branch = true
        ado_pure({ "open", "pull_request" })
        assert.are.same({}, picked)
        assert.are.same({}, activated)
        assert.are.same("adopure://repo/pullrequest/2", vim.api.nvim_buf_get_name(0))
        assert.are.same("# Pull request 2", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])

        vim.cmd("enew")
        ado_pure({ "open", "pull_request" })
        assert.are.same(1, fetch_count)
        assert.are.same("adopure://repo/pullrequest/2", vim.api.nvim_buf_get_name(0))
    end)

    it("keeps the loaded pull request when the checked out branch still points at it", function()
        config.pull_request_from_branch = true
        ado_pure({ "open", "pull_request" })
        local state = require("adopure").get_loaded_state()
        ado_pure({ "load", "context" })
        assert.are.same(1, load_count)
        assert.are.equal(state, require("adopure").get_loaded_state())
        assert.are.same({ 2 }, activated)

        pull_requests = { pull_request(2, "feature/two", "3333333333333333333333333333333333333333") }
        ado_pure({ "load", "context" })
        assert.are.same(2, load_count)
        assert.are_not.equal(state, require("adopure").get_loaded_state())
    end)

    it("keeps an open overview usable after its pull request is loaded again", function()
        ado_pure({ "open", "pull_request" })
        local manager = require("adopure").load_state_manager()
        local first_state = manager.state
        local reloaded = pull_request(1, "feature/one")
        reloaded.title = "Reloaded pull request"
        manager:set_state_by_choice(reloaded)
        assert.are_not.equal(first_state, manager.state)

        vim.cmd("doautocmd BufEnter")
        assert.are.same("# Reloaded pull request", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
    end)
end)
