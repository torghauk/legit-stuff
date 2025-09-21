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

  -- Register our templates
  self:_register_templates()

  return self
end

-- Register manager-specific templates
function M:_register_templates()
  -- Build template
  overseer.register_template({
    name = "manager build",
    params = {
      args = {
        type = "list",
        delimiter = " ",
        default = {},
        optional = true,
        desc = "Additional build arguments",
      },
      target = {
        type = "string",
        default = self.config.default_target or "default",
        optional = true,
        desc = "Build target",
      },
    },
    condition = {
      callback = function()
        return package_mgr:get_current() ~= nil
      end,
    },
    builder = function(params)
      local pkg = package_mgr:get_current()
      if not pkg then
        return nil
      end

      local cmd = { "builder", "-a", pkg, "-b", params.target }
      vim.list_extend(cmd, params.args or {})

      return {
        cmd = cmd,
        name = string.format("Build %s", vim.fn.fnamemodify(pkg, ":t")),
        cwd = workspace:get_root(),
        env = {
          MANAGER_ACTIVITY = workspace:get_current_activity() or "",
        },
        components = {
          { "on_output_quickfix", open = false, close = true },
          "on_exit_set_status",
          "on_complete_notify",
          "unique",
        },
      }
    end,
  })

  -- Test template
  overseer.register_template({
    name = "manager test",
    params = {
      filter = {
        type = "string",
        optional = true,
        desc = "GTest filter pattern",
      },
      args = {
        type = "list",
        delimiter = " ",
        default = {},
        optional = true,
        desc = "Additional test arguments",
      },
    },
    condition = {
      callback = function()
        return true -- Tests can run without a specific package
      end,
    },
    builder = function(params)
      local cmd = { "builder", "+test_runner" }

      if params.filter and params.filter ~= "" then
        table.insert(cmd, "--gtest_filter=" .. params.filter)
      end

      vim.list_extend(cmd, params.args or {})

      return {
        cmd = cmd,
        name = params.filter and ("Test: " .. params.filter) or "Run all tests",
        cwd = workspace:get_root(),
        env = {
          MANAGER_ACTIVITY = workspace:get_current_activity() or "",
        },
        components = {
          {
            "on_output_parse",
            parser = {
              diagnostics = {
                { "loop",
                  { "sequence",
                    -- Try to parse GTest output format
                    { "extract",
                      {
                        regex = true,
                        consume = true,
                        append = true,
                        postprocess = function(item, ctx)
                          -- Store test results for later use
                          ctx = ctx or {}
                          ctx.tests = ctx.tests or { passed = 0, failed = 0 }

                          if item.text and item.text:match("%[%s*OK%s*%]") then
                            ctx.tests.passed = ctx.tests.passed + 1
                            item.type = "I"
                          elseif item.text and item.text:match("%[%s*FAILED%s*%]") then
                            ctx.tests.failed = ctx.tests.failed + 1
                            item.type = "E"
                          end

                          return item
                        end,
                      },
                      "\\v\\[\\s*(RUN|OK|FAILED)\\s*\\]\\s+(.+)",
                      "status",
                      "text",
                    },
                    -- Parse assertion failures with file:line
                    { "extract",
                      {
                        regex = true,
                        consume = true,
                        append = true,
                      },
                      "\\v^([^:]+):(\\d+): Failure",
                      "filename",
                      "lnum",
                    },
                  },
                },
              },
            },
          },
          { "on_output_quickfix", open = false },
          "on_exit_set_status",
          {
            "on_complete_notify",
            statuses = { "SUCCESS", "FAILURE" },
          },
          "unique",
        },
      }
    end,
  })

  -- Coverage template
  overseer.register_template({
    name = "manager coverage",
    condition = {
      callback = function()
        return package_mgr:get_current() ~= nil
      end,
    },
    builder = function(params)
      local pkg = package_mgr:get_current()
      if not pkg then
        return nil
      end

      return {
        cmd = { "builder", "-a", pkg, "-b", "default", "+gcov" },
        name = "Generate coverage",
        cwd = workspace:get_root(),
        components = {
          "on_exit_set_status",
          "on_complete_notify",
          "unique",
        },
      }
    end,
  })

  -- Clean template
  overseer.register_template({
    name = "manager clean",
    builder = function(params)
      return {
        cmd = { "builder", "+clean" },
        name = "Clean build",
        cwd = workspace:get_root(),
        components = {
          "on_exit_set_status",
          "on_complete_notify",
          "unique",
        },
      }
    end,
  })
end

-- Build current package
function M:build(args)
  -- Parse arguments
  local arg_list = {}
  if args and args ~= "" then
    arg_list = vim.split(args, " ", { trimempty = true })
  end

  -- Use saved args if none provided
  local config = require("manager.core.config")
  if #arg_list == 0 then
    arg_list = config:get_build_args()
  else
    -- Save new args
    config:save_build_args(arg_list)
  end

  -- Run the build template
  overseer.run_template(
    {
      name = "manager build",
      params = { args = arg_list },
    },
    function(task)
      if task then
        -- Fire event for hooks
        vim.api.nvim_exec_autocmds("User", {
          pattern = "ManagerBuildStart",
          data = { task = task },
        })

        -- Set up completion callback
        task:subscribe("on_complete", function()
          vim.api.nvim_exec_autocmds("User", {
            pattern = "ManagerBuildComplete",
            data = {
              task = task,
              status = task.status,
            },
          })

          -- Generate compile_commands if successful
          if task.status == "SUCCESS" and self.config.auto_generate_compile_commands then
            vim.defer_fn(function()
              local compile_commands = require("manager.builders.compile_commands")
              compile_commands:generate()
            end, 100)
          end
        end)
      else
        vim.notify("Failed to create build task", vim.log.levels.ERROR)
      end
    end
  )
end

-- Run tests
function M:test(args)
  -- Parse arguments for filter
  local filter = nil
  local other_args = {}

  if args and args ~= "" then
    for _, arg in ipairs(vim.split(args, " ", { trimempty = true })) do
      if arg:match("^--gtest_filter=") then
        filter = arg:match("^--gtest_filter=(.+)")
      else
        table.insert(other_args, arg)
      end
    end
  end

  -- Use saved args if none provided
  local config = require("manager.core.config")
  if #other_args == 0 then
    other_args = config:get_test_args()
  else
    config:save_test_args(other_args)
  end

  -- Save filter if provided
  if filter then
    config:add_test_filter(filter)
  end

  -- Run the test template
  overseer.run_template(
    {
      name = "manager test",
      params = {
        filter = filter,
        args = other_args,
      },
    },
    function(task)
      if task then
        -- Fire event
        vim.api.nvim_exec_autocmds("User", {
          pattern = "ManagerTestStart",
          data = { task = task },
        })

        -- Set up completion callback
        task:subscribe("on_complete", function()
          vim.api.nvim_exec_autocmds("User", {
            pattern = "ManagerTestComplete",
            data = {
              task = task,
              status = task.status,
            },
          })

          -- Check for failed tests and offer to rerun
          if task.status == "FAILURE" then
            vim.defer_fn(function()
              local qf_list = vim.fn.getqflist()
              local failed_tests = {}

              for _, item in ipairs(qf_list) do
                if item.text and item.text:match("%[%s*FAILED%s*%]%s+(.+)") then
                  local test_name = item.text:match("%[%s*FAILED%s*%]%s+(.+)")
                  table.insert(failed_tests, test_name)
                end
              end

              if #failed_tests > 0 then
                vim.ui.select({ "Yes", "No" }, {
                  prompt = string.format("Rerun %d failed tests?", #failed_tests),
                }, function(choice)
                  if choice == "Yes" then
                    local new_filter = table.concat(failed_tests, ":")
                    self:test("--gtest_filter=" .. new_filter)
                  end
                end)
              end
            end, 500)
          end
        end)
      else
        vim.notify("Failed to create test task", vim.log.levels.ERROR)
      end
    end
  )
end

-- Clean build artifacts
function M:clean()
  overseer.run_template({ name = "manager clean" })
end

-- Get running tasks
function M:get_running_tasks()
  local tasks = {}
  for _, task in ipairs(overseer.list_tasks({ status = "RUNNING" })) do
    -- Only include our tasks
    if task.name:match("^Build ") or
        task.name:match("^Test") or
        task.name:match("^Clean") or
        task.name:match("^Generate coverage") then
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
  filter = filter or {}

  -- Add our task name pattern to filter
  local tasks = overseer.list_tasks(filter)
  local our_tasks = {}

  for _, task in ipairs(tasks) do
    if task.name:match("^Build ") or
        task.name:match("^Test") or
        task.name:match("^Clean") or
        task.name:match("^Generate coverage") then
      table.insert(our_tasks, task)
    end
  end

  return our_tasks
end

-- Open quickfix with build/test results
function M:populate_quickfix()
  vim.cmd("copen")
end

return M
