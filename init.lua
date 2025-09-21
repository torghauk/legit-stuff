require("config.keymaps")
require("config.options")
require("config.lazy")

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


-- Configure the manager system
local manager_config = {
  -- Core settings
  auto_detect_activity = false,
  auto_save_session = false,
  cache_duration = 300,

  -- UI configuration
  ui = {
    show_inline_coverage = false,
    auto_preview_quickfix = true,
    dashboard_on_startup = false,
    icons = {
      covered = "✓",
      uncovered = "✗",
      partial = "○",
      success = "✓",
      failure = "✗",
      running = "⟳",
    },
  },

  -- Builder configuration
  builder = {
    use_overseer = true, -- Use overseer.nvim for task management
    default_target = "this",
    auto_generate_compile_commands = true,
    compile_commands_dir = "build",
    show_task_list = false, -- Don't auto-show overseer window
  },

  -- Testing configuration
  testing = {
    use_neotest = false, -- Can enable when gtest adapter is available
    gtest_args = { "--gtest_color=yes" },
    auto_run_affected = false,
  },

  -- Integrations
  integrations = {
    telescope = true,
    lsp = false,
    treesitter = false,
    coverage = false,
  },

  -- Keymaps
  keymaps = {
    enable_default = true,
    prefix = "<leader>m",
  },

  -- Hooks for custom behavior
  hooks = {
    on_activity_change = function(activity)
      vim.notify("Switched to activity: " .. activity, vim.log.levels.INFO)
    end,

    on_package_change = function(package)
      if package then
        vim.notify("Working on: " .. vim.fn.fnamemodify(package, ":t"), vim.log.levels.INFO)
      end
    end,

    on_build_complete = function(task, status)
      if status == "SUCCESS" then
        vim.notify("Build completed successfully!", vim.log.levels.INFO)
      else
        vim.notify("Build failed!", vim.log.levels.ERROR)
      end
    end,

    on_test_complete = function(task, status)
      -- Custom test completion handling
    end,
  },
}

-- Initialize the manager system
require("manager").setup(manager_config)

-- Additional custom keymaps
local keymap = vim.keymap.set
local opts = { silent = true, noremap = true }


-- Auto commands for enhanced workflow
local augroup = vim.api.nvim_create_augroup("ManagerWorkflow", { clear = true })

-- Auto-save before building
vim.api.nvim_create_autocmd("User", {
  pattern = "ManagerBuildPre",
  group = augroup,
  callback = function()
    vim.cmd("wall") -- Save all modified buffers
  end,
})

-- Auto-refresh diagnostics after build
vim.api.nvim_create_autocmd("User", {
  pattern = "ManagerBuildComplete",
  group = augroup,
  callback = function(args)
    if args.data.status == "SUCCESS" then
      -- Refresh LSP if compile_commands.json was updated
      vim.defer_fn(function()
        vim.cmd("LspRestart")
      end, 100)
    end
  end,
})

-- Show test results in a nice format
vim.api.nvim_create_autocmd("User", {
  pattern = "ManagerTestComplete",
  group = augroup,
  callback = function(args)
    if args.data.task and args.data.task.metadata.test_results then
      local results = args.data.task.metadata.test_results
      if results.failed > 0 then
        vim.cmd("TroubleToggle quickfix")
      end
    end
  end,
})

-- Optional: Set up a startup dashboard
if manager_config.ui.dashboard_on_startup then
  vim.api.nvim_create_autocmd("VimEnter", {
    group = augroup,
    callback = function()
      if vim.fn.argc() == 0 then
        -- No files opened, show status
        vim.defer_fn(function()
          vim.cmd("ManagerStatus")
        end, 100)
      end
    end,
  })
end

-- Helper function to quickly run test at cursor
local function run_test_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local patterns = {
    "TEST%(([^,]+),([^%)]+)%)",
    "TEST_F%(([^,]+),([^%)]+)%)",
    "TEST_P%(([^,]+),([^%)]+)%)",
  }

  for _, pattern in ipairs(patterns) do
    local suite, name = line:match(pattern)
    if suite and name then
      local filter = string.format("%s.%s", suite:gsub("%s", ""), name:gsub("%s", ""))
      vim.cmd("ManagerTest --gtest_filter=" .. filter)
      return
    end
  end

  vim.notify("No test found at cursor", vim.log.levels.WARN)
end

keymap("n", "<leader>tc", run_test_at_cursor, vim.tbl_extend("force", opts, { desc = "Run test at cursor" }))

-- Final message
vim.notify("Manager system loaded successfully!", vim.log.levels.INFO)
