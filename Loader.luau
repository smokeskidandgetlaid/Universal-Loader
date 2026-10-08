local executorEnvironment = getfenv()
local getGlobalEnvironment = executorEnvironment.getgenv
local environment = (type(getGlobalEnvironment) == "function" and getGlobalEnvironment()) or _G
local sessionKey = "__UniversalLoaderSession_v1"
local repository = "smokeskidandgetlaid/Universal-Loader"
local branch = "main"
local baseUrl = "https://raw.githubusercontent.com/" .. repository .. "/" .. branch .. "/"
local existing = rawget(environment, sessionKey)
if existing then
    if existing.Open then
        existing:Open()
    else
        warn("Universal Loader is already initializing. Retry after it finishes.")
    end
    return
end

local reservation = {}
environment[sessionKey] = reservation
local Remote = {timeout = 20}

function Remote:GetUrl(url)
    local done, result, failure = false, nil, nil
    local expired = false
    local requestFunction = executorEnvironment.request or executorEnvironment.http_request
        or (type(executorEnvironment.syn) == "table" and executorEnvironment.syn.request)
    if type(requestFunction) ~= "function" then requestFunction = nil end
    local worker = task.spawn(function()
        local ok, response = pcall(function()
            if requestFunction then
                local reply = requestFunction({
                    Url = url, Method = "GET", Timeout = self.timeout,
                    Headers = {["Cache-Control"] = "no-cache", Pragma = "no-cache"}
                })
                assert(type(reply) == "table", "Invalid HTTP response")
                local status = tonumber(reply.StatusCode)
                assert(status and status >= 200 and status < 300, "HTTP " .. tostring(status))
                return reply.Body
            end
            return (game :: any):HttpGet(url, false)
        end)
        if expired then return end
        if ok and type(response) == "string" and #response > 0 then
            result = response
        else
            failure = tostring(ok and "Remote file is empty; add its lifecycle-compatible source before loading" or response)
        end
        done = true
    end)
    local deadline = os.clock() + self.timeout
    while not done and os.clock() < deadline do task.wait(0.05) end
    if not done then
        expired = true
        pcall(task.cancel, worker)
        error("Remote request timed out after " .. self.timeout .. " seconds", 0)
    end
    if failure then error(failure, 0) end
    return result
end

function Remote:Get(path)
    assert(type(path) == "string" and path:match("^[%w_./%-]+$")
        and not path:find("..", 1, true) and path:sub(1, 1) ~= "/", "Invalid repository path")
    return self:GetUrl(baseUrl .. path .. "?nocache=" .. game:GetService("HttpService"):GenerateGUID(false))
end

function Remote:Compile(source, name)
    assert(type(loadstring) == "function", "This environment requires loadstring")
    local chunk, failure = loadstring(source, "=" .. name)
    assert(chunk, "Compilation failed: " .. tostring(failure))
    return chunk
end

local ok, failure = xpcall(function()
    assert(type(setfenv) == "function", "This environment requires setfenv for independent UI ownership")
    local modules = {}
    local function requireModule(name)
        if modules[name] then return modules[name] end
        local value = Remote:Compile(Remote:Get("Modules/" .. name .. ".luau"), name)()
        assert(type(value) == "table", "Invalid module: " .. name)
        modules[name] = value
        return value
    end
    local dependencies = {
        Remote = Remote,
        Scope = requireModule("Scope"),
        Registry = requireModule("Registry"),
        UI = requireModule("UI")
    }
    local manager = requireModule("Session").new(dependencies, environment)
    environment[sessionKey] = manager
    manager:Open()
end, debug.traceback)
if not ok then
    if environment[sessionKey] == reservation then environment[sessionKey] = nil end
    warn("Universal Loader: " .. tostring(failure) .. "\nRun the loader again to retry.")
end
