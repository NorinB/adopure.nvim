---@mod adopure.config.meta
---@brief [[
---The plugin is configured by assigning an adopure.Config table to vim.g.adopure.
--->lua
--- vim.g.adopure = {}
---<
---There is no mechanism built-in to securely load secrets.
---If you have a cli command that will produce the secret, consider doing something like this:
--->lua
--- local nio = require("nio")
--- nio.run(function()
---     local secret_job = nio.process.run({ cmd = "pass", args = { "show", "my_pat_token_secret_name"} })
---     vim.g.adopure = { pat_token = secret_job.stdout.read():sub(1, -2) }
--- end)
---<
---Alternatively, you can set it as environment variable.
---@brief ]]
---
---@class adopure.Highlights
---@field active? string Highlight for lines with active comments.
---@field active_sign? string Highlight for sign indicating active comments.
---@field inactive? string Highlight for lines with inactive comments.
---@field inactive_sign? string Highlight for sign indicating in active comments.

---@class adopure.Config
---If not provided, attempt to use AZURE_DEVOPS_EXT_PAT environment variable.
---If no environment variable is set, and no config is provided, the plugin will not work.
---@field pat_token? string Personal Access Token to access Azure DevOps.
---@field hl_groups? adopure.Highlights Highlight groups to apply.
---List with preferred remotes to extract Azure DevOps context from.
---Remotes are elected among the following options:
---1. Any remote in this list can be picked, non-deterministically.
---2. Any Azure DevOps remote.
---3. Any remote. If the remote is not an Azure DevOps remote, the plugin will not work.
---@field preferred_remotes? string[]
---@field filter_my_pull_requests? boolean Fetches only pull requests assigned to me, my team or created by me.
---Diff viewers to open the pull request in, by priority; the first installed one is used.
---Supported: "diffview" (sindrets/diffview.nvim) and "diffbandit" (CoreyKaylor/diffbandit.nvim).
---Defaults to { "diffview", "diffbandit" }.
---@field viewers? string[]
---How comment thread windows are opened: "split" opens a split below, "float" a centered floating window.
---Defaults to "split".
---@field thread_window? string
---Whether loading a pull request context opens it in the diff viewer:
---"ask" prompts first, "always" opens it right away, "never" only loads the context.
---Defaults to "ask".
---@field open_viewer? string
---Take the pull request of the checked out branch instead of prompting to choose one.
---Applies when exactly one open pull request has the checked out branch or commit as its source.
---Defaults to false.
---@field pull_request_from_branch? boolean
---How to check out a pull request whose source is not checked out yet; see |adopure.checkout|.
---Each entry is "detached", "switch", a table with a name and a command, or a function returning those.
---One entry is used right away, several are offered in a prompt, an empty list never checks out.
---When not set, a prompt asks whether to check out the source commit detached.
---@field checkout_methods? (string|adopure.CheckoutMethod|fun(context: adopure.CheckoutContext): any)[]
---Called after every successful checkout, whichever method was used.
---@field on_checkout? fun(context: adopure.CheckoutContext)

local config = {}

---@type adopure.Config | fun():adopure.Config | nil
vim.g.adopure = vim.g.adopure

return config
