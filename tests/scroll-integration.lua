-- Run after VimEnter so native WinScrolled events reach the normal event loop.
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = assert(vim.env.MDMAID_NVIM_TEST_ROOT)
local command = vim.json.decode(assert(vim.env.MDMAID_DESK_COMMAND))
local real_config = vim.env.MDMAID_NVIM_REAL_CONFIG == "1"
if real_config then vim.cmd("Lazy load mdmaid.nvim") end
local mdmaid = require("mdmaid")
local terminal = require("mdmaid.terminal")
local live = require("mdmaid.live")
local config = require("mdmaid.config")
if not real_config then
  mdmaid.setup({ mdmaid_path = command, keymaps = false,
    preview = { auto_start = false, live = true, debounce = 20, sync_scroll = true } })
end
vim.o.columns, vim.o.lines = 160, 40
local path = root .. "/scroll.md"
local lines = {}
for i = 1, 120 do
  lines[#lines + 1] = string.format("Paragraph %03d", i)
  lines[#lines + 1] = ""
end
vim.fn.writefile(lines, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
vim.wo.foldenable = false
local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local function rendered(buf)
  return vim.api.nvim_buf_is_valid(buf) and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") or ""
end
local function await(condition, message)
  local deadline = (vim.uv or vim.loop).hrtime() + 20000000000
  while not condition() do
    assert((vim.uv or vim.loop).hrtime() < deadline, message)
    coroutine.yield(20)
  end
end
local function scroll(keys)
  terminal.source()
  vim.cmd("normal! " .. keys)
  vim.cmd("redraw")
end
local function test()
  if real_config then
    assert(vim.fn.maparg("<Space>T", "n") ~= "", "Missing quick TUI shortcut")
    assert(vim.fn.maparg("<Space>W", "n") ~= "", "Missing quick Web shortcut")
  end
  vim.cmd("MdmaidTui")
  await(terminal.is_visible, "Real TUI did not open")
  local tui
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "terminal" then tui = buf end
  end
  assert(tui, "Missing TUI terminal buffer")
  await(function() return rendered(tui):find("Paragraph 001", 1, true) end, "TUI did not show the document start")
  scroll("Gzt")
  local cursor = vim.api.nvim_win_get_cursor(source_win)
  await(function()
    local info = live.get(source_buf)
    return info and info.viewport and info.viewport.progress == 1
      and rendered(tui):find("Paragraph 120", 1, true)
  end, "Real source scroll did not reach the rendered document end")
  assert(vim.api.nvim_get_current_win() == source_win, "Scroll synchronization stole focus")
  assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(source_win)), "Scroll synchronization moved the source cursor")
  io.stdout:write("PASS real source scrolling moves the TUI to the document end\n")

  local view = vim.api.nvim_win_call(source_win, vim.fn.winsaveview)
  local revision = live.get(source_buf).viewport.revision
  vim.api.nvim_chan_send(vim.bo[tui].channel, "k")
  coroutine.yield(150)
  assert(vim.deep_equal(view, vim.api.nvim_win_call(source_win, vim.fn.winsaveview)), "Right scroll changed the left view")
  assert(live.get(source_buf).viewport.revision == revision, "Right scroll wrote back to the source viewport")
  scroll("ggzt")
  await(function()
    return live.get(source_buf).viewport.progress == 0 and rendered(tui):find("Paragraph 001", 1, true)
      and not rendered(tui):find("Paragraph 120", 1, true)
  end, "Real source scroll did not return to the rendered document start")
  io.stdout:write("PASS scroll follow is one-way and returns to the document start\n")

  -- Prove unsaved delivery independently of an optional user autosave plugin.
  if real_config and require("lazy.core.config").plugins["autosave.nvim"] then
    require("lazy").load({ plugins = { "autosave.nvim" } })
    require("autosave.action").disable()
  end
  vim.api.nvim_buf_set_lines(source_buf, 0, 1, false, { "# Updated while typing" })
  await(function() return rendered(tui):find("Updated while typing", 1, true) end, "Typing did not update the right preview")
  assert(vim.fn.readfile(path)[1] == "Paragraph 001", "Typing unexpectedly saved the source")
  vim.cmd("write")
  assert(vim.fn.readfile(path)[1] == "# Updated while typing")
  assert(rendered(tui):find("Updated while typing", 1, true), "Saved preview lost the edit")
  io.stdout:write("PASS edits render before saving and remain visible after saving\n")

  config.get().preview.sync_scroll = false
  revision = live.get(source_buf).viewport.revision
  scroll("Gzt")
  coroutine.yield(200)
  assert(live.get(source_buf).viewport.revision == revision, "Disabled scroll follow still updated the viewport")
  io.stdout:write("PASS scroll follow can be disabled\n")
end
local co = coroutine.create(test)
local function resume()
  local ok, delay = coroutine.resume(co)
  if not ok or coroutine.status(co) == "dead" then
    mdmaid.preview.stop()
    if not ok then io.stderr:write(debug.traceback(co, delay) .. "\n"); vim.cmd("cquit 1") end
    vim.cmd("qa!")
  else
    vim.defer_fn(resume, delay)
  end
end
resume()
