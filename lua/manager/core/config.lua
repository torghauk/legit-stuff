-- manager/core/config.lua
-- Configuration persistence and session management

local M = {}

local api = vim.api
local fn = vim.fn

-- State
M.state = {
  -- Activity-specific configurations
  activity_configs = {},
  -- Recent packages across all activities
  recent_packages = {},
  -- Global settings
  global_config = {},
  -- Session data
  session_data = {},
}

-- Paths
M.paths = {
  config_dir = fn.stdpath("data") .. "/manager",
  activity_config = fn.stdpath("data") .. "/manager/activity_configs.json",
  recent_packages = fn.stdpath("data") .. "/manager/recent_packages.json",
  global_config = fn.stdpath("data") .. "/manager/global_config.json",
  sessions_dir = fn.stdpath("data") .. "/manager/sessions",
}

-- Initialize config module
function M:init(config)
  self.config = config

  -- Ensure directories exist
  fn.mkdir(self.paths.config_dir, "p")
  fn.mkdir(self.paths.sessions_dir, "p")

  -- Load persisted configurations
  self:load()

  return self
end

-- Load all configurations from disk
function M:load()
  self:load_activity_configs()
  self:load_recent_packages()
  self:load_global_config()
end

-- Save all configurations to disk
function M:save()
  self:save_activity_configs()
  self:save_recent_packages()
  self:save_global_config()
end

-- ============================================================================
-- Activity Configurations
-- ============================================================================

-- Load activity configurations
function M:load_activity_configs()
  if fn.filereadable(self.paths.activity_config) == 1 then
    local content = table.concat(fn.readfile(self.paths.activity_config), "\n")
    local ok, configs = pcall(vim.json.decode, content)
    if ok and configs then
      self.state.activity_configs = configs
    end
  end
end

-- Save activity configurations
function M:save_activity_configs()
  local content = vim.json.encode(self.state.activity_configs)
  fn.writefile(vim.split(content, "\n"), self.paths.activity_config)
end

-- Get configuration for an activity
function M:get_activity_config(activity)
  activity = activity or require("manager.core.workspace"):get_current_activity()

  if not activity then
    return {}
  end

  if not self.state.activity_configs[activity] then
    self.state.activity_configs[activity] = {
      last_package = nil,
      build_args = {},
      test_args = {},
      test_filters = {},
      default_target = "default",
      created_at = os.time(),
      updated_at = os.time(),
    }
  end

  return self.state.activity_configs[activity]
end

-- Load configuration for specific activity
function M:load_activity(activity)
  local config = self:get_activity_config(activity)

  -- Restore package if it still exists
  if config.last_package and fn.filereadable(config.last_package) == 1 then
    local package = require("manager.core.package")
    package:set_current(config.last_package)
  end

  -- Update accessed time
  config.accessed_at = os.time()
  self:save_activity_configs()

  return config
end

-- Set a value in activity configuration
function M:set_activity_value(activity, key, value)
  local config = self:get_activity_config(activity)
  config[key] = value
  config.updated_at = os.time()
  self:save_activity_configs()
end

-- Get a value from activity configuration
function M:get_activity_value(activity, key, default)
  local config = self:get_activity_config(activity)
  return config[key] or default
end

-- ============================================================================
-- Recent Packages
-- ============================================================================

-- Load recent packages list
function M:load_recent_packages()
  if fn.filereadable(self.paths.recent_packages) == 1 then
    local content = table.concat(fn.readfile(self.paths.recent_packages), "\n")
    local ok, packages = pcall(vim.json.decode, content)
    if ok and packages then
      self.state.recent_packages = packages
    end
  end
end

-- Save recent packages list
function M:save_recent_packages()
  local content = vim.json.encode(self.state.recent_packages)
  fn.writefile(vim.split(content, "\n"), self.paths.recent_packages)
end

-- Add package to recent list
function M:add_recent_package(pkg_file)
  if not pkg_file then
    return
  end

  -- Remove if already in list
  for i, pkg in ipairs(self.state.recent_packages) do
    if pkg == pkg_file then
      table.remove(self.state.recent_packages, i)
      break
    end
  end

  -- Add to front of list
  table.insert(self.state.recent_packages, 1, pkg_file)

  -- Keep only last 20
  while #self.state.recent_packages > 20 do
    table.remove(self.state.recent_packages)
  end

  self:save_recent_packages()
end

-- Get recent packages
function M:get_recent_packages(limit)
  limit = limit or 10
  local recent = {}

  for i = 1, math.min(limit, #self.state.recent_packages) do
    local pkg = self.state.recent_packages[i]
    -- Only include if file still exists
    if fn.filereadable(pkg) == 1 then
      table.insert(recent, pkg)
    end
  end

  return recent
end

-- ============================================================================
-- Global Configuration
-- ============================================================================

-- Load global configuration
function M:load_global_config()
  if fn.filereadable(self.paths.global_config) == 1 then
    local content = table.concat(fn.readfile(self.paths.global_config), "\n")
    local ok, config = pcall(vim.json.decode, content)
    if ok and config then
      self.state.global_config = config
    end
  end
end

-- Save global configuration
function M:save_global_config()
  local content = vim.json.encode(self.state.global_config)
  fn.writefile(vim.split(content, "\n"), self.paths.global_config)
end

-- Set global configuration value
function M:set_global(key, value)
  self.state.global_config[key] = value
  self:save_global_config()
end

-- Get global configuration value
function M:get_global(key, default)
  return self.state.global_config[key] or default
end

-- ============================================================================
-- Build/Test Arguments Management
-- ============================================================================

-- Save build arguments for current activity
function M:save_build_args(args)
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if activity then
    self:set_activity_value(activity, "build_args", args)
  end
end

-- Get build arguments for current activity
function M:get_build_args()
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if activity then
    return self:get_activity_value(activity, "build_args", {})
  end

  return {}
end

-- Save test arguments for current activity
function M:save_test_args(args)
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if activity then
    self:set_activity_value(activity, "test_args", args)
  end
end

-- Get test arguments for current activity
function M:get_test_args()
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if activity then
    return self:get_activity_value(activity, "test_args", {})
  end

  return {}
end

-- Add test filter to history
function M:add_test_filter(filter)
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if not activity then
    return
  end

  local config = self:get_activity_config(activity)
  if not config.test_filters then
    config.test_filters = {}
  end

  -- Remove if already exists
  for i, f in ipairs(config.test_filters) do
    if f == filter then
      table.remove(config.test_filters, i)
      break
    end
  end

  -- Add to front
  table.insert(config.test_filters, 1, filter)

  -- Keep only last 20
  while #config.test_filters > 20 do
    table.remove(config.test_filters)
  end

  config.updated_at = os.time()
  self:save_activity_configs()
end

-- Get recent test filters
function M:get_test_filters(limit)
  limit = limit or 10
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if not activity then
    return {}
  end

  local config = self:get_activity_config(activity)
  local filters = config.test_filters or {}

  local result = {}
  for i = 1, math.min(limit, #filters) do
    table.insert(result, filters[i])
  end

  return result
end

-- ============================================================================
-- Session Management
-- ============================================================================

-- Get session file path for an activity
function M:get_session_file(activity)
  activity = activity or require("manager.core.workspace"):get_current_activity()

  if not activity then
    return nil
  end

  -- Sanitize activity name for filename
  local filename = activity:gsub("[^%w%-_]", "_") .. ".vim"
  return self.paths.sessions_dir .. "/" .. filename
end

-- Save current session
function M:save_session()
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if not activity then
    vim.notify("No activity to save session for", vim.log.levels.WARN)
    return
  end

  local session_file = self:get_session_file(activity)
  if not session_file then
    return
  end

  -- Save Vim session
  vim.cmd("mksession! " .. fn.fnameescape(session_file))

  -- Save additional context
  local context = {
    activity = activity,
    package = require("manager.core.package"):get_current(),
    workspace_root = workspace:get_root(),
    build_args = self:get_build_args(),
    test_args = self:get_test_args(),
    last_test_filter = self:get_test_filters(1)[1],
    saved_at = os.time(),
  }

  local context_file = session_file:gsub("%.vim$", ".json")
  local file = io.open(context_file, "w")
  if file then
    file:write(vim.json.encode(context))
    file:close()
  end

  vim.notify("Session saved for " .. activity, vim.log.levels.INFO)
end

-- Restore session for current activity
function M:restore_session()
  local workspace = require("manager.core.workspace")
  local activity = workspace:get_current_activity()

  if not activity then
    vim.notify("No activity to restore session for", vim.log.levels.WARN)
    return
  end

  local session_file = self:get_session_file(activity)
  if not session_file or fn.filereadable(session_file) == 0 then
    vim.notify("No saved session for " .. activity, vim.log.levels.INFO)
    return
  end

  -- Restore Vim session
  vim.cmd("source " .. fn.fnameescape(session_file))

  -- Restore additional context
  local context_file = session_file:gsub("%.vim$", ".json")
  if fn.filereadable(context_file) == 1 then
    local file = io.open(context_file, "r")
    if file then
      local content = file:read("*a")
      file:close()

      local ok, context = pcall(vim.json.decode, content)
      if ok and context then
        -- Restore package
        if context.package and fn.filereadable(context.package) == 1 then
          require("manager.core.package"):set_current(context.package)
        end

        -- Restore test filter
        if context.last_test_filter then
          self:add_test_filter(context.last_test_filter)
        end
      end
    end
  end

  vim.notify("Session restored for " .. activity, vim.log.levels.INFO)
end

-- Clean old sessions
function M:clean_old_sessions(days)
  days = days or 30
  local cutoff = os.time() - (days * 24 * 60 * 60)

  local sessions = fn.glob(self.paths.sessions_dir .. "/*.json", false, true)
  local removed = 0

  for _, context_file in ipairs(sessions) do
    local file = io.open(context_file, "r")
    if file then
      local content = file:read("*a")
      file:close()

      local ok, context = pcall(vim.json.decode, content)
      if ok and context and context.saved_at and context.saved_at < cutoff then
        -- Remove session files
        local session_file = context_file:gsub("%.json$", ".vim")
        fn.delete(session_file)
        fn.delete(context_file)
        removed = removed + 1
      end
    end
  end

  if removed > 0 then
    vim.notify(string.format("Cleaned %d old sessions", removed), vim.log.levels.INFO)
  end
end

-- ============================================================================
-- Statistics and Metrics
-- ============================================================================

-- Track command usage
function M:track_command(command)
  local stats = self:get_global("command_stats", {})

  if not stats[command] then
    stats[command] = { count = 0, last_used = 0 }
  end

  stats[command].count = stats[command].count + 1
  stats[command].last_used = os.time()

  self:set_global("command_stats", stats)
end

-- Get command statistics
function M:get_command_stats()
  return self:get_global("command_stats", {})
end

-- ============================================================================
-- Import/Export
-- ============================================================================

-- Export configuration
function M:export(filepath)
  filepath = filepath or (fn.getcwd() .. "/manager_config_export.json")

  local export_data = {
    version = "1.0.0",
    exported_at = os.time(),
    activity_configs = self.state.activity_configs,
    recent_packages = self.state.recent_packages,
    global_config = self.state.global_config,
  }

  local file = io.open(filepath, "w")
  if file then
    file:write(vim.json.encode(export_data))
    file:close()
    vim.notify("Configuration exported to " .. filepath, vim.log.levels.INFO)
    return true
  else
    vim.notify("Failed to export configuration", vim.log.levels.ERROR)
    return false
  end
end

-- Import configuration
function M:import(filepath)
  if fn.filereadable(filepath) == 0 then
    vim.notify("Import file not found: " .. filepath, vim.log.levels.ERROR)
    return false
  end

  local file = io.open(filepath, "r")
  if not file then
    return false
  end

  local content = file:read("*a")
  file:close()

  local ok, import_data = pcall(vim.json.decode, content)
  if not ok or not import_data then
    vim.notify("Failed to parse import file", vim.log.levels.ERROR)
    return false
  end

  -- Merge configurations
  if import_data.activity_configs then
    self.state.activity_configs = vim.tbl_deep_extend("force",
      self.state.activity_configs,
      import_data.activity_configs
    )
  end

  if import_data.recent_packages then
    -- Merge recent packages, keeping unique
    local seen = {}
    for _, pkg in ipairs(self.state.recent_packages) do
      seen[pkg] = true
    end

    for _, pkg in ipairs(import_data.recent_packages) do
      if not seen[pkg] then
        table.insert(self.state.recent_packages, pkg)
      end
    end
  end

  if import_data.global_config then
    self.state.global_config = vim.tbl_deep_extend("force",
      self.state.global_config,
      import_data.global_config
    )
  end

  -- Save merged configuration
  self:save()

  vim.notify("Configuration imported successfully", vim.log.levels.INFO)
  return true
end

return M
