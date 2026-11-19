local config = require("mdmaid.config")
local desk = require("mdmaid.desk")
local live = require("mdmaid.live")
local terminal = require("mdmaid.terminal")
local M = { browser_opened = false }
local latest_open = 0

local function open_command(url)
  local browser = config.get().preview.browser
  if browser then
    local cmd = type(browser) == "table" and vim.deepcopy(browser) or { browser }
    table.insert(cmd, url)
    return cmd
  end
  local sysname = (vim.uv or vim.loop).os_uname().sysname
  if sysname == "Darwin" then return { "open", url }
  elseif sysname == "Windows_NT" then return { "rundll32", "url.dll,FileProtocolHandler", url } end
  return { "xdg-open", url }
end

function M.open_browser(url)
  if not url then return M.web() end
  local ok, job = pcall(vim.fn.jobstart, open_command(url), {
    detach = true,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.schedule(function()
          M.browser_opened = false
          vim.notify("Failed to open mdmaid.desk in browser", vim.log.levels.WARN)
        end)
      end
    end,
  })
  M.browser_opened = ok and job > 0
  if not M.browser_opened then vim.notify("Failed to launch browser", vim.log.levels.WARN) end
end

local function source_buffer(file)
  if not file and vim.bo.buftype == "terminal" then
    local original = terminal.get_source()
    if original and vim.api.nvim_buf_is_valid(original.buf) then
      return original.buf, vim.api.nvim_buf_get_name(original.buf), original
    end
  end
  file = file or vim.api.nvim_buf_get_name(0)
  local buf = vim.fn.bufnr(file)
  if buf == -1 then buf = vim.fn.bufadd(file) end
  if buf ~= 0 and not vim.api.nvim_buf_is_loaded(buf) then vim.fn.bufload(buf) end
  if buf == 0 then buf = vim.api.nvim_get_current_buf() end
  return buf, file, terminal.capture(buf)
end

local function launch(file, target, layout, open_browser)
  local buf, path, source = source_buffer(file)
  latest_open = latest_open + 1
  local request = latest_open
  return desk.start(path, function(document)
    if request ~= latest_open or not vim.api.nvim_buf_is_valid(buf) then return end
    live.attach(buf, document, function(info)
      if request ~= latest_open then return end
      if target == "tui" then terminal.open(document, info, source, layout)
      elseif open_browser then M.open_browser(desk.get_open_url(document, info)) end
    end)
  end)
end

function M.start(file, open_browser)
  if open_browser == nil then open_browser = config.get().preview.open_browser end
  return launch(file, config.get().preview.target, config.get().preview.layout, open_browser)
end

function M.web(file)
  return launch(file, "web", nil, true)
end

function M.tui(file, layout)
  return launch(file, "tui", layout or config.get().preview.layout, false)
end

function M.source()
  terminal.source()
end

function M.stop()
  latest_open = latest_open + 1
  terminal.close()
  live.stop_all()
  desk.stop()
  M.browser_opened = false
end

function M.toggle(file)
  if config.get().preview.target == "tui" then
    if terminal.is_visible() then terminal.source() else M.start(file) end
  elseif desk.is_running() then M.stop()
  else M.start(file) end
end

function M.status()
  local document = require("mdmaid.session").get_document()
  return {
    server_running = desk.is_running(), connected = desk.is_running(),
    browser_opened = M.browser_opened, tui_opened = terminal.is_open(),
    url = desk.get_url(), document_id = document and document.id,
    file = desk.get_current_file(), files = desk.get_files(),
  }
end

return M
