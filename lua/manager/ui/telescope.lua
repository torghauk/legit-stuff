-- package_telescope.lua
-- Telescope integration for package-aware file searching

local M = {}

-- Dependencies
local has_telescope, telescope = pcall(require, 'telescope')
if not has_telescope then
  vim.notify("Telescope not found. Package file search will be limited.", vim.log.levels.WARN)
  return M
end

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local previewers = require('telescope.previewers')
local make_entry = require('telescope.make_entry')
local Path = require('plenary.path')

-- ============================================================================
-- Cache Management
-- ============================================================================

local cache = {
  -- Cache structure: [activity:package] = { files = {...}, expires = timestamp }
  package_files = {},
  -- Cache duration in seconds (5 minutes)
  cache_duration = 300,
}

function cache:get_key(activity, package)
  return (activity or "default") .. ":" .. (package or "none")
end

function cache:is_valid(key)
  local entry = self.package_files[key]
  if not entry then
    return false
  end
  return os.time() < entry.expires
end

function cache:set(key, files)
  self.package_files[key] = {
    files = files,
    expires = os.time() + self.cache_duration
  }
end

function cache:get(key)
  if self:is_valid(key) then
    return self.package_files[key].files
  end
  return nil
end

function cache:invalidate(key)
  self.package_files[key] = nil
end

function cache:invalidate_all()
  self.package_files = {}
end

-- ============================================================================
-- File Collection from Project Info
-- ============================================================================

-- Extract all relevant files from a package
local function get_package_files(project_info, package_name)
  local files = {}
  local seen = {} -- Deduplication

  -- Find the target package
  local target_package = nil
  for _, pkg in ipairs(project_info.packages) do
    if pkg.name == package_name or pkg.pkg_file == package_name then
      target_package = pkg
      break
    end
  end

  if not target_package then
    return files
  end

  -- Add source files
  for _, source in ipairs(target_package.sources) do
    if not seen[source] then
      table.insert(files, {
        path = source,
        type = "source",
        display = vim.fn.fnamemodify(source, ":t"),
        relative = vim.fn.fnamemodify(source, ":.")
      })
      seen[source] = true
    end
  end

  -- Add header files from dependencies (include directories)
  for _, dep_dir in ipairs(target_package.dependencies) do
    -- Find header files in dependency directories
    local headers = vim.fn.glob(dep_dir .. "/**/*.{h,hpp,hxx,H}", false, true)
    for _, header in ipairs(headers) do
      if not seen[header] then
        table.insert(files, {
          path = header,
          type = "header",
          display = vim.fn.fnamemodify(header, ":t"),
          relative = vim.fn.fnamemodify(header, ":.")
        })
        seen[header] = true
      end
    end
  end

  -- Add output files
  for _, output in ipairs(target_package.outputs) do
    if not seen[output] then
      table.insert(files, {
        path = output,
        type = "output",
        display = vim.fn.fnamemodify(output, ":t"),
        relative = vim.fn.fnamemodify(output, ":.")
      })
      seen[output] = true
    end
  end

  -- Add the package file itself
  if not seen[target_package.pkg_file] then
    table.insert(files, {
      path = target_package.pkg_file,
      type = "package",
      display = vim.fn.fnamemodify(target_package.pkg_file, ":t"),
      relative = vim.fn.fnamemodify(target_package.pkg_file, ":.")
    })
    seen[target_package.pkg_file] = true
  end

  -- Add generated files related to this package
  for _, gen in ipairs(project_info.generated_files) do
    -- Check if the source file belongs to this package
    for _, source in ipairs(target_package.sources) do
      if gen.source == source and not seen[gen.generated] then
        table.insert(files, {
          path = gen.generated,
          type = "generated",
          display = vim.fn.fnamemodify(gen.generated, ":t"),
          relative = vim.fn.fnamemodify(gen.generated, ":.")
        })
        seen[gen.generated] = true
      end
    end
  end

  return files
end

-- Get all packages and their dependencies for cross-package search
local function get_all_package_files(project_info)
  local files = {}
  local seen = {}

  for _, pkg in ipairs(project_info.packages) do
    -- Add all sources
    for _, source in ipairs(pkg.sources) do
      if not seen[source] then
        table.insert(files, {
          path = source,
          type = "source",
          package = pkg.name,
          display = vim.fn.fnamemodify(source, ":t"),
          relative = vim.fn.fnamemodify(source, ":.")
        })
        seen[source] = true
      end
    end

    -- Add package files
    if not seen[pkg.pkg_file] then
      table.insert(files, {
        path = pkg.pkg_file,
        type = "package",
        package = pkg.name,
        display = vim.fn.fnamemodify(pkg.pkg_file, ":t"),
        relative = vim.fn.fnamemodify(pkg.pkg_file, ":.")
      })
      seen[pkg.pkg_file] = true
    end
  end

  return files
end

-- ============================================================================
-- Custom Telescope Pickers
-- ============================================================================

-- Create entry maker for package files
local function make_package_entry(opts)
  opts = opts or {}

  return function(entry)
    local display_items = {}

    -- Icon based on file type
    local icon = ""
    if entry.type == "source" then
      icon = ""
    elseif entry.type == "header" then
      icon = ""
    elseif entry.type == "package" then
      icon = ""
    elseif entry.type == "generated" then
      icon = ""
    elseif entry.type == "output" then
      icon = "󰈔"
    end

    -- Build display string
    local display = string.format("%s %s", icon, entry.display)

    -- Add relative path if different from display name
    if entry.relative ~= entry.display then
      display = display .. string.format(" (%s)", entry.relative)
    end

    -- Add package name if searching across packages
    if entry.package then
      display = display .. string.format(" [%s]", entry.package)
    end

    return {
      value = entry,
      display = display,
      ordinal = entry.display .. " " .. entry.relative,
      path = entry.path,
      lnum = 1,
    }
  end
end

-- Package file finder
function M.find_package_files(opts)
  opts = opts or {}

  -- Get manager system reference
  local manager = opts.manager or require('manager-system').ManagerSystem

  if not manager.current_package then
    vim.notify("No package selected. Use :ManagerSelectPackage first", vim.log.levels.ERROR)
    return
  end

  -- Check cache
  local cache_key = cache:get_key(manager.current_activity, manager.current_package)
  local files = cache:get(cache_key)

  if not files then
    -- Parse project info to get files
    local parser = require('project_info_parser')

    -- Generate fresh project info if needed
    local info_file = manager:generate_project_info(manager.current_package, "default")
    if not info_file then
      vim.notify("Failed to generate project info", vim.log.levels.ERROR)
      return
    end

    local project_info, err = parser.parse_project_info(info_file)
    vim.fn.delete(info_file) -- Clean up

    if not project_info then
      vim.notify("Failed to parse project info: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Get files for current package
    files = get_package_files(project_info, manager.current_package)

    -- Cache the results
    cache:set(cache_key, files)
  end

  -- Create telescope picker
  pickers.new(opts, {
    prompt_title = "Package Files: " .. vim.fn.fnamemodify(manager.current_package, ":t"),
    finder = finders.new_table {
      results = files,
      entry_maker = make_package_entry(opts),
    },
    previewer = conf.file_previewer(opts),
    sorter = conf.file_sorter(opts),
    attach_mappings = function(prompt_bufnr, map)
      -- Custom action to invalidate cache and refresh
      map("i", "<C-r>", function()
        cache:invalidate(cache_key)
        actions.close(prompt_bufnr)
        vim.schedule(function()
          M.find_package_files(opts)
        end)
      end)

      -- Custom action to show file info
      map("i", "<C-i>", function()
        local selection = action_state.get_selected_entry()
        if selection then
          local file_info = selection.value
          print(string.format("File: %s\nType: %s\nPath: %s",
            file_info.display, file_info.type, file_info.path))
        end
      end)

      return true
    end,
  }):find()
end

-- Find files across all packages
function M.find_all_packages_files(opts)
  opts = opts or {}

  local manager = opts.manager or require('manager-system').ManagerSystem

  -- Parse all packages
  local parser = require('project_info_parser')

  -- We need to generate info for the entire workspace
  -- This might require a different command or iterating through packages
  vim.notify("Scanning all packages...", vim.log.levels.INFO)

  -- For now, use current package info as example
  if not manager.current_package then
    vim.notify("No package selected to start from", vim.log.levels.ERROR)
    return
  end

  local info_file = manager:generate_project_info(manager.current_package, "default")
  if not info_file then
    return
  end

  local project_info, err = parser.parse_project_info(info_file)
  vim.fn.delete(info_file)

  if not project_info then
    vim.notify("Failed to parse project info: " .. err, vim.log.levels.ERROR)
    return
  end

  local files = get_all_package_files(project_info)

  pickers.new(opts, {
    prompt_title = "All Package Files",
    finder = finders.new_table {
      results = files,
      entry_maker = make_package_entry(opts),
    },
    previewer = conf.file_previewer(opts),
    sorter = conf.file_sorter(opts),
  }):find()
end

-- Grep only in package files
function M.grep_package_files(opts)
  opts = opts or {}

  local manager = opts.manager or require('manager').ManagerSystem

  if not manager.current_package then
    vim.notify("No package selected. Use :ManagerSelectPackage first", vim.log.levels.ERROR)
    return
  end

  -- Get package files
  local cache_key = cache:get_key(manager.current_activity, manager.current_package)
  local files = cache:get(cache_key)

  if not files then
    -- Generate and parse project info
    local parser = require('project_info_parser')
    local info_file = manager:generate_project_info(manager.current_package, "default")

    if not info_file then
      return
    end

    local project_info, err = parser.parse_project_info(info_file)
    vim.fn.delete(info_file)

    if not project_info then
      vim.notify("Failed to parse project info: " .. err, vim.log.levels.ERROR)
      return
    end

    files = get_package_files(project_info, manager.current_package)
    cache:set(cache_key, files)
  end

  -- Extract just the file paths
  local file_paths = {}
  for _, file in ipairs(files) do
    -- Only include actual source and header files for grep
    if file.type == "source" or file.type == "header" then
      table.insert(file_paths, file.path)
    end
  end

  -- Use telescope's live_grep with specific files
  require('telescope.builtin').live_grep({
    prompt_title = "Grep Package: " .. vim.fn.fnamemodify(manager.current_package, ":t"),
    search_dirs = file_paths,
    additional_args = function()
      return { "--hidden" }
    end,
  })
end

-- ============================================================================
-- Integration Commands
-- ============================================================================

function M.setup(opts)
  opts = opts or {}

  -- Create user commands
  vim.api.nvim_create_user_command("TelescopePackageFiles", function()
    M.find_package_files()
  end, {
    desc = "Find files in current package"
  })

  vim.api.nvim_create_user_command("TelescopeAllPackages", function()
    M.find_all_packages_files()
  end, {
    desc = "Find files across all packages"
  })

  vim.api.nvim_create_user_command("TelescopePackageGrep", function()
    M.grep_package_files()
  end, {
    desc = "Grep in current package files"
  })

  -- Add keymaps
  local keymap_opts = { noremap = true, silent = true }

  -- Package-aware file search
  vim.keymap.set("n", "<leader>fp", function()
    M.find_package_files()
  end, vim.tbl_extend("force", keymap_opts, { desc = "Find package files" }))

  -- Package-aware grep
  vim.keymap.set("n", "<leader>gp", function()
    M.grep_package_files()
  end, vim.tbl_extend("force", keymap_opts, { desc = "Grep package files" }))

  -- All packages search
  vim.keymap.set("n", "<leader>fP", function()
    M.find_all_packages_files()
  end, vim.tbl_extend("force", keymap_opts, { desc = "Find all packages files" }))

  -- Override default telescope mappings if requested
  if opts.override_defaults then
    vim.keymap.set("n", "<leader>ff", function()
      M.find_package_files()
    end, vim.tbl_extend("force", keymap_opts, { desc = "Find files (package-aware)" }))

    vim.keymap.set("n", "<leader>fg", function()
      M.grep_package_files()
    end, vim.tbl_extend("force", keymap_opts, { desc = "Live grep (package-aware)" }))
  end
end

-- ============================================================================
-- Module Export
-- ============================================================================

return M
