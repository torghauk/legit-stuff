-- manager/core/package.lua
-- Package management module

local M = {}

local api = vim.api

-- State
M.state = {
  current_package = nil,
  package_cache = {},
  last_scan_time = 0,
}

-- Initialize package module
function M:init(config)
  self.config = config
  return self
end

-- Get current package
function M:get_current()
  return self.state.current_package
end

-- Set current package
function M:set_current(pkg_file)
  if not pkg_file then
    self.state.current_package = nil
    return false
  end

  -- Validate package file
  if vim.fn.filereadable(pkg_file) == 0 then
    vim.notify("Package file not found: " .. pkg_file, vim.log.levels.ERROR)
    return false
  end

  local old_package = self.state.current_package
  self.state.current_package = pkg_file

  -- Store in activity config
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if activity then
    local config = require("manager.core.config")
    config:set_activity_value(activity, "last_package", pkg_file)
  end

  -- Emit event if package changed
  if old_package ~= pkg_file then
    api.nvim_exec_autocmds("User", {
      pattern = "ManagerPackageChanged",
      data = {
        old = old_package,
        new = pkg_file,
      },
    })

    -- Generate compile commands if configured
    if self.config.builder and self.config.builder.auto_generate_compile_commands then
      vim.schedule(function()
        self:generate_compile_commands()
      end)
    end
  end

  vim.notify("Current package: " .. vim.fn.fnamemodify(pkg_file, ":t"), vim.log.levels.INFO)
  return true
end

-- Find all package files in workspace
function M:find_all()
  local workspace = require("manager.core.workspace")
  local root = workspace:get_root()

  if not root then
    return {}
  end

  -- Check cache
  local now = os.time()
  if now - self.state.last_scan_time < 30 then -- Cache for 30 seconds
    return self.state.package_cache
  end

  local packages = {}

  -- Use fd if available for faster search
  local has_fd = vim.fn.executable("fd") == 1
  local cmd

  if has_fd then
    cmd = string.format("fd -e pkg -t f . %s", vim.fn.shellescape(root))
  else
    cmd = string.format("find %s -name '*.pkg' -type f 2>/dev/null", vim.fn.shellescape(root))
  end

  local handle = io.popen(cmd)
  if handle then
    for line in handle:lines() do
      table.insert(packages, line)
    end
    handle:close()
  end

  -- Update cache
  self.state.package_cache = packages
  self.state.last_scan_time = now

  return packages
end

-- Get available packages (for completion)
function M:get_available()
  local packages = self:find_all()
  local names = {}

  for _, pkg in ipairs(packages) do
    table.insert(names, pkg)
  end

  return names
end

-- Select package interactively
function M:select(pkg_file)
  if pkg_file and pkg_file ~= "" then
    self:set_current(pkg_file)
    return
  end

  -- Try to use Telescope if available
  local ok, telescope = pcall(require, "telescope")
  if ok then
    self:_select_with_telescope()
  else
    self:_select_with_vim_ui()
  end
end

-- Select package using Telescope
function M:_select_with_telescope()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local packages = self:find_all()

  pickers.new({}, {
    prompt_title = "Select Package",
    finder = finders.new_table({
      results = packages,
      entry_maker = function(entry)
        return {
          value = entry,
          display = vim.fn.fnamemodify(entry, ":t") .. " (" .. vim.fn.fnamemodify(entry, ":h:t") .. ")",
          ordinal = vim.fn.fnamemodify(entry, ":t"),
          path = entry,
        }
      end,
    }),
    sorter = conf.file_sorter({}),
    previewer = conf.file_previewer({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          self:set_current(selection.path)
        end
      end)
      return true
    end,
  }):find()
end

-- Select package using vim.ui.select
function M:_select_with_vim_ui()
  local packages = self:find_all()

  if #packages == 0 then
    vim.notify("No package files found in workspace", vim.log.levels.WARN)
    return
  end

  -- Create display items
  local items = {}
  for _, pkg in ipairs(packages) do
    table.insert(items, {
      path = pkg,
      display = vim.fn.fnamemodify(pkg, ":t") .. " (" .. vim.fn.fnamemodify(pkg, ":h:t") .. ")",
    })
  end

  vim.ui.select(items, {
    prompt = "Select package:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if choice then
      self:set_current(choice.path)
    end
  end)
end

-- Generate compile commands for current package
function M:generate_compile_commands()
  local compile_commands = require("manager.builders.compile_commands")

  if not self.state.current_package then
    vim.notify("No package selected", vim.log.levels.ERROR)
    return false
  end

  return compile_commands:generate(self.state.current_package)
end

-- Get package info
function M:get_info(pkg_file)
  pkg_file = pkg_file or self.state.current_package

  if not pkg_file then
    return nil
  end

  local parser = require("manager.parsers.project_info")
  local info_file = self:_generate_info_file(pkg_file)

  if not info_file then
    return nil
  end

  local info = parser:parse(info_file)
  vim.fn.delete(info_file)

  return info
end

-- Generate project info file
function M:_generate_info_file(pkg_file, target)
  target = target or self.config.builder.default_target or "default"

  local info_file = vim.fn.tempname() .. "_info.txt"

  local cmd = string.format("builder -a %s -b %s +pkg_info %s",
    vim.fn.shellescape(pkg_file),
    vim.fn.shellescape(target),
    vim.fn.shellescape(info_file)
  )

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to generate project info: " .. result, vim.log.levels.ERROR)
    return nil
  end

  return info_file
end

-- Quick switch to recent packages
function M:switch_recent()
  local config = require("manager.core.config")
  local recent = config:get_recent_packages()

  if #recent == 0 then
    vim.notify("No recent packages", vim.log.levels.INFO)
    return
  end

  vim.ui.select(recent, {
    prompt = "Recent packages:",
    format_item = function(item)
      return vim.fn.fnamemodify(item, ":t") .. " (" .. vim.fn.fnamemodify(item, ":h:t") .. ")"
    end,
  }, function(choice)
    if choice then
      self:set_current(choice)
    end
  end)
end

-- Get files in current package
function M:get_files()
  if not self.state.current_package then
    return {}
  end

  local cache = require("manager.utils.cache")
  local cached = cache:get("package_files:" .. self.state.current_package)

  if cached then
    return cached
  end

  local info = self:get_info()
  if not info then
    return {}
  end

  local files = {}
  local seen = {}

  for _, pkg in ipairs(info.packages) do
    -- Add sources
    for _, source in ipairs(pkg.sources) do
      if not seen[source] then
        table.insert(files, {
          path = source,
          type = "source",
          package = pkg.name,
        })
        seen[source] = true
      end
    end

    -- Add headers from dependencies
    for _, dep_dir in ipairs(pkg.dependencies) do
      local headers = vim.fn.glob(dep_dir .. "/**/*.{h,hpp,hxx}", false, true)
      for _, header in ipairs(headers) do
        if not seen[header] then
          table.insert(files, {
            path = header,
            type = "header",
            package = pkg.name,
          })
          seen[header] = true
        end
      end
    end
  end

  cache:set("package_files:" .. self.state.current_package, files, 60) -- Cache for 1 minute

  return files
end

return M
