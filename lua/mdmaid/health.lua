local M = {}

function M.check()
  vim.health.start("mdmaid.nvim")
  local opts = require("mdmaid.config").get()
  local cmd = type(opts.mdmaid_path) == "table" and vim.deepcopy(opts.mdmaid_path) or { opts.mdmaid_path }
  table.insert(cmd, "--help")
  local ok, output = pcall(vim.fn.system, cmd)
  if ok and vim.v.shell_error == 0 and output:find("mdmaid%-desk register") and output:find("%-%-live") then
    if opts.preview.live and not output:find("mdmaid%-desk preview") then
      vim.health.error("This desk CLI supports saved files only", {
        "Use a desk build with preview --document and tui --document --preview.",
        "Or set preview.live=false to use saved-source Web previews.",
      })
    else
      vim.health.ok("mdmaid-desk CLI found (live registration supported)")
    end
  else
    vim.health.error("Current mdmaid-desk CLI not found", {
      "Install/update: npm install --global mdmaid-desk",
      "Set mdmaid_path to the mdmaid-desk executable (or an argv list).",
      "The legacy mdmaid CLI is no longer used.",
    })
  end
  local has_telescope = pcall(require, "telescope")
  vim.health.info(has_telescope and "Telescope picker available" or "Using vim.ui.select picker")
  local status = require("mdmaid.preview").status()
  vim.health.info("Desk client: " .. (status.connected and "active" or "disconnected"))
  if status.document_id then
    vim.health.ok("Current document: " .. status.document_id)
  end
  vim.health.info("mdmaid.desk owns the service and source watcher; Neovim exit leaves them running.")
end

return M
