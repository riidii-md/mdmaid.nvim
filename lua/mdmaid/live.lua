local config = require("mdmaid.config")
local desk = require("mdmaid.desk")
local M = {}
local streams = {}

local function warn(message)
  vim.notify("mdmaid.desk: " .. tostring(message):gsub("([?&]token=)[^%s&]+", "%1[redacted]"), vim.log.levels.ERROR)
end

function M.stop(buf)
  local state = streams[buf]
  if not state then return end
  streams[buf] = nil
  state.stopped = true
  if state.job then
    pcall(vim.fn.chanclose, state.job, "stdin")
    pcall(vim.fn.jobstop, state.job)
  end
end

function M.stop_all()
  local buffers = vim.tbl_keys(streams)
  for _, buf in ipairs(buffers) do M.stop(buf) end
end

function M.get(buf)
  return streams[buf] and streams[buf].info
end

local function send(state)
  if state.stopped or not vim.api.nvim_buf_is_valid(state.buf) then return false end
  if desk.canonical_path(vim.api.nvim_buf_get_name(state.buf)) ~= state.path then
    M.stop(state.buf)
    return false
  end
  local version = math.max(1, vim.api.nvim_buf_get_changedtick(state.buf))
  local update = { version = version }
  if state.sent_version ~= version then
    local content = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    if vim.bo[state.buf].endofline then content = content .. "\n" end
    if #content > 2 * 1024 * 1024 then
      warn("Live buffer preview exceeds 2 MiB")
      return false
    end
    update.content = content
  end
  if state.scroll_progress ~= nil and state.sent_scroll_progress ~= state.scroll_progress then
    update.scroll = state.scroll_progress
  end
  if update.content == nil and update.scroll == nil then return true end
  local ok, sent = pcall(vim.fn.chansend, state.job, vim.json.encode(update) .. "\n")
  if not ok or sent == 0 then
    warn("Cannot send buffer updates; update mdmaid-desk and reopen the preview")
    M.stop(state.buf)
    return false
  end
  state.sent_version = version
  if update.scroll ~= nil then state.sent_scroll_progress = update.scroll end
  return true
end

function M.set_scroll(buf, progress)
  local state = streams[buf]
  -- Older desk services keep live typing working without viewport control.
  if not state or not state.info or not state.info.viewport then return false end
  if type(progress) ~= "number" or progress ~= progress then return false end
  state.scroll_progress = math.max(0, math.min(1, progress))
  return send(state)
end

function M.attach(buf, document, callback)
  if not config.get().preview.live then callback(nil); return end
  local previous = streams[buf]
  if previous and previous.document_id == document.id then
    if previous.info then callback(previous.info)
    else table.insert(previous.callbacks, callback) end
    return
  end
  M.stop(buf)
  local state = {
    buf = buf, path = desk.canonical_path(vim.api.nvim_buf_get_name(buf)),
    document_id = document.id, callbacks = { callback }, output = "", stderr = "", serial = 0,
  }
  streams[buf] = state
  local function consume(data)
    state.output = state.output .. table.concat(data or {}, "\n")
    while true do
      local boundary = state.output:find("\n", 1, true)
      if not boundary then break end
      local line = state.output:sub(1, boundary - 1)
      state.output = state.output:sub(boundary + 1)
      if line ~= "" then
        local ok, receipt = pcall(vim.json.decode, line)
        local info = ok and type(receipt) == "table" and receipt.preview
        if type(info) ~= "table" or receipt.schemaVersion ~= 1
          or type(info.id) ~= "string" or not info.id:match("^preview%-%x+$")
          or #info.id ~= 40 or info.documentId ~= document.id
          or type(info.version) ~= "number"
          or info.route ~= "/d/" .. document.id .. "?preview=" .. info.id then
          warn("Invalid live preview receipt from mdmaid-desk")
          M.stop(buf)
          return
        end
        state.info = info
        local callbacks = state.callbacks
        state.callbacks = {}
        for _, ready in ipairs(callbacks) do ready(info) end
      end
    end
  end
  local ok, job = pcall(vim.fn.jobstart, desk.command({ "preview", "--document", document.id }), {
    on_stdout = function(_, data)
      vim.schedule(function()
        if streams[buf] == state then consume(data) end
      end)
    end,
    stderr_buffered = true,
    on_stderr = function(_, data) state.stderr = table.concat(data or {}, "\n") end,
    on_exit = function(_, code)
      vim.schedule(function()
        if streams[buf] == state then
          streams[buf] = nil
          state.stopped = true
          if code ~= 0 then
            warn(vim.trim(state.stderr) ~= "" and state.stderr
              or "Live preview disconnected. Update mdmaid-desk and restart its shared daemon.")
          end
        end
      end)
    end,
  })
  if not ok or job <= 0 then
    streams[buf] = nil
    warn("Cannot start live buffer preview; update mdmaid-desk or set preview.live=false for saved files")
    return
  end
  state.job = job
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if streams[buf] ~= state then return true end
      state.serial = state.serial + 1
      local serial = state.serial
      vim.defer_fn(function()
        if streams[buf] == state and state.serial == serial then send(state) end
      end, config.get().preview.debounce)
    end,
    on_detach = function()
      if streams[buf] == state then M.stop(buf) end
    end,
  })
  send(state)
  vim.defer_fn(function()
    if streams[buf] == state and not state.info then
      warn("Timed out starting live preview; update mdmaid-desk and restart its shared daemon")
      M.stop(buf)
    end
  end, config.get().desk.timeout)
end

return M
