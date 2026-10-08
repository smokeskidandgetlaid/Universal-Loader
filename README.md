# Universal Loader

A registry-driven Roblox script loader using the same Rayfield Gen2 library as the existing BreakDoor interfaces. It detects the current game, presents its registered options, and downloads a game script only after an explicit selection.

**Hunter.luau and Survivor.luau are intentionally empty, at the owner's request.** Fill these two files with lifecycle-compatible modules before expecting a game script to run. Empty files fail during preparation; they do not stop an active script. The original standalone scripts are not published by this project.

## Run

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/smokeskidandgetlaid/Universal-Loader/main/Loader.luau?nocache=" .. game:GetService("HttpService"):GenerateGUID(false), false))()
```

This is an executor-style client loader. It requires `loadstring`, `setfenv`, client HTTP access (`request`, `http_request`, `syn.request`, or `game:HttpGet`), and task/coroutine cancellation. It is not a regular Roblox LocalScript. The original game scripts also depend on executor capabilities and game-specific replicated controllers.

## Files

```text
Loader.luau
games.json
Modules/
  Registry.luau
  Scope.luau
  Session.luau
  UI.luau
Games/
  Breakdoor/
    Hunter.luau      (empty; supplied by owner)
    Survivor.luau    (empty; supplied by owner)
README.md
```

`Loader.luau` centralizes remote requests and compilation. `Registry` validates configuration and detects the game. `Session` holds persistent session state and controls transitions. `Scope` owns resources and implements the lifecycle contract. `UI` creates dynamic selection controls independently of game-script windows.

## Registry and game detection

The initial configuration uses Universe ID **9788139379**. The four existing script destinations all resolved to that universe through Roblox's public universe API:

| Place | Place ID |
| --- | --- |
| Normal / root | 119004860768199 |
| Pro | 108994049761860 |
| AFK | 140725422147474 |
| GamePlace | 138031701774088 |

Source: `https://apis.roblox.com/universes/v1/places/{placeId}/universe`. Roblox's games endpoint also returned root Place ID 119004860768199 for this universe. Identifiers were retrieved on 2026-10-09.

Each game has a unique `id`, a display `name`, `universeIds`, optional `placeIds`, and one or more `scripts`. Each script has a unique per-game `id`, a custom `label`, and a relative `.luau` `path` under `Games/`.

Universe matching takes priority. By default, any place in a configured universe matches. Set `restrictToPlaces: true` to allow only the listed places within that universe. For a place-only configuration, omit `universeIds` or use an empty array. Place-only matches are considered after universe matches. A listed place never overrides a conflicting configured universe.

Invalid JSON, duplicate IDs, ambiguous matching, empty script lists, and unsafe paths are rejected. Unsupported games show `Unsupported Game — This game is not currently supported.` and Close; no game scripts are requested.

## Required game-script contract

Each game file must return a factory without starting tasks, creating UI, or modifying gameplay during preparation. The factory receives an inactive resource context and returns `context:CreateScript(initializer)`. The manager authorizes `Start()` only after the previous script has stopped.

Minimal example, to adapt inside a game file:

```lua
return function(context)
    return context:CreateScript(function()
        local window = context:CreateWindow({
            name = "My Game Tools",
            subtitle = "Game script",
            sidebarLayout = false,
            configuration = {autoSave = false, autoLoad = false}
        })
        local tab = window:CreateTab({name = "Tools"})
        tab:CreateButton({name = "Unload Script", callback = function()
            local stopped, failure = context.script:Stop()
            assert(stopped, failure)
        end})
    end)
end
```

Move the script's initialization into the initializer, preserving its existing gameplay callbacks and settings. Return only when required initialization has completed; throw an error when initialization cannot complete. Completion of this function, a live scope, and intact owned windows form the ready contract. This verifies initialization completion, not successful multiplayer gameplay or every optional background operation.

Use the context consistently:

| Resource | API |
| --- | --- |
| Background work | `context.task.spawn/defer/delay/wait/cancel` |
| Events, including yielding callbacks | `context:Connect(signal, callback)` |
| Explicit event disconnect | `context:Disconnect(connection)` |
| Temporary instances | `context:New(className, optionalParent)` |
| Tween | `context:Tween(TweenService, instance, info, goals)` |
| Properties changed on existing objects | `context:Set(object, property, value)` |
| Save a property before other code changes it | `context:Remember(object, property)` |
| Additional shutdown work | `context:OnStop(callback)` |
| Owned simulated mouse buttons | `context:SendMouseButton(VirtualInputManager, x, y, button, down, game, 0)` |
| Independent Rayfield window | `context:CreateWindow(properties)` |
| Lifecycle | `context.script:Start()/Stop()/IsRunning()` |

`OnStop` returns a function that removes that cleanup callback, useful when a temporary operation finishes normally. Register restoration before a yielding temporary teleport or other stateful operation. Cleanup callbacks must be bounded, non-yielding, and must not create new resources. Restore controller-held actions and other game-module state explicitly; arbitrary effects inside game controllers cannot be inferred automatically.

All tasks, event connections, tweens, temporary instances, simulated pressed buttons, window resources, and remembered properties belong to the context. Stop disconnects events and cancels tasks before invoking custom cleanup and restoring properties. Failed cleanup retains ownership records for another attempt and blocks switching. Start is idempotent while running; Stop is idempotent after stopping. Restart executes a fresh initializer. A factory obtained by directly executing a module file does not automatically start it.

**Do not paste the old standalone Hunter/Survivor sources unchanged.** Their UI-only unload routines do not cancel every background loop, and their shared cached Rayfield object is unsuitable for independent ownership. They need the contract above. Game scripts using raw tasks, connections, globals, or unregistered controller state bypass the cleanup guarantees. Already-running legacy standalone scripts cannot be adopted or stopped safely by this manager; start in a fresh Roblox session.

## Switching and manual recovery

Rerunning the loader reuses `__UniversalLoaderSession_v1` and focuses the existing loader or creates one after it has closed. The active game script is unaffected by reopening.

Selection acquires one session lock, disables loading controls, downloads and compiles the selected source, and prepares its lifecycle factory while the old script continues running. Only then does the manager stop the old script, require a successful stopped state, authorize the new Start, and require its running/ready state. It closes only the loader's resource scope after success.

If preparation fails, the old script stays active. If stopping fails, switching aborts. If the new initialization fails after stopping the old script, no automatic rollback occurs: the loader remains open with Retry and all game options. The active label shows None after successful failure cleanup, or a failed script if resources still require cleanup. Choosing the previous option manually downloads its current source and restarts it. Locks are released after failures. States are `loading`, `running`, `stopping`, `stopped`, and `failed`.

## Updates and additional games

Add a lifecycle-compatible file under `Games/<game>/`, then add that game's identifiers and script options to `games.json` on `main`. One script or many scripts use the same structure. No loader changes are necessary. Verify identifiers through Roblox's public APIs or the running game's `game.GameId` and `game.PlaceId`.

To publish an update, replace the game file on `main`. Each selection fetches fresh source with a unique query parameter and requests no-cache behavior where supported. The registry is fetched when a new loader interface opens. No polling occurs while a script is running. GitHub and executor caches cannot be absolutely controlled; unique URLs reduce stale cache reuse.

A running script remains unchanged by repository updates. Selecting the same active option prevents a duplicate; stop it through its own Unload Script control before selecting it again to pick up an update. Framework modules stay in the current session manager; start a fresh Roblox session to adopt framework changes. The single-line entry command remains unchanged.

## Failures and validation limits

Remote requests time out after 20 seconds, Stop after 15 seconds, and Start after 45 seconds. Compilation, registry, preparation, initialization, and shutdown failures are surfaced; full errors remain in the console. Timeout cancellation and successful cleanup are required before a transition can proceed.

Registry and script errors have in-window recovery controls. If the initial bootstrap modules or Rayfield itself cannot download before any UI exists, the console reports the error and instructs the user to rerun the same command. This cannot offer an in-window Retry until the UI library is available. Rayfield source may be cached within the session, but each window uses a separate library instance, tasks, instances, tweens, and connections.

The two role files are intentionally empty and cannot be runtime-validated. Live Roblox validation is still required after they are filled: duplicate launches, every enabled automation during Stop, Hunter/Survivor switching, startup failures, timeout recovery, UI independence, saved settings, temporary character-state restoration, and game-controller action release. Destruction of pre-existing world objects by an existing FPS booster is irreversible within the client session; resource cleanup does not reconstruct those objects.
