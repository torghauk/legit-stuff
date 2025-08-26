require("config.keymaps")
require("config.lazy")

vim.opt.conceallevel = 0       -- so that `` is visible in markdown files

vim.opt.fileencoding = "utf-8" -- the encoding written to a file

vim.opt.hlsearch = false       -- highlight all matches on previous search pattern
vim.opt.ignorecase = true      -- ignore case in search patterns
vim.opt.mouse = ""             -- allow the mouse to be used in neovim
vim.opt.pumheight = 10         -- pop up menu height
vim.opt.showmode = false       -- we don't need to see things like -- INSERT -- anymore
vim.opt.showtabline = 2        -- always show tabs
vim.opt.smartcase = true       -- smart case
vim.opt.smartindent = true     -- make indenting smarter again
vim.opt.splitbelow = true      -- force all horizontal splits to go below current window
vim.opt.splitright = true      -- force all vertical splits to go to the right of current window
vim.opt.swapfile = false       -- creates a swapfile
vim.opt.termguicolors = true   -- set term gui colors (most terminals support this)
vim.opt.timeoutlen = 1000      -- time to wait for a mapped sequence to complete (in milliseconds)
vim.opt.undofile = true        -- enable persistent undo
vim.opt.updatetime = 100       -- faster completion (4000ms default)
vim.opt.writebackup = false    -- if a file is being edited by another program (or was written to file while editing with another program), it is not allowed to be edited
vim.opt.expandtab = true       -- convert tabs to spaces
vim.opt.shiftwidth = 4         -- the number of spaces inserted for each indentation
vim.opt.tabstop = 4            -- insert 4 spaces for a tab
vim.opt.cursorline = false     -- highlight the current line
vim.opt.number = true          -- set numbered lines
vim.opt.relativenumber = true  -- set relative numbered lines
vim.opt.numberwidth = 2        -- set number column width to 2 {default 4}
vim.opt.signcolumn =
"yes"                          -- always show the sign column, otherwise it would shift the text each time
vim.opt.wrap = true            -- display lines as one long line
vim.opt.scrolloff = 8          -- is one of my fav
vim.opt.sidescrolloff = 8
vim.opt.scrolloff = 8
vim.opt.guifont = "monospace:h17" -- the font used in graphical neovim applications
vim.opt.colorcolumn = "80"
vim.opt.shortmess:append "c"

vim.keymap.set("", "<up>", "<nop>", { noremap = true })
vim.keymap.set("", "<down>", "<nop>", { noremap = true })
vim.keymap.set("", "<left>", "<nop>", { noremap = true })
vim.keymap.set("", "<right>", "<nop>", { noremap = true })
vim.keymap.set("i", "<up>", "<nop>", { noremap = true })
vim.keymap.set("i", "<down>", "<nop>", { noremap = true })
vim.keymap.set("i", "<left>", "<nop>", { noremap = true })
vim.keymap.set("i", "<right>", "<nop>", { noremap = true })

vim.keymap.set("n", "<c-d>", "<c-d>zz", { noremap = true })
vim.keymap.set("n", "<c-u>", "<c-u>zz", { noremap = true })


vim.keymap.set("n", "<space><space>x", "<cmd>source %<CR>")
vim.keymap.set("n", "<space>x", ":.lua<CR>")
vim.keymap.set("v", "<space>x", ":lua<CR>")

vim.keymap.set("n", "-", ":Oil<CR>")

vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

local job_id = 0
vim.keymap.set("n", "<space>st", function()
  vim.cmd.vnew()
  vim.cmd.term()
  vim.cmd.wincmd("J")
  vim.api.nvim_win_set_height(0, 15)

  job_id = vim.bo.channel
end)

vim.keymap.set("n", "<space>exam", function()
  vim.fn.chansend(job_id, { "ls -la\r\n" })
end)
