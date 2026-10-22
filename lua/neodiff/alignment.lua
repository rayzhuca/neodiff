-- Both display buffers have exactly the same rows. Blank padding is real display
-- space, so ordinary scrollbind can cross arbitrarily large added/deleted blocks.
local M = {}
local function changed_span(line, other)
  local first, last, peer_last = 0, #line, #other
  while first < last and first < peer_last and line:byte(first + 1) == other:byte(first + 1) do
    first = first + 1
  end
  while last > first and peer_last > first and line:byte(last) == other:byte(peer_last) do
    last, peer_last = last - 1, peer_last - 1
  end
  -- Extmarks use byte offsets, but highlights must not split a UTF-8 character.
  local function continuation(byte)
    return byte and byte >= 128 and byte < 192
  end
  while first > 0 and continuation(line:byte(first + 1)) do
    first = first - 1
  end
  while last < #line and continuation(line:byte(last + 1)) do
    last = last + 1
  end
  return first, last
end

local namespace = vim.api.nvim_create_namespace('neodiff_alignment')
local buffers = {}

local function text(lines)
  return #lines == 0 and '' or table.concat(lines, '\n') .. '\n'
end

local function options()
  local result = { result_type = 'indices' }
  local flags = {
    ['indent-heuristic'] = 'indent_heuristic',
    iwhite = 'ignore_whitespace_change',
    iwhiteall = 'ignore_whitespace',
    iwhiteeol = 'ignore_whitespace_change_at_eol',
    iblank = 'ignore_blank_lines',
  }
  for item in vim.o.diffopt:gmatch('[^,]+') do
    local algorithm = item:match('^algorithm:(.+)$')
    if algorithm then
      result.algorithm = algorithm
    end
    if flags[item] then
      result[flags[item]] = true
    end
  end
  return result
end

function M.build(left, right)
  local pair = {
    left = { source = left, lines = {}, numbers = {}, highlights = {} },
    right = { source = right, lines = {}, numbers = {}, highlights = {} },
    hunks = {},
  }
  local function append(a, b, changed)
    for _, side in ipairs({ 'left', 'right' }) do
      local data = pair[side]
      local line
      if side == 'left' then
        line = a
      else
        line = b
      end
      local row = #data.lines + 1
      data.lines[row] = line and data.source[line] or ''
      data.numbers[row] = line or 0
      if changed or not line then
        data.highlights[row] = not line and 'NeoDiffFiller'
          or side == 'left' and 'NeoDiffDelete'
          or 'NeoDiffAdd'
      end
    end
  end
  local a, b, previous_end = 1, 1, nil
  for _, hunk in ipairs(vim.diff(text(left), text(right), options())) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    local first_a = count_a == 0 and start_a + 1 or start_a
    local first_b = count_b == 0 and start_b + 1 or start_b
    while a < first_a or b < first_b do
      append(a < first_a and a or nil, b < first_b and b or nil, false)
      if a < first_a then
        a = a + 1
      end
      if b < first_b then
        b = b + 1
      end
    end
    local row = #pair.left.lines + 1
    if not previous_end or row - previous_end > 2 then
      pair.hunks[#pair.hunks + 1] = { left = row, right = row }
    end
    for offset = 0, math.max(count_a, count_b) - 1 do
      append(
        offset < count_a and first_a + offset or nil,
        offset < count_b and first_b + offset or nil,
        true
      )
    end
    previous_end = #pair.left.lines + 1
    a, b = first_a + count_a, first_b + count_b
  end
  while a <= #left or b <= #right do
    append(a <= #left and a or nil, b <= #right and b or nil, false)
    a, b = a + 1, b + 1
  end
  -- Preserve stronger highlighting around the changed text in paired lines.
  for row, number in ipairs(pair.left.numbers) do
    if number > 0 and pair.right.numbers[row] > 0 and pair.left.highlights[row] then
      for _, side in ipairs({ 'left', 'right' }) do
        local data = pair[side]
        local other = pair[side == 'left' and 'right' or 'left']
        data.spans = data.spans or {}
        local first, last = changed_span(data.lines[row], other.lines[row])
        if first < last then
          data.spans[row] = { first, last }
        end
      end
    end
  end
  return pair
end

function M.attach(buf, data)
  buffers[buf] = data
  vim.b[buf].neodiff_view = true
  for row, highlight in pairs(data.highlights) do
    vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, { line_hl_group = highlight })
  end
  for row, span in pairs(data.spans or {}) do
    vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, span[1], {
      end_col = span[2],
      hl_group = data.highlights[row] .. 'Text',
      priority = 200,
    })
  end
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      buffers[buf] = nil
    end,
  })
end

function M.source(buf)
  return buffers[buf]
end

function M.number()
  local data = buffers[vim.api.nvim_get_current_buf()]
  local number = data and data.numbers[vim.v.lnum] or 0
  return number == 0 and '' or tostring(number)
end

return M
