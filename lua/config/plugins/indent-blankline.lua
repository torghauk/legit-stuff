return
{
  {
    "lukas-reineke/indent-blankline.nvim",
    main = "ibl",
    ---@module "ibl"
    ---@type ibl.config
    opts = {
      indent = { char = "|", tab_char = "-" },
      whitespace = { remove_blankline_trail = false },
      -- show_trailing_blankline_indent = false,
    },
  }
}
