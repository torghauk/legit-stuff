-- manager/init.lua
-- Main entry point for the manager system

local M = {}

-- Default configuration
M.defaults = {
  -- Core settings
  auto_detect_activity = true,
  auto_save_session = false,
  cache_duration = 300, -- 5 minutes

  -- UI settings
  ui = {
    show_inline_coverage = false,
    auto_preview_quickfix = true,
    dashboard_on_startup = false,
    icons = {
      covered = "█",
      uncovered = "█",
      partial = "█",
      success = "✓",
      failure = "✗",
      running = "⟳",
    },
  },

  -- Builder settings
  builder = {
    use_overseer = true,
    default_target = "default",
    auto_generate_compile_commands = true,
    compile_commands_dir = "build",
  },

  -- Testing settings
  testing = {
    use_neotest = false, -- Use neotest if available
    gtest_args = {},
    auto_run_affected = false,
  },

  -- Integrations
  integrations = {
    telescope = true,
    lsp = true,
    treesitter = true,
    coverage = true,
  },

  -- Keymaps
  keymaps = {
    enable_default = true,
    prefix = "<leader>m",
  },

  -- Hooks
  hooks = {
    on_activity_change = nil,
    on_package_change = nil,
    on_build_complete = nil,
    on_test_complete = nil,
  },
}

M.config = {}
M.modules = {}

-- Setup function
function M.setup(opts)
  -- Merge configuration
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

  -- Check dependencies
  M._check_dependencies()

  -- Load core modules
  M.modules.workspace = require("manager.core.workspace")
  M.modules.package = require("manager.core.package")
  M.modules.config = require("manager.core.config")

  -- Initialize core
  M.modules.workspace:init(M.config)
  M.modules.config:load()

  -- Load builders
  if M.config.builder.use_overseer then
    M._safe_require("manager.builders.overseer", function(mod)
      M.modules.builder = mod
      mod:setup(M.config)
    end)
  end

  -- Load optional modules
  if M.config.integrations.telescope then
    M._safe_require("manager.ui.telescope", function(mod)
      M.modules.telescope = mod
      mod:setup(M.config)
    end)
  end

  if M.config.integrations.coverage then
    M._safe_require("manager.analysis.coverage", function(mod)
      M.modules.coverage = mod
      mod:setup(M.config.ui)
    end)
  end

  if M.config.integrations.treesitter then
    M._safe_require("manager.analysis.test_impact", function(mod)
      M.modules.test_impact = mod
      mod:setup(M.config)
    end)
  end

  -- Setup integrations
  if M.config.integrations.lsp then
    M._safe_require("manager.integrations.lsp", function(mod)
      M.modules.lsp = mod
      mod:setup(M.config)
    end)
  end

  -- Setup commands
  M._setup_commands()

  -- Setup keymaps
  if M.config.keymaps.enable_default then
    M._setup_keymaps()
  end

  -- Setup autocmds
  M._setup_autocmds()

  return M
end

-- Check for required dependencies
function M._check_dependencies()
  local required = {
    { plugin = "nvim-telescope/telescope.nvim",   optional = true },
    { plugin = "stevearc/overseer.nvim",          optional = true },
    { plugin = "nvim-treesitter/nvim-treesitter", optional = true },
  }

  for _, dep in ipairs(required) do
    local ok = pcall(require, dep.plugin:match("([^/]+)$"):gsub("%.nvim$", ""))
    if not ok and not dep.optional then
      error(string.format("Manager: Required dependency '%s' not found", dep.plugin))
    elseif not ok and dep.optional then
      vim.notify(
        string.format("Manager: Optional dependency '%s' not found. Some features will be disabled.", dep.plugin),
        vim.log.levels.WARN)
    end
  end
end

-- Safe require with fallback
function M._safe_require(module_name, callback)
  local ok, module = pcall(require, module_name)
  if ok and callback then
    callback(module)
  elseif not ok then
    vim.notify(string.format("Manager: Failed to load module '%s'", module_name), vim.log.levels.WARN)
  end
  return ok, module
end

-- Setup user commands
function M._setup_commands()
  local commands = {
    -- Core commands
    {
      name = "ManagerStatus",
      callback = function() M.modules.workspace:show_status() end,
      desc = "Show current manager status",
    },
    {
      name = "ManagerSelectPackage",
      callback = function(opts) M.modules.package:select(opts.args) end,
      desc = "Select a package to work on",
      nargs = "?",
      complete = function() return M.modules.package:get_available() end,
    },
    -- Build commands
    {
      name = "ManagerBuild",
      callback = function(opts) M.modules.builder:build(opts.args) end,
      desc = "Build current package",
      nargs = "*",
    },
    {
      name = "ManagerTest",
      callback = function(opts) M.modules.builder:test(opts.args) end,
      desc = "Run tests",
      nargs = "*",
    },
    {
      name = "ManagerClean",
      callback = function() M.modules.builder:clean() end,
      desc = "Clean build artifacts",
    },
    -- Analysis commands
    {
      name = "ManagerCoverage",
      callback = function()
        if M.modules.coverage then
          M.modules.coverage:toggle()
        else
          vim.notify("Coverage module not loaded", vim.log.levels.ERROR)
        end
      end,
      desc = "Toggle coverage display",
    },
    {
      name = "ManagerTestImpact",
      callback = function(opts)
        if M.modules.test_impact then
          M.modules.test_impact:analyze(opts.args)
        else
          vim.notify("Test impact module not loaded", vim.log.levels.ERROR)
        end
      end,
      desc = "Analyze test impact",
      nargs = "?",
    },
    -- Session commands
    {
      name = "ManagerSessionSave",
      callback = function() M.modules.config:save_session() end,
      desc = "Save current session",
    },
    {
      name = "ManagerSessionRestore",
      callback = function() M.modules.config:restore_session() end,
      desc = "Restore session",
    },
  }

  for _, cmd in ipairs(commands) do
    vim.api.nvim_create_user_command(cmd.name, cmd.callback, {
      desc = cmd.desc,
      nargs = cmd.nargs,
      complete = cmd.complete,
    })
  end
end

-- Setup keymaps
function M._setup_keymaps()
  local prefix = M.config.keymaps.prefix
  local maps = {
    { prefix .. "s", "<cmd>ManagerStatus<CR>",        "Manager status" },
    { prefix .. "p", "<cmd>ManagerSelectPackage<CR>", "Select package" },
    { prefix .. "b", "<cmd>ManagerBuild<CR>",         "Build" },
    { prefix .. "t", "<cmd>ManagerTest<CR>",          "Run tests" },
    { prefix .. "c", "<cmd>ManagerClean<CR>",         "Clean" },
    { prefix .. "g", "<cmd>ManagerCoverage<CR>",      "Toggle coverage" },
    { prefix .. "i", "<cmd>ManagerTestImpact<CR>",    "Test impact" },
  }

  for _, map in ipairs(maps) do
    vim.keymap.set("n", map[1], map[2], { desc = map[3], silent = true })
  end
end

-- Setup autocmds
function M._setup_autocmds()
  local group = vim.api.nvim_create_augroup("ManagerSystem", { clear = true })

  -- Auto-detect activity changes
  if M.config.auto_detect_activity then
    vim.api.nvim_create_autocmd({ "DirChanged", "BufEnter" }, {
      group = group,
      callback = function()
        M.modules.workspace:check_activity_change()
      end,
    })
  end

  -- Auto-save session
  if M.config.auto_save_session then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        M.modules.config:save_session()
      end,
    })
  end

  -- Trigger hooks
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ManagerActivityChanged",
    callback = function()
      if M.config.hooks.on_activity_change then
        M.config.hooks.on_activity_change(M.modules.workspace:get_current_activity())
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "ManagerPackageChanged",
    callback = function()
      if M.config.hooks.on_package_change then
        M.config.hooks.on_package_change(M.modules.package:get_current())
      end
    end,
  })
end

-- Get current state
function M.get_state()
  return {
    activity = M.modules.workspace:get_current_activity(),
    package = M.modules.package:get_current(),
    workspace_root = M.modules.workspace:get_root(),
  }
end

-- API functions for external use
M.api = {
  build = function(...) return M.modules.builder:build(...) end,
  test = function(...) return M.modules.builder:test(...) end,
  select_package = function(...) return M.modules.package:select(...) end,
  get_state = function() return M.get_state() end,
}

return M
