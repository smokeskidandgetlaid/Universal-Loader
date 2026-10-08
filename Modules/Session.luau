local Session = {}
Session.__index = Session

function Session.new(dependencies, environment)
    return setmetatable({dependencies = dependencies, environment = environment,
        states = {}, active = nil, busy = false, opening = false, loader = nil,
        librarySource = nil, startPermit = nil, lastSelection = nil}, Session)
end

function Session:GetLibrarySource()
    if self.librarySource then return self.librarySource end
    local cached = rawget(self.environment, "__RayfieldGen2Source")
    if type(cached) == "string" and #cached > 1000 then
        local valid = pcall(self.dependencies.Remote.Compile, self.dependencies.Remote, cached, "Rayfield Gen2")
        if valid then
            self.librarySource = cached
            return cached
        end
    end
    self.librarySource = self.dependencies.Remote:GetUrl("https://sirius.menu/gen2")
    return self.librarySource
end

function Session:ActiveLabel()
    if not self.active then return "Active: None" end
    return "Active: " .. self.active.label .. " (" .. tostring(self.active.script.state) .. ")"
end

function Session:Update(message, isError)
    if self.loader and self.loader.Update then self.loader:Update(message, isError) end
end

function Session:ScriptStopped(script, ok, failure)
    if self.active and self.active.script == script then
        self.states[self.active.identity] = ok and "stopped" or "failed"
        if ok then self.active = nil end
        self:Update(ok and "Script stopped. Choose a script to restart." or "Cleanup failed: " .. tostring(failure), not ok)
    end
end

function Session:LoaderClosed(scope)
    if self.loader and self.loader.scope == scope then self.loader = nil end
end

function Session:CloseLoader()
    if self.busy then
        self:Update("Wait for the current transition to finish.")
        return
    end
    if self.loader then self.loader:Close() end
end

function Session:Open()
    if self.loader then
        if self.loader.Focus then self.loader:Focus() end
        return
    end
    if self.opening then
        warn("Universal Loader is fetching its registry. Please wait.")
        return
    end
    self.opening = true
    task.spawn(function()
        local entry, registryFailure
        local ok, failure = xpcall(function()
            local registry = self.dependencies.Registry.Parse(self.dependencies.Remote:Get("games.json"))
            entry = self.dependencies.Registry.Detect(registry, game.GameId, game.PlaceId)
        end, debug.traceback)
        if not ok then registryFailure = failure end
        local scope = self.dependencies.Scope.new(self, "loader")
        scope.active = true
        local created, view = xpcall(function()
            local interface = self.dependencies.UI.new(self, scope, entry, registryFailure)
            assert(scope.active and not interface.window.unloaded, "Loader closed during initialization")
            return interface
        end, debug.traceback)
        self.opening = false
        if not created then
            scope:Close()
            self.librarySource = nil
            warn("Universal Loader UI failed: " .. tostring(view) .. "\nRun the loader again to retry.")
            return
        end
        self.loader = view
        view:Update(registryFailure and "Registry failed. Retry to fetch it again." or "Choose a script to run.", registryFailure ~= nil)
    end)
end

function Session:RetryRegistry()
    if self.busy or self.opening then return end
    if self.loader then
        local ok = self.loader:Close()
        if not ok then return end
    end
    self:Open()
end

function Session:Await(scope, callback, timeout)
    local finished, result = false, nil
    local worker = coroutine.create(function()
        result = table.pack(xpcall(callback, debug.traceback))
        finished = true
    end)
    scope.threads[worker] = true
    task.spawn(worker)
    local deadline = os.clock() + timeout
    while not finished and os.clock() < deadline do task.wait(0.05) end
    if finished then
        scope.threads[worker] = nil
        if not result[1] then return false, result[2] end
        return table.unpack(result, 2, result.n)
    end
    local cancelled, cancelFailure = pcall(task.cancel, worker)
    if cancelled and coroutine.status(worker) == "dead" then scope.threads[worker] = nil end
    return false, "Lifecycle operation timed out after " .. timeout .. " seconds"
        .. (cancelled and "" or ": " .. tostring(cancelFailure))
end

function Session:Select(entry, option)
    if self.busy or self.opening then return end
    local detected = self.loader and self.loader.entry
    if detected ~= entry or not table.find(entry.scripts, option) then return end
    local identity = entry.id .. "/" .. option.id
    if self.active and self.active.identity == identity and self.active.script:IsRunning() then
        self:Update(option.label .. " is already running.")
        return
    end
    self.busy = true
    self.lastSelection = {entry = entry, option = option}
    self.states[identity] = "loading"
    self:Update("Downloading " .. option.label .. "…")
    task.spawn(function()
        local candidate
        local ok, failure = xpcall(function()
            local source = self.dependencies.Remote:Get(option.path)
            local chunk = self.dependencies.Remote:Compile(source, option.path)
            local factory = chunk()
            assert(type(factory) == "function", "Script must return a lifecycle factory")
            local scope = self.dependencies.Scope.new(self, identity)
            local script = factory(scope)
            assert(script == scope.script and type(script.Start) == "function"
                and type(script.Stop) == "function" and type(script.IsRunning) == "function",
                "Invalid script lifecycle contract")
            assert(script.state == "stopped" and not script:IsRunning(), "Script started during preparation")
            candidate = {script = script, scope = scope, identity = identity, label = option.label}
            if self.active then
                local old = self.active
                self.states[old.identity] = "stopping"
                self:Update("Stopping " .. old.label .. "…")
                local stopped, stopFailure = self:Await(old.scope, function() return old.script:Stop() end, 15)
                if not stopped then
                    old.script.state = "failed"
                    self.states[old.identity] = "failed"
                end
                assert(stopped and old.script.state == "stopped" and not old.script:IsRunning(),
                    "Cannot safely stop " .. old.label .. ": " .. tostring(stopFailure))
                self.active = nil
            end
            self:Update("Initializing " .. option.label .. "…")
            self.active = candidate
            self.startPermit = script
            local started, startFailure = self:Await(scope, function() return script:Start() end, 45)
            self.startPermit = nil
            assert(started and script:IsRunning(), "Initialization failed: " .. tostring(startFailure))
            self.states[identity] = "running"
            self:Update(option.label .. " initialized successfully.")
        end, debug.traceback)
        self.startPermit = nil
        if not ok then
            local cleanupFailure
            if candidate and self.active == candidate then
                local cleaned, reason = self:Await(candidate.scope, function() return candidate.script:Stop() end, 15)
                if cleaned and candidate.script.state == "stopped" then
                    self.active = nil
                else
                    cleanupFailure = reason
                    candidate.script.state = "failed"
                end
            end
            self.states[identity] = "failed"
            self.busy = false
            self:Update(tostring(failure) .. (cleanupFailure and "\nCleanup failed: " .. tostring(cleanupFailure) or ""), true)
            return
        end
        self.busy = false
        if self.loader then
            task.wait(0.35)
            if not self.busy and self.loader then self.loader:Close() end
        end
    end)
end

function Session:RetrySelection()
    if self.lastSelection and self.loader and self.loader.entry == self.lastSelection.entry then
        self:Select(self.lastSelection.entry, self.lastSelection.option)
    end
end

return Session
