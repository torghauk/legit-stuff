-- manager/builders/compile_commands.lua
-- Compile commands generation for LSP integration

local M = {}

local api = vim.api

-- Initialize module
function M:init(config)
  self.config = config
  return self
end

-- Generate compile_commands.json for a package
function M:generate(pkg_file, target)
  local package = require("manager.core.package")
  pkg_file = pkg_file or package:get_current()
  target = target or self.config.default_target or "this"

  if not pkg_file then
    vim.notify("No package specified for compile commands generation", vim.log.levels.ERROR)
    return false
  end

  vim.notify("Generating compile_commands.json...", vim.log.levels.INFO)

  -- Generate project info
  local info_file = self:_generate_project_info(pkg_file, target)
  if not info_file then
    return false
  end

  -- Parse project info
  local parser = require("manager.builders.project_info")
  local project_info = parser:parse_project_info(info_file)
  vim.fn.delete(info_file)

  if not project_info then
    vim.notify("Failed to parse project info", vim.log.levels.ERROR)
    return false
  end

  -- Generate compile commands
  local commands = self:_create_compile_commands(project_info)

  -- Determine output path
  local output_dir = self:_get_output_directory(pkg_file)
  local output_path = output_dir .. "/compile_commands.json"

  -- Write to file
  local success = self:_write_compile_commands(commands, output_path)

  if success then
    vim.notify("Generated compile_commands.json with " .. #commands .. " entries", vim.log.levels.INFO)

    -- Notify LSP
    self:_notify_lsp(output_path)
  end

  return success
end

-- Generate project info file
function M:_generate_project_info(pkg_file, target)
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

-- Create compile commands from project info
function M:_create_compile_commands(project_info)
  local commands = {}
  local workspace = require("manager.core.workspace")
  local workspace_root = workspace:get_root() or vim.fn.getcwd()

  -- Default compiler settings
  local compiler = self.config.compiler or "clang++"
  local default_flags = self.config.default_flags or {
    "-std=c++17",
    "-Wall",
    "-Wextra",
  }

  for _, pkg in ipairs(project_info.packages) do
    -- Build include flags from dependencies
    local include_flags = {}
    for _, dep in ipairs(pkg.dependencies) do
      table.insert(include_flags, "-I" .. dep)
    end

    -- Process each source file
    for _, source in ipairs(pkg.sources) do
      local entry = {
        file = source,
        directory = workspace_root,
        arguments = { compiler },
      }

      -- Add default flags
      vim.list_extend(entry.arguments, default_flags)

      -- Add include flags
      vim.list_extend(entry.arguments, include_flags)

      -- Add package-specific flags
      vim.list_extend(entry.arguments, pkg.flags)

      -- Add the source file
      table.insert(entry.arguments, source)

      table.insert(commands, entry)
    end
  end

  return commands
end

-- Determine output directory for compile_commands.json
function M:_get_output_directory(pkg_file)
  -- Priority order:
  -- 1. Configured directory
  -- 2. Package directory
  -- 3. Workspace root
  -- 4. Current directory

  if self.config.compile_commands_dir then
    local dir = self.config.compile_commands_dir
    if not vim.fn.isabsolute(dir) then
      local workspace = require("manager.core.workspace")
      dir = workspace:get_root() .. "/" .. dir
    end
    vim.fn.mkdir(dir, "p")
    return dir
  end

  if pkg_file then
    return vim.fn.fnamemodify(pkg_file, ":h")
  end

  local workspace = require("manager.core.workspace")
  return workspace:get_root() or vim.fn.getcwd()
end

-- Write compile commands to file
function M:_write_compile_commands(commands, output_path)
  -- Ensure directory exists
  vim.fn.mkdir(vim.fn.fnamemodify(output_path, ":h"), "p")

  -- Convert to JSON
  local json_str = vim.json.encode(commands)

  -- Format JSON for readability (optional)
  if self.config.format_json ~= false then
    json_str = self:_format_json(json_str)
  end

  -- Write to file
  local file = io.open(output_path, "w")
  if not file then
    vim.notify("Failed to write compile_commands.json", vim.log.levels.ERROR)
    return false
  end

  file:write(json_str)
  file:close()

  return true
end

-- Format JSON string for readability
function M:_format_json(json_str)
  -- Basic formatting - proper formatting would require a JSON library
  json_str = json_str:gsub(',%[', ',\n[')
  json_str = json_str:gsub('%[{', '[\n  {')
  json_str = json_str:gsub('},{', '},\n  {')
  json_str = json_str:gsub('}%]', '}\n]')
  return json_str
end

-- Notify LSP about new compile commands
function M:_notify_lsp(compile_commands_path)
  -- Check if clangd is running
  local clients = vim.lsp.get_active_clients({ name = "clangd" })

  if #clients == 0 then
    -- No clangd running, it will pick up the file when started
    return
  end

  -- Notify user
  vim.notify("Restarting LSP to pick up new compile_commands.json", vim.log.levels.INFO)

  -- Restart clangd
  vim.defer_fn(function()
    for _, client in ipairs(clients) do
      local buffers = vim.lsp.get_buffers_by_client_id(client.id)
      vim.lsp.stop_client(client.id)

      -- Restart for C/C++ buffers
      vim.defer_fn(function()
        for _, buf in ipairs(buffers) do
          if vim.api.nvim_buf_is_valid(buf) then
            local ft = vim.bo[buf].filetype
            if ft == "cpp" or ft == "h" then
              vim.cmd("LspStart clangd")
              break
            end
          end
        end
      end, 100)
    end
  end, 100)
end

-- Generate for all packages in workspace
function M:generate_all()
  local package = require("manager.core.package")
  local packages = package:find_all()

  if #packages == 0 then
    vim.notify("No packages found in workspace", vim.log.levels.WARN)
    return
  end

  local success_count = 0
  local total = #packages

  for i, pkg_file in ipairs(packages) do
    vim.notify(string.format("Processing %d/%d: %s", i, total, vim.fn.fnamemodify(pkg_file, ":t")))

    if self:generate(pkg_file) then
      success_count = success_count + 1
    end
  end

  vim.notify(string.format("Generated compile commands for %d/%d packages", success_count, total),
    success_count == total and vim.log.levels.INFO or vim.log.levels.WARN)
end

-- Check if compile_commands.json exists for current package
function M:exists()
  local package = require("manager.core.package")
  local pkg_file = package:get_current()

  if not pkg_file then
    return false
  end

  local output_dir = self:_get_output_directory(pkg_file)
  local compile_commands = output_dir .. "/compile_commands.json"

  return vim.fn.filereadable(compile_commands) == 1
end

-- Get path to compile_commands.json for current package
function M:get_path()
  local package = require("manager.core.package")
  local pkg_file = package:get_current()

  if not pkg_file then
    return nil
  end

  local output_dir = self:_get_output_directory(pkg_file)
  return output_dir .. "/compile_commands.json"
end

return M
