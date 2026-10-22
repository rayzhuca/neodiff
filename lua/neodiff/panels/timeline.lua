-- The Timeline panel: endpoints to compare, branches, and their commits.
local M = {}
local git = require('neodiff.git')
local ui = require('neodiff.ui')
local keymaps = require('neodiff.keymaps')
local commit_page_size = 100

local function revision_endpoint(root, reference)
  if reference == 'HEAD' then
    reference = git.current_branch(root)
  end
  return { kind = 'revision', ref = reference, label = reference, id = 'ref:' .. reference }
end

function M.create(root, options)
  local base = revision_endpoint(root, options.base or git.current_branch(root))
  local target = { kind = 'worktree', id = 'worktree', label = 'working tree' }
  if options.target or options.base or options.mode == 'commits' or options.mode == 'branch' then
    target = revision_endpoint(root, options.target or 'HEAD')
  end

  return {
    root = root,
    base = base,
    target = target,
    branches = git.branch_stack(root),
    current_branch = git.current_branch(root),
    default_base = git.default_base(root),
    expanded = {},
    commits = {},
    rows = {},
  }
end

-- Loads the next page of a branch's commits and returns the first newly loaded one.
local function load_commit_page(state, branch)
  local entry = state.commits[branch.id]
  if not entry then
    entry = {
      range = git.branch_commit_range(state.root, branch, state.default_base),
      items = {},
    }
    state.commits[branch.id] = entry
  end
  local page = git.list_commits(state.root, entry.range, #entry.items, commit_page_size + 1)
  if #entry.items == 0 and #page == 0 and #entry.range > 1 then
    -- The branch is fully merged, so show its history rather than nothing.
    entry.range = { entry.range[1] }
    page = git.list_commits(state.root, entry.range, 0, commit_page_size + 1)
  end
  entry.done = #page <= commit_page_size
  for index = 1, math.min(#page, commit_page_size) do
    page[index].indent = true
    entry.items[#entry.items + 1] = page[index]
  end
  return page[1]
end

local function build_rows(state)
  local rows = {
    { kind = 'worktree', id = 'worktree', label = 'working tree' },
    { kind = 'index', id = 'index', label = 'staging area' },
  }
  local branches = vim.deepcopy(state.branches)
  local current = state.current_branch
  local default = state.default_base
  table.sort(branches, function(a, b)
    local function rank(branch)
      if branch.ref == default then
        return 3
      end
      if branch.ref == current then
        return 1
      end
      return 2
    end
    if rank(a) ~= rank(b) then
      return rank(a) < rank(b)
    end
    return a.ref < b.ref
  end)

  for _, branch in ipairs(branches) do
    branch.expandable = true
    rows[#rows + 1] = branch
    local entry = state.commits[branch.id]
    if state.expanded[branch.id] and entry then
      vim.list_extend(rows, entry.items)
      if not entry.done then
        rows[#rows + 1] = {
          kind = 'more',
          id = 'more:' .. branch.id,
          label = 'load more…',
          indent = true,
          branch = branch,
        }
      end
    end
  end

  -- Keep explicit revisions and selected commits visible even after collapsing a branch.
  for _, endpoint in ipairs({ state.base, state.target }) do
    local present = false
    for _, row in ipairs(rows) do
      if row.id == endpoint.id then
        present = true
        break
      end
    end
    if not present then
      rows[#rows + 1] = vim.deepcopy(endpoint)
    end
  end
  return rows
end

function M.render(state)
  local previous = state.rows[vim.api.nvim_win_get_cursor(state.window)[1]]
  local cursor_id = state.cursor_id or (previous and previous.id)
  state.cursor_id = nil
  state.rows = build_rows(state)
  local lines, cursor = {}, 1

  for index, row in ipairs(state.rows) do
    local is_base = row.id == state.base.id
    local is_target = row.id == state.target.id
    local circle = row.kind == 'more' and ' ' or (is_base or is_target) and '●' or '○'
    local expansion = row.expandable and (state.expanded[row.id] and '▾ ' or '▸ ') or ''
    local label = row.label:gsub('[\r\n\t]', ' ')
    lines[index] = (row.indent and '   ' or ' ') .. circle .. ' ' .. expansion .. label
    if cursor == 1 and row.id == cursor_id then
      cursor = index
    end
  end

  vim.bo[state.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(state.buffer, 0, -1, false, lines)
  vim.bo[state.buffer].modifiable = false
  vim.api.nvim_win_set_cursor(state.window, { cursor, 0 })
end

function M.attach(state, window, buffer, on_select, on_error)
  state.window, state.buffer = window, buffer

  local function map(key, description, callback)
    vim.keymap.set('n', key, function()
      local ok, err = pcall(callback)
      if not ok then
        on_error(err)
      end
    end, { buffer = buffer, silent = true, desc = description })
  end

  local function load_more(row)
    local first = load_commit_page(state, row.branch)
    state.cursor_id = first and first.id
    M.render(state)
  end

  local function select_endpoint(role)
    local selected_index = vim.api.nvim_win_get_cursor(window)[1]
    local row = state.rows[selected_index]
    if not row then
      return
    elseif row.kind == 'more' then
      return load_more(row)
    end
    local base, target = state.base, state.target
    if role == 'base' then
      if row.id == target.id then
        target = base
      end
      base = row
    else
      local base_index
      for index, entry in ipairs(state.rows) do
        if entry.id == base.id then
          base_index = index
          break
        end
      end

      if row.id == base.id then
        return
      elseif base_index and selected_index > base_index then
        base = row
      else
        target = row
      end
    end

    -- Validate and load the comparison before committing the new selection.
    on_select(base, target)
    state.base, state.target = base, target
    M.render(state)
  end

  local function toggle_expansion()
    local row = state.rows[vim.api.nvim_win_get_cursor(window)[1]]
    if row and row.kind == 'more' then
      return load_more(row)
    elseif not row or not row.expandable then
      return
    end
    state.expanded[row.id] = not state.expanded[row.id]
    if state.expanded[row.id] and not state.commits[row.id] then
      load_commit_page(state, row)
    end
    M.render(state)
  end

  map('<CR>', 'Select target, or move base to a lower entry', function()
    select_endpoint('target')
  end)
  map('<2-LeftMouse>', 'Select like Enter, or expand an already selected branch', function()
    local row = state.rows[vim.api.nvim_win_get_cursor(window)[1]]
    if row and row.expandable and (row.id == state.base.id or row.id == state.target.id) then
      toggle_expansion()
    else
      select_endpoint('target')
    end
  end)
  map('b', 'Use selected entry as base', function()
    select_endpoint('base')
  end)
  map('o', 'Expand or collapse branch commits', toggle_expansion)
  -- Scrolling onto the "load more" row fetches the next page.
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer = buffer,
    callback = function()
      local row = state.rows[vim.api.nvim_win_get_cursor(window)[1]]
      if row and row.kind == 'more' then
        local ok, err = pcall(load_more, row)
        if not ok then
          on_error(err)
        end
      end
    end,
  })
  M.render(state)
end

function M.mount(session)
  local buffer = ui.create_readonly_buffer({ '' })
  vim.api.nvim_win_set_buf(session.stack_win, buffer)
  ui.configure_panel_window(session.stack_win)
  ui.set_panel_header(session.stack_win, 'Timeline')
  vim.wo[session.stack_win].cursorline = true
  vim.wo[session.stack_win].statusline = "%@v:lua.require'neodiff'.show_help@ ? for help %T"
  keymaps.attach(buffer, session)

  M.attach(session.timeline, session.stack_win, buffer, session.actions.compare, ui.notify_error)
end

function M.refresh(state)
  state.branches = git.branch_stack(state.root)
  state.current_branch = git.current_branch(state.root)
  state.default_base = git.default_base(state.root)
  -- Branch tips may have moved, so reload the first page of each expanded branch.
  state.commits = {}
  for _, branch in ipairs(state.branches) do
    if state.expanded[branch.id] then
      load_commit_page(state, branch)
    end
  end
  M.render(state)
end

return M
