-- manager/builders/overseer.lua
-- Overseer.nvim integration for build and test management

local M = {}

local overseer = nil
local workspace = nil
local package_mgr = nil

-- Initialize module
function M:setup(config)
  self.config = config

  -- Check if overseer is available
  local ok, ovs = pcall(require, "overseer")
  if not ok then
    vim.notify("Manager: overseer.nvim not found, falling back to basic builder", vim.log.levels.WARN)
    return require("manager.builders.basic"):setup(config)
  end

  overseer = ovs
  workspace = require("manager.core.workspace")
  package_mgr = require("manager.core.package")

  -- Setup overseer
  overseer.setup({
    templates = { "manager" },
    task_list = {
      direction = "bottom",
      min_height = 10,
      max_height = 25,
      default_detail = 1,
    },
    component_aliases = {
      default = {
        { "display_duration",    detail_level = 2 },
        { "on_exit_set_status",  success_codes = { 0 } },
        { "on_complete_notify" },
        { "on_complete_dispose", timeout = 300 },
      },
    },
  })

  -- Register custom templates
  self:_register_templates()

  return self
end

-- Register manager-specific templates
function M:_register_templates()
  local Template = require("overseer.template")

  -- Create parsers
  self:_create_parsers()

  -- Build template
  overseer.register_template({
    name = "manager.build",
    priority = 50,
    params = {
      args = {
        type = "list",
        delimiter = " ",
        default = {},
        optional = true,
      },
      target = {
        type = "string",
        default = self.config.default_target or "default",
        optional = true,
      },
    },
    builder = function(params)
      local pkg = package_mgr:get_current()
      if not pkg then
        vim.notify("No package selected for build", vim.log.levels.ERROR)
        return nil
      end

      local cmd = { "builder", "-a", pkg, "-b", params.target }
      vim.list_extend(cmd, params.args or {})

      return {
        cmd = cmd,
        name = string.format("Build %s", vim.fn.fnamemodify(pkg, ":t")),
        cwd = workspace:get_root(),
        env = {
          MANAGER_ACTIVITY = workspace:get_current_activity(),
        },
        components = {
          { "on_output_parse",    parser = self.compiler_parser },
          { "on_output_quickfix", open = false,                 close = true },
          "on_exit_set_status",
          "on_complete_notify",
          "unique",
        },
        metadata = {
          type = "build",
          package = pkg,
          activity = workspace:get_current_activity(),
        },
      }
    end,
  })

  -- Test template
  overseer.register_template({
    name = "manager.test",
    priority = 50,
    params = {
      filter = {
        type = "string",
        optional = true,
        description = "GTest filter pattern",
      },
      args = {
        type = "list",
        delimiter = " ",
        default = {},
        optional = true,
      },
    },
    builder = function(params)
      local cmd = { "builder", "+test_runner" }

      if params.filter then
        table.insert(cmd, "--gtest_filter=" .. params.filter)
      end

      vim.list_extend(cmd, params.args or {})

      return {
        cmd = cmd,
        name = params.filter and ("Test: " .. params.filter) or "Run all tests",
        cwd = workspace:get_root(),
        env = {
          MANAGER_ACTIVITY = workspace:get_current_activity(),
        },
        components = {
          { "on_output_parse",    parser = self.gtest_parser },
          { "on_output_quickfix", open = false },
          "on_exit_set_status",
          "on_complete_notify",
          "unique",
        },
        metadata = {
          type = "test",
          filter = params.filter,
          activity = workspace:get_current_activity(),
        },
      }
    end,
  })

  -- Coverage template
  overseer.register_template({
    name = "manager.coverage",
    priority = 50,
    builder = function(params)
      local pkg = package_mgr:get_current()
      if not pkg then
        return nil
      end

      return {
        cmd = { "builder", "-a", pkg, "-b", "default", "+gcov" },
        name = "Generate coverage",
        cwd = workspace:get_root(),
        components = { "default", "unique" },
        metadata = {
          type = "coverage",
          package = pkg,
        },
      }
    end,
  })

  -- Clean template
  overseer.register_template({
    name = "manager.clean",
    priority = 50,
    builder = function(params)
      return {
        cmd = { "builder", "+clean" },
        name = "Clean build",
        cwd = workspace:get_root(),
        components = { "default", "unique" },
        metadata = { type = "clean" },
      }
    end,
  })
end

-- Create custom parsers for output
function M:_create_parsers()
  -- GTest output parser
  self.gtest_parser = {
    diagnostics = {
      { "loop",
        { "parallel",
          -- Exit loop when we see test summary
          { "invert",
            { "test", "%[%s*========%s*%] %d+ tests? from %d+ test " }
          },
          -- Extract test results
          { "sequence",
            -- Try to extract test start/pass/fail
            { "always",
              { "extract",
                { regex = true, append = true },
                "\\[\\s*RUN\\s*\\] (.+)",
                "test_name"
              }
            },
            { "always",
              { "extract",
                {
                  regex = true,
                  append = true,
                  postprocess = function(item)
                    item.type = "I"
                    item.status = "passed"
                    return item
                  end
                },
                "\\[\\s*OK\\s*\\] ([^ ]+) \\((\\d+) ms\\)",
                "test_name", "duration"
              }
            },
            { "always",
              { "extract",
                {
                  regex = true,
                  append = true,
                  postprocess = function(item)
                    item.type = "E"
                    item.status = "failed"
                    return item
                  end
                },
                "\\[\\s*FAILED\\s*\\] ([^ ]+) \\((\\d+) ms\\)",
                "test_name", "duration"
              }
            },
            -- Extract assertion failures
            { "always",
              { "extract",
                { regex = true },
                "^([^:]+):(\\d+): Failure",
                "filename", "lnum"
              }
            },
          },
          -- Skip unmatched lines
          { "skip_lines", 1 }
        }
      }
    }
  }

  -- Compiler output parser using errorformat
  self.compiler_parser = {
    diagnostics = {
      { "loop",
        { "sequence",
          -- Use errorformat to parse compiler output
          { "extract_efm",
            {
              efm = "%f:%l:%c: %t%*[^:]: %m,%f:%l: %t%*[^:]: %m",
              append = true
            }
          },
          -- Skip lines that don't match
          { "skip_lines", 1 }
        }
      }
    }
  }
end

-- Build current package
function M:build(args)
  local task = overseer.new_task({
    template = "manager.build",
    params = { args = vim.split(args or "", " ", { trimempty = true }) },
  })

  if task then
    task:add_component({
      "on_complete_callback",
      callback = function(task, status)
        vim.api.nvim_exec_autocmds("User", {
          pattern = "ManagerBuildComplete",
          data = { task = task, status = status },
        })

        -- Update compile_commands if successful
        if status == "SUCCESS" and self.config.auto_generate_compile_commands then
          self:_generate_compile_commands()
        end
      end
    })

    task:start()

    -- Open task list if configured
    if self.config.show_task_list then
      overseer.open()
    end
  end

  return task
end

-- Run tests
function M:test(args)
  local params = {}

  -- Parse arguments for filter
  local filter = nil
  local other_args = {}

  for _, arg in ipairs(vim.split(args or "", " ", { trimempty = true })) do
    if arg:match("^--gtest_filter=") then
      filter = arg:match("^--gtest_filter=(.+)")
    else
      table.insert(other_args, arg)
    end
  end

  params.filter = filter
  params.args = other_args

  local task = overseer.new_task({
    template = "manager.test",
    params = params,
  })

  if task then
    task:add_component({
      "on_complete_callback",
      callback = function(task, status)
        vim.api.nvim_exec_autocmds("User", {
          pattern = "ManagerTestComplete",
          data = { task = task, status = status },
        })

        -- Show summary
        if task.metadata.test_results then
          local results = task.metadata.test_results
          local msg = string.format("Tests: %d/%d passed", results.passed, results.total)

          if results.failed > 0 then
            vim.notify(msg, vim.log.levels.ERROR)
            -- Offer to rerun failed tests
            if #task.metadata.failed_tests > 0 then
              vim.defer_fn(function()
                vim.ui.select({ "Yes", "No" }, {
                  prompt = "Rerun failed tests?",
                }, function(choice)
                  if choice == "Yes" then
                    local filter = table.concat(task.metadata.failed_tests, ":")
                    self:test("--gtest_filter=" .. filter)
                  end
                end)
              end, 100)
            end
          else
            vim.notify(msg, vim.log.levels.INFO)
          end
        end
      end
    })

    task:start()
  end

  return task
end

-- Clean build artifacts
function M:clean()
  local task = overseer.new_task({ template = "manager.clean" })
  if task then
    task:start()
  end
  return task
end

-- Generate compile_commands.json
function M:_generate_compile_commands()
  local compile_commands = require("manager.builders.compile_commands")
  compile_commands:generate()
end

-- Get running tasks
function M:get_running_tasks()
  local tasks = {}
  for _, task in ipairs(overseer.list_tasks()) do
    if task:is_running() then
      table.insert(tasks, task)
    end
  end
  return tasks
end

-- Stop all tasks
function M:stop_all()
  for _, task in ipairs(self:get_running_tasks()) do
    task:stop()
  end
end

-- Get task history
function M:get_history(filter)
  local tasks = overseer.list_tasks(filter)
  return tasks
end

-- Integration with quickfix
function M:populate_quickfix()
  local items = {}

  for _, task in ipairs(overseer.list_tasks({ recent = 10 })) do
    if task.metadata.type == "build" or task.metadata.type == "test" then
      -- Get diagnostics from task
      local diagnostics = task:get_component("on_output_quickfix")
      if diagnostics and diagnostics.items then
        vim.list_extend(items, diagnostics.items)
      end
    end
  end

  if #items > 0 then
    vim.fn.setqflist(items)
    vim.cmd("copen")
  else
    vim.notify("No diagnostics found", vim.log.levels.INFO)
  end
end

return M
