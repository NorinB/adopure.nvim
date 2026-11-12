local assert = require("luassert.assert")

describe("pull request overview", function()
    local AdoThread = require("adopure.types.ado_thread").AdoThread
    local head_commit = vim.trim(vim.fn.system({ "git", "rev-parse", "HEAD" }))

    ---@param id number
    ---@param content string|nil
    ---@param comment_type string
    ---@param published string
    local function comment(id, content, comment_type, published)
        return {
            id = id,
            commentType = comment_type,
            content = content,
            author = { id = "author-" .. id, displayName = "Author " .. id },
            isDeleted = false,
            publishedDate = published,
            lastUpdatedDate = published,
            lastContentUpdatedDate = published,
        }
    end

    local function fake_state()
        return {
            root_path = vim.fn.getcwd(),
            repository = { name = "repo", webUrl = "https://dev.azure.com/org/project/_git/repo" },
            active_pull_request = {
                pullRequestId = 42,
                title = "Add the overview",
                description = "First line\r\nSecond line",
                status = "active",
                isDraft = true,
                mergeStatus = "succeeded",
                sourceRefName = "refs/heads/feature/overview",
                targetRefName = "refs/heads/master",
                creationDate = "2026-11-10T09:00:00.123Z",
                createdBy = { id = "creator", displayName = "Creator" },
                reviewers = {
                    { id = "r1", displayName = "Reviewer One", vote = 10, isRequired = true },
                    { id = "r2", displayName = "Reviewer Two", vote = 0 },
                },
            },
            active_pull_request_iteration = { id = 1, sourceRefCommit = { commitId = head_commit } },
            pull_request_threads = {
                AdoThread:new({
                    id = 3,
                    status = "fixed",
                    publishedDate = "2026-11-10T12:00:00Z",
                    threadContext = vim.NIL,
                    comments = { comment(1, "General remark", "text", "2026-11-10T12:00:00Z") },
                }),
                AdoThread:new({
                    id = 1,
                    publishedDate = "2026-11-10T10:00:00Z",
                    threadContext = vim.NIL,
                    comments = { comment(1, "Author 1 voted 10", "system", "2026-11-10T10:00:00Z") },
                }),
                AdoThread:new({
                    id = 2,
                    status = "active",
                    publishedDate = "2026-11-10T11:00:00Z",
                    threadContext = {
                        filePath = "/tests/pr-test-file.md",
                        rightFileStart = { line = 1, offset = 1 },
                        rightFileEnd = { line = 1, offset = 5 },
                    },
                    comments = {
                        comment(1, "Why this line?", "text", "2026-11-10T11:00:00Z"),
                        comment(2, "Because.", "text", "2026-11-10T11:30:00Z"),
                    },
                }),
            },
            comment_replies = {},
            comment_creations = {},
        }
    end

    ---@param lines string[]
    ---@param needle string
    ---@return number|nil
    local function line_of(lines, needle)
        for index, line in ipairs(lines) do
            if line:find(needle, 1, true) then
                return index
            end
        end
    end

    ---@param opts table
    ---@return string[] lines, number bufnr
    local function open(opts)
        local bufnr = require("adopure.pull_request").open(fake_state(), opts)
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
    end

    it("renders the pull request details", function()
        local lines, bufnr = open({})
        assert.are.same("adopure://repo/pullrequest/42", vim.api.nvim_buf_get_name(bufnr))
        assert.is_false(vim.bo[bufnr].modifiable)
        assert.are.same("adopure", vim.bo[bufnr].filetype)
        assert.are.same("nowrite", vim.bo[bufnr].buftype)
        assert.are.same("markdown", vim.treesitter.get_parser(bufnr):lang())
        assert.are.same("# Add the overview", lines[1])
        assert.are.same("!42 · Creator wants to merge `feature/overview` into `master`", lines[3])
        assert.are.same("- **Status:** active (draft)", lines[5])
        assert.are.same("- **Merge:** succeeded", lines[6])
        assert.is_truthy(lines[7]:find("- **Created:** 2026-11-", 1, true))
        assert.are.same("- **Threads:** 1 active · 1 closed", lines[8])
        assert.are.same("- **Link:** https://dev.azure.com/org/project/_git/repo/pullrequest/42", lines[9])
        assert.is_truthy(line_of(lines, "**Reviewer One** · approved (required)"))
        assert.is_truthy(line_of(lines, "**Reviewer Two** · no vote"))
        local description = line_of(lines, "## Description")
        assert.are.same({ "---", "" }, { lines[description - 2], lines[description - 1] })
        assert.are.same({ "First line", "Second line" }, { lines[description + 2], lines[description + 3] })
    end)

    it("renders threads chronologically with code context", function()
        local lines = open({})
        local event = line_of(lines, "Author 1 voted 10")
        local code_thread = line_of(lines, "tests/pr-test-file.md:1 · active")
        local general_thread = line_of(lines, "General comment · resolved")
        assert.is_truthy(event and code_thread and general_thread)
        assert.is_true(event < code_thread and code_thread < general_thread)
        assert.are.same("```markdown", lines[code_thread + 2])
        assert.are.same(vim.fn.readfile("tests/pr-test-file.md")[1], lines[code_thread + 3])
        assert.are.same("```", lines[code_thread + 4])
        assert.are.same("> Because.", lines[line_of(lines, "> **Author 2** · ") + 1])
        assert.are.same({ "", "---", "" }, vim.list_slice(lines, code_thread - 3, code_thread - 1))
        assert.are.same({ "", "---", "" }, vim.list_slice(lines, general_thread - 3, general_thread - 1))
    end)

    it("applies thread filters", function()
        local lines = open({ thread_filters = { "hide_system", "hide_closed" } })
        assert.is_nil(line_of(lines, "Author 1 voted 10"))
        assert.is_nil(line_of(lines, "General comment"))
        assert.is_truthy(line_of(lines, "tests/pr-test-file.md:1 · active"))
    end)

    it("reuses the buffer and jumps between threads", function()
        local lines, bufnr = open({})
        local _, second_bufnr = open({})
        assert.are.same(bufnr, second_bufnr)

        local code_thread = line_of(lines, "tests/pr-test-file.md:1 · active")
        local general_thread = line_of(lines, "General comment · resolved")
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.api.nvim_feedkeys("]]", "x", false)
        assert.are.same(code_thread, vim.api.nvim_win_get_cursor(0)[1])
        vim.api.nvim_feedkeys("]]", "x", false)
        assert.are.same(general_thread, vim.api.nvim_win_get_cursor(0)[1])
        vim.api.nvim_feedkeys("[[", "x", false)
        assert.are.same(code_thread, vim.api.nvim_win_get_cursor(0)[1])
    end)
end)
