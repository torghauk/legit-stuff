return {
  {
    "mhartington/formatter.nvim",

    config = function()
      local util = require("formatter.util")
      require("formatter").setup({
        logging = true,
        log_level = vim.log.levels.WARN,
        filetype = {
          lua = {
            require("formatter.filetypes.lua").stylua,
          },
          markdown = {
            function()
              return {
                exe = "prettierd",
                args = { util.escape_path(util.get_current_buffer_file_path()) },
                stdin = true,
              }
            end,
          },
        },
      })

      vim.api.nvim_set_keymap("n", "<leader>F", "<cmd>FormatLock<CR>", { desc = "Format" })
      -- vim.api.nvim_create_autocmd({ "BufWritePre" }, {
      --   command = ":FormatLock",
      -- })
    end,
  },
}
