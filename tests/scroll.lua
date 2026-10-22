-- Exercise real keyboard, wheel input, and redraws in an attached Neovim UI.
vim.opt.runtimepath:append(vim.fn.getcwd())
local child = vim.fn.jobstart(
  { vim.v.progpath, '--embed', '--headless', '-u', 'NONE' },
  { rpc = true }
)
local function lua(code, ...)
  return vim.rpcrequest(child, 'nvim_exec_lua', code, { ... })
end
local ok, err = xpcall(function()
  vim.rpcrequest(child, 'nvim_ui_attach', 140, 45, {})
  lua(
    [[
    vim.opt.runtimepath:append(...)
    vim.o.mouse = 'a'
    vim.o.scrolloff = 0
    vim.o.diffopt = 'internal,filler,closeoff'
    local diff = require('neodiff.panels.diff')
    local left, right = {}, {}
    for i = 1, 200 do
      left[#left + 1] = 'shared ' .. i
      right[#right + 1] = 'shared ' .. i
      if i == 30 then
        for j = 1, 80 do right[#right + 1] = 'inserted ' .. j end
      end
    end
    fixtures = {
      uneven = { left, right },
      leading = { left, vim.list_extend({ 'new first', 'new second' }, vim.deepcopy(left)) },
      equal = { left, vim.deepcopy(left) },
      added = { {}, right },
      deleted = { right, {} },
    }
    require('neodiff.git').read_file_at_revision = function(_, file, side)
      return fixtures[file.path][side == 'left' and 1 or 2], false
    end
    session = { comparison = { root = '/tmp' }, actions = {} }
    sidebar = vim.api.nvim_get_current_win()
    vim.cmd('rightbelow vsplit')
    session.left_win = vim.api.nvim_get_current_win()
    vim.cmd('rightbelow vsplit')
    session.right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(sidebar)
    require('neodiff.keymaps').attach(vim.api.nvim_get_current_buf(), session)
    function show(name)
      diff.show_file(session, { path = name, old_path = name, status = 'M' })
      vim.cmd('redraw')
    end
    function view(side)
      return vim.api.nvim_win_call(session[side .. '_win'], function()
        local v = vim.fn.winsaveview()
        local row = v.topline - 1 - v.topfill
        for line = 1, v.topline do row = row + vim.fn.diff_filler(line) end
        return { row = row, top = v.topline, fill = v.topfill }
      end)
    end
  ]],
    vim.fn.getcwd()
  )
  local function aligned(label)
    local views = lua("return { view('left'), view('right') }")
    assert(views[1].row == views[2].row, label .. ': ' .. vim.inspect(views))
  end
  for _, name in ipairs({ 'uneven', 'leading', 'equal', 'uneven', 'leading' }) do
    lua('show(...)', name)
    assert(
      lua('return vim.wo[session.left_win].scrollbind and vim.wo[session.right_win].scrollbind'),
      'both panes must remain scroll bound after ' .. name
    )
    aligned('switch to ' .. name)
    assert(lua("return view('left').row == 0"), 'new files must start at the first aligned row')
    for _, side in ipairs({ 'left', 'right' }) do
      lua(
        [[
        vim.api.nvim_set_current_win(session[(...) .. '_win'])
        vim.cmd('normal! 90Gzt')
        vim.cmd('redraw')
      ]],
        side
      )
      aligned('keyboard ' .. side .. ' in ' .. name)
    end
    -- Wheel events over an unfocused pane must synchronize without stealing focus.
    lua('vim.api.nvim_set_current_win(sidebar)')
    local before = lua("return view('right').row")
    local pos = lua('return vim.api.nvim_win_get_position(session.right_win)')
    for _ = 1, 6 do
      vim.rpcrequest(child, 'nvim_input_mouse', 'wheel', 'down', '', 0, pos[1] + 3, pos[2] + 5)
      lua("vim.cmd('redraw')")
    end
    aligned('wheel in ' .. name)
    assert(lua("return view('right').row") > before, 'wheel input must actually scroll')
    assert(lua('return vim.api.nvim_get_current_win() == sidebar'))
  end
  lua([[
    show('uneven')
    local function number(side, row)
      local win = session[side .. '_win']
      return vim.trim(vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn,
        { winid = win, use_statuscol_lnum = row }).str)
    end
    assert(number('left', 31) == '', 'padding must not have a line number')
    assert(number('left', 111) == '31', 'display must show original left line numbers')
    assert(number('right', 111) == '111', 'display must show original right line numbers')
    vim.api.nvim_set_current_win(session.left_win)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require('neodiff.panels.diff').jump_to_hunk(session, 1)
    assert(vim.api.nvim_win_get_cursor(session.left_win)[1] == 31)
    assert(vim.api.nvim_win_get_cursor(session.right_win)[1] == 31)
  ]])

  -- Cross a large filler block in both directions, with focus in either pane
  -- or the sidebar. Every wheel step must move in its requested direction and
  -- settle without a later redraw pulling either pane back.
  for _, scrolloff in ipairs({ 0, 8 }) do
    for _, focus in ipairs({ 'sidebar', 'left', 'right' }) do
      for _, hovered in ipairs({ 'left', 'right' }) do
        lua(
          [[
          show('uneven')
          vim.o.scrolloff = ...
        ]],
          scrolloff
        )
        lua(
          [[
          local focus = ...
          vim.api.nvim_set_current_win(focus == 'sidebar' and sidebar or session[focus .. '_win'])
        ]],
          focus
        )
        local pos = lua("return vim.api.nvim_win_get_position(session[(...) .. '_win'])", hovered)
        for _, direction in ipairs({ 'down', 'up' }) do
          for _ = 1, 45 do
            local before = lua("return view('right').row")
            vim.rpcrequest(
              child,
              'nvim_input_mouse',
              'wheel',
              direction,
              '',
              0,
              pos[1] + 3,
              pos[2] + 5
            )
            lua("vim.cmd('redraw')")
            local after = lua("return view('right').row")
            assert(
              direction == 'down' and after >= before or direction == 'up' and after <= before,
              'scroll must never bounce in the opposite direction'
            )
            aligned('wheel through filler: ' .. focus .. '/' .. hovered .. '/' .. direction)
            lua("vim.cmd('redraw')")
            assert(lua("return view('right').row") == after, 'redraw must not move the viewport')
          end
        end
        assert(lua("return view('right').row") == 0, 'upward scrolling must reach the top')
      end
    end
  end

  for _, modifier in ipairs({ 'S', 'C' }) do
    lua("show('uneven'); vim.api.nvim_set_current_win(sidebar)")
    local pos = lua('return vim.api.nvim_win_get_position(session.right_win)')
    vim.rpcrequest(child, 'nvim_input_mouse', 'wheel', 'down', modifier, 0, pos[1] + 3, pos[2] + 5)
    lua("vim.cmd('redraw')")
    aligned('modified wheel ' .. modifier)
    assert(lua("return view('right').row") > 3, 'modified wheel should scroll a page')
  end

  for _, name in ipairs({ 'added', 'deleted' }) do
    lua('show(...)', name)
    local side = name == 'added' and 'right' or 'left'
    local hovered = side == 'right' and 'left' or 'right'
    lua('vim.api.nvim_set_current_win(sidebar)')
    local pos = lua("return vim.api.nvim_win_get_position(session[(...) .. '_win'])", hovered)
    for _ = 1, 100 do
      vim.rpcrequest(child, 'nvim_input_mouse', 'wheel', 'down', '', 0, pos[1] + 3, pos[2] + 5)
      lua("vim.cmd('redraw')")
    end
    assert(
      lua(
        "return vim.api.nvim_win_call(session[(...) .. '_win'], function() return vim.fn.line('w$') end)",
        side
      ) == 280,
      'wheel must reach EOF with an empty peer'
    )
    lua(
      [[
      vim.api.nvim_set_current_win(session[(...) .. '_win'])
      vim.cmd('normal! Gzb')
      vim.cmd('redraw')
    ]],
      side
    )
    assert(
      lua(
        "return vim.api.nvim_win_call(session[(...) .. '_win'], function() return vim.fn.line('w$') end)",
        side
      ) == 280
    )
  end
end, debug.traceback)
vim.fn.jobstop(child)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
end
print('NeoDiff scroll tests passed')
vim.cmd('qa!')
