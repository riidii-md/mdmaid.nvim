---@class MdmaidConfig
---@field mdmaid_path? string|string[] mdmaid-desk executable or argv prefix
---@field desk? table Shared desk options: auto_start, workspace, root, timeout
---@field preview? table Browser options: auto_start, open_browser, browser
---@field keymaps? table|false Buffer-local keymaps

local M = {}

M.defaults = {
  mdmaid_path = "mdmaid-desk",
  desk = {
    auto_start = true,
    timeout = 15000,
    workspace = nil,
    root = nil,
  },
  preview = {
    target = "web",
    layout = "split",
    live = true,
    sync_scroll = true,
    debounce = 150,
    auto_start = true,
    open_browser = true,
    browser = nil,
  },
  keymaps = {
    preview = "<leader>mp",
    stop = "<leader>ms",
    files = "<leader>mf",
    add = "<leader>ma",
    web = "<leader>mw",
    tui = "<leader>mt",
    source = "<leader>me",
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = vim.deepcopy(opts or {})
  -- Preserve the old automatic-preview preference during migration.
  if opts.server then
    opts.preview = opts.preview or {}
    if opts.preview.auto_start == nil then
      opts.preview.auto_start = opts.server.auto_start
    end
  end
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts)
  if opts.server or opts.render then
    vim.notify(
      "mdmaid.nvim now uses shared mdmaid.desk. server and render options are retired; "
        .. "server.auto_start maps to preview.auto_start. Configure rendering in mdmaid.desk.",
      vim.log.levels.WARN
    )
  end
end

function M.get()
  return M.options
end

return M
