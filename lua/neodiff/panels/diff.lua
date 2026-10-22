-- The left (base) and right (target) diff panes and the header spanning both.
local M = {}
local git = require('neodiff.git')
local ui = require('neodiff.ui')
local keymaps = require('neodiff.keymaps')
local alignment = require('neodiff.alignment')

local function disable_diff(session)
  for _, side in ipairs({ 'left', 'right' }) do
    vim.api.nvim_win_call(session[side .. '_win'], function()
      vim.cmd('diffoff')
      vim.wo.scrollbind = false
      vim.wo.cursorbind = false
      vim.wo.statuscolumn = ''
    end)
  end
end

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
  session.hunks = {}
  disable_diff(session)
  for _, side in ipairs({ 'left', 'right' }) do
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

  -- Unbind both panes before replacing their display buffers.
  disable_diff(session)
  local pair = alignment.build(left, right)
  session.hunks = pair.hunks

  for _, side in ipairs({ 'left', 'right' }) do
    local win = session[side .. '_win']
    local data = pair[side]
    local lines = data.lines
    local is_placeholder = (side == 'left' and left_is_placeholder)
      or (side == 'right' and right_is_placeholder)
    local filetype = not is_placeholder and vim.filetype.match({ filename = file.path }) or nil
    local buf = ui.create_readonly_buffer(lines, filetype or 'text')
    -- Navigation distinguishes an absent source from its display padding.
    vim.b[buf].neodiff_empty = #data.source == 0
    alignment.attach(buf, data)

    vim.api.nvim_win_set_buf(win, buf)
    -- A new buffer does not inherit the window's winbar, so reserve the header row again.
    ui.set_panel_header(win, '')
    keymaps.attach(buf, session)
    require('neodiff.navigation').attach(buf, session.comparison.root, file, side, is_placeholder)
    vim.wo[win].foldenable = false
    -- Keep the cursor highlight in the gutter so change colors remain visible.
    vim.wo[win].cursorlineopt = 'number'
    vim.wo[win].number = true
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].statuscolumn = '%'
      .. math.max(3, #tostring(math.max(#left, #right)))
      .. "{v:lua.require'neodiff.alignment'.number()} "
    -- Match the gutters so a longer file on one side does not shift its text over.
    vim.wo[win].numberwidth = math.max(4, #tostring(math.max(#left, #right)) + 1)
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
    vim.wo[win].statusline = ' '
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end

  -- Reset both views before binding; they now share the same display row numbers.
  for _, side in ipairs({ 'left', 'right' }) do
    vim.api.nvim_win_call(session[side .. '_win'], function()
      vim.fn.winrestview({
        lnum = 1,
        col = 0,
        curswant = 0,
        topline = 1,
        topfill = 0,
        leftcol = 0,
        skipcol = 0,
      })
      vim.wo.scrollbind = true
    end)
  end
  M.update_header(session, file.path)
end

local function diff_hunks(session)
  return session.hunks or {}
end

local function find_hunk(hunks, side, cursor, direction)
  for index = direction > 0 and 1 or #hunks, direction > 0 and #hunks or 1, direction do
    local line = hunks[index][side]
    if (direction > 0 and line > cursor) or (direction < 0 and line < cursor) then
      return hunks[index]
    end
  end
end

-- Past the first or last hunk, continue into the previous or next file with changes.
local function find_hunk_in_adjacent_file(session, direction)
  local original = session.index
  local index = original + direction
  while session.comparison.files[index] do
    session.actions.select_file(index)
    local hunks = diff_hunks(session)
    if #hunks > 0 then
      return hunks[direction > 0 and 1 or #hunks]
    end
    index = index + direction
  end
  if session.index ~= original then
    session.actions.select_file(original)
  end
end

-- Works from any panel: outside the diff panes it follows the right pane. Both panes
-- move to the hunk's first line on their own side so they stay on the same change.
function M.jump_to_hunk(session, direction)
  local current = vim.api.nvim_get_current_win()
  local side = current == session.left_win and 'left' or 'right'
  for _ = 1, vim.v.count1 do
    local cursor = vim.api.nvim_win_get_cursor(session[side .. '_win'])[1]
    local hunk = find_hunk(diff_hunks(session), side, cursor, direction)
      or find_hunk_in_adjacent_file(session, direction)
    if not hunk then
      return
    end
    vim.api.nvim_win_call(session[side .. '_win'], function()
      vim.cmd("normal! m'")
    end)
    local other = side == 'left' and 'right' or 'left'
    vim.api.nvim_win_set_cursor(session[other .. '_win'], { hunk[other], 0 })
    vim.api.nvim_win_set_cursor(session[side .. '_win'], { hunk[side], 0 })
  end
end

return M
