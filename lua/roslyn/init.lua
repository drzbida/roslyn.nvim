local server = require("roslyn.server")
local utils = require("roslyn.sln.utils")
local commands = require("roslyn.commands")

---@param buf number
---@return boolean
local function valid_buffer(buf)
    local bufname = vim.api.nvim_buf_get_name(buf)
    return vim.bo[buf].buftype ~= "nofile"
        and (
            bufname:match("^/")
            or bufname:match("^[a-zA-Z]:")
            or bufname:match("^zipfile://")
            or bufname:match("^tarfile:")
        )
end

---@param bufnr integer
---@param cmd string[]
---@param root_dir string
---@param roslyn_config InternalRoslynNvimConfig
---@param on_init fun(client: vim.lsp.Client)
local function lsp_start(bufnr, cmd, root_dir, roslyn_config, on_init)
    local config = vim.deepcopy(roslyn_config.config)
    config.name = "roslyn"
    config.root_dir = root_dir
    config.handlers = vim.tbl_deep_extend("force", {
        ["client/registerCapability"] = function(err, res, ctx)
            for _, reg in ipairs(res.registrations) do
                if reg.method == "workspace/didChangeWatchedFiles" and not roslyn_config.filewatching then
                    reg.registerOptions.watchers = {}
                end
            end
            return vim.lsp.handlers["client/registerCapability"](err, res, ctx)
        end,
        ["workspace/projectInitializationComplete"] = function(_, _, ctx)
            vim.notify("Roslyn project initialization complete", vim.log.levels.INFO, { title = "roslyn.nvim" })

            local buffers = vim.lsp.get_buffers_by_client_id(ctx.client_id)
            for _, buf in ipairs(buffers) do
                vim.lsp.util._refresh("textDocument/diagnostic", { bufnr = buf })
            end

            vim.api.nvim_exec_autocmds("User", { pattern = "RoslynInitialized", modeline = false })
        end,
        ["workspace/_roslyn_projectHasUnresolvedDependencies"] = function()
            vim.notify("Detected missing dependencies. Run dotnet restore command.", vim.log.levels.ERROR, {
                title = "roslyn.nvim",
            })
            return vim.NIL
        end,
        ["workspace/_roslyn_projectNeedsRestore"] = function(_, result, ctx)
            local client = assert(vim.lsp.get_client_by_id(ctx.client_id))

            client:request("workspace/_roslyn_restore", result, function(err, response)
                if err then
                    vim.notify(err.message, vim.log.levels.ERROR, { title = "roslyn.nvim" })
                end
                if response then
                    for _, v in ipairs(response) do
                        vim.notify(v.message, vim.log.levels.INFO, { title = "roslyn.nvim" })
                    end
                end
            end)

            return vim.NIL
        end,
    }, config.handlers or {})
    config.on_init = function(client, initialize_result)
        if roslyn_config.config.on_init then
            roslyn_config.config.on_init(client, initialize_result)
        end
        on_init(client)

        local lsp_commands = require("roslyn.lsp_commands")
        lsp_commands.fix_all_code_action(client)
        lsp_commands.nested_code_action(client)
    end

    config.on_exit = function(code, signal, client_id)
        vim.g.roslyn_nvim_selected_solution = nil
        server.stop_server(client_id)
        vim.schedule(function()
            vim.notify("Roslyn server stopped", vim.log.levels.INFO, { title = "roslyn.nvim" })
        end)
        if roslyn_config.config.on_exit then
            roslyn_config.config.on_exit(code, signal, client_id)
        end
    end

    server.start_server(bufnr, cmd, config)
end

local function on_init_sln(client)
    local target = vim.g.roslyn_nvim_selected_solution
    vim.notify("Initializing Roslyn client for " .. target, vim.log.levels.INFO, { title = "roslyn.nvim" })
    client.notify("solution/open", {
        solution = vim.uri_from_fname(target),
    })
end

---@param files string[]
local function on_init_project(files)
    return function(client)
        vim.notify("Initializing Roslyn client for projects", vim.log.levels.INFO, { title = "roslyn.nvim" })
        client.notify("project/open", {
            projects = vim.tbl_map(function(file)
                return vim.uri_from_fname(file)
            end, files),
        })
    end
end

local M = {}

---@param config? RoslynNvimConfig
function M.setup(config)
    local roslyn_config = require("roslyn.config").setup(config)

    vim.treesitter.language.register("c_sharp", "csharp")

    local cmd = vim.list_extend(vim.deepcopy(roslyn_config.exe), vim.deepcopy(roslyn_config.args))
    commands.create_roslyn_commands()

    vim.api.nvim_create_autocmd({ "FileType" }, {
        group = vim.api.nvim_create_augroup("Roslyn", { clear = true }),
        pattern = "cs",
        callback = function(opt)
            if not valid_buffer(opt.buf) then
                return
            end

            -- Lock the target and always start with the currently selected solution
            if roslyn_config.lock_target and vim.g.roslyn_nvim_selected_solution then
                local sln_dir = vim.fs.dirname(vim.g.roslyn_nvim_selected_solution)
                return lsp_start(opt.buf, cmd, sln_dir, roslyn_config, on_init_sln)
            end

            commands.attach_subcommand_to_buffer("target", opt.buf, {
                impl = function()
                    local root = vim.b.roslyn_root or utils.root(opt.buf, roslyn_config.broad_search)

                    vim.ui.select(root.solutions or {}, { prompt = "Select target solution: " }, function(file)
                        vim.lsp.stop_client(vim.lsp.get_clients({ name = "roslyn" }), true)
                        vim.g.roslyn_nvim_selected_solution = file
                        local sln_dir = vim.fs.dirname(file)
                        lsp_start(opt.buf, cmd, assert(sln_dir), roslyn_config, on_init_sln)
                    end)
                end,
            })

            vim.schedule(function()
                local root = utils.root(opt.buf, roslyn_config.broad_search)
                vim.b.roslyn_root = root

                local solution = utils.predict_sln_file(root, roslyn_config)
                if solution then
                    vim.g.roslyn_nvim_selected_solution = solution
                    return lsp_start(opt.buf, cmd, vim.fs.dirname(solution), roslyn_config, on_init_sln)
                elseif root.projects then
                    local dir = root.projects.directory
                    return lsp_start(opt.buf, cmd, dir, roslyn_config, on_init_project(root.projects.files))
                end

                -- Fallback to the selected solution if we don't find anything.
                -- This makes it work kind of like vscode for the decoded files
                if vim.g.roslyn_nvim_selected_solution then
                    local sln_dir = vim.fs.dirname(vim.g.roslyn_nvim_selected_solution)
                    return lsp_start(opt.buf, cmd, sln_dir, roslyn_config, on_init_sln)
                end
            end)
        end,
    })
end

return M
