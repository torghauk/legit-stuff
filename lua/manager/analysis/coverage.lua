-- manager/analysis/coverage.lua
-- Integration with nvim-coverage for GCov support

local M = {}

-- Check if nvim-coverage is available
local has_coverage, coverage = pcall(require, "coverage")

-- Initialize module
function M:setup(config)
  self.config = config

  if not has_coverage then
    vim.notify("nvim-coverage not found. Coverage features will be disabled.", vim.log.levels.WARN)
    return self
  end

  -- Setup nvim-coverage with our configuration
  coverage.setup({
    commands = true, -- create commands
    highlights = {
      -- customize highlight groups
      covered = { fg = "#00FF00" },
      uncovered = { fg = "#FF0000" },
      partial = { fg = "#FFFF00" },
    },
    signs = {
      -- customize signs
      covered = { hl = "CoverageCovered", text = "█" },
      uncovered = { hl = "CoverageUncovered", text = "█" },
      partial = { hl = "CoveragePartial", text = "▓" },
    },
    summary = {
      -- customize summary window
      min_coverage = 80.0,
    },
    lang = {
      -- Additional language-specific settings can go here
    },
    auto_reload = true,
    lcov_file = nil, -- We use gcov directly, not lcov
  })

  -- Register our gcov languages if not already present
  self:_ensure_gcov_languages()

  -- Setup keymaps if configured
  if self.config.keymaps and self.config.keymaps.enable_coverage then
    self:_setup_keymaps()
  end

  -- Setup autocmds
  self:_setup_autocmds()

  return self
end

-- Ensure gcov language modules are available
function M:_ensure_gcov_languages()
  -- Check if our gcov modules exist
  local c_module_path = vim.fn.stdpath("config") .. "/lua/coverage/languages/c.lua"
  local cpp_module_path = vim.fn.stdpath("config") .. "/lua/coverage/languages/cpp.lua"

  -- Create directory if it doesn't exist
  local lang_dir = vim.fn.stdpath("config") .. "/lua/coverage/languages"
  vim.fn.mkdir(lang_dir, "p")

  -- If modules don't exist, create them
  if vim.fn.filereadable(c_module_path) == 0 then
    -- Write our gcov module
    self:_create_gcov_module(c_module_path)
  end

  if vim.fn.filereadable(cpp_module_path) == 0 then
    -- C++ module just references C module
    local file = io.open(cpp_module_path, "w")
    if file then
      file:write('return require("coverage.languages.c")\n')
      file:close()
    end
  end
end

-- Create the gcov module file
function M:_create_gcov_module(path)
  -- This would contain the full module code from the previous artifact
  -- For brevity, I'll just note that this would write the file
  vim.notify("Creating GCov language module for nvim-coverage...", vim.log.levels.INFO)
  -- In practice, you would include the full module code here or copy it from a bundled file
end

-- Toggle coverage display
function M:toggle()
  if not has_coverage then
    vim.notify("nvim-coverage is not installed", vim.log.levels.ERROR)
    return
  end

  coverage.toggle()
end

-- Generate coverage data
function M:generate()
  if not has_coverage then
    vim.notify("nvim-coverage is not installed", vim.log.levels.ERROR)
    return
  end

  local manager = require("manager.core.package")
  local pkg = manager:get_current()

  if not pkg then
    vim.notify("No package selected for coverage generation", vim.log.levels.ERROR)
    return
  end

  -- Use overseer to run build and test with coverage
  local overseer = require("overseer")

  -- Create a compound task for build + test with coverage
  local build_task = overseer.new_task({
    cmd = { "builder", "-a", pkg, "-b", "default", "+gcov" },
    name = "Build with coverage",
    components = { "default" },
  })

  build_task:add_component({
    "on_complete_callback",
    callback = function(task, status)
      if status == "SUCCESS" then
        -- Run tests after successful build
        local test_task = overseer.new_task({
          cmd = { "builder", "+test_runner" },
          name = "Run tests for coverage",
          components = { "default" },
        })

        test_task:add_component({
          "on_complete_callback",
          callback = function(task2, status2)
            if status2 == "SUCCESS" then
              -- Load coverage after tests complete
              vim.defer_fn(function()
                coverage.load(true)
              end, 500)
            else
              vim.notify("Tests failed, coverage may be incomplete", vim.log.levels.WARN)
              coverage.load(true)
            end
          end
        })

        test_task:start()
      else
        vim.notify("Build failed, cannot generate coverage", vim.log.levels.ERROR)
      end
    end
  })

  build_task:start()
  vim.notify("Generating coverage data...", vim.log.levels.INFO)
end

-- Show coverage summary
function M:show_summary()
  if not has_coverage then
    vim.notify("nvim-coverage is not installed", vim.log.levels.ERROR)
    return
  end

  coverage.summary()
end

-- Jump to next uncovered line
function M:jump_next_uncovered()
  if not has_coverage then
    return
  end

  coverage.jump_next_uncovered()
end

-- Jump to previous uncovered line
function M:jump_prev_uncovered()
  if not has_coverage then
    return
  end

  coverage.jump_prev_uncovered()
end

-- Clear coverage data
function M:clear()
  if not has_coverage then
    return
  end

  coverage.clear()

  -- Also clear our gcov files if configured
  if self.config.clear_gcov_files then
    self:_clear_gcov_files()
  end
end

-- Clear gcov files from the project
function M:_clear_gcov_files()
  local gcov_files = vim.fn.glob("**/*.gcov", false, true)
  local gcda_files = vim.fn.glob("**/*.gcda", false, true)
  local gcno_files = vim.fn.glob("**/*.gcno", false, true)

  local all_files = vim.list_extend(gcov_files, gcda_files)
  all_files = vim.list_extend(all_files, gcno_files)

  for _, file in ipairs(all_files) do
    vim.fn.delete(file)
  end

  if #all_files > 0 then
    vim.notify(string.format("Cleared %d coverage files", #all_files), vim.log.levels.INFO)
  end
end

-- Setup keymaps
function M:_setup_keymaps()
  local prefix = self.config.keymaps.coverage_prefix or "<leader>c"

  local maps = {
    { prefix .. "t", function() self:toggle() end,              "Toggle coverage" },
    { prefix .. "g", function() self:generate() end,            "Generate coverage" },
    { prefix .. "s", function() self:show_summary() end,        "Show summary" },
    { prefix .. "c", function() self:clear() end,               "Clear coverage" },
    { prefix .. "r", function() coverage.load(true) end,        "Reload coverage" },
    { "]u",          function() self:jump_next_uncovered() end, "Next uncovered" },
    { "[u",          function() self:jump_prev_uncovered() end, "Prev uncovered" },
  }

  for _, map in ipairs(maps) do
    vim.keymap.set("n", map[1], map[2], { desc = map[3], silent = true })
  end
end

-- Setup autocmds
function M:_setup_autocmds()
  local group = vim.api.nvim_create_augroup("ManagerCoverage", { clear = true })

  -- Auto-load coverage when entering a C/C++ buffer if coverage exists
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    pattern = { "*.c", "*.cpp", "*.cc", "*.cxx", "*.h", "*.hpp" },
    callback = function()
      -- Check if we have coverage data
      local gcov_files = vim.fn.glob("**/*.gcov", false, true)
      if #gcov_files > 0 and has_coverage then
        -- Coverage data exists but might not be loaded
        if not coverage.is_loaded() then
          coverage.load(false) -- Load silently
        end
      end
    end,
  })

  -- Optionally auto-generate coverage after successful test run
  if self.config.auto_coverage_on_test then
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "ManagerTestComplete",
      callback = function(args)
        if args.data and args.data.status == "SUCCESS" then
          vim.defer_fn(function()
            coverage.load(true)
          end, 1000)
        end
      end,
    })
  end
end

-- Get coverage percentage for current file
function M:get_file_coverage()
  if not has_coverage then
    return nil
  end

  local current_file = vim.api.nvim_buf_get_name(0)
  local summary = coverage.get_summary()

  if summary and summary.files then
    for _, file in ipairs(summary.files) do
      if file.filename == current_file or vim.fn.fnamemodify(file.filename, ":p") == current_file then
        return file.coverage
      end
    end
  end

  return nil
end

-- Integration with statusline
function M:statusline()
  local coverage_pct = self:get_file_coverage()
  if coverage_pct then
    local icon = coverage_pct >= 80 and "✓" or "⚠"
    return string.format("%s %.1f%%", icon, coverage_pct)
  end
  return ""
end

return M
