local Registry = {}

local function array(value, name, allowEmpty)
    assert(type(value) == "table", name .. " must be an array")
    local count = 0
    for key in pairs(value) do
        assert(type(key) == "number" and key % 1 == 0 and key >= 1, name .. " must be an array")
        count += 1
    end
    assert(count == #value and (allowEmpty or count > 0), name .. " has invalid length")
end

local function text(value, name)
    assert(type(value) == "string" and value:find("%S"), name .. " must be nonempty text")
end

local function identifiers(values, name, owners, owner)
    values = values or {}
    array(values, name, true)
    for _, value in ipairs(values) do
        assert(type(value) == "number" and value > 0 and value % 1 == 0 and value <= 9007199254740991,
            name .. " contains an invalid ID")
        assert(not owners[value], name .. " contains a duplicate or ambiguous ID: " .. value)
        owners[value] = owner
    end
    return values
end

function Registry.Parse(source)
    local ok, decoded = pcall(game:GetService("HttpService").JSONDecode, game:GetService("HttpService"), source)
    assert(ok, "Invalid registry JSON: " .. tostring(decoded))
    assert(type(decoded) == "table" and decoded.version == 1, "Unsupported registry version")
    array(decoded.games, "games", true)
    local ids, universes, places = {}, {}, {}
    for _, entry in ipairs(decoded.games) do
        assert(type(entry) == "table", "Invalid game configuration")
        text(entry.id, "game.id")
        text(entry.name, "game.name")
        assert(not ids[entry.id], "Duplicate game.id: " .. entry.id)
        ids[entry.id] = true
        entry.universeIds = identifiers(entry.universeIds, "universeIds", universes, entry)
        entry.placeIds = identifiers(entry.placeIds, "placeIds", places, entry)
        assert(#entry.universeIds > 0 or #entry.placeIds > 0, "Game has no matching IDs: " .. entry.id)
        assert(entry.restrictToPlaces == nil or type(entry.restrictToPlaces) == "boolean", "Invalid restrictToPlaces")
        assert(not entry.restrictToPlaces or #entry.placeIds > 0, "restrictToPlaces requires placeIds")
        array(entry.scripts, "scripts", false)
        local scripts = {}
        for _, option in ipairs(entry.scripts) do
            assert(type(option) == "table", "Invalid script option")
            text(option.id, "script.id")
            text(option.label, "script.label")
            text(option.path, "script.path")
            assert(not scripts[option.id], "Duplicate script.id: " .. option.id)
            scripts[option.id] = true
            assert(option.path:match("^Games/[%w_./%-]+%.luau$") and not option.path:find("..", 1, true),
                "Script path must be a relative .luau file under Games/")
        end
    end
    return decoded
end

function Registry.Detect(registry, universeId, placeId)
    for _, entry in ipairs(registry.games) do
        if table.find(entry.universeIds, universeId) then
            if not entry.restrictToPlaces or table.find(entry.placeIds, placeId) then return entry end
            return nil
        end
    end
    for _, entry in ipairs(registry.games) do
        if #entry.universeIds == 0 and table.find(entry.placeIds, placeId) then return entry end
    end
    return nil
end

return Registry
