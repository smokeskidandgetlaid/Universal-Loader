local UI = {}
UI.__index = UI

function UI.new(manager, scope, entry, registryFailure)
    local self = setmetatable({manager = manager, scope = scope, entry = entry,
        buttons = {}, registryFailure = registryFailure, closed = false}, UI)
    self.window = scope:CreateWindow({
        name = "Universal Loader",
        subtitle = entry and entry.name or "Game selection",
        sidebarLayout = false,
        configuration = {autoSave = false, autoLoad = false}
    })
    local tab = self.window:CreateTab({name = "Scripts", icon = "rbxassetid://10734975692"})
    tab:CreateSection({name = entry and entry.name or "Current game"})
    tab:CreateText({name = "Game", text = entry and entry.name
        or ("Universe " .. game.GameId .. " · Place " .. game.PlaceId)})
    self.activeText = tab:CreateText({name = "Session", text = manager:ActiveLabel()})
    self.status = tab:CreateText({name = "Status", text = "Initializing loader…"})
    if registryFailure then
        self.status:Set("Registry error: " .. (tostring(registryFailure):match("^[^\n]+") or tostring(registryFailure)))
    elseif entry then
        for _, option in ipairs(entry.scripts) do
            local button = tab:CreateButton({name = option.label, callback = function()
                manager:Select(entry, option)
            end})
            table.insert(self.buttons, button)
        end
    else
        self.status:Set("Unsupported Game — This game is not currently supported.")
    end
    self.retry = tab:CreateButton({name = "Retry", callback = function()
        if self.registryFailure or not self.entry then manager:RetryRegistry() else manager:RetrySelection() end
    end})
    self.retry:Lock("No failed operation to retry")
    self.closeButton = tab:CreateButton({name = "Close", callback = function() manager:CloseLoader() end})
    return self
end

function UI:Focus()
    if not self.closed and not self.window.unloaded then self.window:Show() end
end

function UI:Update(message, isError)
    if self.closed or self.window.unloaded then return end
    self.activeText:Set(self.manager:ActiveLabel())
    if not self.entry and not self.registryFailure then
        self.status:Set("Unsupported Game — This game is not currently supported.")
    else
        self.status:Set(tostring(message):match("^[^\n]+"))
    end
    for _, button in ipairs(self.buttons) do
        if self.manager.busy then button:Lock("Transition in progress") else button:Unlock() end
    end
    if self.manager.busy then
        self.retry:Lock("Transition in progress")
        self.closeButton:Lock("Transition in progress")
    else
        self.closeButton:Unlock()
        if isError or self.registryFailure then self.retry:Unlock() else self.retry:Lock("No failed operation to retry") end
    end
    if isError then
        warn("Universal Loader: " .. tostring(message))
        self.window:Notify({title = "Universal Loader", content = tostring(message):match("^[^\n]+"), duration = 6})
    end
end

function UI:Close()
    if self.closed then return true end
    local ok, failure = self.scope:Close()
    if not ok then
        warn("Universal Loader UI cleanup failed: " .. tostring(failure))
        return false
    end
    self.closed = true
    self.manager:LoaderClosed(self.scope)
    return true
end

return UI
