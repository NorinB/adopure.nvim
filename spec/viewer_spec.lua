local assert = require("luassert.assert")

describe("viewer", function()
    local config = require("adopure.config.internal")
    local real = { viewers = config.viewers, diffbandit = package.loaded["diffbandit"] }

    after_each(function()
        config.viewers = real.viewers
        package.loaded["diffbandit"] = real.diffbandit
    end)

    it("opens diffbandit in the given repository root", function()
        local panel_opts
        config.viewers = { "diffbandit" }
        package.loaded["diffbandit"] = {
            git_panel = function(opts)
                panel_opts = opts
                return { tabpage = vim.api.nvim_get_current_tabpage() }, nil
            end,
        }
        local review, err = require("adopure.viewer").open("merge-base", "/repository")
        assert.is_nil(err)
        assert.are.same("diffbandit", review.viewer)
        assert.are.same("merge-base", panel_opts.base)
        assert.are.same("/repository", panel_opts.root)
    end)
end)
