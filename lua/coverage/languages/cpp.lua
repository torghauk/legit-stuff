-- coverage/languages/c.lua
-- GCov support for nvim-coverage
-- Place this file in ~/.config/nvim/lua/coverage/languages/c.lua
-- This will handle both C and C++ files

local M = {}

local Path = require("plenary.path")
local signs = require("coverage.signs")

-- Cache for parsed gcov data
M.coverage_data = {}
M.last_load_time = 0

-- Parse a .gcov file
local function parse_gcov_file(gcov_path)
  local coverage_data = {}
  local source_file = nil

  local file = io.open(gcov_path, "r")
  if not file then
    return nil, nil
  end

  for line in file:lines() do
    -- Parse source file name
    -- Format: "Source:filename"
    if line:match("^Source:") then
      source_file = line:match("^Source:(.+)$")
      if source_file then
        source_file = vim.trim(source_file)
      end
    end

    -- Parse coverage lines
    -- Format examples:
    -- "    #####:   42:    code_here"  (not executed)
    -- "        5:   42:    code_here"  (executed 5 times)
    -- "        -:   42:    code_here"  (not executable)
    local hits, line_num = line:match("^%s*([%d#%-]+):%s*(%d+):")

    if hits and line_num then
      line_num = tonumber(line_num)
      if hits == "-" then
        -- Not executable line, skip
        coverage_data[line_num] = nil
      elseif hits == "#####" or hits == "=====" then
        -- Line not executed
        coverage_data[line_num] = 0
      else
        -- Line executed N times
        local hit_count = tonumber(hits)
        if hit_count then
          coverage_data[line_num] = hit_count
        end
      end
    end
  end

  file:close()

  return source_file, coverage_data
end

-- Find all .gcov files in the project
local function find_gcov_files()
  local gcov_files = {}

  -- Look for gcov files in common locations
  local search_dirs = {
    vim.fn.getcwd(),
    vim.fn.getcwd() .. "/build",
    vim.fn.getcwd() .. "/coverage",
    vim.fn.getcwd() .. "/cmake-build-debug",
    vim.fn.getcwd() .. "/cmake-build-release",
  }

  -- Also check if there's a compile_commands.json to find build directory
  local compile_commands = vim.fn.findfile("compile_commands.json", vim.fn.getcwd() .. ";")
  if compile_commands ~= "" then
    local build_dir = vim.fn.fnamemodify(compile_commands, ":h")
    table.insert(search_dirs, build_dir)
  end

  for _, dir in ipairs(search_dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      local cmd = string.format("find %s -maxdepth 3 -name '*.gcov' -type f 2>/dev/null", vim.fn.shellescape(dir))
      local handle = io.popen(cmd)
      if handle then
        for file in handle:lines() do
          table.insert(gcov_files, file)
        end
        handle:close()
      end
    end
  end

  return gcov_files
end

-- Generate coverage data if needed
local function generate_coverage()
  -- Check if we're in a manager workspace
  local has_manager = vim.fn.executable("manager") == 1
  local has_builder = vim.fn.executable("builder") == 1

  if has_manager and has_builder then
    -- Try to build with gcov enabled using manager system
    vim.notify("Generating coverage data with manager/builder...", vim.log.levels.INFO)

    -- Get current package
    local manager_ok, manager = pcall(require, "manager")
    if manager_ok then
      local state = manager.get_state()
      if state.package then
        -- Build with gcov
        vim.fn.system(string.format("builder -a %s -b default +gcov", vim.fn.shellescape(state.package)))

        -- Run tests to generate coverage
        vim.fn.system("builder +test_runner")
      end
    end
  else
    -- Try standard gcov generation
    vim.notify("Generating coverage data with gcov...", vim.log.levels.INFO)

    -- Look for executable files and run them
    local executables = vim.fn.glob("**/*test*", false, true)
    for _, exe in ipairs(executables) do
      if vim.fn.executable(exe) == 1 then
        vim.fn.system(exe)
      end
    end

    -- Generate gcov files
    local gcda_files = vim.fn.glob("**/*.gcda", false, true)
    for _, gcda in ipairs(gcda_files) do
      local dir = vim.fn.fnamemodify(gcda, ":h")
      vim.fn.system(string.format("cd %s && gcov %s", vim.fn.shellescape(dir), vim.fn.shellescape(gcda)))
    end
  end
end

--- Loads a coverage report
M.load = function(callback)
  vim.notify("Loading GCov coverage data...", vim.log.levels.INFO)

  -- Find gcov files
  local gcov_files = find_gcov_files()

  -- If no gcov files found, try to generate them
  if #gcov_files == 0 then
    generate_coverage()
    -- Try again
    gcov_files = find_gcov_files()
  end

  if #gcov_files == 0 then
    vim.notify("No .gcov files found. Run tests with coverage enabled first.", vim.log.levels.WARN)
    callback({})
    return
  end

  -- Parse all gcov files
  local all_coverage = {}

  for _, gcov_file in ipairs(gcov_files) do
    local source_file, coverage_data = parse_gcov_file(gcov_file)

    if source_file and coverage_data then
      -- Convert to absolute path if needed
      if not vim.fn.fnamemodify(source_file, ":p") == source_file then
        -- Try to find the actual file
        local found = vim.fn.findfile(vim.fn.fnamemodify(source_file, ":t"), vim.fn.getcwd() .. "/**")
        if found ~= "" then
          source_file = vim.fn.fnamemodify(found, ":p")
        else
          -- Use as-is but make it absolute relative to cwd
          source_file = vim.fn.fnamemodify(vim.fn.getcwd() .. "/" .. source_file, ":p")
        end
      end

      -- Merge coverage data for the same file
      if all_coverage[source_file] then
        for line_num, hits in pairs(coverage_data) do
          -- Keep the maximum hit count for each line
          if not all_coverage[source_file][line_num] or all_coverage[source_file][line_num] < hits then
            all_coverage[source_file][line_num] = hits
          end
        end
      else
        all_coverage[source_file] = coverage_data
      end
    end
  end

  -- Store in cache
  M.coverage_data = all_coverage
  M.last_load_time = os.time()

  vim.notify(string.format("Loaded coverage data for %d files", vim.tbl_count(all_coverage)), vim.log.levels.INFO)

  callback(all_coverage)
end

--- Returns a list of signs that will be placed in buffers
M.sign_list = function(data)
  local sign_list = {}

  for filepath, coverage in pairs(data) do
    -- Find buffer for this file
    local bufnr = vim.fn.bufnr(filepath)

    if bufnr == -1 then
      -- Try to find by filename only
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local buf_name = vim.api.nvim_buf_get_name(buf)
        if buf_name == filepath or vim.fn.fnamemodify(buf_name, ":p") == filepath then
          bufnr = buf
          break
        end
      end
    end

    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
      for line_num, hits in pairs(coverage) do
        if hits > 0 then
          -- Line was covered
          table.insert(sign_list, signs.new_covered(bufnr, line_num))
        else
          -- Line was not covered
          table.insert(sign_list, signs.new_uncovered(bufnr, line_num))
        end
      end
    end
  end

  return sign_list
end

--- Returns a summary report
M.summary = function(data)
  local files = {}
  local totals = {
    statements = 0,
    missing = 0,
    coverage = 0,
  }

  for filepath, coverage in pairs(data) do
    local statements = 0
    local missing = 0

    for _, hits in pairs(coverage) do
      statements = statements + 1
      if hits == 0 then
        missing = missing + 1
      end
    end

    local file_coverage = 0
    if statements > 0 then
      file_coverage = ((statements - missing) / statements) * 100
    end

    table.insert(files, {
      filename = vim.fn.fnamemodify(filepath, ":~:."),
      statements = statements,
      missing = missing,
      coverage = file_coverage,
    })

    totals.statements = totals.statements + statements
    totals.missing = totals.missing + missing
  end

  -- Sort files by coverage percentage (lowest first)
  table.sort(files, function(a, b)
    return (a.coverage or 0) < (b.coverage or 0)
  end)

  -- Calculate total coverage
  if totals.statements > 0 then
    totals.coverage = ((totals.statements - totals.missing) / totals.statements) * 100
  end

  return {
    files = files,
    totals = totals,
  }
end

-- Helper function to clear cached data
M.clear_cache = function()
  M.coverage_data = {}
  M.last_load_time = 0
end

return M
