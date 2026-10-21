local M = {}

local function run_git_command(working_directory, arguments, allow_failure)
  local command = { 'git', '-C', working_directory }
  vim.list_extend(command, arguments)

  local result = vim.system(command, { text = false }):wait(10000)

  if result.code ~= 0 then
    if allow_failure then
      return nil
    end
    local message = vim.trim(result.stderr or '')
    if message == '' then
      message = 'git ' .. table.concat(arguments, ' ') .. ' failed'
    end
    error(message, 0)
  end

  return result.stdout or ''
end

local function resolve_commit_hash(root, revision)
  local resolved_revision = run_git_command(
    root,
    { 'rev-parse', '--verify', '--end-of-options', revision .. '^{commit}' },
    true
  )
  if not resolved_revision then
    error('Not a commit or branch: ' .. revision, 0)
  end

  return vim.trim(resolved_revision)
end

local function detect_base_branch(root)
  local base = run_git_command(
    root,
    { 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD' },
    true
  )
  base = base and vim.trim(base)
  if not base then
    for _, candidate in ipairs({ 'main', 'master', 'origin/main', 'origin/master' }) do
      if run_git_command(root, { 'rev-parse', '--verify', candidate .. '^{commit}' }, true) then
        base = candidate
        break
      end
    end
  end
  if not base then
    error('Cannot detect a base branch. Use :NeoDiff <base>.', 0)
  end

  return base
end

local function parse_changed_files(output)
  local status_fields = vim.split(output, '\0', { plain = true, trimempty = true })
  local files, field_index = {}, 1

  while field_index <= #status_fields do
    local status, old_path, new_path =
      status_fields[field_index], status_fields[field_index + 1], status_fields[field_index + 1]
    field_index = field_index + 2
    if status:match('^[RC]') then
      new_path = status_fields[field_index]
      field_index = field_index + 1
    end
    files[#files + 1] = { status = status:sub(1, 1), old_path = old_path, path = new_path }
  end

  return files
end

function M.repository_root(directory)
  return vim.trim(run_git_command(directory, { 'rev-parse', '--show-toplevel' }))
end

function M.default_base(root)
  local ok, base = pcall(detect_base_branch, root)
  return ok and base or 'HEAD'
end

function M.current_branch(root)
  local branch = run_git_command(root, { 'symbolic-ref', '--quiet', '--short', 'HEAD' }, true)
  return branch and vim.trim(branch) or 'HEAD'
end

function M.list_branches(root)
  local output = run_git_command(root, {
    'for-each-ref',
    '--sort=refname',
    '--format=%(refname:short)%09%(objectname)',
    'refs/heads/',
  })
  local branches = {}
  for line in output:gmatch('[^\n]+') do
    local name, hash = line:match('^(.-)\t(%x+)$')
    branches[#branches + 1] =
      { kind = 'revision', ref = name, label = name, id = 'ref:' .. name, hash = hash }
  end
  return branches
end

-- Returns the revision arguments selecting the commits that belong to a branch.
function M.branch_commit_range(root, branch, default_base)
  local tip = resolve_commit_hash(root, branch.ref)
  if branch.ref == default_base or 'origin/' .. branch.ref == default_base then
    return { tip }
  end

  -- Git has no parent-branch metadata. Exclude the default base and every other branch
  -- tip this branch already contains, so stacked branches only list their own commits.
  local range = { tip, '--not' }
  local base_hash = run_git_command(
    root,
    { 'rev-parse', '--verify', '--end-of-options', default_base .. '^{commit}' },
    true
  )
  if base_hash then
    range[#range + 1] = vim.trim(base_hash)
  end
  local merged = run_git_command(
    root,
    { 'for-each-ref', '--merged=' .. tip, '--format=%(objectname)', 'refs/heads/' }
  )
  for hash in merged:gmatch('%x+') do
    if hash ~= tip then
      range[#range + 1] = hash
    end
  end
  return range
end

function M.list_commits(root, range, skip, count)
  local arguments = { 'log', '--format=%H%x09%s', '--skip=' .. skip, '--max-count=' .. count }
  vim.list_extend(arguments, range)
  arguments[#arguments + 1] = '--'
  local commits = {}
  for line in run_git_command(root, arguments):gmatch('[^\n]+') do
    local hash, subject = line:match('^(%x+)\t(.*)$')
    commits[#commits + 1] = {
      kind = 'revision',
      ref = hash,
      id = 'commit:' .. hash,
      label = hash:sub(1, 8) .. ' ' .. subject,
      commit = true,
    }
  end
  return commits
end

function M.compare_endpoints(root, base, target)
  local left = vim.deepcopy(base)
  local right = vim.deepcopy(target)
  for _, endpoint in ipairs({ left, right }) do
    if endpoint.kind == 'revision' then
      endpoint.hash = resolve_commit_hash(root, endpoint.ref)
    end
  end

  if left.kind == 'index' or right.kind == 'index' then
    if run_git_command(root, { 'ls-files', '--unmerged' }) ~= '' then
      error('Resolve merge conflicts before comparing the staging area.', 0)
    end
  end

  local arguments = { 'diff', '--name-status', '-z', '--find-renames' }
  local reverse = left.kind == 'worktree' or (left.kind == 'index' and right.kind == 'revision')
  if reverse then
    arguments[#arguments + 1] = '-R'
  end

  local same_source = left.kind == right.kind
    and (left.kind ~= 'revision' or left.hash == right.hash)
  if left.kind == 'revision' and right.kind == 'revision' then
    vim.list_extend(arguments, { left.hash, right.hash })
  elseif left.kind == 'revision' or right.kind == 'revision' then
    if left.kind == 'index' or right.kind == 'index' then
      arguments[#arguments + 1] = '--cached'
    end
    arguments[#arguments + 1] = left.hash or right.hash
  end
  arguments[#arguments + 1] = '--'

  local files = same_source and {} or parse_changed_files(run_git_command(root, arguments))
  if not same_source and (left.kind == 'worktree' or right.kind == 'worktree') then
    local paths = run_git_command(root, { 'ls-files', '--others', '--exclude-standard', '-z' })
    local existing = {}
    for _, file in ipairs(files) do
      existing[file.path] = true
    end
    for _, path in ipairs(vim.split(paths, '\0', { plain = true, trimempty = true })) do
      -- A file deleted from the index may still exist in the compared commit.
      local other = left.kind == 'worktree' and right or left
      if not existing[path] then
        local in_revision = other.kind == 'revision'
          and run_git_command(root, { 'cat-file', '-e', other.hash .. ':' .. path }, true)
        if not in_revision then
          files[#files + 1] = { path = path, old_path = path, status = reverse and 'D' or 'U' }
        end
      end
    end
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)

  return { root = root, files = files, sources = { left = left, right = right } }
end

function M.build_comparison(working_directory, base, target, mode)
  local root = vim.trim(run_git_command(working_directory, { 'rev-parse', '--show-toplevel' }))
  target = target or 'HEAD'
  base = base or detect_base_branch(root)

  local base_sha, target_sha = resolve_commit_hash(root, base), resolve_commit_hash(root, target)

  local left_sha = base_sha
  if mode ~= 'commits' then
    left_sha = vim.trim(run_git_command(root, { 'merge-base', base_sha, target_sha }))
  end

  local output = run_git_command(
    root,
    { 'diff', '--name-status', '-z', '--find-renames', left_sha, target_sha, '--' }
  )
  local files = parse_changed_files(output)

  local branch = run_git_command(root, { 'symbolic-ref', '--quiet', '--short', 'HEAD' }, true)
  branch = branch and vim.trim(branch)
    or ('detached @ ' .. resolve_commit_hash(root, 'HEAD'):sub(1, 8))

  return {
    root = root,
    base = base,
    base_commit = base_sha,
    target = target,
    left = left_sha,
    right = target_sha,
    files = files,
    branch = branch,
    mode = mode or 'branch',
  }
end

function M.build_local_comparison(working_directory)
  local comparison = M.build_comparison(working_directory, 'HEAD', 'HEAD', 'commits')
  comparison.mode = 'local'

  local output = run_git_command(comparison.root, {
    'diff',
    '--name-status',
    '-z',
    '--find-renames',
    comparison.left,
    '--',
  })
  comparison.files = parse_changed_files(output)

  local untracked = run_git_command(comparison.root, {
    'ls-files',
    '--others',
    '--exclude-standard',
    '-z',
  })
  for _, path in ipairs(vim.split(untracked, '\0', { plain = true, trimempty = true })) do
    comparison.files[#comparison.files + 1] = { status = 'U', path = path, old_path = path }
  end
  table.sort(comparison.files, function(a, b)
    return a.path < b.path
  end)

  local has_base, base = pcall(detect_base_branch, comparison.root)
  if has_base then
    comparison.base = base
    comparison.base_commit = resolve_commit_hash(comparison.root, base)
  end

  return comparison
end

local function decode_file_contents(contents)
  if contents:find('\0', 1, true) then
    return { '[Binary file]' }, true
  end

  local has_final_newline = contents:sub(-1) == '\n'
  if has_final_newline then
    contents = contents:sub(1, -2)
  end

  return vim.split(contents, '\n', { plain = true }), false, has_final_newline
end

local function read_working_file(root, path)
  local absolute_path = root .. '/' .. path
  local info, stat_error = vim.uv.fs_lstat(absolute_path)
  if not info then
    error('Cannot read ' .. path .. ': ' .. tostring(stat_error), 0)
  end

  if info.type == 'link' then
    local destination, link_error = vim.uv.fs_readlink(absolute_path)
    if not destination then
      error(link_error, 0)
    end
    return decode_file_contents(destination)
  end
  if info.type ~= 'file' then
    return { '[Working-tree ' .. info.type .. ': ' .. path .. ']' }, true
  end
  if info.size > 2 * 1024 * 1024 then
    return { '[File exceeds 2 MiB preview limit]' }, true
  end

  local descriptor, open_error = vim.uv.fs_open(absolute_path, 'r', 438)
  if not descriptor then
    error(open_error, 0)
  end
  local contents, read_error = vim.uv.fs_read(descriptor, info.size, 0)
  vim.uv.fs_close(descriptor)
  if not contents then
    error(read_error, 0)
  end

  return decode_file_contents(contents)
end

function M.read_file_at_revision(comparison, file, side)
  local added = file.status == 'A' or file.status == 'U'
  -- No lines at all, rather than one blank line, so the diff marks every line on the
  -- other side as changed instead of pairing a blank line with this one.
  if (side == 'left' and added) or (side == 'right' and file.status == 'D') then
    return {}, false
  end

  local path = side == 'left' and file.old_path or file.path
  local source = comparison.sources and comparison.sources[side]
  if (source and source.kind == 'worktree') or (comparison.mode == 'local' and side == 'right') then
    return read_working_file(comparison.root, path)
  end

  local revision = source and (source.kind == 'index' and '' or source.hash) or comparison[side]
  local object = revision .. ':' .. path
  local object_type = vim.trim(run_git_command(comparison.root, { 'cat-file', '-t', object }))
  if object_type ~= 'blob' then
    return { '[Git ' .. object_type .. ': ' .. object .. ']' }, true
  end

  local size_bytes = tonumber(run_git_command(comparison.root, { 'cat-file', '-s', object }))
  if size_bytes and size_bytes > 2 * 1024 * 1024 then
    return { '[File exceeds 2 MiB preview limit]' }, true
  end

  local contents = run_git_command(comparison.root, { 'cat-file', 'blob', object })
  return decode_file_contents(contents)
end

return M
