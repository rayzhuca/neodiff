-- Session lifecycle: opens the NeoDiff tab, wires the panels together, and owns the
-- comparison shown in them. Panel rendering lives in lua/neodiff/panels/.
local M = {}
local git = require('neodiff.git')
local layout = require('neodiff.layout')
local tabline = require('neodiff.tabline')
local ui = require('neodiff.ui')
local diff = require('neodiff.panels.diff')
local files = require('neodiff.panels.files')
local timeline = require('neodiff.panels.timeline')
require('neodiff.highlights')

local sessions = {}
local config = { sidebar_width = 32, stack_height = 8 }

-- These global options are scoped to the viewer and restored on leaving it.
local saved_options
local function use_session_options(active)
  if active and not saved_options then
    saved_options = { laststatus = vim.o.laststatus, scrollopt = vim.o.scrollopt }
    vim.o.laststatus = 2
    -- The panes have identical display rows, so native vertical/horizontal
    -- binding needs no relative offset adjustment when focus changes.
    vim.o.scrollopt = 'ver,hor'
  elseif not active and saved_options then
    vim.o.laststatus = saved_options.laststatus
    vim.o.scrollopt = saved_options.scrollopt
    saved_options = nil
  end
end

local function current_session()
  return sessions[vim.api.nvim_get_current_tabpage()]
end

function M.setup(opts)
  config = vim.tbl_extend('force', config, opts or {})
end

function M.show_help()
  local session = current_session()
  if session then
    require('neodiff.help').open(session)
  end
end

function M.render_tabline()
  return tabline.render(sessions)
end

function M.select_file(session, index)
  local file = session.comparison.files[index]
  if not file then
    return
  end

  diff.show_file(session, file)
  session.index = index
  files.mark_selected(session, index)
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
  tabline.release(sessions)
end

function M.refresh_comparison(session, base, target)
  local comparison = git.compare_endpoints(
    session.comparison.root,
    base or session.timeline.base,
    target or session.timeline.target
  )

  session.comparison = comparison
  session.index = 0
  files.render(session)
  diff.reset(session)
  M.select_file(session, 1)

  if not base then
    timeline.refresh(session.timeline)
  end
end

local function create_actions(session)
  return {
    close = M.close,
    refresh = function()
      M.refresh_comparison(session)
    end,
    compare = function(base, target)
      M.refresh_comparison(session, base, target)
    end,
    select_file = function(index)
      M.select_file(session, index)
    end,
    jump_to_hunk = function(direction)
      diff.jump_to_hunk(session, direction)
    end,
  }
end

M.open = ui.with_error_notification(function(opts)
  opts = opts or {}
  local root = git.repository_root(opts.cwd or vim.fn.getcwd())
  local timeline_state = timeline.create(root, opts)
  local comparison = git.compare_endpoints(root, timeline_state.base, timeline_state.target)
  vim.cmd('tabnew')

  local session = { comparison = comparison, index = 0, timeline = timeline_state }
  session.actions = create_actions(session)
  sessions[vim.api.nvim_get_current_tabpage()] = session
  use_session_options(true)
  tabline.claim()

  layout.create(session)
  files.render(session)
  timeline.mount(session)
  layout.apply_dimensions(session, config)
  diff.reset(session)

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
    tabline.release(sessions)
    use_session_options(current_session() ~= nil)
  end,
})

vim.api.nvim_create_autocmd('TabEnter', {
  callback = function()
    use_session_options(current_session() ~= nil)
  end,
})

vim.api.nvim_create_autocmd({ 'WinResized', 'VimResized', 'TabEnter' }, {
  callback = function()
    local session = sessions[vim.api.nvim_get_current_tabpage()]
    if session then
      layout.equalize_diff_panes(session)
      diff.update_header(session)
    end
  end,
})

return M
