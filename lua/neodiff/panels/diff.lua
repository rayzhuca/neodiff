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
    -- Lets diff_hunks tell an empty pane from one holding a single blank line.
    vim.b[buf].neodiff_empty = #lines == 0

    vim.api.nvim_win_set_buf(win, buf)
    -- A new buffer does not inherit the window's winbar, so reserve the header row again.
    ui.set_panel_header(win, '')
    keymaps.attach(buf, session)
    vim.api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
    vim.wo[win].foldenable = false
    -- On diff lines Neovim draws CursorLine as an underline; highlight only the number.
    vim.wo[win].cursorlineopt = 'number'
    vim.wo[win].number = true
    -- Match the gutters so a longer file on one side does not shift its text over.
    vim.wo[win].numberwidth = math.max(4, #tostring(math.max(#left, #right)) + 1)
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

-- Hunks separated by at most this many unchanged lines are one stop for ]c / [c, the
-- way git merges hunks whose context overlaps. Neovim's own highlighting splits a block
-- at every matching line, which leaves stray "end" lines as hunk boundaries.
local hunk_merge_gap = 2

-- vim.diff() options that match how Neovim diffs the panes.
local function diff_options()
  local options = { result_type = 'indices' }
  for item in vim.o.diffopt:gmatch('[^,]+') do
    local name, value = item:match('^([^:]+):?(.*)$')
    if name == 'algorithm' then
      options.algorithm = value
    elseif name == 'indent-heuristic' then
      options.indent_heuristic = true
    elseif name == 'iwhite' then
      options.ignore_whitespace_change = true
    elseif name == 'iwhiteall' then
      options.ignore_whitespace = true
    elseif name == 'iwhiteeol' then
      options.ignore_whitespace_change_at_eol = true
    elseif name == 'iblank' then
      options.ignore_blank_lines = true
    end
  end
  return options
end

-- A pane's text for vim.diff(). An empty buffer still reads back as one blank line.
local function window_text(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.b[buf].neodiff_empty then
    return '', 0
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, '\n') .. '\n', #lines
end

-- Returns { left = line, right = line } for the first line of each hunk on both sides.
local function diff_hunks(session)
  if not vim.wo[session.left_win].diff or not vim.wo[session.right_win].diff then
    return {}
  end
  local left, left_total = window_text(session.left_win)
  local right, right_total = window_text(session.right_win)
  local indices = vim.diff(left, right, diff_options())

  local hunks, next_left = {}, nil
  for _, index in ipairs(indices) do
    local left_start, left_count, right_start, right_count = unpack(index)
    -- A side with no lines in the hunk shows filler rows below its start line.
    local left_first = left_count > 0 and left_start or left_start + 1
    local right_first = right_count > 0 and right_start or right_start + 1
    if not next_left or left_first - next_left > hunk_merge_gap then
      hunks[#hunks + 1] = {
        left = math.max(1, math.min(left_first, left_total)),
        right = math.max(1, math.min(right_first, right_total)),
      }
    end
    next_left = left_first + left_count
  end
  return hunks
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

local function top_of(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  return view.topline .. ':' .. (view.topfill or 0)
end

-- A scroll that left the window somewhere other than where sync_scroll last put it.
local function scrolled_by_user(session, win)
  return vim.v.event[tostring(win)] ~= nil and session.synced_tops[win] ~= top_of(win)
end

-- Mouse-wheel scrolling an unfocused pane bypasses 'scrollbind', so sync the panes here.
function M.sync_scroll(session)
  if session.syncing_scroll then
    return
  end
  session.synced_tops = session.synced_tops or {}
  local current = vim.api.nvim_get_current_win()
  -- When the focused pane scrolls, 'scrollbind' already moves the other one. Syncing
  -- from the other pane as well drags the focused pane back to wherever it lagged during
  -- fast scrolling. Moves made by an earlier sync are reported here too, alongside the
  -- next wheel step, so those do not count as the focused pane scrolling.
  if scrolled_by_user(session, current) then
    session.synced_tops = {}
    return
  end
  for _, side in ipairs({ 'left', 'right' }) do
    local win = session[side .. '_win']
    if
      win ~= current
      and vim.api.nvim_win_is_valid(win)
      and vim.wo[win].scrollbind
      and scrolled_by_user(session, win)
    then
      session.syncing_scroll = true
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd('syncbind')
      end)
      session.syncing_scroll = false
      local other = session[(side == 'left' and 'right' or 'left') .. '_win']
      session.synced_tops = { [other] = top_of(other) }
      return
    end
  end
end

return M
