return {
  {
    "smoka7/hop.nvim",
    version = "*",
    opts = {
      keys = "etovxqpdygfblzhckisuran",
    },
    config = function()
      require("hop").setup()
      local opts = { noremap = true, silent = true }

      local keymap = vim.api.nvim_set_keymap

      keymap("n", "t", ":HopCamelCase<CR>", opts)
      keymap("n", "T", ":HopAnywhere<CR>", opts)
      keymap("n", "<leader>t", ":HopPattern<CR>", opts)
    end,
    enabled = false,
  },
}
