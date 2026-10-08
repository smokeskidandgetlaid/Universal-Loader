local nativeTask = task
local nativeInstance = Instance
local Scope = {}
Scope.__index = Scope

function Scope.new(manager, identity)
    local self = setmetatable({
        manager = manager, identity = identity, active = false,
        threads = {}, connections = {}, instances = {}, tweens = {},
        restores = {} :: {[any]: {[string]: {value: any}}},
        cleanups = {}, windows = {}, inputs = {}, closing = false
    }, Scope)
    self.task = {
        wait = nativeTask.wait,
        cancel = function(thread)
            nativeTask.cancel(thread)
            self.threads[thread] = nil
        end,
        spawn = function(callback, ...) return self:Schedule("spawn", 0, callback, ...) end,
        defer = function(callback, ...) return self:Schedule("defer", 0, callback, ...) end,
        delay = function(duration, callback, ...) return self:Schedule("delay", duration, callback, ...) end
    }
    self.Instance = {new = function(className, parent) return self:New(className, parent) end}
    return self
end

function Scope:AssertActive()
    assert(self.active and not self.closing, "Resource scope is stopped")
end

function Scope:Schedule(method, duration, callback, ...)
    self:AssertActive()
    assert(type(callback) == "function", "Scoped tasks require a function")
    local arguments = table.pack(...)
    local thread
    thread = coroutine.create(function()
        if not self.active then
            self.threads[thread] = nil
            return
        end
        local ok, failure = xpcall(function()
            return callback(table.unpack(arguments, 1, arguments.n))
        end, debug.traceback)
        self.threads[thread] = nil
        if not ok then warn("Universal Loader [" .. self.identity .. "]: " .. tostring(failure)) end
    end)
    self.threads[thread] = true
    if method == "delay" then nativeTask.delay(duration, thread) else nativeTask[method](thread) end
    return thread
end

function Scope:Connect(signal, callback)
    self:AssertActive()
    if type(signal) == "table" and rawget(signal, "__scopeSignal") then signal = signal.__scopeSignal end
    local connection = signal:Connect(function(...)
        if not self.active then return end
        self:Schedule("spawn", 0, callback, ...)
    end)
    self.connections[connection] = true
    return connection
end

function Scope:Disconnect(connection)
    connection:Disconnect()
    self.connections[connection] = nil
end

function Scope:New(className, parent)
    self:AssertActive()
    local instance = nativeInstance.new(className)
    self.instances[instance] = true
    local connection
    local ok = pcall(function()
        connection = instance.Destroying:Connect(function()
            self.instances[instance] = nil
            self.connections[connection] = nil
            connection:Disconnect()
        end)
    end)
    if ok and connection then self.connections[connection] = true end
    if parent then instance.Parent = parent end
    return instance
end

function Scope:Tween(service, ...)
    self:AssertActive()
    local tween = service:Create(...)
    self.tweens[tween] = true
    local connection
    connection = tween.Completed:Connect(function()
        self.tweens[tween] = nil
        self.connections[connection] = nil
        connection:Disconnect()
    end)
    self.connections[connection] = true
    return tween
end

function Scope:Remember(object: any, property: string)
    self:AssertActive()
    if self.instances[object] then return end
    local properties = self.restores[object]
    if not properties then
        properties = {}
        self.restores[object] = properties
    end
    if properties[property] == nil then properties[property] = {value = object[property]} end
end

function Scope:Set(object: any, property: string, value: any)
    if self.closing then
        object[property] = value
        return
    end
    self:Remember(object, property)
    object[property] = value
end

function Scope:OnStop(callback)
    self:AssertActive()
    local record = {callback = callback}
    table.insert(self.cleanups, record)
    return function()
        record.callback = nil
        local index = table.find(self.cleanups, record)
        if index then table.remove(self.cleanups, index) end
    end
end

function Scope:SendMouseButton(input, x, y, button, down, ...)
    self:AssertActive()
    self.inputs[button] = down and {input = input, x = x, y = y} or nil
    return input:SendMouseButtonEvent(x, y, button, down, ...)
end

function Scope:CreateWindow(properties)
    self:AssertActive()
    local source = self.manager:GetLibrarySource()
    self:AssertActive()
    local chunk = self.manager.dependencies.Remote:Compile(source, "Rayfield Gen2")
    local tweenService = game:GetService("TweenService")
    local cloneReference = getfenv().cloneref
    local tweenProxy = {Create = function(_, ...) return self:Tween(tweenService, ...) end}
    local services = {}
    local function serviceProxy(service)
        return setmetatable({}, {__index = function(_, key)
            local value = service[key]
            if typeof(value) == "RBXScriptSignal" then
                return {__scopeSignal = value,
                    Connect = function(_, callback) return self:Connect(value, callback) end,
                    Wait = function() return value:Wait() end}
            end
            if type(value) == "function" then return function(_, ...) return value(service, ...) end end
            return value
        end})
    end
    local gameProxy = setmetatable({}, {__index = function(_, key)
        if key == "GetService" then
            return function(_, name)
                if name == "TweenService" then return tweenProxy end
                if name == "RunService" or name == "UserInputService" or name == "GuiService" then
                    if not services[name] then services[name] = serviceProxy(game:GetService(name)) end
                    return services[name]
                end
                return game:GetService(name)
            end
        end
        local value = game[key]
        if type(value) == "function" then return function(_, ...) return value(game, ...) end end
        return value
    end})
    local libraryEnvironment = setmetatable({
        task = self.task, Instance = self.Instance, game = gameProxy,
        cloneref = function(value)
            if typeof(value) == "Instance" and type(cloneReference) == "function" then return cloneReference(value) end
            return value
        end
    }, {__index = getfenv(chunk)})
    setfenv(chunk, libraryEnvironment)
    local library = chunk()
    self:AssertActive()
    assert(type(library) == "table" and type(library.CreateWindow) == "function", "Invalid Rayfield Gen2 library")
    local window = library:CreateWindow(properties)
    assert(window and type(window.Unload) == "function", "Rayfield window has no independent Unload")
    table.insert(self.windows, window)
    assert(type(window.Connect) == "function", "Rayfield window has no Connect resource contract")
    window.Connect = function(owner, signal, callback)
        local connection = self:Connect(signal, callback)
        table.insert(owner.connections, connection)
        return connection
    end
    local disconnect = window.Disconnect
    window.Disconnect = function(owner, connection)
        self.connections[connection] = nil
        return disconnect(owner, connection)
    end
    local unload = window.Unload
    window.Unload = function(owner)
        if self.closing or not self.active then return unload(owner) end
        if not self.script and self.manager.busy then
            self.manager:Update("Wait for the current transition to finish.")
            return nil
        end
        local stopped, failure
        if self.script then
            stopped, failure = self.script:Stop()
        else
            stopped, failure = self:Close()
            if stopped then self.manager:LoaderClosed(self) end
        end
        if not stopped then warn("Universal Loader cleanup failed: " .. tostring(failure)) end
        return nil
    end
    self:Connect(window.screenGui.Destroying, function()
        if not self.closing and self.active then window:Unload() end
    end)
    return window
end

function Scope:Close()
    if self.closing then return false, "Cleanup is already in progress" end
    self.active = false
    self.closing = true
    local failures = {}
    local function attempt(callback)
        local ok, failure = pcall(callback)
        if not ok then table.insert(failures, tostring(failure)) end
        return ok
    end
    for connection in pairs(self.connections) do
        if attempt(function() connection:Disconnect() end) then self.connections[connection] = nil end
    end
    local current = coroutine.running()
    for thread in pairs(self.threads) do
        if thread == current or coroutine.status(thread) == "dead" then
            self.threads[thread] = nil
        elseif attempt(function()
            nativeTask.cancel(thread)
            assert(coroutine.status(thread) == "dead", "A background task did not stop")
        end) then
            self.threads[thread] = nil
        end
    end
    for tween in pairs(self.tweens) do
        if attempt(function()
            tween:Cancel()
            tween:Destroy()
        end) then self.tweens[tween] = nil end
    end
    for button, record in pairs(self.inputs) do
        if attempt(function() record.input:SendMouseButtonEvent(record.x, record.y, button, false, game, 0) end) then
            self.inputs[button] = nil
        end
    end
    local cleanups = table.clone(self.cleanups)
    for index = #cleanups, 1, -1 do
        local record = cleanups[index]
        if record.callback and attempt(record.callback) then record.callback = nil end
    end
    for _, window in ipairs(self.windows) do
        if not window.unloaded then attempt(function() window:Unload() end) end
    end
    for instance in pairs(self.instances) do
        if attempt(function() instance:Destroy() end) then self.instances[instance] = nil end
    end
    for object, properties in pairs(self.restores) do
        if typeof(object) == "Instance" and object.Parent == nil then
            self.restores[object] = nil
        else
            for property, record in pairs(properties) do
                if attempt(function() (object :: any)[property] = record.value end) then properties[property] = nil end
            end
            if next(properties) == nil then self.restores[object] = nil end
        end
    end
    self.closing = false
    if #failures > 0 then return false, table.concat(failures, "; ") end
    table.clear(self.windows)
    table.clear(self.cleanups)
    return true
end

function Scope:CreateScript(initialize)
    assert(not self.script, "Only one script may own this scope")
    local scope = self
    local script = {state = "stopped"}
    self.script = script
    function script:IsRunning()
        return self.state == "running" and scope.active
    end
    function script:Start()
        if self:IsRunning() then return true end
        assert(scope.manager.startPermit == self, "Start must be authorized by the session manager")
        assert(self.state == "stopped", "Script must be stopped before starting")
        self.state = "loading"
        scope.active = true
        local ok, failure = xpcall(function() initialize(scope) end, debug.traceback)
        if ok then
            for _, window in ipairs(scope.windows) do
                if window.unloaded then
                    ok, failure = false, "UI closed during initialization"
                    break
                end
            end
        end
        if ok and scope.active then
            self.state = "running"
            return true
        end
        self.state = "failed"
        local cleaned, cleanupFailure = scope:Close()
        return false, tostring(failure or "Initialization was interrupted")
            .. (cleaned and "" or "; Cleanup failed: " .. tostring(cleanupFailure))
    end
    function script:Stop()
        if self.state == "stopped" then return true end
        self.state = "stopping"
        local ok, failure = scope:Close()
        self.state = ok and "stopped" or "failed"
        scope.manager:ScriptStopped(self, ok, failure)
        return ok, failure
    end
    return script
end

return Scope
