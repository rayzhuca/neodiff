local M = {}

function M.define()
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

  for name, link in pairs({
    Modified = 'DiagnosticWarn',
    Deleted = 'DiagnosticError',
    Untracked = 'Comment',
  }) do
    vim.api.nvim_set_hl(0, 'NeoDiffStatus' .. name, { link = link, default = true })
  end
end

M.define()
vim.api.nvim_create_autocmd('ColorScheme', { callback = M.define })

return M
