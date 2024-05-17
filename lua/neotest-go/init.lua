local fn = vim.fn
local Path = require("plenary.path")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local async = require("neotest.async")
local utils = require("neotest-go.utils")
local output = require("neotest-go.output")
local test_statuses = require("neotest-go.test_status")

local function get_experimental_opts()
    return {
        test_table = false,
    }
end

local get_args = function()
    return {}
end

local recursive_run = function()
    return false
end

local notify = function(msg)
    vim.notify(msg, vim.log.levels.INFO, {
        title = "neotest-go", --[[ replace = last_notification ]]
    })
    logger.info("[neotest-go] " .. msg)
end

---@type neotest.Adapter
local adapter = { name = "neotest-go" }

-- adapter.root = lib.files.match_root_pattern("go.mod", "go.sum")

function adapter.root(dir)
    local root_dir = lib.files.match_root_pattern("go.mod", "go.sum")(dir)
    -- notify("adapter.root(" .. dir .. ") = " .. tostring(root_dir))
    return root_dir
end

function adapter.is_test_file(file_path)
    local is_test = vim.endswith(file_path, "_test.go")
    return is_test
end

---@param position neotest.Position The position to return an ID for
---@param namespaces neotest.Position[] Any namespaces the position is within
function adapter._generate_position_id(position, namespaces)
    local prefix = {}
    for _, namespace in ipairs(namespaces) do
        if namespace.type ~= "file" then
            table.insert(prefix, namespace.name)
        end
    end
    local name = utils.transform_test_name(position.name)
    local position_id = table.concat(vim.tbl_flatten({ position.path, prefix, name }), "::")

    -- notify(
    --     "adapter._generate_position_id("
    --         .. vim.inspect(position)
    --         .. ", "
    --         .. vim.inspect(namespaces)
    --         .. ") = "
    --         .. position_id
    -- )
    return position_id
end

function split_string(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t = {}
    for str in string.gmatch(inputstr, "([^" .. sep .. "]+)") do
        table.insert(t, str)
    end
    return t
end

---@async
---@return neotest.Tree| nil
function adapter.discover_positions(path)
    -- notify("adapter.discover_positions(" .. path .. ") called")
    -- get package path from file path (package path is the directory of the file)
    -- local package_path = fn.fnamemodify(path, ":p:h") .. "/..."
    local tests = {}

    local function parse_and_notify(data)
        if not data then
            return
        end

        for _, line in ipairs(data) do
            if (line ~= nil) and (line ~= "") then
                local decoded
                local ok, result = pcall(vim.fn.json_decode, line)
                if not ok then
                    notify("Error decoding json: " .. line .. " - " .. result)
                else
                    decoded = result
                end
                if
                    (decoded ~= nil)
                    and (decoded.Test ~= nil)
                    and (decoded.Action == "pass" or decoded.Action == "fail")
                then
                    table.insert(
                        tests,
                        table.concat(
                            vim.tbl_flatten({ path, split_string(decoded.Test, "/") }),
                            "::"
                        )
                    )
                end
            end
        end
    end

    local job_id = vim.fn.jobstart({ "go", "test", "-json", "-v", "-fullpath", path }, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data)
            parse_and_notify(data)
        end,
        on_stderr = function(_, data)
            parse_and_notify(data)
        end,
        on_exit = function(_, code)
            -- notify("job exited with code: " .. code)
        end,
    })

    vim.fn.jobwait({ job_id }, -1)
    -- notify("tests: " .. vim.inspect(tests))

    -- return nil
    local query = [[
      ;;query
      ((function_declaration
        name: (identifier) @test.name)
        (#match? @test.name "^(Test|Example)"))
        @test.definition

      (method_declaration
        name: (field_identifier) @test.name
        (#match? @test.name "^(Test|Example)")) @test.definition

      (call_expression
        function: (selector_expression
          field: (field_identifier) @test.method)
          (#match? @test.method "^Run$")
        arguments: (argument_list . (interpreted_string_literal) @test.name))
        @test.definition
    ]]

    if get_experimental_opts().test_table then
        query = query
            .. [[
  ;; query for list table tests
      (block
        (short_var_declaration
          left: (expression_list
            (identifier) @test.cases)
          right: (expression_list
            (composite_literal
              (literal_value
                (literal_element
                  (literal_value
                    (keyed_element
                      (literal_element
                        (identifier) @test.field.name)
                      (literal_element
                        (interpreted_string_literal) @test.name)))) @test.definition))))
        (for_statement
          (range_clause
            left: (expression_list
              (identifier) @test.case)
            right: (identifier) @test.cases1
              (#eq? @test.cases @test.cases1))
          body: (block
           (expression_statement
            (call_expression
              function: (selector_expression
                field: (field_identifier) @test.method)
                (#match? @test.method "^Run$")
              arguments: (argument_list
                (selector_expression
                  operand: (identifier) @test.case1
                  (#eq? @test.case @test.case1)
                  field: (field_identifier) @test.field.name1
                  (#eq? @test.field.name @test.field.name1))))))))

  ;; query for map table tests
  	(block
        (short_var_declaration
          left: (expression_list
            (identifier) @test.cases)
          right: (expression_list
            (composite_literal
              (literal_value
                (keyed_element
              	(literal_element
                    (interpreted_string_literal)  @test.name)
                  (literal_element
                    (literal_value)  @test.definition))))))
  	  (for_statement
         (range_clause
            left: (expression_list
              ((identifier) @test.key.name)
              ((identifier) @test.case))
            right: (identifier) @test.cases1
              (#eq? @test.cases @test.cases1))
  	      body: (block
             (expression_statement
              (call_expression
                function: (selector_expression
                  field: (field_identifier) @test.method)
                  (#match? @test.method "^Run$")
                  arguments: (argument_list
                  ((identifier) @test.key.name1
                  (#eq? @test.key.name @test.key.name1))))))))
      ]]
    end

    local tree = lib.treesitter.parse_positions(path, query, {
        require_namespaces = false,
        nested_tests = true,
        position_id = "require('neotest-go')._generate_position_id",
        -- position_id = adapter._generate_position_id,
    })

    -- remove " from test names and test ids
    for _, node in tree:iter_nodes() do
        local value = node:data()
        value.id = value.id:gsub('%"', ""):gsub(" ", "_")
        value.name = value.name:gsub('%"', ""):gsub(" ", "_")
    end

    -- find missing tests
    local function parent(test)
        local parts = vim.split(test, "::")
        table.remove(parts, #parts)
        return table.concat(parts, "::")
    end

    local function test_name(test)
        local parts = vim.split(test, "::")
        return parts[#parts]
    end

    local missing_tests = {}
    for _, test in ipairs(tests) do
        local found = false
        for _, node in tree:iter_nodes() do
            local value = node:data()
            if value.id == test then
                found = true
                break
            end
        end
        if not found then
            table.insert(missing_tests, {
                id = test,
                parent_id = parent(test),
            })
        end
    end

    -- create a new table derived from missing_tests, such that parent always comes before child,
    -- while children inside the same parent preserve their order from the original list
    -- the new table should have the following structure:
    local missing_tests_ordered = {}
    local position_ids = {}
    for _, test in ipairs(missing_tests) do
        position_ids[test.id] = test
    end
    for _, test in ipairs(missing_tests) do
        local parent_id = test.parent_id
        if parent_id == "" then
            table.insert(missing_tests_ordered, test)
        else
            local parent = position_ids[parent_id]
            if parent then
                if not parent.children then
                    parent.children = {}
                end
                table.insert(parent.children, test)
            else
                table.insert(missing_tests_ordered, test)
            end
        end
    end

    -- notify("Missing tests: " .. vim.inspect(missing_tests_ordered))

    local Tree = require("neotest.types").Tree

    local tree_copy = Tree.from_list(tree:to_list(), function(pos)
        return pos.id
    end)

    -- add missing tests to the tree, parent of top-level items in missing_tests_ordered is guaranteed to exist
    local function add_test(tree, test)
        local parent = test.parent_id
        local parent_node = tree:get_key(parent)
        if not parent_node then
            notify("Parent node not found for test: " .. test.id)
        else
            local child = Tree:new({
                id = test.id,
                name = test_name(test.id),
                type = "test",
                path = path,
                range = nil, --[[ parent_node:data().range, ]]
            }, {}, function(pos)
                return pos.id
            end, nil, {})
            -- notify(
            --     "Adding test: "
            --         .. vim.inspect(child:to_list())
            --         .. " to parent: "
            --         .. parent_node:data().id
            -- )
            parent_node:add_child(test.id, child)
        end
        for _, child in ipairs(test.children or {}) do
            add_test(tree_copy, child)
        end
    end

    for _, test in ipairs(missing_tests_ordered) do
        add_test(tree_copy, test)
    end

    -- local package_dir = fn.fnamemodify(path, ":h")
    -- local root_tree = Tree:new({
    --     id = path,
    --     name = package_dir,
    --     type = "namespace",
    --     path = package_dir,
    --     range = nil,
    -- }, {}, function(pos)
    --     return pos.id
    -- end, nil, {})
    --
    -- root_tree:add_child(path, tree_copy)

    -- notify(vim.inspect(position_ids))
    -- notify(vim.inspect(tree_copy:to_list()))

    -- notify(
    --     "tree.id: " .. tree_copy:data().id .. ", tree.parent: " .. vim.inspect(tree_copy:parent())
    -- )

    return tree_copy
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec
function adapter.build_spec(args)
    local results_path = async.fn.tempname()
    local position = args.tree:data()
    local dir = "./"
    if recursive_run() then
        dir = "./..."
    end
    local location = position.path
    if fn.isdirectory(position.path) ~= 1 then
        location = fn.fnamemodify(position.path, ":h")
    end
    local command = vim.tbl_flatten({
        "cd",
        location,
        "&&",
        "go",
        "test",
        "-v",
        "-json",
        utils.get_build_tags(),
        vim.list_extend(get_args(), args.extra_args or {}),
        dir,
    })
    return {
        command = table.concat(command, " "),
        context = {
            results_path = results_path,
            file = position.path,
        },
    }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result[]>
function adapter.results(spec, result, tree)
    local go_root = utils.get_go_root(spec.context.file)
    if not go_root then
        return {}
    end
    local go_module = utils.get_go_module_name(go_root)
    if not go_module then
        return {}
    end

    local success, lines = pcall(lib.files.read_lines, result.output)
    if not success then
        logger.error("neotest-go: could not read output: " .. lines)
        return {}
    end
    return adapter.prepare_results(tree, lines, go_root, go_module)
end

---@param tree neotest.Tree
---@param lines string[]
---@param go_root string
---@param go_module string
---@return table<string, neotest.Result[]>
function adapter.prepare_results(tree, lines, go_root, go_module)
    local tests, log = output.marshal_gotest_output(lines)
    local results = {}
    local no_results = vim.tbl_isempty(tests)
    local empty_result_fname
    local file_id
    empty_result_fname = async.fn.tempname()
    fn.writefile(log, empty_result_fname)
    for _, node in tree:iter_nodes() do
        local value = node:data()
        if no_results then
            results[value.id] = {
                status = test_statuses.fail,
                output = empty_result_fname,
            }
            break
        end
        if value.type == "file" then
            results[value.id] = {
                status = test_statuses.pass,
                output = empty_result_fname,
            }
            file_id = value.id
        else
            -- mitigates `value.id` such as jsonoutput_test.go::Test_Level_1::"Level 2"::Level_3'
            local value_id = value.id:gsub('%"', ""):gsub(" ", "_")
            local normalized_id = utils.normalize_id(value_id, go_root, go_module)
            local test_result = tests[normalized_id]
            -- file level node
            if test_result then
                local fname = async.fn.tempname()
                fn.writefile(test_result.output, fname)
                results[value.id] = {
                    status = test_result.status,
                    short = table.concat(test_result.output, ""),
                    output = fname,
                }
                local errors =
                    utils.get_errors_from_test(test_result, utils.get_filename_from_id(value.id))
                if errors then
                    results[value.id].errors = errors
                end
                if test_result.status == test_statuses.fail and file_id then
                    results[file_id].status = test_statuses.fail
                end
            end
        end
    end
    return results
end

local is_callable = function(obj)
    return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(adapter, {
    __call = function(_, opts)
        if is_callable(opts.experimental) then
            get_experimental_opts = opts.experimental
        elseif opts.experimental then
            get_experimental_opts = function()
                return opts.experimental
            end
        end

        if is_callable(opts.args) then
            get_args = opts.args
        elseif opts.args then
            get_args = function()
                return opts.args
            end
        end

        if is_callable(opts.recursive_run) then
            recursive_run = opts.recursive_run
        elseif opts.recursive_run then
            recursive_run = function()
                return opts.recursive_run
            end
        end
        return adapter
    end,
})

return adapter
