-- The "Files Changed" sidebar.
local M = {}
local ui = require('neodiff.ui')
local keymaps = require('neodiff.keymaps')
local selection_namespace = vim.api.nvim_create_namespace('neodiff')
local status_namespace = vim.api.nvim_create_namespace('neodiff_file_status')
local status_highlights =
  { M = 'NeoDiffStatusModified', D = 'NeoDiffStatusDeleted', U = 'NeoDiffStatusUntracked' }

function M.render(session)
  local comparison = session.comparison
  local names = {}

  for _, file in ipairs(comparison.files) do
    local name = file.path
    if file.status == 'R' then
      name = file.old_path .. ' → ' .. file.path
    end
    names[#names + 1] = ' ' .. file.status .. '  ' .. name:gsub('[\r\n\t]', ' ')
  end

  session.files_buf = ui.create_readonly_buffer(#names > 0 and names or { ' No changed files' })
  for index, file in ipairs(comparison.files) do
    local highlight = status_highlights[file.status]
    if highlight then
      vim.api.nvim_buf_set_extmark(session.files_buf, status_namespace, index - 1, 0, {
        end_col = #names[index],
        hl_group = highlight,
      })
    end
  end
  vim.api.nvim_win_set_buf(session.files_win, session.files_buf)
  ui.configure_panel_window(session.files_win)
  vim.wo[session.files_win].cursorline = true
  ui.set_panel_header(session.files_win, 'Files Changed  (' .. #names .. ')')
  -- A nonempty blank value suppresses the global statusline for this window.
  vim.wo[session.files_win].statusline = ' '
  keymaps.attach(session.files_buf, session)

  local view_diff = ui.with_error_notification(function()
    session.actions.select_file(vim.api.nvim_win_get_cursor(session.files_win)[1])
  end)
  for _, key in ipairs({ '<CR>', '<2-LeftMouse>' }) do
    vim.keymap.set('n', key, view_diff, { buffer = session.files_buf, desc = 'View diff' })
  end
end

function M.mark_selected(session, index)
  vim.api.nvim_buf_clear_namespace(session.files_buf, selection_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(
    session.files_buf,
    selection_namespace,
    index - 1,
    0,
    { line_hl_group = 'Visual' }
  )
  vim.api.nvim_win_set_cursor(session.files_win, { index, 0 })
end

return M
