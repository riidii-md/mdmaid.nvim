-- Invoked by integration.py with a private XDG_STATE_HOME and fixture root.
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = assert(vim.env.MDMAID_NVIM_TEST_ROOT)
local mdmaid = require("mdmaid")
mdmaid.setup({
  keymaps = false,
  preview = { auto_start = false, open_browser = false },
})
local first = root .. "/" .. assert(vim.env.MDMAID_NVIM_TEST_NAME)
local second = root .. "/second.md"

local function register(file)
  local result
  assert(mdmaid.desk.start(file, function(document) result = document end))
  assert(vim.wait(20000, function() return result ~= nil end), "Desk registration timed out")
  return result
end

local ok, err = xpcall(function()
  local original = register(first)
  assert(register(root .. "/./" .. vim.env.MDMAID_NVIM_TEST_NAME).id == original.id, "Repeated open changed identity")
  local other = register(second)
  assert(other.id ~= original.id, "Different sources share identity")
  assert(register(first).id == original.id, "Switching back changed identity")
  assert(#mdmaid.desk.get_files() == 2, "Duplicate tracked files")
  local status = mdmaid.preview.status()
  assert(not status.url:find("token", 1, true), "Status exposed token")
  mdmaid.preview.stop()
  assert(not mdmaid.desk.is_running(), "Stop left client active")
  vim.fn.writefile({ vim.json.encode({
    id = original.id,
    revision = original.revision,
    url = original.url,
    other_id = other.id,
  }) }, root .. "/result.json")
end, debug.traceback)

if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
