local M = {}

-- Files over Timeline on the left, then the left and right diff panes.
function M.create(session)
  session.files_win = vim.api.nvim_get_current_win()

  vim.cmd('rightbelow vsplit')
  session.left_win = vim.api.nvim_get_current_win()

  vim.cmd('rightbelow vsplit')
  session.right_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(session.files_win)
  vim.cmd('rightbelow split')
  session.stack_win = vim.api.nvim_get_current_win()
end

-- Splits the space right of the sidebar evenly between the two diff panes.
function M.equalize_diff_panes(session)
  if
    not vim.api.nvim_win_is_valid(session.left_win)
    or not vim.api.nvim_win_is_valid(session.right_win)
  then
    return
  end
  local left = vim.api.nvim_win_get_width(session.left_win)
  local right = vim.api.nvim_win_get_width(session.right_win)
  local width = math.floor((left + right) / 2)
  if left ~= width then
    vim.api.nvim_win_set_width(session.left_win, width)
  end
end

function M.apply_dimensions(session, config)
  vim.api.nvim_win_set_width(session.files_win, config.sidebar_width)
  vim.wo[session.files_win].winfixwidth = true
  vim.wo[session.stack_win].winfixwidth = true

  vim.api.nvim_win_set_height(session.stack_win, config.stack_height)
  vim.wo[session.stack_win].winfixheight = true
  M.equalize_diff_panes(session)
end

return M
