-- Buffer and window helpers shared by every panel.
local M = {}

function M.notify_error(err)
  vim.notify('NeoDiff: ' .. tostring(err), vim.log.levels.ERROR)
end

function M.with_error_notification(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      M.notify_error(err)
    end
  end
end

function M.create_readonly_buffer(lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { '' })
  vim.bo[buf].filetype = filetype or 'neodiff'
  vim.bo[buf].modifiable = false

  return buf
end

function M.set_panel_header(win, title)
  vim.wo[win].winbar = ' ' .. title:gsub('%%', '%%%%'):gsub('[\r\n]', ' ')
end

function M.configure_panel_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = false
  vim.wo[win].spell = false
  vim.wo[win].foldcolumn = '0'
end

return M
