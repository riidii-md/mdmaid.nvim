local desk = require("mdmaid.desk")
local config = require("mdmaid.config")
local M = {}
local state

local preview_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  winbar = "",
}

local function window_options(win)
  local options = {}
  for name in pairs(preview_options) do options[name] = vim.wo[win][name] end
  return options
end

local function configure_window(win, options)
  for name, value in pairs(options) do vim.wo[win][name] = value end
end

function M.capture(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local win = vim.fn.bufwinid(buf)
  local view
  if win ~= -1 then
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end
  return { buf = buf, win = win ~= -1 and win or vim.api.nvim_get_current_win(), view = view }
end

function M.get_source()
  return state and state.source
end

function M.is_visible()
  return state ~= nil and vim.fn.bufwinid(state.buf) ~= -1
end

function M.is_open()
  return state ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

local function show(win, buf, view)
  vim.api.nvim_win_call(win, function()
    -- :hide preserves modified source buffers even when 'hidden' is disabled.
    vim.cmd("hide buffer " .. buf)
    if view then vim.fn.winrestview(view) end
  end)
end

function M.sync_scroll()
  local current = state
  if not current or current.layout ~= "split" or not current.preview_id
    or not config.get().preview.sync_scroll then return end
  current.scroll_serial = (current.scroll_serial or 0) + 1
  local serial = current.scroll_serial
  vim.defer_fn(function()
    if state ~= current or current.scroll_serial ~= serial or not config.get().preview.sync_scroll
      or not vim.api.nvim_win_is_valid(current.source.win)
      or not vim.api.nvim_win_is_valid(current.win)
      or vim.api.nvim_win_get_buf(current.source.win) ~= current.source.buf
      or vim.api.nvim_win_get_buf(current.win) ~= current.buf then return end
    local info = vim.fn.getwininfo(current.source.win)[1]
    if not info then return end
    local progress
    if vim.api.nvim_win_text_height then
      -- Screen rows also follow folds and scrolling within a wrapped paragraph.
      local view = vim.api.nvim_win_call(current.source.win, vim.fn.winsaveview)
      local total = vim.api.nvim_win_text_height(current.source.win, {}).all
      local offset = vim.api.nvim_win_text_height(current.source.win, {
        end_row = info.topline - 1, end_vcol = view.skipcol or 0,
      }).all
      local remaining = total - info.height
      progress = remaining > 0 and offset / remaining or 0
    else
      local count = vim.api.nvim_buf_line_count(current.source.buf)
      local visible = math.max(1, math.min(count, info.botline - info.topline + 1))
      local remaining = count - visible
      progress = remaining > 0 and (info.topline - 1) / remaining or 0
    end
    progress = math.max(0, math.min(1, progress))
    if progress == current.source_progress then return end
    if require("mdmaid.live").set_scroll(current.source.buf, progress) then
      current.source_progress = progress
    end
  end, 40)
end

local scroll_group = vim.api.nvim_create_augroup("MdmaidScroll", { clear = true })
vim.api.nvim_create_autocmd("WinScrolled", {
  group = scroll_group,
  callback = function(event)
    if state and (tonumber(event.match) == state.source.win or vim.v.event[tostring(state.source.win)]) then
      M.sync_scroll()
    end
  end,
})

function M.source()
  if not state or not vim.api.nvim_buf_is_valid(state.source.buf) then return end
  local source = state.source
  vim.cmd("stopinsert")
  local existing = vim.fn.bufwinid(source.buf)
  if existing ~= -1 then
    if existing == state.win then configure_window(existing, state.window_options) end
    vim.api.nvim_set_current_win(existing)
    return
  end
  local win = vim.api.nvim_win_is_valid(source.win) and source.win
    or (vim.api.nvim_win_is_valid(state.win) and state.win or vim.api.nvim_get_current_win())
  vim.api.nvim_set_current_win(win)
  show(win, source.buf, source.view)
  if win == state.win then configure_window(win, state.window_options) end
end

function M.close()
  if not state then return end
  local previous = state
  M.source()
  state = nil
  if previous.job then pcall(vim.fn.jobstop, previous.job) end
  if vim.api.nvim_win_is_valid(previous.win)
    and vim.api.nvim_win_get_buf(previous.win) == previous.buf and previous.layout == "split" then
    pcall(vim.api.nvim_win_close, previous.win, true)
  end
  if vim.api.nvim_buf_is_valid(previous.buf) then
    pcall(vim.api.nvim_buf_delete, previous.buf, { force = true })
  end
end

function M.open(document, preview, source, layout)
  layout = layout or config.get().preview.layout
  if state and state.layout == layout and state.document_id == document.id and state.preview_id == (preview and preview.id)
    and vim.api.nvim_buf_is_valid(state.buf) then
    state.source = source
    if not vim.api.nvim_win_is_valid(state.win) then state.win = vim.api.nvim_get_current_win() end
    vim.api.nvim_set_current_win(state.win)
    if vim.api.nvim_win_get_buf(state.win) ~= state.buf then
      state.window_options = window_options(state.win)
    end
    show(state.win, state.buf)
    configure_window(state.win, preview_options)
    M.sync_scroll()
    vim.cmd("startinsert")
    return
  end
  M.close()
  if vim.api.nvim_win_is_valid(source.win) then vim.api.nvim_set_current_win(source.win) end
  if layout == "split" then vim.cmd("botright vsplit") end
  local win = vim.api.nvim_get_current_win()
  local original_options = window_options(win)
  local buf = vim.api.nvim_create_buf(false, true)
  show(win, buf)
  configure_window(win, preview_options)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  local current = { buf = buf, win = win, source = source, layout = layout, window_options = original_options,
    document_id = document.id, preview_id = preview and preview.id }
  state = current
  local args = { "tui", "--document", document.id }
  if preview then vim.list_extend(args, { "--preview", preview.id }) end
  local ok, job = pcall(vim.fn.termopen, desk.command(args), {
    on_exit = function(_, code)
      vim.schedule(function()
        if state == current then
          M.close()
          if code ~= 0 then
            vim.notify("mdmaid-desk TUI exited with code " .. code .. "; update desk if --document is unsupported", vim.log.levels.ERROR)
          end
        end
      end)
    end,
  })
  if not ok or job <= 0 then
    M.close()
    vim.notify("Cannot open mdmaid-desk TUI", vim.log.levels.ERROR)
    return
  end
  current.job = job
  M.sync_scroll()
  local keys = config.get().keymaps
  if keys and keys.source then
    vim.keymap.set({ "n", "t" }, keys.source, M.source, { buffer = buf, desc = "Return to Markdown source" })
  end
  vim.cmd("startinsert")
end

return M
