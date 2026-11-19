vim.opt.rtp:prepend(vim.fn.getcwd())
local root = assert(vim.env.MDMAID_NVIM_TEST_ROOT)
local command = vim.json.decode(assert(vim.env.MDMAID_DESK_COMMAND))
local mdmaid = require("mdmaid")
local terminal = require("mdmaid.terminal")
local live = require("mdmaid.live")
local capture = root .. "/browser-url"
mdmaid.setup({
  mdmaid_path = command, keymaps = false,
  preview = {
    auto_start = false, live = true, debounce = 20,
    browser = { "node", "-e", "require('node:fs').writeFileSync(process.argv[1],process.argv[2])", capture },
  },
})
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/source.md"))
local source = vim.api.nvim_get_current_buf()
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# Initial unsaved", "First editor paragraph." })
vim.api.nvim_win_set_cursor(0, { 2, 5 })
vim.o.hidden = false

local function wait(condition, message)
  assert(vim.wait(20000, condition, 20), message)
end
local function rendered(buf)
  return vim.api.nvim_buf_is_valid(buf) and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") or ""
end
local function api(preview_id)
  local descriptor = vim.json.decode(table.concat(vim.fn.readfile(vim.env.XDG_STATE_HOME .. "/mdmaid.desk/daemon.json"), "\n"))
  local id = assert(mdmaid.preview.status().document_id)
  local url = "http://127.0.0.1:" .. descriptor.port .. "/api/v1/documents/" .. id .. "/render?target=web"
  if preview_id then url = url .. "&preview=" .. preview_id end
  local text = vim.fn.system({ "node", "-e",
    "fetch(process.argv[1],{headers:{authorization:'Bearer '+process.argv[2]}}).then(async r=>console.log(JSON.stringify({status:r.status,body:await r.json()}))).catch(e=>{console.error(e.message);process.exitCode=1})",
    url, descriptor.token })
  assert(vim.v.shell_error == 0, text)
  return vim.json.decode(text)
end

local ok, err = xpcall(function()
  vim.cmd("MdmaidTui")
  wait(function() return terminal.is_visible() end, "TUI did not open")
  local tui = vim.api.nvim_get_current_buf()
  wait(function() return rendered(tui):find("Initial unsaved", 1, true) end, "TUI did not render the unsaved source")
  assert(#vim.api.nvim_list_wins() == 2)
  assert(vim.api.nvim_win_get_buf(source_win) == source)
  local initial = assert(live.get(source))
  assert(api(initial.id).body.data.content:find("Initial unsaved", 1, true))
  assert(api().body.data.content:find("Saved source", 1, true))
  print("PASS real TUI opens the requested whole document with unsaved content")

  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# Updated while typing", "Still not saved." })
  wait(function() return rendered(tui):find("Updated while typing", 1, true) end, "TUI did not follow typing")
  assert(vim.fn.readfile(root .. "/source.md")[1] == "# Saved source")
  vim.cmd("MdmaidSource")
  assert(vim.api.nvim_get_current_buf() == source)
  assert(vim.bo[source].modified)
  print("PASS typing refreshes the TUI while the saved file remains unchanged")

  vim.cmd("MdmaidTui!")
  wait(function() return terminal.is_visible() and vim.api.nvim_get_current_buf() ~= source end, "Replacement TUI did not open")
  local replacement = vim.api.nvim_get_current_buf()
  wait(function() return rendered(replacement):find("Updated while typing", 1, true) end, "Replacement TUI has wrong source")
  assert(#vim.api.nvim_list_wins() == 1)
  vim.cmd("MdmaidSource")
  assert(vim.api.nvim_get_current_buf() == source)
  assert(vim.bo[source].modified)
  print("PASS TUI replacement and return preserve the original source buffer")

  vim.cmd("MdmaidWeb")
  wait(function() return vim.fn.filereadable(capture) == 1 end, "Browser command did not receive a URL")
  local url = table.concat(vim.fn.readfile(capture), "\n")
  assert(url:find("/d/" .. mdmaid.preview.status().document_id .. "?preview=" .. initial.id, 1, true))
  assert(not url:find("#", 1, true), "Whole-document preview must not request a source-line anchor")
  assert(api(initial.id).body.data.content:find("Updated while typing", 1, true))
  print("PASS Web opens the same unsaved document without cursor mapping")

  vim.cmd("MdmaidStop")
  local closed
  wait(function()
    closed = api(initial.id)
    return closed.status == 404
  end, "Temporary editor preview was not released")
  assert(vim.api.nvim_get_current_buf() == source)
  assert(vim.fn.readfile(root .. "/source.md")[1] == "# Saved source")
  print("PASS Stop releases the draft and preserves the source")
end, debug.traceback)
mdmaid.preview.stop()
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
vim.cmd("qa!")
