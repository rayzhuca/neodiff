-- Resolve snapshot locations through the real project buffer and its LSP clients.
local M = {}
local ui = require('neodiff.ui')

local function project_line(snapshot, current, line)
  local offset = 0
  for _, hunk in
    ipairs(
      vim.diff(
        table.concat(snapshot, '\n') .. '\n',
        table.concat(current, '\n') .. '\n',
        { result_type = 'indices' }
      )
    )
  do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    if old_count == 0 then
      if line <= old_start then
        break
      end
    elseif line < old_start then
      break
    elseif line < old_start + old_count then
      -- Deleted lines have no location in the current checkout.
      if new_count == 0 then
        return nil
      end
      return new_start + math.min(line - old_start, new_count - 1)
    end
    offset = offset + new_count - old_count
  end
  return line + offset
end

local function open_project(root, file, side, placeholder, require_location)
  local snapshot_buf = vim.api.nvim_get_current_buf()
  if require_location and (placeholder or vim.b[snapshot_buf].neodiff_empty) then
    error('No source code in this pane.', 0)
  end
  -- The destination path is the current name after a rename, including from the
  -- old side. Fall back to the old path when comparing revisions in reverse.
  local paths = { file.path, file.old_path }
  if side == 'left' and file.status ~= 'R' then
    paths = { file.old_path, file.path }
  end
  local path
  for _, relative in ipairs(paths) do
    local candidate = root .. '/' .. relative
    if vim.fn.filereadable(candidate) == 1 then
      path = candidate
      break
    end
  end
  if not path then
    error('File is not present in the current checkout: ' .. file.path, 0)
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local display = require('neodiff.alignment').source(snapshot_buf)
  local snapshot = display and display.source
    or vim.api.nvim_buf_get_lines(snapshot_buf, 0, -1, false)
  if display then
    local source_line = display.numbers[cursor[1]] or 0
    if source_line == 0 and require_location then
      error('No source code on this padding row.', 0)
    end
    -- Opening from padding goes to the next real line, or the end of the file.
    if source_line == 0 then
      for row = cursor[1], #display.numbers do
        if display.numbers[row] > 0 then
          source_line = display.numbers[row]
          break
        end
      end
    end
    cursor[1] = source_line > 0 and source_line or math.max(1, #snapshot)
  end
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  -- Reuse loaded buffers, including unsaved edits, without reloading them.
  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local line, column = 1, 0
  if side and not placeholder and not vim.b[snapshot_buf].neodiff_empty then
    line = project_line(snapshot, current, cursor[1])
    if not line and require_location then
      error('This line was deleted from the current project file.', 0)
    end
    line = line or math.min(cursor[1], #current)
    column = math.min(cursor[2], math.max(0, #current[line] - 1))
  end

  vim.cmd('tabnew')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].buflisted = true
  if vim.bo[buf].filetype == '' then
    vim.bo[buf].filetype = vim.filetype.match({ buf = buf }) or ''
  end
  vim.api.nvim_win_set_cursor(win, { line, column })

  return win, buf, line, column
end

function M.open_file(root, file, side, placeholder)
  open_project(root, file, side, placeholder, false)
end

function M.definition(root, file, side, placeholder)
  local win, buf, line, column = open_project(root, file, side, placeholder, true)

  -- Opening a file may start its server. Give it time to attach, but abandon
  -- the pending lookup if the user moves elsewhere in the meantime.
  local attempts = 0
  local function lookup()
    if
      not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_get_current_win() ~= win
      or vim.api.nvim_win_get_buf(win) ~= buf
      or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), { line, column })
    then
      return
    end
    if #vim.lsp.get_clients({ bufnr = buf, method = 'textDocument/definition' }) > 0 then
      ui.with_error_notification(vim.lsp.buf.definition)()
    elseif attempts < 60 then
      attempts = attempts + 1
      vim.defer_fn(lookup, 50)
    else
      vim.notify(
        'NeoDiff: No language server with definition support attached. '
          .. 'The project file is open; retry go to definition once its server is ready.',
        vim.log.levels.WARN
      )
    end
  end
  lookup()
end

function M.attach(buf, root, file, side, placeholder)
  vim.keymap.set(
    'n',
    'o',
    ui.with_error_notification(function()
      M.open_file(root, file, side, placeholder)
    end),
    { buffer = buf, silent = true, desc = 'Open project file in a new tab' }
  )
  vim.keymap.set(
    'n',
    'gd',
    ui.with_error_notification(function()
      M.definition(root, file, side, placeholder)
    end),
    { buffer = buf, silent = true, desc = 'Go to definition in current project' }
  )
end

return M
