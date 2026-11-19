-- Run with: nvim --headless -u NONE -i NONE -l tests/headless.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname() .. " project & ü"
vim.fn.mkdir(root .. "/.git", "p")
root = (vim.uv or vim.loop).fs_realpath(root)
local a = root .. "/first.md"
local b = root .. "/second $(literal).md"
vim.fn.writefile({ "# First" }, a)
vim.fn.writefile({ "# Second" }, b)
local original_start, original_stop = vim.fn.jobstart, vim.fn.jobstop
local calls, pending, browsers, stopped, notices = {}, {}, {}, {}, {}
local next_id = 0
vim.notify = function(message)
  table.insert(notices, message)
end
vim.fn.jobstart = function(cmd, opts)
  next_id = next_id + 1
  local job = { id = next_id, cmd = cmd, opts = opts }
  table.insert(calls, job)
  if cmd[1] == "test-browser" then
    table.insert(browsers, job)
  else
    table.insert(pending, job)
  end
  return job.id
end
vim.fn.jobstop = function(id)
  table.insert(stopped, id)
  return 1
end

local mdmaid = require("mdmaid")
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function flush()
  vim.wait(5, function() return false end)
end
local function reply(output, code, stderr)
  local job = table.remove(pending, 1)
  assert(job, "no pending CLI job")
  if job.opts.on_stdout then job.opts.on_stdout(job.id, vim.split(output or "", "\n", { plain = true })) end
  if job.opts.on_stderr then job.opts.on_stderr(job.id, { stderr or "" }) end
  job.opts.on_exit(job.id, code or 0)
  flush()
  return job
end
local function expect(args)
  assert(pending[1], "expected pending job: " .. vim.inspect(args))
  equal(pending[1].cmd, vim.list_extend({ "mdmaid-desk" }, args))
end
local service = "daemon running (pid 123, port 43127)\nmdmaid.desk web: http://mdmaid.desk.localhost/?token=test-token\n"
local function registration(file, id, options)
  options = options or {}
  expect({ "daemon", options.status and "status" or "start" })
  reply(options.service or service)
  expect({ "workspace", "list" })
  reply(options.workspaces or ("existing\tExisting\t" .. root .. "\n"))
  if options.new_workspace then
    equal(pending[1].cmd[2], "workspace")
    equal(pending[1].cmd[3], "add")
    equal(pending[1].cmd[4], root)
    equal(pending[1].cmd[6], options.workspace or ("nvim-" .. vim.fn.sha256(root):sub(1, 16)))
    reply("workspace added")
  end
  expect({ "register", file, "--workspace", options.workspace or "existing", "--live", "--producer", "mdmaid.nvim", "--json" })
  reply(options.output or vim.json.encode({
    schemaVersion = 1, document = { id = id, revision = 1, route = "/d/" .. id },
  }), options.code, options.stderr)
end
local function reset(opts)
  mdmaid.preview.stop()
  mdmaid.session.delete()
  calls, pending, browsers, stopped, notices = {}, {}, {}, {}, {}
  mdmaid.config.setup(vim.tbl_deep_extend("force", {
    preview = { live = false,  auto_start = false, browser = "test-browser" },
    keymaps = false,
  }, opts or {}))
  vim.api.nvim_buf_set_name(0, a)
end

local passed = 0
local function test(name, fn)
  reset()
  fn()
  passed = passed + 1
  print("PASS " .. name)
end

local ok, err = xpcall(function()
  test("opens the current buffer at its authenticated stable document route", function()
    assert(mdmaid.preview.start())
    registration(a, "doc-first")
    equal(#browsers, 1)
    equal(browsers[1].cmd, { "test-browser", "http://mdmaid.desk.localhost/d/doc-first?token=test-token" })
    equal(mdmaid.preview.status().url, "http://mdmaid.desk.localhost/d/doc-first")
    equal(mdmaid.desk.get_current_file(), a)
    assert(not mdmaid.preview.status().url:find("token", 1, true))
  end)
  test("repeated opens register the same canonical source", function()
    mdmaid.preview.start(a)
    registration(a, "doc-first")
    mdmaid.preview.start(root .. "/./first.md")
    registration(a, "doc-first")
    equal(#mdmaid.desk.get_files(), 1)
    equal(mdmaid.preview.status().document_id, "doc-first")
  end)
  test("switching and re-opening an already tracked file updates the active document", function()
    mdmaid.preview.start(a)
    registration(a, "doc-first")
    mdmaid.desk.switch_file(b)
    registration(b, "doc-second")
    mdmaid.desk.switch_file(a)
    registration(a, "doc-first")
    equal(mdmaid.desk.get_current_file(), a)
    equal(#mdmaid.desk.get_files(), 2)
    assert(browsers[2].cmd[2]:find("/d/doc-second?", 1, true))
  end)
  test("a failed registration preserves the active document and redacts tokens", function()
    mdmaid.preview.start(a)
    registration(a, "doc-first")
    mdmaid.preview.start(b)
    registration(b, "doc-second", { code = 1, stderr = "rejected ?token=private-token" })
    equal(mdmaid.desk.get_current_file(), a)
    equal(mdmaid.preview.status().document_id, "doc-first")
    equal(#mdmaid.desk.get_files(), 1)
    equal(#browsers, 1)
    assert(not table.concat(notices):find("private-token", 1, true))
  end)
  test("rejects malformed registration JSON and foreign document routes", function()
    for _, output in ipairs({ "not json", vim.json.encode({
      schemaVersion = 1, document = { id = "doc-first", revision = 1, route = "https://example.com" },
    }) }) do
      mdmaid.preview.start(a)
      registration(a, "doc-first", { output = output })
      equal(mdmaid.preview.status().document_id, nil)
    end
    equal(#browsers, 0)
  end)
  test("creates a deterministic workspace when none contains the source", function()
    mdmaid.preview.start(a)
    local id = "nvim-" .. vim.fn.sha256(root):sub(1, 16)
    registration(a, "doc-first", { workspaces = "", new_workspace = true, workspace = id })
    equal(mdmaid.preview.status().document_id, "doc-first")
  end)
  test("chooses the deepest existing workspace without rewriting it", function()
    mdmaid.preview.start(a)
    registration(a, "doc-first", { workspaces = "parent\tParent\t" .. vim.fn.fnamemodify(root, ":h")
      .. "\nexisting\tExisting\t" .. root })
  end)
  test("configured workspaces are reused and unknown IDs fail without creating", function()
    mdmaid.config.setup({ desk = { workspace = "unknown" }, preview = { live = false,  open_browser = false } })
    mdmaid.preview.start(a)
    reply(service)
    reply("existing\tExisting\t" .. root)
    equal(#pending, 0)
    equal(#mdmaid.desk.get_files(), 0)
    assert(table.concat(notices):find("Unknown desk.workspace", 1, true))
  end)
  test("desk auto_start=false checks the shared daemon without starting it", function()
    mdmaid.config.setup({ desk = { auto_start = false }, preview = { live = false,  open_browser = false } })
    mdmaid.preview.start(a)
    registration(a, "doc-first", { status = true })
    equal(#browsers, 0)
  end)
  test("stop and stale callbacks cannot open a browser or stop the shared daemon", function()
    mdmaid.preview.start(a)
    local job = pending[1]
    mdmaid.preview.stop()
    reply(service)
    equal(#pending, 0)
    equal(#browsers, 0)
    equal(stopped, { job.id })
    equal(mdmaid.desk.is_running(), false)
    for _, call in ipairs(calls) do
      assert(not (call.cmd[2] == "daemon" and call.cmd[3] == "stop"))
    end
  end)
  test("rapid preview requests only open the most recently requested document", function()
    mdmaid.preview.start(a)
    mdmaid.preview.start(b)
    registration(a, "doc-first")
    equal(#browsers, 0)
    registration(b, "doc-second")
    equal(#browsers, 1)
    equal(mdmaid.desk.get_current_file(), b)
  end)
  test("removing an in-flight file prevents it being added back", function()
    mdmaid.preview.start(a)
    mdmaid.desk.remove_file(a)
    registration(a, "doc-first")
    equal(#mdmaid.desk.get_files(), 0)
    equal(#browsers, 0)
  end)
  test("CLI prefixes and file names remain individual argv entries", function()
    mdmaid.config.setup({ mdmaid_path = { "node", "/path with spaces/desk.js" } })
    mdmaid.preview.start(b)
    equal(pending[1].cmd, { "node", "/path with spaces/desk.js", "daemon", "start" })
    mdmaid.preview.stop()
    equal(#stopped, 1)
  end)
  test("missing executables and timeouts leave no active client", function()
    local saved = vim.fn.jobstart
    vim.fn.jobstart = function() return -1 end
    assert(mdmaid.preview.start(a))
    equal(mdmaid.desk.is_running(), false)
    vim.fn.jobstart = saved
    mdmaid.config.setup({ desk = { timeout = 1 } })
    mdmaid.preview.start(a)
    assert(vim.wait(100, function() return not mdmaid.desk.is_running() end))
    equal(#stopped, 1)
  end)
  test("unsaved and non-Markdown buffers do not start a service", function()
    equal(mdmaid.preview.start(root .. "/missing.md"), false)
    vim.fn.writefile({ "text" }, root .. "/file.txt")
    equal(mdmaid.preview.start(root .. "/file.txt"), false)
    equal(#calls, 0)
  end)
  test("setup is repeatable, supports keymaps=false, and exit only disconnects", function()
    local options = { keymaps = false, preview = { live = false,  auto_start = false, open_browser = false, browser = "test-browser" } }
    mdmaid.setup(options)
    local count = #vim.api.nvim_get_autocmds({ group = "Mdmaid", event = "BufEnter" })
    mdmaid.setup(options)
    equal(#vim.api.nvim_get_autocmds({ group = "Mdmaid", event = "BufEnter" }), count)
    vim.api.nvim_exec_autocmds("FileType", { pattern = "markdown" })
    vim.cmd("MdmaidOpen")
    registration(a, "doc-first")
    -- Explicit Open overrides open_browser=false.
    equal(#browsers, 1)
    vim.cmd("MdmaidStatus")
    assert(not table.concat(notices):find("test-token", 1, true))
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    equal(mdmaid.desk.is_running(), false)
    for _, call in ipairs(calls) do
      assert(not (call.cmd[2] == "daemon" and call.cmd[3] == "stop"))
    end
  end)
  test("root workspaces contain their descendants", function()
    mdmaid.preview.start(a)
    registration(a, "doc-first", { workspaces = "existing\tRoot\t/\n" })
  end)
  test("symlink aliases use the same canonical source identity", function()
    local alias = root .. "/alias.md"
    assert((vim.uv or vim.loop).fs_symlink(a, alias))
    mdmaid.preview.start(alias)
    registration(a, "doc-first")
    equal(mdmaid.desk.get_files(), { a })
  end)
  test("refuses remote or credential-bearing service URLs", function()
    for _, origin in ipairs({ "https://example.com", "http://user@desk.localhost" }) do
      mdmaid.preview.start(a)
      reply("daemon running (pid 123, port 43127)\nmdmaid.desk web: " .. origin .. "/?token=test-token")
      equal(#pending, 0)
      equal(#browsers, 0)
    end
  end)
  test("uses the service's advertised origin and custom port", function()
    mdmaid.preview.start(a)
    registration(a, "doc-first", {
      service = "daemon running (pid 123, port 43210)\nmdmaid.desk web: https://reader.localhost:9443/?token=test-token",
    })
    equal(browsers[1].cmd[2], "https://reader.localhost:9443/d/doc-first?token=test-token")
  end)
  test("an explicit workspace root can create a configured workspace", function()
    mdmaid.config.setup({
      desk = { workspace = "chosen", root = root },
      preview = { live = false,  open_browser = false },
    })
    mdmaid.preview.start(a)
    registration(a, "doc-first", { workspaces = "", new_workspace = true, workspace = "chosen" })
  end)
  test("live typing streams unsaved snapshots and opens a session-specific URL", function()
    local original_send = vim.fn.chansend
    local sent = {}
    vim.fn.chansend = function(_, data) table.insert(sent, vim.json.decode(data)); return #data end
    mdmaid.config.setup({
      keymaps = false,
      preview = { live = true, auto_start = false, browser = "test-browser", debounce = 1 },
    })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Unsaved initial" })
    mdmaid.preview.start(a)
    registration(a, "doc-first")
    local job = table.remove(pending, 1)
    equal(job.cmd, { "mdmaid-desk", "preview", "--document", "doc-first" })
    equal(sent[1].content, "# Unsaved initial\n")
    local id = "preview-" .. string.rep("a", 32)
    local info = { id = id, documentId = "doc-first", version = 1, route = "/d/doc-first?preview=" .. id, viewport = { progress = 0, revision = 0 } }
    job.opts.on_stdout(job.id, { vim.json.encode({ schemaVersion = 1, preview = info }), "" })
    flush()
    equal(browsers[1].cmd[2], "http://mdmaid.desk.localhost/d/doc-first?preview=" .. id .. "&token=test-token")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Typed without saving" })
    assert(vim.wait(1000, function() return #sent >= 2 end))
    equal(sent[#sent].content, "# Typed without saving\n")
    assert(require("mdmaid.live").set_scroll(vim.api.nvim_get_current_buf(), 0.5))
    equal(sent[#sent].scroll, 0.5)
    equal(sent[#sent].content, nil)
    equal(vim.fn.readfile(a)[1], "# First")
    mdmaid.preview.stop()
    equal(require("mdmaid.live").get(vim.api.nvim_get_current_buf()), nil)
    vim.fn.chansend = original_send
  end)
  test("legacy automatic-preview preference is migrated", function()
    mdmaid.config.setup({ server = { auto_start = false, auto_stop = true } })
    equal(mdmaid.config.get().preview.auto_start, false)
    equal(mdmaid.config.get().desk.auto_start, true)
    equal(mdmaid.config.get().mdmaid_path, "mdmaid-desk")
  end)
end, debug.traceback)

mdmaid.preview.stop()
vim.fn.jobstart, vim.fn.jobstop = original_start, original_stop
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print(string.format("%d headless tests passed", passed))
vim.cmd("qa!")
