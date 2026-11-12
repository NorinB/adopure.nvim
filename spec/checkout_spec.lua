local assert = require("luassert.assert")

describe("checkout", function()
    local config = require("adopure.config.internal")
    local git = require("adopure.git")
    local real = {
        system = vim.system,
        select = vim.ui.select,
        input = vim.ui.input,
        notify = vim.notify,
        is_checked_out = git.is_checked_out,
        get_remote_name = git.get_remote_name,
    }
    local pull_request = {
        pullRequestId = 42,
        sourceRefName = "refs/heads/feature/x",
        targetRefName = "refs/heads/master",
        lastMergeSourceCommit = { commitId = "1111111111111111111111111111111111111111" },
    }
    local commands, exit_result, select_items, select_choice, prompts, notifications, hooks, opened

    local function checkout()
        require("adopure.checkout").checkout_and_open(pull_request, function()
            opened = opened + 1
        end)
        vim.wait(50)
    end

    before_each(function()
        commands, select_items, prompts, notifications, hooks, opened = {}, nil, {}, {}, {}, 0
        exit_result, select_choice = { code = 0, stdout = "", stderr = "" }, nil
        git.is_checked_out = function()
            return false
        end
        git.get_remote_name = function()
            return "origin"
        end
        vim.system = function(command, _, on_exit) ---@diagnostic disable-line: duplicate-set-field
            table.insert(commands, command)
            on_exit(exit_result)
        end
        vim.ui.select = function(items, opts, on_choice) ---@diagnostic disable-line: duplicate-set-field
            select_items = vim.tbl_map(opts.format_item, items)
            on_choice(select_choice and items[select_choice] or nil)
        end
        vim.ui.input = function(opts, _) ---@diagnostic disable-line: duplicate-set-field
            table.insert(prompts, opts.prompt)
        end
        vim.notify = function(message) ---@diagnostic disable-line: duplicate-set-field
            table.insert(notifications, message)
        end
        config.on_checkout = function(context)
            table.insert(hooks, context.method .. ":" .. context.branch)
        end
    end)

    after_each(function()
        config.checkout_methods, config.on_checkout = nil, nil
        vim.system, vim.ui.select, vim.ui.input, vim.notify = real.system, real.select, real.input, real.notify
        git.is_checked_out, git.get_remote_name = real.is_checked_out, real.get_remote_name
    end)

    it("asks before a detached checkout when no methods are configured", function()
        checkout()
        assert.are.same({ "Try to checkout pull request source branch? <CR> / <ESC>" }, prompts)
        assert.are.same({}, commands)
    end)

    it("opens right away when the pull request is checked out", function()
        config.checkout_methods = { "switch" }
        git.is_checked_out = function()
            return true
        end
        checkout()
        assert.are.same({}, commands)
        assert.are.same({}, hooks)
        assert.are.same(1, opened)
    end)

    it("uses a single method without asking and runs the hook", function()
        config.checkout_methods = { "switch" }
        checkout()
        assert.is_nil(select_items)
        assert.are.same({ { "git", "switch", "feature/x" } }, commands)
        assert.are.same({ "switch:feature/x" }, hooks)
        assert.are.same(1, opened)
    end)

    it("checks out the source commit with the detached method", function()
        config.checkout_methods = { "detached" }
        checkout()
        assert.are.same({ { "git", "checkout", "1111111111111111111111111111111111111111" } }, commands)
    end)

    it("escapes placeholders in a shell command", function()
        config.checkout_methods = {
            { name = "worktree", command = "git fetch {remote} {branch} && git worktree add ../pr-{id} {branch}" },
        }
        checkout()
        assert.are.same({
            {
                vim.o.shell,
                vim.o.shellcmdflag,
                "git fetch 'origin' 'feature/x' && git worktree add ../pr-'42' 'feature/x'",
            },
        }, commands)
        assert.are.same({ "worktree:feature/x" }, hooks)
    end)

    it("fills placeholders in a list command without a shell", function()
        config.checkout_methods = {
            { name = "custom", command = { "git", "switch", "-c", "review/{id}", "{commit}" } },
        }
        checkout()
        assert.are.same(
            { { "git", "switch", "-c", "review/42", "1111111111111111111111111111111111111111" } },
            commands
        )
    end)

    it("offers several methods and only runs the chosen command function", function()
        local evaluated = {}
        config.checkout_methods = {
            "detached",
            {
                name = "first",
                command = function()
                    table.insert(evaluated, "first")
                    return { "first" }
                end,
            },
            function(context)
                return "second",
                    function()
                        table.insert(evaluated, "second")
                        return { "second", context.target }
                    end
            end,
        }
        select_choice = 3
        checkout()
        assert.are.same({ "detached", "first", "second" }, select_items)
        assert.are.same({ "second" }, evaluated)
        assert.are.same({ { "second", "master" } }, commands)
        assert.are.same({ "second:feature/x" }, hooks)
        assert.are.same(1, opened)
    end)

    it("continues without a checkout when the method prompt is cancelled", function()
        config.checkout_methods = { "detached", "switch" }
        checkout()
        assert.are.same({}, commands)
        assert.are.same({}, hooks)
        assert.are.same(1, opened)
    end)

    it("lets a command function do the checkout itself", function()
        config.checkout_methods = {
            function()
                return {
                    name = "lua",
                    command = function() end,
                }
            end,
        }
        checkout()
        assert.are.same({}, commands)
        assert.are.same({ "lua:feature/x" }, hooks)
        assert.are.same(1, opened)
    end)

    it("reports a failed checkout and does not open", function()
        config.checkout_methods = { "switch" }
        exit_result = { code = 1, stdout = "", stderr = "fatal: invalid reference: feature/x\n" }
        checkout()
        assert.are.same({ "AdoPure: checkout with switch failed: fatal: invalid reference: feature/x" }, notifications)
        assert.are.same({}, hooks)
        assert.are.same(0, opened)
    end)

    it("never checks out with an empty list and skips unknown methods", function()
        config.checkout_methods = {}
        checkout()
        config.checkout_methods = { "nope" }
        checkout()
        assert.are.same({}, commands)
        assert.are.same({ "AdoPure: unknown checkout method: nope;" }, notifications)
        assert.are.same(2, opened)
    end)
end)
