-- manager/core/workspace.lua
-- Workspace and activity management

local M = {}

local uv = vim.loop
local api = vim.api

-- State
M.state = {
  workspace_root = nil,
  current_activity = nil,
  watcher = nil,
  check_timer = nil,
}

-- Initialize workspace module
function M:init(config)
  self.config = config

  -- Get initial workspace root
  self:update_root()

  -- Get initial activity
  self:update_activity()

  -- Setup file watcher
  if self.config.auto_detect_activity then
    self:_setup_watcher()
  end

  return self
end

-- Get workspace root using manager command
function M:update_root()
  local handle = io.popen("manager getwsroot 2>/dev/null")
  if handle then
    local result = handle:read("*a"):gsub("%s+$", "")
    handle:close()

    if result ~= "" then
      self.state.workspace_root = result
      return result
    end
  end

  -- Fallback to git root
  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")[1]
  if git_root and git_root ~= "" then
    self.state.workspace_root = git_root
    return git_root
  end

  -- Fallback to current directory
  self.state.workspace_root = vim.fn.getcwd()
  return self.state.workspace_root
end

-- Get current activity
function M:update_activity()
  local handle = io.popen("manager lsact 2>/dev/null")
  if handle then
    local result = handle:read("*a"):gsub("%s+$", "")
    handle:close()

    if result ~= "" and result ~= self.state.current_activity then
      local old_activity = self.state.current_activity
      self.state.current_activity = result

      if old_activity then
        vim.schedule(function()
          vim.notify(string.format("Activity changed: %s → %s", old_activity, result), vim.log.levels.INFO)
          self:_on_activity_changed(old_activity, result)
        end)
      end

      return result
    end
  end

  return self.state.current_activity
end

-- Setup file watcher for .git directory
function M:_setup_watcher()
  if not self.state.workspace_root then
    return
  end

  local git_dir = self.state.workspace_root .. "/.git"

  -- Check if .git directory exists
  if vim.fn.isdirectory(git_dir) == 0 then
    return
  end

  -- Stop existing watcher
  if self.state.watcher then
    self.state.watcher:stop()
    self.state.watcher = nil
  end

  -- Create new watcher
  self.state.watcher = uv.new_fs_event()
  if self.state.watcher then
    self.state.watcher:start(git_dir, {}, vim.schedule_wrap(function(err, filename, events)
      if not err then
        -- Debounce activity check
        if self.state.check_timer then
          uv.timer_stop(self.state.check_timer)
        end

        self.state.check_timer = uv.new_timer()
        self.state.check_timer:start(500, 0, vim.schedule_wrap(function()
          self:check_activity_change()
          self.state.check_timer:stop()
          self.state.check_timer = nil
        end))
      end
    end))
  end
end

-- Check if activity has changed
function M:check_activity_change()
  local old_activity = self.state.current_activity
  self:update_activity()

  if old_activity ~= self.state.current_activity and self.state.current_activity then
    self:_on_activity_changed(old_activity, self.state.current_activity)
  end
end

-- Handle activity change
function M:_on_activity_changed(old_activity, new_activity)
  -- Emit user event
  api.nvim_exec_autocmds("User", {
    pattern = "ManagerActivityChanged",
    data = {
      old = old_activity,
      new = new_activity,
    },
  })

  -- Clear caches
  local cache = require("manager.utils.cache")
  cache:invalidate_activity(old_activity)

  -- Load new activity configuration
  local config = require("manager.core.config")
  config:load_activity(new_activity)

  -- Restart LSP if needed
  if self.config.integrations and self.config.integrations.lsp then
    local lsp = require("manager.integrations.lsp")
    lsp:restart_for_activity(new_activity)
  end
end

-- Get current state
function M:get_current_activity()
  return self.state.current_activity
end

function M:get_root()
  return self.state.workspace_root
end

-- Show status information
function M:show_status()
  local lines = {
    "Manager Status",
    "══════════════",
    "",
    "Workspace: " .. (self.state.workspace_root or "none"),
    "Activity: " .. (self.state.current_activity or "none"),
  }

  -- Add package info
  local package = require("manager.core.package")
  local current_pkg = package:get_current()
  if current_pkg then
    table.insert(lines, "Package: " .. vim.fn.fnamemodify(current_pkg, ":t"))
  else
    table.insert(lines, "Package: none")
  end

  -- Add builder status
  local builder = require("manager.builders.overseer")
  local running_tasks = builder:get_running_tasks()
  if #running_tasks > 0 then
    table.insert(lines, "")
    table.insert(lines, "Running Tasks:")
    for _, task in ipairs(running_tasks) do
      table.insert(lines, "  • " .. task.name)
    end
  end

  -- Show in floating window
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_set_option(buf, "modifiable", false)
  api.nvim_buf_set_option(buf, "buftype", "nofile")

  local width = 40
  local height = #lines

  local opts = {
    relative = "editor",
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = "minimal",
    border = "rounded",
    title = " Manager Status ",
    title_pos = "center",
  }

  local win = api.nvim_open_win(buf, true, opts)

  -- Close on any key
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = buf })
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
end

-- Cleanup on exit
function M:cleanup()
  if self.state.watcher then
    self.state.watcher:stop()
    self.state.watcher = nil
  end

  if self.state.check_timer then
    self.state.check_timer:stop()
    self.state.check_timer = nil
  end
end

return M
