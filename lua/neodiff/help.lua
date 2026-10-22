local M = {}
local ui = require('neodiff.ui')
local lines = {
  ' Anywhere',
  '   ?                 Shortcut help',
  '   q                 Close NeoDiff',
  '   r                 Refresh comparison',
  '   Tab               Next panel',
  '   Ctrl-w + direction  Move between panels',
  '   ]f / [f           Next / previous file',
  '   ]c / [c           Next / previous hunk (across files)',
  '',
  ' Files',
  '   j / k             Move selection',
  '   Enter / double-click  View diff',
  '   o                 Open project file in a new tab',
  '',
  ' Diff panes',
  '   o                 Open project file in a new tab',
  '   gd                Go to definition in current project',
  '',
  ' Timeline',
  '   Enter             Pick target; below base, pick base',
  '   b                 Pick base (on target: swap sides)',
  '   o                 Expand / collapse branch; load more',
  '   Double-click      Pick entry; expand selected branch',
  '   Load more row     Scroll onto it to fetch more commits',
  '',
  ' Esc / q / ? / Enter to close help',
}

local function dimensions()
  local width = math.max(1, math.min(60, vim.o.columns - 4))
  local available = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local height = math.min(#lines, available)
  return {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
  }
end

function M.open(session)
  if session.help_win and vim.api.nvim_win_is_valid(session.help_win) then
    vim.api.nvim_set_current_win(session.help_win)
    return
  end
  local previous = vim.api.nvim_get_current_win()
  local buf = ui.create_readonly_buffer(lines)
  local opts = vim.tbl_extend('force', dimensions(), {
    style = 'minimal',
    border = 'rounded',
    title = ' NeoDiff shortcuts ',
    title_pos = 'center',
    zindex = 60,
  })
  local win = vim.api.nvim_open_win(buf, true, opts)
  session.help_win = win
  vim.wo[win].wrap = true
  vim.wo[win].winbar = ''
  vim.wo[win].scrolloff = 0

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      local focused = vim.api.nvim_get_current_win() == win
      vim.api.nvim_win_close(win, true)
      if focused and vim.api.nvim_win_is_valid(previous) then
        vim.api.nvim_set_current_win(previous)
      end
    end
  end
  for _, key in ipairs({ '<Esc>', 'q', '?', '<CR>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, silent = true, desc = 'Close shortcut help' })
  end
  local resize = vim.api.nvim_create_autocmd('VimResized', {
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, dimensions())
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      session.help_win = nil
      vim.api.nvim_del_autocmd(resize)
    end,
  })
end

return M
