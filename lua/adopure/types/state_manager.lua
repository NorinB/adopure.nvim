---@mod adopure.types.state_manager
local M = {}

---@private
---@class adopure.AdoContext
---@field organization_url string
---@field project_name string
---@field repository_name string
---@field root_path string
local AdoContext = {}
M.AdoContext = AdoContext

---@return adopure.AdoContext
function AdoContext:new()
    local organization_url, project_name, repository_name, root_path = require("adopure.git").get_remote_config()
    local o = {
        organization_url = organization_url,
        project_name = project_name,
        repository_name = require("adopure.utils").url_decode(repository_name),
        root_path = root_path,
    }
    self.__index = self
    return setmetatable(o, self)
end

---@class adopure.StateManager
---@field repository adopure.Repository
---@field pull_requests adopure.PullRequest[]
---@field state adopure.AdoState|nil
---@field root_path string
local StateManager = {}
M.StateManager = StateManager

---@param context adopure.AdoContext
function StateManager:new(context)
    local repository, repository_err = require("adopure.api").get_repository(context)
    if repository_err then
        error(repository_err)
    end
    assert(repository, "No repository with correct name found in project;")

    local o = {
        repository = repository,
        pull_requests = {},
        state = nil,
        root_path = context.root_path,
    }
    self.__index = self
    self = setmetatable(o, self)
    self:load_pull_requests()
    return self
end

---Fetch the open pull requests of the repository from Azure DevOps.
---Called upon initialization, and again every time a pull request context is loaded.
function StateManager:load_pull_requests()
    local pull_requests, err = require("adopure.api").get_pull_requests(
        self.repository,
        require("adopure.config.internal").filter_my_pull_requests
    )
    if err then
        error(err)
    end
    self.pull_requests = pull_requests
end

---The open pull request whose source is checked out, matched by branch name or by source commit.
---Returns nil when none or several pull requests match.
---@return adopure.PullRequest|nil
function StateManager:checked_out_pull_request()
    local head_commit, head_branch = require("adopure.git").get_head()
    if not head_commit then
        return nil
    end
    local matches = vim.iter(self.pull_requests)
        :filter(function(pull_request) ---@param pull_request adopure.PullRequest
            return pull_request.sourceRefName == "refs/heads/" .. tostring(head_branch)
                or vim.tbl_get(pull_request, "lastMergeSourceCommit", "commitId") == head_commit
        end)
        :totable()
    if #matches ~= 1 then
        return nil
    end
    return matches[1]
end

---Whether the pull request is the loaded one, still at the same source commit.
---@param pull_request adopure.PullRequest
---@return boolean
function StateManager:is_loaded(pull_request)
    local loaded = self.state and self.state.active_pull_request
    if not loaded or loaded.pullRequestId ~= pull_request.pullRequestId then
        return false
    end
    return vim.tbl_get(loaded, "lastMergeSourceCommit", "commitId")
        == vim.tbl_get(pull_request, "lastMergeSourceCommit", "commitId")
end

---Parameters for choosing a pull request.
---@class adopure.ChooseOpts
---Always prompt, even when the pull_request_from_branch config would pick the checked out pull request.
---@field pick boolean|nil

---Load a pull request into state and hand the state to on_choice.
---Takes the pull request of the checked out branch when pull_request_from_branch is configured;
---prompts to choose one otherwise.
---A pull request taken from the branch that is loaded already is not loaded again.
---@param opts adopure.ChooseOpts
---@param on_choice fun(state: adopure.AdoState)
function StateManager:choose(opts, on_choice)
    local pull_request
    if require("adopure.config.internal").pull_request_from_branch and not opts.pick then
        pull_request = self:checked_out_pull_request()
    end
    if not pull_request then
        require("adopure.pickers.pull_request").choose(self, on_choice)
        return
    end
    if self:is_loaded(pull_request) then
        on_choice(self.state)
        return
    end
    self:set_state_by_choice(pull_request)
    vim.notify(
        table.concat({
            "AdoPure: loaded pull request !",
            tostring(pull_request.pullRequestId),
            " of the checked out branch: ",
            tostring(pull_request.title),
        })
    )
    on_choice(self.state)
end

---Choose a PR and activate the context.
---@param opts adopure.ChooseOpts
function StateManager:choose_and_activate(opts)
    self:choose(opts or {}, require("adopure.activate").activate_pull_request_context)
end

---@param pull_request adopure.PullRequest
function StateManager:set_state_by_choice(pull_request)
    self.root_path = require("adopure.git").get_root() or self.root_path
    self.state = require("adopure.types.ado_state").AdoState:new(self.repository, pull_request, self.root_path)
end

---@export AdoState, StateManager
return M
