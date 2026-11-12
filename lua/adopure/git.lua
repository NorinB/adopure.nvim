local M = {}

---@param remote_stdout string[]
---@return string remote
local function elect_remote(remote_stdout)
    local preferred_remotes = require("adopure.config.internal").preferred_remotes
    for _, remote_line in ipairs(remote_stdout) do
        local name_and_details = vim.split(remote_line, "\t")
        local remote_name = name_and_details[1]
        if vim.tbl_contains(preferred_remotes, remote_name) then
            return remote_line
        end
    end
    for _, remote_line in ipairs(remote_stdout) do
        if remote_line:find("azure.com") or remote_line:find("visualstudio.com") then
            return remote_line
        end
    end
    vim.notify("adopure unable to elect azure devops remote url; taking the first", 3)
    return remote_stdout[1]
end

---@param remote_stdout string
---@param root_path string
---@return string organization_url
---@return string project_name
---@return string repository_name
---@return string root_path
local function extract_git_details(remote_stdout, root_path)
    local host, project_name, repository_name, organization_name
    local url_with_type = vim.split(remote_stdout, "\t")[2]
    local url = vim.split(url_with_type, " ")[1]
    if url:find("@ssh") then
        local ssh_base
        ssh_base, organization_name, project_name, repository_name = unpack(vim.split(url, "/"))
        host = vim.split(vim.split(ssh_base, ":")[1], "@ssh.")[2]
    end
    if remote_stdout:find("https://") then
        local https_base, user_domain
        https_base, repository_name = unpack(vim.split(url, "/_git/"))
        user_domain, organization_name, project_name = unpack(vim.split(https_base, "/"), 3)
        local user_at_host_parts = vim.split(user_domain, "@")
        host = user_at_host_parts[#user_at_host_parts]
    end
    local organization_url = table.concat({ "https://", host, "/", organization_name, "/" })
    return organization_url, project_name, repository_name, root_path
end

---Get config from git remote
---@return string organization_url
---@return string project_name
---@return string repository_name
---@return string root_path
function M.get_remote_config()
    local get_remotes = require("plenary.job"):new({ ---@diagnostic disable-line: missing-fields
        command = "git",
        args = { "remote", "-v" },
        cwd = ".",
    })
    local get_root = require("plenary.job"):new({ ---@diagnostic disable-line: missing-fields
        command = "git",
        args = { "rev-parse", "--show-toplevel" },
        cwd = ".",
    })

    get_remotes:start()
    get_root:start()
    local remote_result = require("adopure.utils").await_result(get_remotes)
    local root_result = require("adopure.utils").await_result(get_root)
    vim.iter({ remote_result, root_result })
        :filter(function(result) ---@param result adopure.JobResult
            return not not result.stderr[1]
        end)
        :each(function(result) ---@param result adopure.JobResult
            if not result.stdout[1] then
                error(result.stderr[1])
            end
            vim.notify(result.stderr[1], 3)
        end)
    assert(remote_result.stdout[1], "No remote found to extract details;")
    assert(root_result.stdout[1], "No root location found in repo;")
    local elected_remote = elect_remote(remote_result.stdout)
    return extract_git_details(elected_remote, root_result.stdout[1])
end

---Get merge base commit
---@param pull_request adopure.PullRequest
---@return string merge_base
function M.get_merge_base(pull_request)
    local get_merge_base = require("plenary.job"):new({ ---@diagnostic disable-line: missing-fields
        command = "git",
        args = {
            "merge-base",
            pull_request.lastMergeSourceCommit.commitId,
            pull_request.lastMergeTargetCommit.commitId,
        },
        cwd = ".",
    })
    get_merge_base:start()
    local result = require("adopure.utils").await_result(get_merge_base)
    if result.stderr[1] then
        if not result.stdout[1] then
            error(result.stderr[1])
        end
        vim.notify(result.stderr[1], 3)
    end
    assert(result.stdout[1], "No merge base found;")
    return result.stdout[1]
end

---Describe how the checked out branch relates to the pull request head.
---@param source_commit string
---@return string
local function describe_divergence(source_commit)
    local head = "the pull request head " .. source_commit:sub(1, 8)
    local result = vim.system(
        { "git", "rev-list", "--left-right", "--count", "HEAD..." .. source_commit },
        { text = true }
    ):wait()
    local ahead, behind = (result.stdout or ""):match("(%d+)%s+(%d+)")
    ahead, behind = tonumber(ahead), tonumber(behind)
    if result.code ~= 0 or not ahead or not behind then
        return "AdoPure: " .. head .. " is not available locally; fetch and pull to get correct comment positions;"
    end
    local function commits(count)
        return count .. (count == 1 and " commit" or " commits")
    end
    if ahead == 0 then
        return table.concat({
            "AdoPure: local branch is ",
            commits(behind),
            " behind ",
            head,
            "; pull to get correct comment positions;",
        })
    end
    if behind == 0 then
        return table.concat({
            "AdoPure: local branch is ",
            commits(ahead),
            " ahead of ",
            head,
            "; comment positions may be off;",
        })
    end
    return table.concat({
        "AdoPure: local branch has diverged from ",
        head,
        " (",
        ahead,
        " ahead, ",
        behind,
        " behind); comment positions may be off;",
    })
end

---Get the checked out commit and branch; the branch is "HEAD" when detached.
---@return string|nil head_commit, string|nil head_branch
function M.get_head()
    local result = vim.system({ "git", "rev-parse", "HEAD", "--abbrev-ref", "HEAD" }, { text = true }):wait()
    if result.code ~= 0 then
        return nil, nil
    end
    local head_commit, head_branch = unpack(vim.split(vim.trim(result.stdout or ""), "\n"))
    return head_commit, head_branch
end

---Whether the working tree already is the pull request source, by commit or by branch name.
---@param pull_request adopure.PullRequest
---@return boolean
function M.is_checked_out(pull_request)
    local head_commit, head_branch = M.get_head()
    if not head_commit then
        return false
    end
    local source_commit = pull_request.lastMergeSourceCommit.commitId
    if head_commit == source_commit then
        return true
    end
    if "refs/heads/" .. tostring(head_branch) ~= pull_request.sourceRefName then
        return false
    end
    vim.notify(describe_divergence(source_commit), vim.log.levels.WARN)
    return true
end

---Get the root of the checked out working tree.
---@return string|nil
function M.get_root()
    local result = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
    local root = vim.trim(result.stdout or "")
    if result.code ~= 0 or root == "" then
        return nil
    end
    return root
end

---Get the name of the git remote the Azure DevOps context is taken from.
---@return string|nil
function M.get_remote_name()
    local result = vim.system({ "git", "remote", "-v" }, { text = true }):wait()
    local remotes = vim.split(vim.trim(result.stdout or ""), "\n", { trimempty = true })
    if result.code ~= 0 or #remotes == 0 then
        return nil
    end
    return vim.split(elect_remote(remotes), "\t")[1]
end

return M
