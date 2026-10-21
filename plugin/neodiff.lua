if vim.g.loaded_neodiff then
  return
end
vim.g.loaded_neodiff = true

vim.api.nvim_create_user_command('NeoDiff', function(opts)
  if #opts.fargs > 2 then
    vim.notify('Usage: :NeoDiff[!] [base] [target]', vim.log.levels.ERROR)
    return
  end
  require('neodiff').open({
    base = opts.fargs[1],
    target = opts.fargs[2],
    mode = opts.bang and 'commits' or (#opts.fargs == 0 and 'timeline' or 'branch'),
  })
end, {
  nargs = '*',
  bang = true,
  desc = 'Open the diff timeline with optional base and target revisions',
})

vim.api.nvim_create_user_command('NeoDiffClose', function()
  require('neodiff').close()
end, { desc = 'Close the current NeoDiff tab' })
