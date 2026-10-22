-- Let Neovim's scrollbind do all alignment. Wheel input must run as a
-- normal scroll in a diff window: native wheel input in an unfocused window
-- bypasses scrollbind entirely.
local M = {}

function M.attach(buf, session)
  for _, direction in ipairs({ 'Up', 'Down' }) do
    for _, modifier in ipairs({ '', 'S-', 'C-' }) do
      local key = '<' .. modifier .. 'ScrollWheel' .. direction .. '>'
      vim.keymap.set('n', key, function()
        local mouse = vim.fn.getmousepos()
        local win = mouse.winid
        if
          (win ~= session.left_win and win ~= session.right_win)
          or not vim.api.nvim_win_is_valid(win)
          or not vim.b[vim.api.nvim_win_get_buf(win)].neodiff_view
        then
          vim.cmd.normal({
            args = { vim.api.nvim_replace_termcodes(key, true, false, true) },
            bang = true,
          })
          return
        end
        local amount = modifier == '' and (tonumber(vim.o.mousescroll:match('ver:(%d+)')) or 3)
          or math.max(1, vim.api.nvim_win_get_height(win) - 2)
        if amount == 0 then
          return
        end
        vim.api.nvim_win_call(win, function()
          local command = direction == 'Down' and '<C-E>' or '<C-Y>'
          vim.cmd.normal({
            args = { amount .. vim.api.nvim_replace_termcodes(command, true, false, true) },
            bang = true,
          })
        end)
      end, { buffer = buf, silent = true, desc = 'Scroll diff ' .. direction:lower() })
    end
  end
end

return M
