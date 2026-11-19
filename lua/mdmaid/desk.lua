local config = require("mdmaid.config")
local session = require("mdmaid.session")
local uv = vim.uv or vim.loop

local M = {}
local active = false
local connection
local generation = 0
local jobs = {}
local queue = {}
local processing = false
local current_request

local function redact(message)
  return tostring(message):gsub("([?&]token=)[^%s&]+", "%1[redacted]")
end

local function report(message)
  vim.notify("mdmaid.desk: " .. redact(message), vim.log.levels.ERROR)
end

local function command(args)
  local executable = config.get().mdmaid_path
  local cmd = type(executable) == "table" and vim.deepcopy(executable) or { executable }
  vim.list_extend(cmd, args)
  return cmd
end

-- Buffered jobs preserve JSON even when stdout arrives in several chunks.
local function run(args, callback)
  local epoch = generation
  local finished = false
  local stdout, stderr = {}, {}
  local job
  local function finish(err)
    if finished then
      return
    end
    finished = true
    if job then
      jobs[job] = nil
    end
    if epoch == generation then
      callback(err, table.concat(stdout, "\n"))
    end
  end
  local ok, result = pcall(vim.fn.jobstart, command(args), {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data or {}
    end,
    on_stderr = function(_, data)
      stderr = data or {}
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local detail = vim.trim(table.concat(stderr, "\n"))
        finish(code ~= 0 and (detail ~= "" and detail or (args[1] .. " failed (exit " .. code .. ")")) or nil)
      end)
    end,
  })
  if not ok or result <= 0 then
    finish("Cannot run mdmaid-desk. Install it or set mdmaid_path to its executable.")
    return
  end
  job = result
  jobs[job] = true
  vim.defer_fn(function()
    if not finished and epoch == generation then
      finish(args[1] .. " timed out")
      vim.fn.jobstop(job)
    end
  end, config.get().desk.timeout)
end

function M.canonical_path(file)
  local path = uv.fs_realpath(vim.fn.fnamemodify(file, ":p"))
  return path and vim.fs.normalize(path) or nil
end

local function within(root, file)
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  return file == root or file:sub(1, #prefix) == prefix
end

local function parse_connection(output)
  local port = tonumber(output:match("port (%d+)%)"))
  local url = output:match("mdmaid%.desk web: (%S+)")
  if not port or port < 1 or port > 65535 or not url then
    return nil
  end
  local scheme, authority, token = url:match("^(https?)://([^/]+)/%?token=([^%s&#]+)$")
  if not scheme then
    return nil
  end
  local host, url_port = authority:match("^([%w%.%-]+):(%d+)$")
  if not host and authority:match("^[%w%.%-]+$") then
    host = authority
  end
  local ipv6 = authority == "[::1]" or authority:match("^%[::1%]:%d+$")
  if url_port and (tonumber(url_port) < 1 or tonumber(url_port) > 65535) then
    return nil
  end
  if not ipv6 and not (host == "localhost" or host == "127.0.0.1" or (host and host:match("%.localhost$"))) then
    return nil
  end
  return { origin = scheme .. "://" .. authority, token = token }
end

local function workspace_root(file)
  local configured = config.get().desk.root
  if configured then
    return M.canonical_path(vim.fn.expand(configured))
  end
  local directory = vim.fn.fnamemodify(file, ":h")
  local git = vim.fs.find(".git", { path = directory, upward = true })[1]
  return git and vim.fn.fnamemodify(git, ":h") or directory
end

local function resolve_workspace(file, callback)
  run({ "workspace", "list" }, function(err, output)
    if err then
      callback(err)
      return
    end
    local opts = config.get().desk
    local root = workspace_root(file)
    local stat = root and uv.fs_stat(root)
    if not stat or stat.type ~= "directory" or not within(root, file) then
      callback("desk.root must be an existing directory containing the document")
      return
    end
    local selected
    for line in output:gmatch("[^\r\n]+") do
      local id, path = line:match("^([^\t]+)\t[^\t]+\t(.+)$")
      path = path and M.canonical_path(path)
      if id and path then
        if opts.workspace and id == opts.workspace then
          if not within(path, file) then
            callback("Document is outside the configured desk workspace")
            return
          end
          callback(nil, id)
          return
        end
        if not opts.workspace and within(path, file) and (not opts.root or path == root) then
          if not selected or #path > #selected.path then
            selected = { id = id, path = path }
          end
        end
      end
    end
    if selected then
      callback(nil, selected.id)
      return
    end
    if opts.workspace and not opts.root then
      callback("Unknown desk.workspace. Register it first, or set desk.root to create it.")
      return
    end
    local id = opts.workspace or ("nvim-" .. vim.fn.sha256(root):sub(1, 16))
    run({ "workspace", "add", root, "--id", id, "--name", vim.fn.fnamemodify(root, ":t") }, function(add_err)
      callback(add_err, id)
    end)
  end)
end

local function publish(request, callback)
  local action = config.get().desk.auto_start and "start" or "status"
  run({ "daemon", action }, function(err, output)
    if err then
      callback(err .. (action == "status" and ". Start mdmaid-desk daemon or enable desk.auto_start." or ""))
      return
    end
    local service = parse_connection(output)
    if not service then
      callback("Desk did not return a local authenticated web URL; update mdmaid-desk and check daemon status.")
      return
    end
    resolve_workspace(request.file, function(workspace_err, workspace)
      if workspace_err then
        callback(workspace_err)
        return
      end
      run({ "register", request.file, "--workspace", workspace, "--live", "--producer", "mdmaid.nvim", "--json" },
        function(register_err, result)
          if register_err then
            callback(register_err)
            return
          end
          local ok, envelope = pcall(vim.json.decode, result)
          local document = ok and type(envelope) == "table" and envelope.document
          if type(document) ~= "table"
            or envelope.schemaVersion ~= 1
            or type(document.id) ~= "string"
            or not document.id:match("^doc%-%w+$")
            or type(document.revision) ~= "number"
            or document.revision < 1
            or document.revision % 1 ~= 0
            or document.route ~= "/d/" .. document.id
          then
            callback("Invalid registration response; update mdmaid-desk.")
            return
          end
          document.url = service.origin .. document.route
          callback(nil, document, service)
        end)
    end)
  end)
end

local pump
pump = function()
  if processing or #queue == 0 then
    return
  end
  processing = true
  local request = table.remove(queue, 1)
  current_request = request
  publish(request, function(err, document, service)
    processing = false
    current_request = nil
    if not request.cancelled then
      if err then
        report(err)
      else
        active = true
        connection = service
        session.add_file(request.file, document)
        if request.activate then
          session.set_current_file(request.file)
        end
        if request.callback then
          request.callback(document)
        end
      end
    end
    pump()
  end)
end

---Register a live source. State changes only after successful registration.
function M.start(file, callback, activate)
  file = file or vim.api.nvim_buf_get_name(0)
  local path = file ~= "" and M.canonical_path(file) or nil
  local stat = path and uv.fs_stat(path)
  if not path or not stat or stat.type ~= "file" or not path:lower():match("%.md$") then
    report("Open a saved, readable Markdown (.md) file first.")
    return false
  end
  table.insert(queue, { file = path, callback = callback, activate = activate ~= false })
  pump()
  return true
end

---Release this client; the shared service and registered sources remain live.
function M.stop()
  generation = generation + 1
  queue = {}
  processing = false
  current_request = nil
  active = false
  connection = nil
  local pending = jobs
  jobs = {}
  for job in pairs(pending) do
    vim.fn.jobstop(job)
  end
end

function M.is_running()
  return active or processing
end

function M.get_url()
  local document = session.get_document()
  return document and document.url or nil
end

function M.get_open_url(document, preview)
  document = document or session.get_document()
  if connection and document then
    local route = preview and preview.route or document.route
    return connection.origin .. route .. (route:find("?", 1, true) and "&" or "?") .. "token=" .. connection.token
  end
end

function M.get_current_file()
  return session.get_or_create().current_file
end

function M.get_files()
  return session.get_files()
end

function M.add_file(file)
  local path = M.canonical_path(file)
  if path and session.get_document(path) then
    session.add_file(path)
    return true
  end
  return M.start(file, nil, false)
end

function M.remove_file(file)
  local path = M.canonical_path(file) or vim.fn.fnamemodify(file, ":p")
  if current_request and current_request.file == path then
    current_request.cancelled = true
  end
  for _, request in ipairs(queue) do
    if request.file == path then
      request.cancelled = true
    end
  end
  require("mdmaid.live").stop(vim.fn.bufnr(path))
  session.remove_file(path)
end

function M.switch_file(file)
  require("mdmaid.preview").start(file)
end

function M.restart()
  local file = M.get_current_file() or vim.api.nvim_buf_get_name(0)
  require("mdmaid.preview").stop()
  require("mdmaid.preview").start(file)
end

M.command = command
return M
