-- This session belongs only to Neovim. The desk owns durable document state.
local M = { current = nil }

function M.get_or_create()
  if not M.current then
    M.current = { files = {}, documents = {}, current_file = nil }
  end
  return M.current
end

function M.add_file(file, document)
  local state = M.get_or_create()
  if not vim.tbl_contains(state.files, file) then
    table.insert(state.files, file)
  end
  if document then
    state.documents[file] = document
  end
end

function M.set_current_file(file)
  M.add_file(file)
  M.current.current_file = file
end

function M.remove_file(file)
  local state = M.get_or_create()
  state.files = vim.tbl_filter(function(path)
    return path ~= file
  end, state.files)
  state.documents[file] = nil
  if state.current_file == file then
    state.current_file = nil
    for _, path in ipairs(state.files) do
      if state.documents[path] then
        state.current_file = path
        break
      end
    end
  end
end

function M.get_document(file)
  local state = M.get_or_create()
  return state.documents[file or state.current_file]
end

function M.get_files()
  return M.get_or_create().files
end

function M.delete()
  M.current = nil
end

return M
