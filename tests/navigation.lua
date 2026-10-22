vim.opt.runtimepath:append(vim.fn.getcwd())
local navigation = require('neodiff.navigation')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local get_clients, definition = vim.lsp.get_clients, vim.lsp.buf.definition
local calls, ready = {}, true
vim.lsp.get_clients = function(filter)
  if not filter or filter.method ~= 'textDocument/definition' then
    return get_clients(filter)
  end
  assert(
    vim.uv.fs_realpath(vim.api.nvim_buf_get_name(filter.bufnr))
      == vim.uv.fs_realpath(root .. '/new name.lua')
  )
  return ready and { {} } or {}
end
vim.lsp.buf.definition = function()
  calls[#calls + 1] = {
    buffer = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
    tab = vim.api.nvim_get_current_tabpage(),
  }
end
local ok, err = xpcall(function()
  vim.fn.writefile(
    { '-- inserted', 'local value = foo()', 'return value' },
    root .. '/new name.lua'
  )
  local source_tab = vim.api.nvim_get_current_tabpage()
  local snapshot = require('neodiff.ui').create_readonly_buffer({
    'local value = foo()',
    'return value',
  }, 'lua')
  vim.api.nvim_win_set_buf(0, snapshot)
  local file = { path = 'new name.lua', old_path = 'old name.lua', status = 'R' }
  for _, side in ipairs({ 'left', 'right' }) do
    vim.api.nvim_win_set_cursor(0, { 1, 14 })
    navigation.attach(snapshot, root, file, side, false)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(snapshot, 'n')) do
      if map.lhs == 'gd' then
        map.callback()
      end
    end
    local call = calls[#calls]
    assert(call and call.tab ~= source_tab, 'definition must run outside the diff tab')
    assert(vim.deep_equal(call.cursor, { 2, 14 }), 'inserted lines should shift the lookup')
    assert(vim.bo[call.buffer].filetype == 'lua')
    assert(vim.bo[call.buffer].modifiable and vim.bo[call.buffer].buftype == '')
    assert(vim.api.nvim_buf_is_valid(snapshot) and not vim.bo[snapshot].modifiable)
    -- Preserve unsaved content and account for its additional line shift.
    vim.bo[call.buffer].bufhidden = 'hide'
    vim.api.nvim_buf_set_lines(call.buffer, 0, 0, false, { '-- unsaved' })
    vim.cmd('tabclose')
    navigation.definition(root, file, side, false)
    assert(vim.deep_equal(calls[#calls].cursor, { 3, 14 }))
    assert(vim.bo[call.buffer].modified, 'lookup must preserve unsaved edits')
    vim.api.nvim_buf_set_lines(call.buffer, 0, 1, false, {})
    vim.cmd('tabclose')
  end

  local count = #calls
  ready = false
  navigation.definition(root, file, 'right', false)
  assert(#calls == count, 'wait for attachment before requesting a definition')
  ready = true
  assert(vim.wait(500, function()
    return #calls == count + 1
  end, 10))
  vim.cmd('tabclose')

  ready = false
  navigation.definition(root, file, 'right', false)
  vim.cmd('tabclose')
  ready = true
  vim.wait(100)
  assert(#calls == count + 1, 'abandon delayed navigation when its tab closes')

  local tab_count = #vim.api.nvim_list_tabpages()
  assert(not pcall(navigation.definition, root, {
    path = 'missing.lua',
    old_path = 'missing.lua',
    status = 'D',
  }, 'left', false))
  assert(not pcall(navigation.definition, root, file, 'left', true))
  vim.bo[snapshot].modifiable = true
  vim.api.nvim_buf_set_lines(snapshot, 0, -1, false, {
    '-- inserted',
    'removed()',
    'local value = foo()',
    'return value',
  })
  vim.bo[snapshot].modifiable = false
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  assert(not pcall(navigation.definition, root, file, 'left', false))
  assert(#vim.api.nvim_list_tabpages() == tab_count, 'failed navigation must leave tabs alone')
  local alignment = require('neodiff.alignment')
  local original = { 'local value = foo()', 'return value' }
  local with_insertions = {}
  for i = 1, 80 do
    with_insertions[i] = 'inserted ' .. i
  end
  vim.list_extend(with_insertions, original)
  local display = alignment.build(original, with_insertions).left
  local padded = require('neodiff.ui').create_readonly_buffer(display.lines, 'lua')
  alignment.attach(padded, display)
  vim.api.nvim_win_set_buf(0, padded)
  vim.api.nvim_win_set_cursor(0, { 81, 14 })
  navigation.definition(root, file, 'left', false)
  assert(
    vim.deep_equal(calls[#calls].cursor, { 2, 14 }),
    'definition must use original source lines, not display padding'
  )
  vim.cmd('tabclose')
  vim.api.nvim_win_set_cursor(0, { 40, 0 })
  assert(
    not pcall(navigation.definition, root, file, 'left', false),
    'padding cannot resolve a definition'
  )
  navigation.open_file(root, file, 'left', false)
  assert(
    vim.api.nvim_win_get_cursor(0)[1] == 2,
    'open from padding should find the next source line'
  )
  vim.cmd('tabclose')
end, debug.traceback)
vim.lsp.get_clients, vim.lsp.buf.definition = get_clients, definition
vim.fn.delete(root, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
print('NeoDiff navigation tests passed')
vim.cmd('qa!')
