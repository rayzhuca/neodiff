vim.opt.runtimepath:append(vim.fn.getcwd())
vim.o.columns = 140
vim.o.lines = 45
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function run_test_git_command(...)
  local args = { 'git', '-C', root }
  vim.list_extend(args, { ... })
  local result = vim.system(args):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function write_fixture_file(name, lines)
  vim.fn.writefile(lines, root .. '/' .. name)
end
local ok, err = xpcall(function()
  run_test_git_command('init', '-b', 'main')
  run_test_git_command('config', 'user.name', 'NeoDiff Test')
  run_test_git_command('config', 'user.email', 'test@example.invalid')
  write_fixture_file('changed.lua', { 'local value = 1', 'return value' })
  write_fixture_file('deleted.txt', { 'removed' })
  write_fixture_file('old name.txt', { 'same content' })
  run_test_git_command('add', '.')
  run_test_git_command('commit', '-m', 'base')
  local base = run_test_git_command('rev-parse', 'HEAD')
  run_test_git_command('checkout', '-b', 'feature')
  write_fixture_file('changed.lua', { 'local value = 2', 'return value' })
  write_fixture_file('added.txt', { 'new' })
  vim.fn.delete(root .. '/deleted.txt')
  run_test_git_command('mv', 'old name.txt', 'new name.txt')
  write_fixture_file('binary.dat', { 'a\nb' }) -- writefile encodes embedded newline as NUL
  run_test_git_command('add', '.')
  run_test_git_command('commit', '-m', 'feature changes')
  local target = run_test_git_command('rev-parse', 'HEAD')
  run_test_git_command('checkout', 'main')
  write_fixture_file('base-only.txt', { 'later base change' })
  run_test_git_command('add', '.')
  run_test_git_command('commit', '-m', 'advance base')
  run_test_git_command('checkout', 'feature')

  local api = require('neodiff.git')
  local comparison = api.build_comparison(root, 'main', 'feature')
  assert(comparison.left == base, 'branch comparison must use merge base')
  assert(#comparison.files == 5)
  local found = {}
  for _, file in ipairs(comparison.files) do
    found[file.status] = true
    local left = api.read_file_at_revision(comparison, file, 'left')
    local right, special = api.read_file_at_revision(comparison, file, 'right')
    if file.status == 'A' then
      assert(left[1] == '')
    end
    if file.status == 'D' then
      assert(right[1] == '')
    end
    if file.status == 'R' then
      assert(left[1] == right[1])
    end
    if file.path == 'binary.dat' then
      assert(special and right[1] == '[Binary file]')
    end
  end
  assert(found.A and found.D and found.R and found.M)
  assert(#api.build_comparison(root, 'main', 'feature', 'commits').files == 6)
  assert(#api.build_comparison(root, base, target, 'commits').files == 5)
  assert(#api.build_comparison(root, target, target, 'commits').files == 0)
  assert(not pcall(api.build_comparison, root, '--invalid-ref', 'HEAD'))

  local plugin = require('neodiff')
  local start = vim.api.nvim_get_current_tabpage()
  local original_statusline = vim.wo.statusline
  local original_tabline = vim.o.tabline
  plugin.open({ cwd = root, base = 'main' })
  assert(vim.api.nvim_get_current_tabpage() ~= start, 'viewer did not open')
  assert(plugin.render_tabline():find(' Neodiff ', 1, true))

  local wins = vim.api.nvim_tabpage_list_wins(0)
  assert(#wins == 5, 'expected four panels and one shared header')
  local header_win
  wins = vim.tbl_filter(function(win)
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      header_win = win
      return false
    end
    return true
  end, wins)
  assert(header_win and not vim.api.nvim_win_get_config(header_win).focusable)
  assert(
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(header_win), 0, 1, false)[1] == ' added.txt'
  )

  local diffs = 0
  local positions = {}
  for _, win in ipairs(wins) do
    if vim.wo[win].diff then
      diffs = diffs + 1
    end
    positions[#positions + 1] = vim.api.nvim_win_get_position(win)
    assert(not vim.bo[vim.api.nvim_win_get_buf(win)].modifiable)
    local status = vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win }).str
    assert(vim.trim(status) == '', 'panel statuslines should be blank')
  end
  assert(diffs == 2)

  local total_width = 1
  for _, win in ipairs(wins) do
    if vim.wo[win].diff then
      total_width = total_width + vim.api.nvim_win_get_width(win)
      assert(vim.trim(vim.wo[win].winbar) == '')
    end
  end
  assert(vim.api.nvim_win_get_width(header_win) == total_width)
  table.sort(positions, function(a, b)
    return a[2] < b[2] or (a[2] == b[2] and a[1] < b[1])
  end)
  assert(positions[1][2] == 0 and positions[2][2] == 0)
  assert(positions[2][1] > positions[1][1], 'stack must be below the file list')
  assert(positions[3][2] > 0 and positions[4][2] > positions[3][2])
  assert(positions[3][1] == positions[1][1] and positions[4][1] == positions[1][1])

  local files_buf = vim.api.nvim_get_current_buf()
  local maps = vim.api.nvim_buf_get_keymap(files_buf, 'n')
  for _, map in ipairs(maps) do
    if map.lhs == ']f' then
      for _ = 1, 6 do
        map.callback()
      end
    end
  end
  assert(vim.api.nvim_win_get_cursor(0)[1] == 6, 'file navigation failed')
  assert(
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(header_win), 0, 1, false)[1]
      == ' new name.txt'
  )

  plugin.close()
  assert(vim.api.nvim_get_current_tabpage() == start)
  assert(not vim.wo.diff, 'diff state leaked to original window')
  assert(vim.wo.statusline == original_statusline, 'statusline leaked to original window')
  assert(vim.o.tabline == original_tabline, 'tabline was not restored')

  plugin.open({ cwd = root, base = target, target = target, mode = 'commits' })
  assert(vim.api.nvim_get_current_line() == ' No changed files')

  plugin.close()
  assert(#api.build_local_comparison(root).files == 0, 'clean worktree should be empty')

  run_test_git_command('checkout', '-b', 'branch-b')
  write_fixture_file('history.txt', { 'first intermediate commit' })
  run_test_git_command('add', 'history.txt')
  run_test_git_command('commit', '-m', 'intermediate one')
  local intermediate = run_test_git_command('rev-parse', 'HEAD')
  write_fixture_file('history.txt', { 'second intermediate commit' })
  run_test_git_command('add', 'history.txt')
  run_test_git_command('commit', '-m', 'intermediate two')
  run_test_git_command('checkout', 'feature')

  local commits = api.list_branch_commits(
    root,
    { ref = 'branch-b' },
    { kind = 'revision', ref = 'main' },
    api.list_branches(root)
  )
  assert(
    #commits == 2 and commits[2].ref == intermediate,
    'expansion should stop at the nearest parent branch'
  )

  write_fixture_file('changed.lua', { 'staged version' })
  run_test_git_command('add', 'changed.lua')
  write_fixture_file('changed.lua', { 'unstaged version' })
  write_fixture_file('staged.txt', { 'staged addition' })
  run_test_git_command('add', 'staged.txt')
  write_fixture_file('untracked.txt', { 'untracked addition' })
  vim.fn.delete(root .. '/added.txt')
  vim.fn.writefile({ 'ignored.txt' }, root .. '/.git/info/exclude')
  write_fixture_file('ignored.txt', { 'ignored' })

  local local_comparison = api.build_local_comparison(root)
  local local_files = {}
  for _, file in ipairs(local_comparison.files) do
    local_files[file.path] = file
  end
  assert(#local_comparison.files == 4)
  assert(not local_files['ignored.txt'])
  assert(local_files['staged.txt'].status == 'A')
  assert(local_files['untracked.txt'].status == 'A')
  assert(local_files['added.txt'].status == 'D')
  assert(
    api.read_file_at_revision(local_comparison, local_files['changed.lua'], 'left')[1]
      == 'local value = 2'
  )
  assert(
    api.read_file_at_revision(local_comparison, local_files['changed.lua'], 'right')[1]
      == 'unstaged version'
  )
  assert(api.read_file_at_revision(local_comparison, local_files['untracked.txt'], 'left')[1] == '')
  assert(
    api.read_file_at_revision(local_comparison, local_files['untracked.txt'], 'right')[1]
      == 'untracked addition'
  )
  assert(api.read_file_at_revision(local_comparison, local_files['added.txt'], 'right')[1] == '')

  local revision = function(ref)
    return { kind = 'revision', ref = ref }
  end
  local index = { kind = 'index' }
  local worktree = { kind = 'worktree' }
  local function find_file(comparison, path)
    for _, file in ipairs(comparison.files) do
      if file.path == path then
        return file
      end
    end
    error('Missing file: ' .. path)
  end
  local staged = api.compare_endpoints(root, revision('HEAD'), index)
  assert(#staged.files == 2)
  assert(
    api.read_file_at_revision(staged, find_file(staged, 'changed.lua'), 'right')[1]
      == 'staged version'
  )
  local unstaged = api.compare_endpoints(root, index, worktree)
  assert(#unstaged.files == 3)
  assert(
    api.read_file_at_revision(unstaged, find_file(unstaged, 'changed.lua'), 'left')[1]
      == 'staged version'
  )
  assert(
    api.read_file_at_revision(unstaged, find_file(unstaged, 'changed.lua'), 'right')[1]
      == 'unstaged version'
  )
  local reversed = api.compare_endpoints(root, worktree, index)
  assert(find_file(reversed, 'untracked.txt').status == 'D')
  assert(
    api.read_file_at_revision(reversed, find_file(reversed, 'changed.lua'), 'left')[1]
      == 'unstaged version'
  )
  local reversed_index = api.compare_endpoints(root, index, revision('HEAD'))
  assert(find_file(reversed_index, 'staged.txt').status == 'D')
  local reversed_worktree = api.compare_endpoints(root, worktree, revision('HEAD'))
  assert(find_file(reversed_worktree, 'untracked.txt').status == 'D')
  assert(#api.compare_endpoints(root, index, index).files == 0)

  run_test_git_command('branch', 'parent', base)
  plugin.open({ cwd = root })
  local files_window = vim.api.nvim_get_current_win()
  local timeline_window
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[window].winbar == ' Timeline' then
      timeline_window = window
    end
  end
  assert(timeline_window)
  local function timeline_lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(timeline_window), 0, -1, false)
  end
  local function press_timeline_key(label, key)
    vim.api.nvim_set_current_win(timeline_window)
    local row
    for number, line in ipairs(timeline_lines()) do
      if line:find(label, 1, true) then
        row = number
        break
      end
    end
    assert(row, 'Missing timeline entry: ' .. label)
    vim.api.nvim_win_set_cursor(timeline_window, { row, 0 })
    for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
      if keymap.lhs == key then
        keymap.callback()
        return
      end
    end
    error('Missing timeline key: ' .. key)
  end
  assert(timeline_lines()[1] == ' ○ Working tree')
  assert(timeline_lines()[2] == ' ● Staging area')
  assert(table.concat(timeline_lines(), '\n'):find('● main ▸', 1, true))
  press_timeline_key('feature', 'b')
  assert(vim.wo[files_window].winbar:find('(2)', 1, true))
  press_timeline_key('main', '<CR>')
  local selection = table.concat(timeline_lines(), '\n')
  assert(selection:find('● Staging area', 1, true), 'moving the base must preserve the target')
  assert(selection:find('● main', 1, true), 'Enter below the base should select a new base')
  assert(selection:find('○ feature', 1, true), 'previous base should be deselected')
  assert(not selection:find('[base]', 1, true) and not selection:find('[target]', 1, true))
  local expected_files = #api.compare_endpoints(root, revision('main'), index).files
  assert(vim.wo[files_window].winbar:find('(' .. expected_files .. ')', 1, true))
  press_timeline_key('main', '<CR>')
  assert(
    table.concat(timeline_lines(), '\n') == selection,
    'Enter on base should not swap selections'
  )
  press_timeline_key('feature', 'b')
  press_timeline_key('Working tree', '<CR>')
  assert(vim.wo[files_window].winbar:find('(4)', 1, true))
  press_timeline_key('Staging area', 'b')
  assert(vim.wo[files_window].winbar:find('(3)', 1, true))
  press_timeline_key('main', 'b')
  press_timeline_key('feature', '<CR>')
  assert(vim.wo[files_window].winbar:find('(6)', 1, true))
  press_timeline_key('feature ▸', 'o')
  assert(table.concat(timeline_lines(), '\n'):find(target:sub(1, 8), 1, true))
  press_timeline_key(target:sub(1, 8), '<CR>')
  assert(
    table
      .concat(timeline_lines(), '\n')
      :find('● ' .. target:sub(1, 8) .. ' feature changes', 1, true)
  )
  press_timeline_key('feature ▾', 'o')
  assert(
    table
      .concat(timeline_lines(), '\n')
      :find('● ' .. target:sub(1, 8) .. ' feature changes', 1, true),
    'selected commit must stay visible'
  )
  press_timeline_key('branch-b ▸', 'o')
  press_timeline_key(intermediate:sub(1, 8), '<CR>')
  assert(vim.wo[files_window].winbar:find('(7)', 1, true))
  press_timeline_key('feature ▸', 'o')
  press_timeline_key(target:sub(1, 8), 'b')
  assert(
    vim.wo[files_window].winbar:find('(1)', 1, true),
    'individual commit comparison should show history.txt only'
  )
  local selected_count = 0
  for _, line in ipairs(timeline_lines()) do
    if line:find('●', 1, true) then
      selected_count = selected_count + 1
    end
  end
  assert(selected_count == 2, 'exactly two endpoints should be selected')
  press_timeline_key('Working tree', '<CR>')
  press_timeline_key('feature ▾', 'b')
  write_fixture_file('another.txt', { 'saved after opening' })
  press_timeline_key('Working tree', 'r')
  assert(vim.wo[files_window].winbar:find('(5)', 1, true))
  plugin.close()
end, debug.traceback)
vim.fn.delete(root, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
print('NeoDiff smoke tests passed')
vim.cmd('qa!')
