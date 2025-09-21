-- Updated plugin configuration with nvim-coverage integration

local plugins = {
  -- Previous plugins...

  -- Coverage plugin with GCov support
  {
    "andythigpen/nvim-coverage",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      -- The manager system will configure this
      -- But we can add default settings here
      require("coverage").setup({
        commands = true,
        highlights = {
          covered = { fg = "#C3E88D" },
          uncovered = { fg = "#F07178" },
        },
        signs = {
          covered = { hl = "CoverageCovered", text = "▎" },
          uncovered = { hl = "CoverageUncovered", text = "▎" },
        },
        summary = {
          min_coverage = 80.0,
        },
        lang = {
          -- GCov modules will be registered by manager system
        },
      })
    end,
  },

  -- Rest of plugins...
}

-- Manager configuration with nvim-coverage
local manager_config = {
  -- Previous config...

  -- Coverage settings
  coverage = {
    use_nvim_coverage = true,     -- Use nvim-coverage instead of custom implementation
    auto_coverage_on_test = true, -- Auto-load coverage after tests
    clear_gcov_files = false,     -- Keep gcov files for debugging
    keymaps = {
      enable_coverage = true,
      coverage_prefix = "<leader>c",
    },
  },

  -- Updated keymaps
  keymaps = {
    enable_default = true,
    prefix = "<leader>m",
    -- Coverage keymaps handled by coverage module
  },
}

-- Initialize manager with coverage support
require("manager").setup(manager_config)

-- Additional coverage-specific keymaps
local keymap = vim.keymap.set
local opts = { silent = true, noremap = true }

-- Coverage commands
keymap("n", "<leader>cg", "<cmd>Coverage<CR>", vim.tbl_extend("force", opts, { desc = "Generate coverage" }))
keymap("n", "<leader>ct", "<cmd>CoverageToggle<CR>", vim.tbl_extend("force", opts, { desc = "Toggle coverage signs" }))
keymap("n", "<leader>cs", "<cmd>CoverageSummary<CR>", vim.tbl_extend("force", opts, { desc = "Coverage summary" }))
keymap("n", "<leader>cl", "<cmd>CoverageLoad<CR>", vim.tbl_extend("force", opts, { desc = "Load coverage" }))
keymap("n", "<leader>cc", "<cmd>CoverageClear<CR>", vim.tbl_extend("force", opts, { desc = "Clear coverage" }))

-- Navigation between uncovered lines (these are set up by the module)
-- keymap("n", "]u", "<cmd>CoverageJumpNext<CR>", opts)
-- keymap("n", "[u", "<cmd>CoverageJumpPrev<CR>", opts)

-- Statusline integration with coverage
-- If using lualine:
require("lualine").setup({
  -- Previous lualine config...
  sections = {
    lualine_x = {
      -- Add coverage percentage to statusline
      {
        function()
          local ok, manager = pcall(require, "manager")
          if ok and manager.modules.coverage then
            local coverage_str = manager.modules.coverage:statusline()
            if coverage_str ~= "" then
              return "COV: " .. coverage_str
            end
          end
          return ""
        end,
        cond = function()
          -- Only show for C/C++ files
          local ft = vim.bo.filetype
          return ft == "c" or ft == "cpp"
        end,
        color = function()
          -- Color based on coverage percentage
          local ok, manager = pcall(require, "manager")
          if ok and manager.modules.coverage then
            local coverage = manager.modules.coverage:get_file_coverage()
            if coverage then
              if coverage >= 80 then
                return { fg = "#C3E88D" } -- Green
              elseif coverage >= 60 then
                return { fg = "#FFCB6B" } -- Yellow
              else
                return { fg = "#F07178" } -- Red
              end
            end
          end
          return nil
        end,
      },
      -- Other statusline components...
    },
  },
})

-- Autocommand to show coverage summary on save if coverage is loaded
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = { "*.c", "*.cpp", "*.h", "*.hpp" },
  callback = function()
    local ok, coverage = pcall(require, "coverage")
    if ok then
      -- Check if coverage is loaded
      local signs = vim.fn.sign_getplaced(0, { group = "coverage" })
      if signs and #signs > 0 and #signs[1].signs > 0 then
        -- Coverage is active, show current file's coverage
        local manager = require("manager")
        if manager.modules.coverage then
          local pct = manager.modules.coverage:get_file_coverage()
          if pct then
            vim.notify(string.format("Coverage: %.1f%%", pct), vim.log.levels.INFO)
          end
        end
      end
    end
  end,
})

-- Helper command to generate coverage report in HTML format (requires gcovr)
vim.api.nvim_create_user_command("CoverageHTML", function()
  if vim.fn.executable("gcovr") == 0 then
    vim.notify("gcovr not found. Install it to generate HTML reports.", vim.log.levels.ERROR)
    return
  end

  local output_dir = vim.fn.getcwd() .. "/coverage_html"
  vim.fn.mkdir(output_dir, "p")

  local cmd = string.format(
    "gcovr --html --html-details -o %s/index.html --root %s",
    vim.fn.shellescape(output_dir),
    vim.fn.shellescape(vim.fn.getcwd())
  )

  vim.fn.system(cmd)

  if vim.v.shell_error == 0 then
    vim.notify("HTML coverage report generated in " .. output_dir, vim.log.levels.INFO)
    -- Optionally open in browser
    if vim.fn.executable("xdg-open") == 1 then
      vim.fn.system("xdg-open " .. output_dir .. "/index.html")
    elseif vim.fn.executable("open") == 1 then
      vim.fn.system("open " .. output_dir .. "/index.html")
    end
  else
    vim.notify("Failed to generate HTML coverage report", vim.log.levels.ERROR)
  end
end, {
  desc = "Generate HTML coverage report with gcovr",
})

-- Integration with Telescope for finding uncovered lines
if pcall(require, "telescope") then
  vim.api.nvim_create_user_command("TelescopeUncoveredLines", function()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local entry_display = require("telescope.pickers.entry_display")

    -- Get uncovered lines from all files
    local uncovered = {}
    local coverage_data = require("coverage").get_coverage()

    if coverage_data then
      for file, data in pairs(coverage_data) do
        for line_num, hits in pairs(data) do
          if hits == 0 then
            table.insert(uncovered, {
              filename = file,
              lnum = line_num,
              text = vim.fn.getline(line_num) or "",
            })
          end
        end
      end
    end

    if #uncovered == 0 then
      vim.notify("No uncovered lines found", vim.log.levels.INFO)
      return
    end

    -- Sort by filename and line number
    table.sort(uncovered, function(a, b)
      if a.filename == b.filename then
        return a.lnum < b.lnum
      end
      return a.filename < b.filename
    end)

    pickers.new({}, {
      prompt_title = "Uncovered Lines",
      finder = finders.new_table({
        results = uncovered,
        entry_maker = function(entry)
          local displayer = entry_display.create({
            separator = " ",
            items = {
              { width = 30 },
              { width = 5 },
              { remaining = true },
            },
          })

          local make_display = function(e)
            return displayer({
              vim.fn.fnamemodify(e.value.filename, ":t"),
              tostring(e.value.lnum),
              vim.trim(e.value.text),
            })
          end

          return {
            value = entry,
            display = make_display,
            ordinal = entry.filename .. ":" .. entry.lnum,
            filename = entry.filename,
            lnum = entry.lnum,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = conf.qflist_previewer({}),
      attach_mappings = function(prompt_bufnr, map)
        local actions = require("telescope.actions")
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = require("telescope.actions.state").get_selected_entry()
          if selection then
            vim.cmd("edit " .. vim.fn.fnameescape(selection.filename))
            vim.api.nvim_win_set_cursor(0, { selection.lnum, 0 })
            vim.cmd("normal! zz")
          end
        end)
        return true
      end,
    }):find()
  end, {
    desc = "Find uncovered lines with Telescope",
  })

  keymap("n", "<leader>cu", "<cmd>TelescopeUncoveredLines<CR>",
    vim.tbl_extend("force", opts, { desc = "Find uncovered lines" }))
end

-- Quick coverage workflow commands
vim.api.nvim_create_user_command("CoverageWorkflow", function()
  -- Run complete coverage workflow
  local steps = {
    function(next)
      vim.notify("Step 1/4: Building with coverage...", vim.log.levels.INFO)
      vim.cmd("ManagerBuild +gcov")
      vim.defer_fn(next, 2000)
    end,
    function(next)
      vim.notify("Step 2/4: Running tests...", vim.log.levels.INFO)
      vim.cmd("ManagerTest")
      vim.defer_fn(next, 3000)
    end,
    function(next)
      vim.notify("Step 3/4: Loading coverage data...", vim.log.levels.INFO)
      vim.cmd("CoverageLoad")
      vim.defer_fn(next, 1000)
    end,
    function()
      vim.notify("Step 4/4: Showing summary...", vim.log.levels.INFO)
      vim.cmd("CoverageSummary")
      vim.notify("Coverage workflow complete!", vim.log.levels.INFO)
    end,
  }

  -- Execute steps sequentially
  local function run_step(index)
    if index <= #steps then
      steps[index](function()
        run_step(index + 1)
      end)
    end
  end

  run_step(1)
end, {
  desc = "Run complete coverage workflow",
})

keymap("n", "<leader>cw", "<cmd>CoverageWorkflow<CR>", vim.tbl_extend("force", opts, { desc = "Run coverage workflow" }))
