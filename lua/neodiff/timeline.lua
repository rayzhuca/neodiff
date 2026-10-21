local M = {}
local git = require('neodiff.git')

local function revision_endpoint(root, reference)
  if reference == 'HEAD' then
    reference = git.current_branch(root)
  end
  return { kind = 'revision', ref = reference, label = reference, id = 'ref:' .. reference }
end

function M.create(root, options)
  local base = revision_endpoint(root, options.base or git.default_base(root))
  local target = { kind = 'index', id = 'index', label = 'Staging area' }
  if options.target or options.base or options.mode == 'commits' or options.mode == 'branch' then
    target = revision_endpoint(root, options.target or 'HEAD')
  elseif options.mode == 'local' then
    target = { kind = 'worktree', id = 'worktree', label = 'Working tree' }
  end

  return {
    root = root,
    base = base,
    target = target,
    branches = git.list_branches(root),
    expanded = {},
    rows = {},
  }
end

local function build_rows(state)
  local rows = {
    { kind = 'index', id = 'index', label = 'Staging area' },
    { kind = 'worktree', id = 'worktree', label = 'Working tree' },
  }
  local branches = vim.deepcopy(state.branches)
  local current = git.current_branch(state.root)
  local default = git.default_base(state.root)
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

  local visible_commits = {}
  for _, branch in ipairs(branches) do
    branch.expandable = true
    rows[#rows + 1] = branch
    if state.expanded[branch.id] then
      local commits = git.list_branch_commits(state.root, branch, state.base, state.branches)
      for _, commit in ipairs(commits) do
        if not visible_commits[commit.id] then
          commit.indent = true
          rows[#rows + 1] = commit
          visible_commits[commit.id] = true
        end
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
  state.rows = build_rows(state)
  local lines, cursor = {}, 1

  for index, row in ipairs(state.rows) do
    local is_base = row.id == state.base.id
    local is_target = row.id == state.target.id
    local circle = (is_base or is_target) and '●' or '○'
    local role = is_base and (is_target and ' [base, target]' or ' [base]')
      or (is_target and ' [target]' or '')
    local expansion = row.expandable and (state.expanded[row.id] and ' ▾' or ' ▸') or ''
    local label = row.label:gsub('[\r\n\t]', ' ')
    lines[index] = (row.indent and '   ' or ' ') .. circle .. ' ' .. label .. expansion .. role
    if previous and previous.id == row.id then
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

  local function select_endpoint(role)
    local row = state.rows[vim.api.nvim_win_get_cursor(window)[1]]
    if not row then
      return
    end
    local base, target = state.base, state.target
    if role == 'base' then
      if row.id == target.id then
        target = base
      end
      base = row
    else
      if row.id == base.id then
        base = target
      end
      target = row
    end

    -- Validate and load the comparison before committing the new selection.
    on_select(base, target)
    state.base, state.target = base, target
    M.render(state)
  end

  map('<CR>', 'Compare selected target against base', function()
    select_endpoint('target')
  end)
  map('b', 'Use selected entry as base', function()
    select_endpoint('base')
  end)
  map('o', 'Expand or collapse branch commits', function()
    local row = state.rows[vim.api.nvim_win_get_cursor(window)[1]]
    if not row or not row.expandable then
      return
    end
    state.expanded[row.id] = not state.expanded[row.id]
    M.render(state)
  end)
  M.render(state)
end

function M.refresh(state)
  state.branches = git.list_branches(state.root)
  M.render(state)
end

return M
