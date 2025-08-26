return {
  {
    "christoomey/vim-tmux-navigator",
    lazy = false,
    config = function()
      local opts = { noremap = true, silent = true }
      local keymap = vim.api.nvim_set_keymap

      keymap("n", "<M-h>", "<cmd> TmuxNavigateLeft<CR>", opts)
      keymap("n", "<M-j>", "<cmd> TmuxNavigateDown<CR>", opts)
      keymap("n", "<M-k>", "<cmd> TmuxNavigateUp<CR>", opts)
      keymap("n", "<M-l>", "<cmd> TmuxNavigateRight<CR>", opts)
    end,
  },
}
