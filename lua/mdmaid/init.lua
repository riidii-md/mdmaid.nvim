local config = require("mdmaid.config")
local desk = require("mdmaid.desk")
local preview = require("mdmaid.preview")
local session = require("mdmaid.session")
local picker = require("mdmaid.picker")

local M = {
  desk = desk,
  server = desk, -- compatibility alias
  preview = preview,
  config = config,
  session = session,
  picker = picker,
}

function M.setup(opts)
  preview.stop()
  config.setup(opts)
  session.get_or_create()
  local cfg = config.get()
  local group = vim.api.nvim_create_augroup("Mdmaid", { clear = true })

  local function set_keymaps(buf)
    if cfg.keymaps == false then
      return
    end
    local mappings = {
      preview = { preview.toggle, "Toggle mdmaid.desk preview" },
      stop = { preview.stop, "Disconnect mdmaid.desk client" },
      files = { picker.pick_file, "Pick mdmaid file" },
      add = { picker.add_current, "Add current file to mdmaid.desk" },
      web = { preview.web, "Open document in mdmaid.desk Web" },
      tui = { preview.tui, "Open document in mdmaid.desk TUI" },
      source = { preview.source, "Return to Markdown source" },
    }
    for key, mapping in pairs(mappings) do
      if cfg.keymaps[key] then
        vim.keymap.set("n", cfg.keymaps[key], mapping[1], { buffer = buf, desc = mapping[2] })
      end
    end
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(ev)
      set_keymaps(ev.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "markdown" then
      set_keymaps(buf)
    end
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = { "*.md", "*.MD" },
    callback = function(ev)
      local file = vim.api.nvim_buf_get_name(ev.buf)
      local path = file ~= "" and desk.canonical_path(file)
      if path then
        if desk.is_running() then
          desk.add_file(path)
        elseif cfg.preview.auto_start then
          preview.start(path)
        else
          session.add_file(path)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      preview.stop()
      session.delete()
    end,
  })

  local commands = {
    MdmaidPreview = { preview.start, "Register current document and open mdmaid.desk" },
    MdmaidStop = { preview.stop, "Disconnect this client from mdmaid.desk" },
    MdmaidRestart = { desk.restart, "Reconnect this client to mdmaid.desk" },
    MdmaidOpen = { preview.web, "Open current document in mdmaid.desk" },
    MdmaidWeb = { preview.web, "Open document in mdmaid.desk Web" },
    MdmaidSource = { preview.source, "Return to Markdown source" },
    MdmaidFiles = { picker.pick_file, "Pick file to open in mdmaid.desk" },
    MdmaidAdd = { picker.add_current, "Register current document with mdmaid.desk" },
    MdmaidRemove = { picker.remove_current, "Remove current file from this client" },
    MdmaidStatus = { function()
      local status = preview.status()
      local lines = {
        "mdmaid.desk client:",
        "  Client: " .. (status.connected and "active" or "disconnected"),
        "  Document: " .. (status.document_id or "none"),
        "  URL: " .. (status.url or "none"),
        "  Current: " .. (status.file or "none"),
        "  Files: " .. #status.files .. " tracked",
      }
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end, "Show mdmaid.desk client status" },
  }
  vim.api.nvim_create_user_command("MdmaidTui", function(args)
    preview.tui(nil, args.bang and "replace" or nil)
  end, { bang = true, force = true, desc = "Open TUI beside source, or replace this window with !" })
  for name, entry in pairs(commands) do
    vim.api.nvim_create_user_command(name, function()
      entry[1]()
    end, { desc = entry[2], force = true })
  end
end

return M
