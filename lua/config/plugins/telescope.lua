return {
  {
    "nvim-telescope/telescope.nvim",
    tag = "0.1.8",
    dependencies = {
      "nvim-lua/plenary.nvim",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
    config = function()
      require("telescope").setup({
        pickers = {},
        extensions = {
          fzf = {},
        },
      })

      -- require('telescope').load_extension('fzf')

      vim.keymap.set("n", "<space>ff", require("telescope.builtin").find_files)
      vim.keymap.set("n", "<space>fw", require("telescope.builtin").live_grep)
      vim.keymap.set("n", "<space>fh", require("telescope.builtin").help_tags)
      vim.keymap.set("n", "<space>en", function()
        local opts = require("telescope.themes").get_ivy({
          cwd = vim.fn.stdpath("config"),
        })
        require("telescope.builtin").find_files(opts)
      end)

      vim.keymap.set("n", "<space>ep", function()
        local opts = require("telescope.themes").get_ivy({
          cwd = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy"),
        })
        require("telescope.builtin").find_files(opts)
      end)

      require("config.telescope.multigrep").setup()
      vim.keymap.set("n", "<leader>fb", ":Telescope buffers <CR>", { desc = "Find buffers" })
      vim.keymap.set("n", "<leader>fo", ":Telescope oldfiles <CR>", { desc = "Find oldfiles" })
      vim.keymap.set(
        "n",
        "<leader>fz",
        ":Telescope current_buffer_fuzzy_find <CR>",
        { desc = "Find in current buffer" }
      )
      vim.keymap.set("n", "<leader>fd", ":Telescope treesitter <CR>", { desc = "Find in treesitter"})
    end,
  },
}
