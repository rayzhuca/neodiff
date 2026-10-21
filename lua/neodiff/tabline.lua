local M = {}
local expression = "%!v:lua.require'neodiff'.render_tabline()"
local owns_tabline = false

function M.render(sessions)
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

-- Replace only Neovim's default tabline; leave other tabline plugins alone.
function M.claim()
  if vim.o.tabline == '' then
    vim.o.tabline = expression
    owns_tabline = true
  end
end

function M.release(sessions)
  if not next(sessions) and owns_tabline then
    if vim.o.tabline == expression then
      vim.o.tabline = ''
    end
    owns_tabline = false
  end
end

return M
