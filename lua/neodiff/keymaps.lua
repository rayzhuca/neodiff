-- Keymaps shared by every panel buffer. Actions come from the session so panels
-- never depend on the module that orchestrates them.
local M = {}
local ui = require('neodiff.ui')

function M.attach(buf, session)
  require('neodiff.scroll').attach(buf, session)
  local actions = session.actions
  local function map(key, fn, desc)
    vim.keymap.set(
      'n',
      key,
      ui.with_error_notification(fn),
      { buffer = buf, silent = true, desc = desc }
    )
  end

  map('?', function()
    require('neodiff.help').open(session)
  end, 'Show NeoDiff shortcuts')
  map('q', actions.close, 'Close NeoDiff')
  map('r', actions.refresh, 'Refresh changes')
  map(']f', function()
    actions.select_file(session.index + 1)
  end, 'Next changed file')
  map('[f', function()
    actions.select_file(session.index - 1)
  end, 'Previous changed file')
  map(']c', function()
    actions.jump_to_hunk(1)
  end, 'Next diff hunk')
  map('[c', function()
    actions.jump_to_hunk(-1)
  end, 'Previous diff hunk')
  map('<Tab>', function()
    local wins = { session.files_win, session.left_win, session.right_win, session.stack_win }
    for i, win in ipairs(wins) do
      if win == vim.api.nvim_get_current_win() then
        vim.api.nvim_set_current_win(wins[i % #wins + 1])
        return
      end
    end
  end, 'Next NeoDiff panel')
end

return M
