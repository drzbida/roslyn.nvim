local server = require("roslyn.server")

local M = {}

---@param bufnr integer
---@param root_dir string
---@param on_init fun(client: vim.lsp.Client)
function M.start(bufnr, root_dir, on_init)
    local roslyn_config = require("roslyn.config").get()
    local cmd = vim.list_extend(vim.deepcopy(roslyn_config.exe), vim.deepcopy(roslyn_config.args))

    local config = vim.deepcopy(roslyn_config.config)
    config.name = "roslyn"
    config.root_dir = root_dir
    config.handlers = vim.tbl_deep_extend("force", {
        ["client/registerCapability"] = function(err, res, ctx)
            if not roslyn_config.filewatching then
                for _, reg in ipairs(res.registrations) do
                    if reg.method == "workspace/didChangeWatchedFiles" then
                        reg.registerOptions.watchers = {}
                    end
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

            ---NOTE: This is used by rzls.nvim for init
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
        ["razor/provideDynamicFileInfo"] = function(_, _, _)
            return vim.notify(
                "Razor is not supported.\nPlease use https://github.com/tris203/rzls.nvim",
                vim.log.levels.WARN,
                { title = "roslyn.nvim" }
            )
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

    config.on_attach = function(client, attach_bufnr)
        local original_request = client.request
        local last_diagnostic = nil
        local default_handler = roslyn_config.config.handlers["textDocument/diagnostic"]
            or vim.lsp.handlers["textDocument/diagnostic"]

        if vim.fn.has("nvim-0.11") == 1 then
            function client:request(method, params, handler, req_bufnr)
                if method ~= "textDocument/diagnostic" then
                    return original_request(self, method, params, handler, req_bufnr)
                end

                params.previousResultId = last_diagnostic and last_diagnostic.resultId
                local function wrapped_handler(err, result, ctx)
                    if result and result.resultId then
                        last_diagnostic = result
                    end
                    return (handler or default_handler)(err, result, ctx)
                end

                return original_request(self, method, params, wrapped_handler, req_bufnr)
            end
        else
            -- Remove this when 0.11 is released
            client.request = function(method, params, handler, req_bufnr)
                if method ~= "textDocument/diagnostic" then
                    return original_request(method, params, handler, req_bufnr)
                end

                params.previousResultId = last_diagnostic and last_diagnostic.resultId
                local function wrapped_handler(err, result, ctx)
                    if result and result.resultId then
                        last_diagnostic = result
                    end
                    return (handler or default_handler)(err, result, ctx)
                end

                return original_request(method, params, wrapped_handler, req_bufnr)
            end
        end
        if roslyn_config.config.on_attach then
            roslyn_config.config.on_attach(client, attach_bufnr)
        end
    end
    server.start_server(bufnr, cmd, config)
end

function M.on_init_sln(client)
    local target = vim.g.roslyn_nvim_selected_solution
    vim.notify("Initializing Roslyn client for " .. target, vim.log.levels.INFO, { title = "roslyn.nvim" })
    client.notify("solution/open", {
        solution = vim.uri_from_fname(target),
    })
end

---@param files string[]
function M.on_init_project(files)
    return function(client)
        vim.notify("Initializing Roslyn client for projects", vim.log.levels.INFO, { title = "roslyn.nvim" })
        client.notify("project/open", {
            projects = vim.tbl_map(function(file)
                return vim.uri_from_fname(file)
            end, files),
        })
    end
end

return M
