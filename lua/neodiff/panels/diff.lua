-- The left (base) and right (target) diff panes and the header spanning both.
local M = {}
local git = require('neodiff.git')
local ui = require('neodiff.ui')
local keymaps = require('neodiff.keymaps')

function M.update_header(session, title)
  if
    not vim.api.nvim_win_is_valid(session.left_win)
    or not vim.api.nvim_win_is_valid(session.right_win)
  then
    return
  end

  local left = vim.api.nvim_win_get_position(session.left_win)
  local right = vim.api.nvim_win_get_position(session.right_win)
  local opts = {
    relative = 'editor',
    row = left[1],
    col = left[2],
    width = right[2] + vim.api.nvim_win_get_width(session.right_win) - left[2],
    height = 1,
    focusable = false,
    style = 'minimal',
    border = 'none',
    zindex = 40,
  }

  if not session.header_win or not vim.api.nvim_win_is_valid(session.header_win) then
    session.header_buf = ui.create_readonly_buffer({ '' })
    session.header_win = vim.api.nvim_open_win(session.header_buf, false, opts)
    vim.wo[session.header_win].winhighlight = 'Normal:WinBar,NormalNC:WinBar'
    vim.wo[session.header_win].winblend = 0
    vim.wo[session.header_win].winbar = ''
  else
    vim.api.nvim_win_set_config(session.header_win, opts)
  end

  if title then
    vim.bo[session.header_buf].modifiable = true
    vim.api.nvim_buf_set_lines(
      session.header_buf,
      0,
      -1,
      false,
      { ' ' .. title:gsub('[\r\n\t]', ' ') }
    )
    vim.bo[session.header_buf].modifiable = false
  end
end

-- Shows a placeholder in both panes until a file is selected.
function M.reset(session)
  for _, side in ipairs({ 'left', 'right' }) do
    vim.api.nvim_win_call(session[side .. '_win'], function()
      vim.cmd('diffoff')
    end)
    local message = 'No changes between these selections.'
    local buf = ui.create_readonly_buffer({ message })
    vim.api.nvim_win_set_buf(session[side .. '_win'], buf)
    ui.configure_panel_window(session[side .. '_win'])
    -- Reserve a row for the single header spanning both diff windows.
    ui.set_panel_header(session[side .. '_win'], '')
    vim.wo[session[side .. '_win']].statusline = ' '
    keymaps.attach(buf, session)
  end
  M.update_header(session, 'No changed files')
end

function M.show_file(session, file)
  -- Read both versions before replacing either pane.
  local left, left_is_placeholder = git.read_file_at_revision(session.comparison, file, 'left')
  local right, right_is_placeholder = git.read_file_at_revision(session.comparison, file, 'right')

  for _, side in ipairs({ 'left', 'right' }) do
    local win = session[side .. '_win']
    local lines = side == 'left' and left or right
    local is_placeholder = (side == 'left' and left_is_placeholder)
      or (side == 'right' and right_is_placeholder)
    local filetype = not is_placeholder and vim.filetype.match({ filename = file.path }) or nil
    local buf = ui.create_readonly_buffer(lines, filetype or 'text')

    vim.api.nvim_win_set_buf(win, buf)
    keymaps.attach(buf, session)
    vim.api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
    vim.wo[win].foldenable = false
    -- On diff lines Neovim draws CursorLine as an underline; highlight only the number.
    vim.wo[win].cursorlineopt = 'number'
    vim.wo[win].number = true
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
    local fillchars = vim.o.fillchars
    vim.wo[win].fillchars = (fillchars == '' and '' or fillchars .. ',') .. 'diff: '

    local tone = side == 'left' and 'Delete' or 'Add'
    vim.wo[win].winhighlight = string.format(
      'DiffAdd:NeoDiff%s,DiffChange:NeoDiff%s,DiffText:NeoDiff%sText,DiffDelete:NeoDiffFiller',
      tone,
      tone,
      tone
    )
    vim.wo[win].statusline = ' '
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end

  M.update_header(session, file.path)
  vim.cmd('diffupdate')
end

-- Start lines of the current window's hunks. Unlike native ]c, which stops at each
-- 'linematch' sub-block, a hunk spans every adjacent changed line and filler row.
local function diff_hunk_starts()
  local starts, in_hunk = {}, false
  local line_count = vim.api.nvim_buf_line_count(0)
  for lnum = 1, line_count + 1 do
    -- Filler rows sit above lnum and stand for lines that only exist on the other side.
    if vim.fn.diff_filler(lnum) > 0 and not in_hunk then
      starts[#starts + 1] = math.min(lnum, line_count)
      in_hunk = true
    end
    if lnum > line_count then
      break
    end
    local changed = vim.fn.diff_hlID(lnum, 1) ~= 0
    if changed and not in_hunk then
      starts[#starts + 1] = lnum
    end
    in_hunk = changed
  end
  return starts
end

local function move_to_hunk(direction)
  local cursor = vim.fn.line('.')
  local starts = diff_hunk_starts()
  for index = direction > 0 and 1 or #starts, direction > 0 and #starts or 1, direction do
    local start = starts[index]
    if (direction > 0 and start > cursor) or (direction < 0 and start < cursor) then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { start, 0 })
      return true
    end
  end
  return false
end

-- Works from any panel: outside the diff panes it moves the right pane. Past the first
-- or last hunk it continues into the previous or next file that has changes.
function M.jump_to_hunk(session, direction)
  local current = vim.api.nvim_get_current_win()
  local win = (current == session.left_win or current == session.right_win) and current
    or session.right_win
  for _ = 1, vim.v.count1 do
    if not vim.api.nvim_win_call(win, function()
      return move_to_hunk(direction)
    end) then
      local original = session.index
      local index, starts = original + direction, nil
      while session.comparison.files[index] do
        session.actions.select_file(index)
        starts = vim.api.nvim_win_call(win, diff_hunk_starts)
        if #starts > 0 then
          break
        end
        starts, index = nil, index + direction
      end
      if not starts then
        if session.index ~= original then
          session.actions.select_file(original)
        end
        return
      end
      vim.api.nvim_win_set_cursor(win, { starts[direction > 0 and 1 or #starts], 0 })
    end
  end
end

-- Mouse-wheel scrolling an unfocused pane bypasses 'scrollbind', so sync the panes here.
function M.sync_scroll(session)
  if session.syncing_scroll then
    return
  end
  local current = vim.api.nvim_get_current_win()
  for _, side in ipairs({ 'left', 'right' }) do
    local win = session[side .. '_win']
    if
      win ~= current
      and vim.v.event[tostring(win)]
      and vim.api.nvim_win_is_valid(win)
      and vim.wo[win].scrollbind
    then
      session.syncing_scroll = true
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd('syncbind')
      end)
      session.syncing_scroll = false
      return
    end
  end
end

return M
