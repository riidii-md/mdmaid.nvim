vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("mdmaid.config")
config.setup({ keymaps = false, preview = { sync_scroll = true } })
local terminal = require("mdmaid.terminal")
local live = require("mdmaid.live")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local path = root .. "/scroll.md"
local lines = {}
for i = 1, 200 do lines[i] = "Source line " .. i end
vim.fn.writefile(lines, path)
vim.cmd("edit " .. vim.fn.fnameescape(path))
vim.wo.wrap = false
vim.wo.foldenable = false
local source_buf = vim.api.nvim_get_current_buf()
local source_win = vim.api.nvim_get_current_win()
local old_termopen, old_jobstop, old_scroll = vim.fn.termopen, vim.fn.jobstop, live.set_scroll
local updates = {}
vim.fn.termopen = function() return vim.api.nvim_open_term(0, {}) end
vim.fn.jobstop = function() return 1 end
live.set_scroll = function(buf, progress)
  assert(buf == source_buf)
  updates[#updates + 1] = progress
  return true
end
local function scroll_to(line)
  terminal.source()
  vim.api.nvim_win_set_cursor(source_win, { line, 0 })
  vim.cmd("normal! zt")
  vim.cmd("redraw")
end
local events = {}
vim.api.nvim_create_autocmd("WinScrolled", {
  callback = function(event) events[#events + 1] = { match = event.match, details = vim.deepcopy(vim.v.event) } end,
})
local function finish(err)
  terminal.close()
  vim.fn.termopen, vim.fn.jobstop, live.set_scroll = old_termopen, old_jobstop, old_scroll
  vim.fn.delete(root, "rf")
  if err then
    io.stderr:write(tostring(err) .. "\nScroll events: " .. vim.json.encode(events) .. "\n")
    vim.cmd("cquit 1")
  end
  vim.cmd("qa!")
end
local function step(fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then finish(err) end
end
local function eventually(condition, next_step, message)
  local deadline = (vim.uv or vim.loop).hrtime() + 2000000000
  local function check()
    step(function()
      if condition() then next_step()
      elseif (vim.uv or vim.loop).hrtime() > deadline then finish(message)
      else vim.defer_fn(check, 10) end
    end)
  end
  vim.defer_fn(check, 10)
end
step(function()
  terminal.open({ id = "doc-11111111111111111111" }, { id = "preview-" .. string.rep("a", 32) },
    terminal.capture(source_buf), "split")
  terminal.source()
  vim.cmd("redraw")
  eventually(function() return #updates > 0 end, function()
    local before = #updates
    scroll_to(100)
    local cursor = vim.api.nvim_win_get_cursor(source_win)
    eventually(function() return #updates > before and updates[#updates] > 0.3 end, function()
      assert(vim.api.nvim_get_current_win() == source_win, "Scroll sync stole focus")
      assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(source_win)), "Scroll sync moved source cursor")
      print("PASS native source scrolling synchronizes without moving focus or cursor")
      before = #updates
      scroll_to(200)
      eventually(function() return #updates > before and updates[#updates] == 1 end, function()
        before = #updates
        scroll_to(1)
        eventually(function() return #updates > before and updates[#updates] == 0 end, function()
          print("PASS document start and end synchronize")
          config.get().preview.sync_scroll = false
          before = #updates
          scroll_to(80)
          vim.defer_fn(function()
            step(function()
              assert(#updates == before, "Disabled scroll synchronization still sent updates")
              config.get().preview.sync_scroll = true
              terminal.close()
              terminal.open({ id = "doc-11111111111111111111" }, { id = "preview-" .. string.rep("a", 32) },
                terminal.capture(source_buf), "replace")
              vim.defer_fn(function()
                step(function()
                  assert(#updates == before, "Replacement views should not synchronize two windows")
                  terminal.source()
                  assert(vim.api.nvim_buf_get_lines(source_buf, 99, 100, false)[1] == "Source line 100")
                  print("PASS synchronization can be disabled and stays inactive in replacement views")
                  terminal.close()
                  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { string.rep("wrapped paragraph ", 500) })
                  vim.wo[source_win].wrap = true
                  terminal.open({ id = "doc-11111111111111111111" }, { id = "preview-" .. string.rep("a", 32) },
                    terminal.capture(source_buf), "split")
                  terminal.source()
                  vim.cmd("normal! gg0")
                  vim.cmd("redraw")
                  eventually(function() return updates[#updates] == 0 end, function()
                    before = #updates
                    vim.cmd("normal! 30gjzt")
                    vim.cmd("redraw")
                    eventually(function() return #updates > before and updates[#updates] > 0 end, function()
                      assert(vim.fn.winsaveview().topline == 1, "Test must scroll inside one wrapped line")
                      print("PASS scrolling within a wrapped paragraph synchronizes")
                      finish()
                    end, "Wrapped-line scrolling did not synchronize")
                  end, "Wrapped source did not start at the top")
                end)
              end, 120)
            end)
          end, 120)
        end, "Source start did not reach preview start")
      end, "Source end did not reach preview end")
    end, "Native source scrolling did not synchronize")
  end, "Initial source viewport was not synchronized")
end)
