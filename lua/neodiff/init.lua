local M = {}
local git = require('neodiff.git')
local timeline = require('neodiff.timeline')
local sessions = {}
local config = { sidebar_width = 32, stack_height = 5 }
local file_selection_namespace = vim.api.nvim_create_namespace('neodiff')
local tabline_expression = "%!v:lua.require'neodiff'.render_tabline()"
local owns_tabline = false

function M.render_tabline()
  local parts = {}

  for index, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local selected = tab == vim.api.nvim_get_current_tabpage()
    local label = 'Neodiff'

    if not sessions[tab] then
      local buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))
      local name = vim.api.nvim_buf_get_name(buf)
      label = name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':t')
      if vim.bo[buf].modified then
        label = label .. ' +'
      end
    end

    label = label:gsub('%%', '%%%%'):gsub('[\r\n\t]', ' ')
    local highlight = selected and '%#TabLineSel#' or '%#TabLine#'
    parts[#parts + 1] = string.format('%s%%%dT %s ', highlight, index, label)
  end

  parts[#parts + 1] = '%#TabLineFill#%T%='
  if #vim.api.nvim_list_tabpages() > 1 then
    parts[#parts + 1] = '%#TabLine#%999X × %X'
  end

  return table.concat(parts)
end

local function restore_default_tabline()
  if not next(sessions) and owns_tabline then
    if vim.o.tabline == tabline_expression then
      vim.o.tabline = ''
    end
    owns_tabline = false
  end
end

local function define_diff_highlights()
  for name, color in pairs({
    Delete = '#44262b',
    DeleteText = '#75343d',
    Add = '#203d2b',
    AddText = '#306744',
  }) do
    vim.api.nvim_set_hl(0, 'NeoDiff' .. name, { bg = color, default = true })
  end

  -- Filler rows (the side without the added/deleted line) get a background just
  -- slightly lighter than Normal so they read as empty space rather than a change.
  local normal_bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg or 0x1e1e1e
  local filler_bg = 0
  for shift = 0, 16, 8 do
    local channel = bit.band(bit.rshift(normal_bg, shift), 0xff)
    channel = math.min(255, channel + math.floor((255 - channel) * 0.05 + 0.5))
    filler_bg = filler_bg + bit.lshift(channel, shift)
  end
  vim.api.nvim_set_hl(0, 'NeoDiffFiller', { bg = filler_bg, default = true })
end

define_diff_highlights()
vim.api.nvim_create_autocmd('ColorScheme', { callback = define_diff_highlights })

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})
end

local function create_readonly_buffer(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { '' })
  vim.bo[buf].filetype = filetype or 'neodiff'
  vim.bo[buf].modifiable = false

  return buf
end

local function set_panel_header(win, title)
  vim.wo[win].winbar = ' ' .. title:gsub('%%', '%%%%'):gsub('[\r\n]', ' ')
end

local function configure_panel_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].spell = false
  vim.wo[win].foldcolumn = '0'
end

local function update_shared_file_header(session, title)
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
    session.header_buf = create_readonly_buffer({ '' })
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

local function with_error_notification(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.notify('NeoDiff: ' .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function set_panel_keymaps(buf, session)
  local function map(key, fn, desc)
    vim.keymap.set(
      'n',
      key,
      with_error_notification(fn),
      { buffer = buf, silent = true, desc = desc }
    )
  end

  map('q', M.close, 'Close NeoDiff')
  map('r', function()
    M.refresh_comparison(session)
  end, 'Refresh changes')
  map(']f', function()
    M.select_file(session, session.index + 1)
  end, 'Next changed file')
  map('[f', function()
    M.select_file(session, session.index - 1)
  end, 'Previous changed file')
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

function M.select_file(session, index)
  local file = session.comparison.files[index]
  if not file then
    return
  end

  -- Read both versions before replacing either pane.
  local left, left_is_placeholder = git.read_file_at_revision(session.comparison, file, 'left')
  local right, right_is_placeholder = git.read_file_at_revision(session.comparison, file, 'right')
  session.index = index

  for _, side in ipairs({ 'left', 'right' }) do
    local win = session[side .. '_win']
    local lines = side == 'left' and left or right
    local is_placeholder = (side == 'left' and left_is_placeholder)
      or (side == 'right' and right_is_placeholder)
    local filetype = not is_placeholder and vim.filetype.match({ filename = file.path }) or nil
    local buf = create_readonly_buffer(lines, filetype or 'text')

    vim.api.nvim_win_set_buf(win, buf)
    set_panel_keymaps(buf, session)
    vim.api.nvim_win_call(win, function()
      vim.cmd('diffthis')
    end)
    vim.wo[win].foldenable = false
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

  update_shared_file_header(session, file.path)
  vim.api.nvim_buf_clear_namespace(session.files_buf, file_selection_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(
    session.files_buf,
    file_selection_namespace,
    index - 1,
    0,
    { line_hl_group = 'Visual' }
  )
  vim.api.nvim_win_set_cursor(session.files_win, { index, 0 })
  vim.cmd('diffupdate')
end

function M.close()
  local tab = vim.api.nvim_get_current_tabpage()
  if not sessions[tab] then
    return
  end

  if #vim.api.nvim_list_tabpages() == 1 then
    vim.cmd('tabnew')
  end

  local number = vim.api.nvim_tabpage_get_number(tab)
  vim.cmd('tabclose ' .. number)
  sessions[tab] = nil
  restore_default_tabline()
end

local function create_panel_layout(session)
  session.files_win = vim.api.nvim_get_current_win()

  vim.cmd('rightbelow vsplit')
  session.left_win = vim.api.nvim_get_current_win()

  vim.cmd('rightbelow vsplit')
  session.right_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_win(session.files_win)
  vim.cmd('rightbelow split')
  session.stack_win = vim.api.nvim_get_current_win()
end

local function populate_files_panel(session)
  local comparison = session.comparison
  local names = {}

  for _, file in ipairs(comparison.files) do
    local name = file.path
    if file.status == 'R' then
      name = file.old_path .. ' → ' .. file.path
    end
    names[#names + 1] = ' ' .. file.status .. '  ' .. name:gsub('[\r\n\t]', ' ')
  end

  session.files_buf = create_readonly_buffer(#names > 0 and names or { ' No changed files' })
  vim.api.nvim_win_set_buf(session.files_win, session.files_buf)
  configure_panel_window(session.files_win)
  vim.wo[session.files_win].cursorline = true
  set_panel_header(session.files_win, 'Files Changed  (' .. #names .. ')')
  -- A nonempty blank value suppresses the global statusline for this window.
  vim.wo[session.files_win].statusline = ' '
  set_panel_keymaps(session.files_buf, session)

  vim.keymap.set(
    'n',
    '<CR>',
    with_error_notification(function()
      M.select_file(session, vim.api.nvim_win_get_cursor(session.files_win)[1])
    end),
    { buffer = session.files_buf, desc = 'View diff' }
  )
end

local function populate_timeline_panel(session)
  local buffer = create_readonly_buffer({ '' })
  vim.api.nvim_win_set_buf(session.stack_win, buffer)
  configure_panel_window(session.stack_win)
  set_panel_header(session.stack_win, 'Timeline')
  vim.wo[session.stack_win].cursorline = true
  vim.wo[session.stack_win].statusline = ' '
  set_panel_keymaps(buffer, session)

  timeline.attach(session.timeline, session.stack_win, buffer, function(base, target)
    M.refresh_comparison(session, base, target)
  end, function(err)
    vim.notify('NeoDiff: ' .. tostring(err), vim.log.levels.ERROR)
  end)
end

local function apply_panel_dimensions(session)
  vim.api.nvim_win_set_width(session.files_win, config.sidebar_width)
  vim.wo[session.files_win].winfixwidth = true
  vim.wo[session.stack_win].winfixwidth = true

  vim.api.nvim_win_set_height(session.stack_win, config.stack_height)
  vim.wo[session.stack_win].winfixheight = true
end

local function initialize_diff_panels(session)
  for _, side in ipairs({ 'left', 'right' }) do
    vim.api.nvim_win_call(session[side .. '_win'], function()
      vim.cmd('diffoff')
    end)
    local message = 'No changes between these selections.'
    local buf = create_readonly_buffer({ message })
    vim.api.nvim_win_set_buf(session[side .. '_win'], buf)
    configure_panel_window(session[side .. '_win'])
    -- Reserve a row for the single header spanning both diff windows.
    set_panel_header(session[side .. '_win'], '')
    vim.wo[session[side .. '_win']].statusline = ' '
    set_panel_keymaps(buf, session)
  end
end

function M.refresh_comparison(session, base, target)
  local comparison = git.compare_endpoints(
    session.comparison.root,
    base or session.timeline.base,
    target or session.timeline.target
  )

  session.comparison = comparison
  session.index = 0
  populate_files_panel(session)
  initialize_diff_panels(session)
  update_shared_file_header(session, 'No changed files')
  M.select_file(session, 1)

  if not base then
    timeline.refresh(session.timeline)
  end
end

M.open = with_error_notification(function(opts)
  opts = opts or {}
  local root = git.repository_root(opts.cwd or vim.fn.getcwd())
  local timeline_state = timeline.create(root, opts)
  local comparison = git.compare_endpoints(root, timeline_state.base, timeline_state.target)
  vim.cmd('tabnew')

  local session = { comparison = comparison, index = 0, timeline = timeline_state }
  sessions[vim.api.nvim_get_current_tabpage()] = session
  -- Replace only Neovim's default tabline; leave other tabline plugins alone.
  if vim.o.tabline == '' then
    vim.o.tabline = tabline_expression
    owns_tabline = true
  end

  create_panel_layout(session)
  populate_files_panel(session)
  populate_timeline_panel(session)
  apply_panel_dimensions(session)
  initialize_diff_panels(session)

  update_shared_file_header(session, 'No changed files')
  M.select_file(session, 1)
  vim.api.nvim_set_current_win(session.files_win)
end)

vim.api.nvim_create_autocmd('TabClosed', {
  callback = function()
    for tab in pairs(sessions) do
      if not vim.api.nvim_tabpage_is_valid(tab) then
        sessions[tab] = nil
      end
    end
    restore_default_tabline()
  end,
})

vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'TabEnter' }, {
  callback = function()
    local session = sessions[vim.api.nvim_get_current_tabpage()]
    if session then
      update_shared_file_header(session)
    end
  end,
})

return M
