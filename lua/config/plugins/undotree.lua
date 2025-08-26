return {
  {
    "mbbill/undotree",
    config = function()
      local opts = { noremap = true, silent = true }
      local keymap = vim.api.nvim_set_keymap

      keymap("n", "<leader>u", ":UndotreeToggle<CR>", opts)
    end,
  },
}
