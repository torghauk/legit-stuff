-- project_info_parser.lua
-- Parser for project info files to generate compile_commands.json

local M = {}

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Check if a line is indented (starts with whitespace)
local function is_indented(line)
  return line:match("^%s") ~= nil
end

-- Trim whitespace from both ends of a string
local function trim(str)
  return str:match("^%s*(.-)%s*$")
end

-- Split a string by whitespace
local function split_whitespace(str)
  local parts = {}
  for part in str:gmatch("%S+") do
    table.insert(parts, part)
  end
  return parts
end

-- Check if a line is blank (empty or only whitespace)
local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

-- ============================================================================
-- Chunk Processing
-- ============================================================================

-- Split file content into chunks separated by blank lines
local function split_into_chunks(lines)
  local chunks = {}
  local current_chunk = {}

  for _, line in ipairs(lines) do
    if is_blank(line) then
      -- End of current chunk
      if #current_chunk > 0 then
        table.insert(chunks, current_chunk)
        current_chunk = {}
      end
    else
      table.insert(current_chunk, line)
    end
  end

  -- Add the last chunk if it exists
  if #current_chunk > 0 then
    table.insert(chunks, current_chunk)
  end

  return chunks
end

-- ============================================================================
-- Package Parser
-- ============================================================================

-- Parse a single package from chunks
local function parse_package(chunks, start_index)
  local package = {
    name = nil,
    pkg_file = nil,
    dependencies = {}, -- Include paths
    sources = {},
    flags = {},
    outputs = {}
  }

  local chunk_index = start_index
  local first_chunk = chunks[chunk_index]

  if not first_chunk or #first_chunk == 0 then
    return nil, start_index
  end

  -- First line of first chunk: package name and .pkg file path
  local first_line = first_chunk[1]
  if is_indented(first_line) then
    -- This is not a new package
    return nil, start_index
  end

  -- Parse package name and .pkg file
  local parts = split_whitespace(first_line)
  if #parts >= 2 then
    package.name = parts[1]
    package.pkg_file = parts[2]
  else
    -- Invalid package format
    return nil, start_index
  end

  -- Parse dependencies (rest of first chunk)
  for i = 2, #first_chunk do
    local dep_line = trim(first_chunk[i])
    if dep_line ~= "" then
      table.insert(package.dependencies, dep_line)
    end
  end

  chunk_index = chunk_index + 1

  -- Process subsequent chunks for this package
  while chunk_index <= #chunks do
    local chunk = chunks[chunk_index]

    -- Check if this chunk belongs to the current package
    if #chunk > 0 and not is_indented(chunk[1]) then
      -- This is the start of a new package
      break
    end

    -- Determine chunk type based on position and content
    local chunk_type = nil

    -- We process chunks in order: sources, flags, outputs
    if #package.sources == 0 then
      -- This should be sources chunk
      chunk_type = "sources"
    elseif #package.flags == 0 then
      -- This should be flags chunk
      chunk_type = "flags"
    else
      -- This should be outputs chunk
      chunk_type = "outputs"
    end

    -- Parse the chunk based on its type
    for _, line in ipairs(chunk) do
      local content = trim(line)
      if content ~= "" then
        if chunk_type == "sources" then
          -- Source files have absolute paths
          table.insert(package.sources, content)
        elseif chunk_type == "flags" then
          -- Compiler flags
          table.insert(package.flags, content)
        elseif chunk_type == "outputs" then
          -- Output files
          table.insert(package.outputs, content)
        end
      end
    end

    chunk_index = chunk_index + 1
  end

  return package, chunk_index
end

-- ============================================================================
-- Generated Files Parser
-- ============================================================================

-- Parse the generated files section (last chunk)
local function parse_generated_files(chunk)
  local generated_files = {}

  for _, line in ipairs(chunk) do
    local parts = split_whitespace(line)
    if #parts >= 3 then
      -- Format: generated_file source_file number
      local entry = {
        generated = parts[1],
        source = parts[2],
        number = tonumber(parts[3]) or 0
      }
      table.insert(generated_files, entry)
    end
  end

  return generated_files
end

-- ============================================================================
-- Main Parser
-- ============================================================================

-- Parse the entire project info file
function M.parse_project_info(file_path)
  -- Read the file
  local lines = {}
  local file = io.open(file_path, "r")

  if not file then
    return nil, "Failed to open file: " .. file_path
  end

  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()

  -- Split into chunks
  local chunks = split_into_chunks(lines)

  if #chunks < 2 then
    return nil, "Invalid project info format: insufficient chunks"
  end

  -- Skip the first chunk as specified
  local packages = {}
  local chunk_index = 2 -- Start from second chunk

  -- Parse packages
  while chunk_index <= #chunks - 1 do -- Leave last chunk for generated files
    local package, next_index = parse_package(chunks, chunk_index)

    if package then
      table.insert(packages, package)
      chunk_index = next_index
    else
      chunk_index = chunk_index + 1
    end
  end

  -- Parse generated files (last chunk)
  local generated_files = {}
  if chunks[#chunks] then
    generated_files = parse_generated_files(chunks[#chunks])
  end

  return {
    packages = packages,
    generated_files = generated_files
  }
end

-- ============================================================================
-- Compile Commands Generation
-- ============================================================================

-- Generate compile_commands.json entries for a package
function M.generate_compile_commands_entries(package, workspace_root)
  local entries = {}

  -- Default compiler (can be made configurable)
  local compiler = "clang++"

  -- Build include flags from dependencies
  local include_flags = {}
  for _, dep in ipairs(package.dependencies) do
    table.insert(include_flags, "-I" .. dep)
  end

  -- Create an entry for each source file
  for _, source in ipairs(package.sources) do
    local entry = {
      file = source,
      directory = workspace_root or vim.fn.getcwd(),
      arguments = { compiler }
    }

    -- Add include flags
    for _, inc in ipairs(include_flags) do
      table.insert(entry.arguments, inc)
    end

    -- Add custom flags
    for _, flag in ipairs(package.flags) do
      table.insert(entry.arguments, flag)
    end

    -- Add the source file as the last argument
    table.insert(entry.arguments, source)

    table.insert(entries, entry)
  end

  return entries
end

-- Generate complete compile_commands.json from project info
function M.generate_compile_commands(project_info, output_path, workspace_root)
  local all_entries = {}

  -- Generate entries for all packages
  for _, package in ipairs(project_info.packages) do
    local entries = M.generate_compile_commands_entries(package, workspace_root)
    vim.list_extend(all_entries, entries)
  end

  -- Write to file
  local json_content = vim.json.encode(all_entries)

  local file = io.open(output_path, "w")
  if not file then
    return false, "Failed to open output file: " .. output_path
  end

  file:write(json_content)
  file:close()

  return true, "Successfully generated compile_commands.json with " .. #all_entries .. " entries"
end

-- ============================================================================
-- Integration Helper
-- ============================================================================

-- Parse project info and generate compile_commands.json in one step
function M.process_project_info(info_file, output_path, workspace_root)
  -- Parse the project info file
  local project_info, err = M.parse_project_info(info_file)

  if not project_info then
    return false, err
  end

  -- Generate compile_commands.json
  local success, msg = M.generate_compile_commands(project_info, output_path, workspace_root)

  return success, msg, project_info
end

-- ============================================================================
-- Debug/Inspection Functions
-- ============================================================================

-- Pretty print project info for debugging
function M.inspect_project_info(file_path)
  local project_info, err = M.parse_project_info(file_path)

  if not project_info then
    print("Error parsing project info: " .. err)
    return
  end

  print("=== PROJECT INFO ===")
  print("Packages found: " .. #project_info.packages)
  print("")

  for i, package in ipairs(project_info.packages) do
    print("Package #" .. i .. ": " .. package.name)
    print("  PKG file: " .. package.pkg_file)
    print("  Dependencies: " .. #package.dependencies)
    for j, dep in ipairs(package.dependencies) do
      if j <= 3 then
        print("    - " .. dep)
      elseif j == 4 then
        print("    ... and " .. (#package.dependencies - 3) .. " more")
        break
      end
    end
    print("  Sources: " .. #package.sources)
    for j, src in ipairs(package.sources) do
      if j <= 3 then
        print("    - " .. vim.fn.fnamemodify(src, ":t"))
      elseif j == 4 then
        print("    ... and " .. (#package.sources - 3) .. " more")
        break
      end
    end
    print("  Flags: " .. #package.flags)
    for j, flag in ipairs(package.flags) do
      if j <= 5 then
        print("    - " .. flag)
      elseif j == 6 then
        print("    ... and " .. (#package.flags - 5) .. " more")
        break
      end
    end
    print("  Outputs: " .. #package.outputs)
    print("")
  end

  print("Generated files: " .. #project_info.generated_files)
  for i, gen in ipairs(project_info.generated_files) do
    if i <= 5 then
      print("  " .. gen.generated .. " <- " .. gen.source)
    elseif i == 6 then
      print("  ... and " .. (#project_info.generated_files - 5) .. " more")
      break
    end
  end
end

-- ============================================================================
-- Module Export
-- ============================================================================

return M
