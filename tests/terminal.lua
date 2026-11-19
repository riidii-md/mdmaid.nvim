vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("mdmaid.config")
config.setup({ keymaps = false })
local terminal = require("mdmaid.terminal")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local path = root .. "/source.md"
vim.fn.writefile({ "# Saved source", "second line" }, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
vim.api.nvim_buf_set_lines(0, 1, 2, false, { "unsaved changes" })
vim.api.nvim_win_set_cursor(0, { 2, 3 })
vim.o.hidden = false
local source_buf = vim.api.nvim_get_current_buf()
local source_win = vim.api.nvim_get_current_win()
vim.wo[source_win].number = true
vim.wo[source_win].relativenumber = true
vim.wo[source_win].signcolumn = "yes:2"
vim.wo[source_win].foldcolumn = "1"
vim.wo[source_win].statuscolumn = "%s%l"
local original_statuscolumn = vim.wo[source_win].statuscolumn
local original_termopen, original_jobstop = vim.fn.termopen, vim.fn.jobstop
local exits = {}
vim.fn.termopen = function(_, opts)
  local job = vim.api.nvim_open_term(0, {})
  exits[job] = opts.on_exit
  return job
end
vim.fn.jobstop = function() return 1 end
local doc = { id = "doc-11111111111111111111" }

local ok, err = xpcall(function()
  terminal.open(doc, nil, terminal.capture(source_buf), "split")
  assert(#vim.api.nvim_list_wins() == 2)
  assert(vim.api.nvim_get_current_buf() ~= source_buf)
  assert(vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff == 0, "Preview reserves terminal columns for editor gutters")
  assert(vim.api.nvim_win_get_buf(source_win) == source_buf)
  terminal.source()
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.api.nvim_buf_get_lines(source_buf, 1, 2, false)[1] == "unsaved changes")
  terminal.close()
  assert(#vim.api.nvim_list_wins() == 1)
  print("PASS split preserves source and returns without discarding edits")

  local source = terminal.capture(source_buf)
  terminal.open(doc, nil, source, "replace")
  assert(#vim.api.nvim_list_wins() == 1)
  assert(vim.api.nvim_get_current_buf() ~= source_buf)
  assert(vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff == 0, "Preview reserves terminal columns for editor gutters")
  terminal.source()
  assert(vim.api.nvim_get_current_buf() == source_buf)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
  assert(vim.bo[source_buf].modified)
  assert(vim.wo[source_win].number and vim.wo[source_win].relativenumber, "Source number options were not restored")
  assert(vim.wo[source_win].signcolumn == "yes:2")
  assert(vim.wo[source_win].foldcolumn == "1")
  assert(vim.wo[source_win].statuscolumn == original_statuscolumn)
  terminal.close()
  assert(vim.fn.readfile(path)[2] == "second line")
  print("PASS replace and return preserve the modified buffer, cursor, and disk")

  terminal.open(doc, nil, terminal.capture(source_buf), "replace")
  local job
  for id in pairs(exits) do job = id end
  -- The last termopen callback closes the TUI and restores the source.
  local newest = 0
  for id in pairs(exits) do if id > newest then newest = id end end
  exits[newest](newest, 0)
  vim.wait(20, function() return not terminal.is_open() end)
  assert(vim.api.nvim_get_current_buf() == source_buf)
  print("PASS TUI exit returns to the source")
end, debug.traceback)
terminal.close()
vim.fn.termopen, vim.fn.jobstop = original_termopen, original_jobstop
vim.fn.delete(root, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
vim.cmd("qa!")
