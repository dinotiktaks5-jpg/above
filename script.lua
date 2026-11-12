--[[
    Slime Farm v3 | WindUI

    Pink Farm cycle:
      1. Teleport to the hub
      2. Look for an ALIVE pink slime under workspace.Hub.Guardians
      3. Pink found  -> teleport to it, kill it, then rejoin so slimes refresh
         Pink missing -> rejoin right away
      4. After the rejoin, Auto Execute re-runs this script and the cycle resumes

    Also: Slime Farm, Combat (Auto M1 / Auto Equip), Rejoin, Save/Load/Auto Load config.
    K = emergency stop for everything (also cancels the auto-resume).

    For Auto Execute: either paste a Script URL in the Rejoin tab, or save this script
    as  SlimeFarm.lua  in your executor's workspace folder.
]]

local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local TweenService    = game:GetService("TweenService")
local UIS             = game:GetService("UserInputService")
local HttpService     = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local PathfindingService = game:GetService("PathfindingService")

local LP = Players.LocalPlayer

-- Stop a previous copy before starting this one
local env = (getgenv and getgenv()) or _G
pcall(function()
    if type(env.__SlimeFarmStop) == "function" then env.__SlimeFarmStop() end
end)

local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)

local ok, WindUI = pcall(function()
    return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
end)
if not ok or not WindUI then
    warn("[SlimeFarm] Failed to load WindUI")
    return
end

----------------------------------------------------------------------
-- State / config
----------------------------------------------------------------------
local S = {
    alive = true,
    farming = false,      -- normal slime farm
    pinkFarm = false,     -- pink slime cycle
    forceCombat = false,  -- pink hunt forces M1 + equip on
    rejoining = false,
    lastRejoin = 0,
    pinkKills = 0,
    status = "Idle",
}

local cfg = {
    -- Slime farm
    slimeMove = "Walk To",     -- Walk To | Tween | Teleport
    slimeMode = "Above",       -- Above | Infront | Behind | Below
    slimeOffset = 4,
    slimeSpeed = 35,
    skipAfter = 15,

    -- Pink farm
    pinkName = "PinkSlime",    -- exact name of the pink slime under Guardians
    pinkByColor = false,       -- optional extra: treat a pink body colour as a pink slime
    hubTarget = "Portal HB",   -- Portal HB | Guardians Area
    hubSettle = 1.5,           -- seconds to wait after teleporting to the hub
    scanWait = 6,              -- seconds to keep looking for a pink slime
    pinkTimeout = 30,          -- give up on a pink slime that takes no damage for this long
    postKillDelay = 2,         -- wait after the kill before rejoining (drops etc.)

    -- Combat
    autoM1 = false,
    m1Delay = 0.1,
    autoEquip = false,
    swordSlot = 1,

    -- Rejoin / execute / config
    rejoinOnClear = false,     -- (normal slime farm) rejoin once every slime is dead
    rejoinDelay = 5,
    rejoinCooldown = 20,       -- minimum seconds between rejoins
    rejoinMethod = "Teleport", -- Teleport | Open Link
    privateLink = "",
    autoExec = false,
    scriptUrl = "",
    autoLoad = true,
}

local function sanitizeConfig()
    cfg.slimeOffset = math.clamp(tonumber(cfg.slimeOffset) or 4, 0, 30)
    cfg.slimeSpeed = math.clamp(tonumber(cfg.slimeSpeed) or 35, 1, 150)
    cfg.skipAfter = math.clamp(tonumber(cfg.skipAfter) or 15, 0, 600)
    cfg.hubSettle = math.clamp(tonumber(cfg.hubSettle) or 1.5, 0, 15)
    cfg.scanWait = math.clamp(tonumber(cfg.scanWait) or 6, 1, 60)
    cfg.pinkTimeout = math.clamp(tonumber(cfg.pinkTimeout) or 30, 5, 300)
    cfg.postKillDelay = math.clamp(tonumber(cfg.postKillDelay) or 2, 0, 30)
    cfg.m1Delay = math.clamp(tonumber(cfg.m1Delay) or 0.1, 0.03, 5)
    cfg.swordSlot = math.clamp(math.floor(tonumber(cfg.swordSlot) or 1), 1, 9)
    cfg.rejoinDelay = math.clamp(tonumber(cfg.rejoinDelay) or 5, 1, 60)
    cfg.rejoinCooldown = math.clamp(tonumber(cfg.rejoinCooldown) or 20, 5, 600)
end
sanitizeConfig()

local SLOT_KEYS = {
    Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five,
    Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
}

local FILE          = "SlimeFarmConfig.json"
local STATE_FILE    = "SlimeFarm_state.json"
local AUTOEXEC_FLAG = "SlimeFarm_autoexec.txt"
local AUTOLOAD_FLAG = "SlimeFarm_autoload.txt"
local SCRIPT_FILE   = "SlimeFarm.lua"

local UIEl, conns = {}, {}
local syncing = false
local statusPara

local function chr()
    local c = LP.Character
    return c, c and c:FindFirstChildOfClass("Humanoid"), c and c:FindFirstChild("HumanoidRootPart")
end

local function notify(title, content)
    pcall(function() WindUI:Notify({ Title = title, Content = content, Duration = 3 }) end)
end

local function setStatus(text)
    S.status = text
    print("[SlimeFarm] " .. text)
    if statusPara then
        pcall(function() statusPara:SetDesc(text) end)
    end
end

----------------------------------------------------------------------
-- Slime resolving (alive filtering)
----------------------------------------------------------------------
local function getGuardians()
    local hub = workspace:FindFirstChild("Hub")
    return hub and hub:FindFirstChild("Guardians")
end

local function partFrom(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst end
    if inst:IsA("Model") then
        return inst.PrimaryPart
            or inst:FindFirstChild("HumanoidRootPart", true)
            or inst:FindFirstChildWhichIsA("BasePart", true)
    end
    return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function isDead(inst)
    local hum = inst:IsA("Humanoid") and inst or inst:FindFirstChildWhichIsA("Humanoid", true)
    return hum ~= nil and hum.Health <= 0
end

local function slimeAlive(child)
    local hp = child:FindFirstChild("Health")
    if hp and hp:IsA("BillboardGui") and not hp.Enabled then return false end

    local model = child:FindFirstChild("Slime")
    if model then
        local body = model:FindFirstChild("InsideBody") or model:FindFirstChildWhichIsA("MeshPart")
        if body and body.Transparency >= 0.95 then return false end
    end
    return true
end

local function healthSig(part)
    local g = part and part:FindFirstChild("Health")
    local bar = g and g:FindFirstChild("Bar")
    if bar and bar:IsA("GuiObject") then return bar.Size.X.Scale end
    return 0
end

local blacklist = {}

local function validTarget(item)
    if not item or not item.inst.Parent or not item.part.Parent then return false end
    if isDead(item.inst) or not slimeAlive(item.inst) then return false end
    local t = blacklist[item.part]
    return not (t and t > os.clock())
end

----------------------------------------------------------------------
-- Pink detection
----------------------------------------------------------------------
local function bodyPart(child)
    local model = child:FindFirstChild("Slime")
    if model then
        return model:FindFirstChild("InsideBody") or model:FindFirstChildWhichIsA("MeshPart")
    end
    local p = partFrom(child)
    if p and p.Transparency < 0.9 then return p end
end

local function isPinkColor(c)
    local h, s, v = c:ToHSV()
    return h >= 0.85 and h <= 0.995 and s >= 0.2 and v >= 0.6
end

local function textHas(str, needle)
    return type(str) == "string" and str:lower():find(needle, 1, true) ~= nil
end

local function isPink(child)
    -- Pink slimes are children of Guardians named exactly "PinkSlime"
    local needle = tostring(cfg.pinkName or ""):lower()
    if needle ~= "" and child.Name:lower() == needle then
        return true
    end
    if cfg.pinkByColor then
        local body = bodyPart(child)
        if body and isPinkColor(body.Color) then return true end
    end
    return false
end

-- Nearest alive slime (optionally only those passing filter)
local function getNearestSlime(filter)
    local g = getGuardians()
    local _, _, r = chr()
    if not (g and r) then return nil end

    local best, bestDist
    for _, child in ipairs(g:GetChildren()) do
        local part = partFrom(child)
        if part then
            local item = { inst = child, part = part }
            if validTarget(item) and (not filter or filter(child)) then
                local d = (part.Position - r.Position).Magnitude
                if not bestDist or d < bestDist then
                    best, bestDist = item, d
                end
            end
        end
    end
    return best
end

local function slimeCensus()
    local g = getGuardians()
    if not g then return 0, 0 end
    local total, alive = 0, 0
    for _, child in ipairs(g:GetChildren()) do
        if partFrom(child) then
            total += 1
            if slimeAlive(child) and not isDead(child) then alive += 1 end
        end
    end
    return total, alive
end

local function targetPosition(part)
    local pos, off = part.Position, cfg.slimeOffset
    local m = cfg.slimeMode
    if m == "Below" then
        return pos - Vector3.new(0, off, 0)
    elseif m == "Infront" then
        return pos + part.CFrame.LookVector * off
    elseif m == "Behind" then
        return pos - part.CFrame.LookVector * off
    end
    return pos + Vector3.new(0, off, 0)
end

local function place(r, pos)
    local rot = r.CFrame - r.CFrame.Position
    r.CFrame = CFrame.new(pos) * rot
end

----------------------------------------------------------------------
-- Input helpers (M1 / hotbar)
----------------------------------------------------------------------
local m1Held = false

local function m1Pos()
    local cam = workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(800, 600)
    return vs.X * 0.8, vs.Y * 0.5
end

local function m1Down()
    if not VIM then return end
    m1Held = true
    local x, y = m1Pos()
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, true, game, 0) end)
end

local function m1Up()
    if not (VIM and m1Held) then return end
    m1Held = false
    local x, y = m1Pos()
    pcall(function() VIM:SendMouseButtonEvent(x, y, 0, false, game, 0) end)
end

local function pressKey(key)
    if not VIM then return end
    pcall(function()
        VIM:SendKeyEvent(true, key, false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, key, false, game)
    end)
end

----------------------------------------------------------------------
-- Config save / load, state file, auto execute
----------------------------------------------------------------------
local syncUI

local function saveConfig(silent)
    if not writefile then
        notify("Config", "Your executor doesn't support writefile")
        return
    end
    local saved = pcall(writefile, FILE, HttpService:JSONEncode({ cfg = cfg }))
    if not silent then notify("Config", saved and ("Saved to " .. FILE) or "Save failed") end
end

local function loadConfig(silent)
    if not (readfile and isfile) then
        if not silent then notify("Config", "Your executor doesn't support readfile") end
        return false
    end
    if not isfile(FILE) then
        if not silent then notify("Config", "No saved config found - press Save Config first") end
        return false
    end
    local readOk, raw = pcall(readfile, FILE)
    if not readOk then
        if not silent then notify("Config", "Couldn't read config") end
        return false
    end
    local decOk, data = pcall(HttpService.JSONDecode, HttpService, raw)
    if not decOk or type(data) ~= "table" then
        if not silent then notify("Config", "Config file is corrupted") end
        return false
    end

    local keepAutoLoad = cfg.autoLoad
    if type(data.cfg) == "table" then
        for k, v in pairs(data.cfg) do
            if cfg[k] ~= nil and type(cfg[k]) == type(v) then cfg[k] = v end
        end
    end
    cfg.autoLoad = keepAutoLoad
    sanitizeConfig()
    if syncUI then syncUI() end
    if not silent then notify("Config", "Config loaded") end
    return true
end

local function readFlag(name)
    if isfile and readfile and isfile(name) then
        local rOk, v = pcall(readfile, name)
        if rOk then return v end
    end
end

local function readState()
    local raw = readFlag(STATE_FILE)
    if raw then
        local dOk, d = pcall(HttpService.JSONDecode, HttpService, raw)
        if dOk and type(d) == "table" then return d end
    end
    return {}
end

local function writeState(d)
    if writefile then pcall(writefile, STATE_FILE, HttpService:JSONEncode(d)) end
end

local qot = queue_on_teleport
    or (syn and syn.queue_on_teleport)
    or (fluxus and fluxus.queue_on_teleport)
local queuedThisSession = false

local function buildLoader()
    local head = string.format(
        'if not game:IsLoaded() then game.Loaded:Wait() end local okf, flag = pcall(readfile, %q) if okf and flag == "0" then return end ',
        AUTOEXEC_FLAG
    )
    if cfg.scriptUrl ~= "" then
        return head .. string.format("loadstring(game:HttpGet(%q))()", cfg.scriptUrl)
    elseif isfile and isfile(SCRIPT_FILE) then
        return head .. string.format("loadstring(readfile(%q))()", SCRIPT_FILE)
    end
end

local function setAutoExec(state)
    cfg.autoExec = state
    if writefile then pcall(writefile, AUTOEXEC_FLAG, state and "1" or "0") end
    if not state then
        notify("Auto Execute", "Disabled")
        return
    end
    if not qot then
        notify("Auto Execute", "queue_on_teleport isn't supported by your executor")
        return
    end
    local src = buildLoader()
    if not src then
        notify("Auto Execute", "Paste a Script URL, or save this script as " .. SCRIPT_FILE .. " in your workspace folder")
        return
    end
    if not queuedThisSession then
        queuedThisSession = pcall(qot, src)
    end
    notify("Auto Execute", queuedThisSession and "Enabled - script re-runs after teleport" or "Failed to queue script")
end

----------------------------------------------------------------------
-- Rejoin (private server)
----------------------------------------------------------------------
local function openPrivateLink()
    local link = cfg.privateLink
    if link == "" then
        notify("Rejoin", "Set your private server link first")
        return false
    end
    if setclipboard then pcall(setclipboard, link) end
    local opened = pcall(function() game:GetService("GuiService"):OpenBrowserWindow(link) end)
    notify("Rejoin", opened and "Opened the link in your browser (also copied)" or "Couldn't open the browser - link copied, open it manually")
    return opened
end

local failedConn
local function rejoinServer(reason)
    if S.rejoining then return end
    S.rejoining = true
    S.lastRejoin = os.time()
    S.forceCombat = false

    saveConfig(true)
    writeState({
        resume = true,
        pinkFarm = S.pinkFarm,
        farming = S.farming,
        autoM1 = cfg.autoM1,
        autoEquip = cfg.autoEquip,
        lastRejoin = S.lastRejoin,
        pinkKills = S.pinkKills,
    })
    setAutoExec(true) -- the script must re-run after the teleport to resume
    setStatus("Rejoining (" .. (reason or "manual") .. ")...")
    m1Up()

    if cfg.rejoinMethod == "Open Link" then
        openPrivateLink()
        task.delay(60, function() S.rejoining = false end)
        return
    end

    if not failedConn then
        failedConn = TeleportService.TeleportInitFailed:Connect(function()
            if S.rejoining then
                notify("Rejoin", "Teleport failed, trying the link instead")
                openPrivateLink()
                S.rejoining = false
            end
        end)
        table.insert(conns, failedConn)
    end

    pcall(function() TeleportService:Teleport(game.PlaceId, LP) end)
    task.delay(25, function()
        if S.alive and S.rejoining then
            notify("Rejoin", "Still here after 25s, trying the link instead")
            openPrivateLink()
            S.rejoining = false
        end
    end)
end

-- (Normal slime farm) rejoin once everything is dead
task.spawn(function()
    local startedAt = os.clock()
    local clearedSince
    while S.alive do
        if cfg.rejoinOnClear and S.farming and not S.pinkFarm and not S.rejoining then
            local total, alive = slimeCensus()
            if total > 0 and alive == 0 then
                clearedSince = clearedSince or os.clock()
                if os.clock() - clearedSince >= cfg.rejoinDelay
                    and os.clock() - startedAt >= 15
                    and os.time() - S.lastRejoin >= cfg.rejoinCooldown then
                    rejoinServer("all slimes dead")
                end
            else
                clearedSince = nil
            end
        else
            clearedSince = nil
        end
        task.wait(1)
    end
end)

----------------------------------------------------------------------
-- Movement (normal slime farm)
----------------------------------------------------------------------
local activeTween = nil

local function cancelTween()
    if activeTween then
        pcall(function() activeTween:Cancel() end)
        activeTween = nil
    end
end

local function tweenTo(r, item, dest)
    cancelTween()
    local dist = (r.Position - dest).Magnitude
    local rot = r.CFrame - r.CFrame.Position
    local tween = TweenService:Create(
        r,
        TweenInfo.new(math.max(dist / math.max(cfg.slimeSpeed, 1), 0.05), Enum.EasingStyle.Linear),
        { CFrame = CFrame.new(dest) * rot }
    )
    activeTween = tween
    tween:Play()

    while tween.PlaybackState == Enum.PlaybackState.Playing and S.farming and S.alive do
        RunService.Heartbeat:Wait()
        if not validTarget(item) then break end
        if (targetPosition(item.part) - dest).Magnitude > 3 then break end
    end

    pcall(function() tween:Cancel() end)
    if activeTween == tween then activeTween = nil end
end

-- WALK TO: real pathfinding. Paths to the ground next to the slime, follows
-- waypoints, jumps where the path says so, and repaths / gives up when stuck.
local floorParams = RaycastParams.new()
floorParams.FilterType = Enum.RaycastFilterType.Exclude

local function groundAt(pos)
    local ignore = { LP.Character }
    local g = getGuardians()
    if g then table.insert(ignore, g) end
    floorParams.FilterDescendantsInstances = ignore
    local res = workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -80, 0), floorParams)
    return res and res.Position or pos
end

local function flatDist(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Where to stand on the ground next to the slime. Above/Below can't be walked,
-- so they just approach from the side we're coming from.
local function walkGoal(part, r)
    local base = part.Position
    local m = cfg.slimeMode
    local dir
    if m == "Infront" then
        dir = part.CFrame.LookVector
    elseif m == "Behind" then
        dir = -part.CFrame.LookVector
    else
        dir = Vector3.new(r.Position.X - base.X, 0, r.Position.Z - base.Z)
    end
    dir = Vector3.new(dir.X, 0, dir.Z)
    dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, 1)
    local d = (m == "Infront" or m == "Behind") and math.max(cfg.slimeOffset, 3) or 3.5
    return groundAt(base + dir * d)
end

local function walkActive()
    return S.alive and S.farming and not S.pinkFarm and not S.rejoining
end

-- Walks to one waypoint. Returns "ok", "stop", "repath" or "stuck"
local function stepToWaypoint(h, r, item, wp, slimeStart, isBlocked)
    h:MoveTo(wp.Position)
    local started = os.clock()
    local lastCheck, lastPos = started, r.Position
    local timeout = math.max(3, flatDist(r.Position, wp.Position) / math.max(h.WalkSpeed * 0.6, 4) + 2)

    while true do
        RunService.Heartbeat:Wait()
        if not walkActive() or h.Health <= 0 or not validTarget(item) then return "stop" end
        if flatDist(r.Position, wp.Position) <= 2.5 then return "ok" end
        if isBlocked() then return "repath" end
        if (item.part.Position - slimeStart).Magnitude > 6 then return "repath" end -- slime moved

        local now = os.clock()
        if now - lastCheck >= 0.6 then
            if (r.Position - lastPos).Magnitude < 0.6 then
                h:ChangeState(Enum.HumanoidStateType.Jumping) -- nudge over small ledges
                if now - started > 1.8 then return "stuck" end
            end
            lastPos, lastCheck = r.Position, now
        end
        if now - started > timeout then return "stuck" end
    end
end

-- Returns "done", "repath", "stuck", "nopath" or "stop"
local function walkToSlime(h, r, item)
    local goal = walkGoal(item.part, r)
    local path = PathfindingService:CreatePath({
        AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 4,
    })
    local computed = pcall(function() path:ComputeAsync(r.Position, goal) end)
    if not computed or path.Status ~= Enum.PathStatus.Success then
        return "nopath"
    end

    local waypoints = path:GetWaypoints()
    local blockedAt = nil
    local blockedConn = path.Blocked:Connect(function(idx) blockedAt = idx end)
    local slimeStart = item.part.Position
    local result = "done"

    for i = 2, #waypoints do
        local wp = waypoints[i]
        if wp.Action == Enum.PathWaypointAction.Jump then
            h:ChangeState(Enum.HumanoidStateType.Jumping)
        end
        local idx = i
        local step = stepToWaypoint(h, r, item, wp, slimeStart, function()
            return blockedAt ~= nil and blockedAt >= idx
        end)
        if step ~= "ok" then
            result = step
            break
        end
    end

    blockedConn:Disconnect()
    return result
end

task.spawn(function()
    local cur, curSince, curSig
    local stuckCount = 0

    while S.alive do
        if not S.farming or S.pinkFarm or S.rejoining then
            if not S.farming then cancelTween() end
            cur = nil
            task.wait(0.1)
        else
            local _, h, r = chr()
            if not (h and r and h.Health > 0) then
                task.wait(0.2)
            else
                if not validTarget(cur) then
                    cur = getNearestSlime()
                    stuckCount = 0
                    if cur then curSince, curSig = os.clock(), healthSig(cur.part) end
                end

                if cur then
                    local now = os.clock()
                    local sig = healthSig(cur.part)
                    if sig ~= curSig then curSig, curSince = sig, now end
                    if cfg.skipAfter > 0 and now - curSince > cfg.skipAfter then
                        blacklist[cur.part] = now + 30
                        cur = nil
                    end
                end

                if cur then
                    if cfg.slimeMove == "Walk To" then
                        local goal = walkGoal(cur.part, r)
                        if flatDist(r.Position, goal) > 3.5 then
                            local result = walkToSlime(h, r, cur)
                            if result == "nopath" then
                                blacklist[cur.part] = os.clock() + 15
                                setStatus("No walkable path to " .. cur.inst.Name .. ", skipping it")
                                cur = nil
                            elseif result == "stuck" then
                                stuckCount += 1
                                if stuckCount >= 3 then
                                    blacklist[cur.part] = os.clock() + 20
                                    setStatus("Got stuck walking to " .. cur.inst.Name .. ", skipping it")
                                    cur, stuckCount = nil, 0
                                else
                                    task.wait(0.2)
                                end
                            else
                                stuckCount = 0
                            end
                        else
                            h:MoveTo(r.Position) -- in range: stand still and fight
                            task.wait(0.1)
                        end
                    else
                        local dest = targetPosition(cur.part)
                        local dist = (r.Position - dest).Magnitude

                        if dist > 3 then
                            if cfg.slimeMove == "Teleport" then
                                place(r, dest)
                                r.AssemblyLinearVelocity = Vector3.zero
                                task.wait(0.1)
                            else
                                tweenTo(r, cur, dest)
                            end
                        else
                            r.AssemblyLinearVelocity = Vector3.zero
                            task.wait(0.1)
                        end
                    end
                else
                    task.wait(0.3)
                end
            end
        end
    end
end)

----------------------------------------------------------------------
-- Combat loops (Auto M1 / Auto Equip). The pink hunt forces both on.
----------------------------------------------------------------------
task.spawn(function()
    while S.alive do
        if cfg.autoM1 or S.forceCombat then
            local _, h = chr()
            if h and h.Health > 0 then
                m1Down()
                task.wait(0.03)
                m1Up()
                task.wait(math.max(cfg.m1Delay, 0.05))
            else
                task.wait(0.2)
            end
        else
            m1Up()
            task.wait(0.1)
        end
    end
end)

task.spawn(function()
    local lastPress = 0
    while S.alive do
        if cfg.autoEquip or S.forceCombat then
            local c, h = chr()
            if c and h and h.Health > 0 and not c:FindFirstChildOfClass("Tool") then
                if os.clock() - lastPress > 0.8 then
                    lastPress = os.clock()
                    pressKey(SLOT_KEYS[math.clamp(math.floor(cfg.swordSlot), 1, 9)])
                end
            end
        end
        task.wait(0.5)
    end
end)

----------------------------------------------------------------------
-- Pink farm cycle
----------------------------------------------------------------------
local function pinkRunning()
    return S.alive and S.pinkFarm
end

local function waitForCharacter(timeout)
    local t0 = os.clock()
    while pinkRunning() and os.clock() - t0 < timeout do
        local _, h, r = chr()
        if h and r and h.Health > 0 then return r end
        task.wait(0.25)
    end
end

local function findHubPoint()
    if cfg.hubTarget == "Portal HB" then
        local candidates = {}
        local mine = workspace:FindFirstChild("Island_" .. LP.UserId .. ":1")
        if mine then table.insert(candidates, mine) end
        for _, ch in ipairs(workspace:GetChildren()) do
            if ch.Name:match("^Island_%d+:1$") and ch ~= mine then table.insert(candidates, ch) end
        end
        for _, island in ipairs(candidates) do
            local hub = island:FindFirstChild("HUB")
            local hb = hub and hub:FindFirstChild("HB")
            if hb and hb:IsA("BasePart") then
                return hb.Position + Vector3.new(0, 3, 0), "Portal HB"
            end
        end
    end

    -- Fallback / "Guardians Area": the average position of the slimes
    local g = getGuardians()
    if g then
        local sum, n = Vector3.zero, 0
        for _, ch in ipairs(g:GetChildren()) do
            local p = partFrom(ch)
            if p then sum += p.Position; n += 1 end
        end
        if n > 0 then
            return sum / n + Vector3.new(0, 8, 0), "Guardians area"
        end
    end
    return nil
end

local function goToHub()
    local r = waitForCharacter(20)
    if not r then return false end
    local point, label = findHubPoint()
    if not point then
        setStatus("Hub point not found")
        return false
    end
    place(r, point)
    r.AssemblyLinearVelocity = Vector3.zero
    setStatus("Teleported to hub (" .. label .. ")")
    return true
end

local function waitForPink()
    local t0 = os.clock()
    while pinkRunning() and os.clock() - t0 < cfg.scanWait do
        if getNearestSlime(isPink) then return true end
        task.wait(0.25)
    end
    return pinkRunning() and getNearestSlime(isPink) ~= nil
end

-- Teleports onto each pink slime in turn until none are left alive.
-- Returns kills, gaveUp
local function huntPink()
    S.forceCombat = true
    local kills, gaveUp = 0, false
    local cur, curSince, curSig

    while pinkRunning() and not S.rejoining do
        local _, h, r = chr()
        if not (h and r and h.Health > 0) then
            task.wait(0.2)
        else
            if not validTarget(cur) then
                local timedOut = cur and blacklist[cur.part] and blacklist[cur.part] > os.clock()
                if cur and not timedOut then
                    kills += 1
                    S.pinkKills += 1
                    setStatus("Pink slime killed (total " .. S.pinkKills .. ")")
                end
                cur = getNearestSlime(isPink)
                if not cur then break end
                curSince, curSig = os.clock(), healthSig(cur.part)
                setStatus("Hunting pink slime: " .. cur.inst.Name)
            end

            local now = os.clock()
            local sig = healthSig(cur.part)
            if sig ~= curSig then curSig, curSince = sig, now end

            if now - curSince > cfg.pinkTimeout then
                blacklist[cur.part] = now + 60
                gaveUp = true
                setStatus("Pink slime isn't taking damage, giving up on it")
                cur = nil
            else
                place(r, targetPosition(cur.part))
                r.AssemblyLinearVelocity = Vector3.zero
                task.wait(0.1)
            end
        end
    end

    S.forceCombat = false
    m1Up()
    return kills, gaveUp
end

local function waitRejoinCooldown()
    while pinkRunning() do
        local remain = cfg.rejoinCooldown - (os.time() - S.lastRejoin)
        if remain <= 0 then return true end
        setStatus("Waiting " .. remain .. "s before rejoining")
        task.wait(1)
    end
    return false
end

local function runPinkCycle()
    if not game:IsLoaded() then game.Loaded:Wait() end

    setStatus("Going to the hub...")
    if not goToHub() then
        if not pinkRunning() then return end
        task.wait(1)
    end
    if not pinkRunning() then return end

    task.wait(cfg.hubSettle)
    setStatus("Checking for a pink slime...")

    local reason
    if waitForPink() then
        local kills = huntPink()
        if not pinkRunning() then return end
        reason = kills > 0 and "pink slime killed" or "pink slime not killed"
        task.wait(cfg.postKillDelay)
    else
        if not pinkRunning() then return end
        reason = "no pink slime"
        setStatus("No pink slime found")
    end

    if not waitRejoinCooldown() then return end
    rejoinServer(reason)

    -- Wait here until the teleport happens (or fails and we try again)
    while S.rejoining and pinkRunning() do
        task.wait(0.5)
    end
end

task.spawn(function()
    while S.alive do
        if S.pinkFarm and not S.rejoining then
            local cycleOk, err = pcall(runPinkCycle)
            if not cycleOk then
                warn("[SlimeFarm] Pink cycle error: " .. tostring(err))
                task.wait(1)
            end
        else
            task.wait(0.3)
        end
    end
end)

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local Window = WindUI:CreateWindow({
    Title = "Slime Farm",
    Icon = "rbxassetid://6023426915",
    Author = "Automation Hub",
    Folder = "SlimeFarmConfig",
    Size = UDim2.fromOffset(580, 420),
    Transparent = true,
    Theme = "Dark",
    SideBarWidth = 150,
    HasOutline = true,
    ToggleKey = Enum.KeyCode.RightShift,
})

local TabPink   = Window:Tab({ Title = "Pink Farm", Icon = "star" })
local TabSlime  = Window:Tab({ Title = "Slime Farm", Icon = "shield" })
local TabCombat = Window:Tab({ Title = "Combat", Icon = "sword" })
local TabRejoin = Window:Tab({ Title = "Rejoin", Icon = "refresh-cw" })
local TabConfig = Window:Tab({ Title = "Config", Icon = "settings" })
TabPink:Select()

local function toggleEl(tab, key, title, desc, onChange)
    UIEl[key] = { kind = "toggle", el = tab:Toggle({
        Title = title, Desc = desc, Value = cfg[key],
        Callback = function(state)
            cfg[key] = state
            if syncing then return end
            if onChange then onChange(state) end
        end,
    }) }
end

local function dropdownEl(tab, key, title, values)
    UIEl[key] = { kind = "dropdown", el = tab:Dropdown({
        Title = title, Values = values, Value = cfg[key],
        Callback = function(item) cfg[key] = item end,
    }) }
end

local function sliderEl(tab, key, title, min, max, step)
    UIEl[key] = { kind = "slider", el = tab:Slider({
        Title = title, Value = { Min = min, Max = max, Default = cfg[key] }, Step = step,
        Callback = function(v) cfg[key] = v end,
    }) }
end

local function inputEl(tab, key, title, desc, placeholder, onChange)
    UIEl[key] = { kind = "input", el = tab:Input({
        Title = title, Desc = desc, Value = cfg[key], Placeholder = placeholder,
        Callback = function(text)
            cfg[key] = (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
            if onChange and not syncing then onChange(cfg[key]) end
        end,
    }) }
end

-- Pink Farm tab
UIEl.pinkFarm = { kind = "toggle", el = TabPink:Toggle({
    Title = "Auto Pink Slime Farm",
    Desc = "Hub -> check for pink -> kill it -> rejoin. No pink = rejoin straight away.",
    Value = false,
    Callback = function(state)
        S.pinkFarm = state
        if state then
            S.farming = false
            cancelTween()
            if not cfg.autoExec then
                notify("Pink Farm", "Tip: turn on Auto Execute (Rejoin tab) so the loop continues after each rejoin")
            end
        else
            S.forceCombat = false
            m1Up()
            setStatus("Pink farm stopped")
        end
    end,
}) }
statusPara = TabPink:Paragraph({ Title = "Status", Desc = S.status })
inputEl(TabPink, "pinkName", "Pink Slime Name",
    "Exact name of the pink slime under Guardians (not case sensitive)", "PinkSlime")
toggleEl(TabPink, "pinkByColor", "Detect By Body Colour",
    "Extra fallback, normally not needed: also counts a pink-coloured body as pink")
dropdownEl(TabPink, "hubTarget", "Hub Teleport Target", { "Portal HB", "Guardians Area" })
sliderEl(TabPink, "hubSettle", "Wait After Hub Teleport (s)", 0, 15, 0.5)
sliderEl(TabPink, "scanWait", "Look For Pink For (s)", 1, 30, 1)
sliderEl(TabPink, "pinkTimeout", "Give Up If No Damage For (s)", 5, 120, 5)
sliderEl(TabPink, "postKillDelay", "Wait After Kill Before Rejoin (s)", 0, 15, 0.5)
TabPink:Button({
    Title = "Scan Slimes (prints to console)",
    Desc = "Lists every slime with its alive state, body colour and whether it counts as pink",
    Callback = function()
        local g = getGuardians()
        if not g then notify("Scan", "workspace.Hub.Guardians not found") return end
        local pinkCount = 0
        for _, child in ipairs(g:GetChildren()) do
            local body = bodyPart(child)
            local alive = slimeAlive(child) and not isDead(child)
            local pink = isPink(child)
            if pink and alive then pinkCount += 1 end
            local colour = body and string.format("(%d,%d,%d)",
                math.floor(body.Color.R * 255), math.floor(body.Color.G * 255), math.floor(body.Color.B * 255)) or "n/a"
            print(string.format("[SlimeFarm scan] %s | %s | alive=%s | body=%s %s | pink=%s",
                child.Name, child.ClassName, tostring(alive), body and body.Name or "none", colour, tostring(pink)))
        end
        notify("Scan", pinkCount .. " alive pink slime(s). Full list is in the console (F9).")
    end,
})

-- Slime Farm tab
UIEl.farming = { kind = "toggle", el = TabSlime:Toggle({
    Title = "Slime Farming",
    Desc = "Targets workspace.Hub.Guardians, nearest alive slime first",
    Value = false,
    Callback = function(state)
        S.farming = state
        if state and S.pinkFarm then
            notify("Slime Farm", "Pink farm is running - it controls movement while it's on")
        end
        if not state then cancelTween() end
    end,
}) }
dropdownEl(TabSlime, "slimeMove", "Movement Mode", { "Walk To", "Tween", "Teleport" })
dropdownEl(TabSlime, "slimeMode", "Position Relative To Slime", { "Above", "Infront", "Behind", "Below" })
sliderEl(TabSlime, "slimeOffset", "Distance Offset", 0, 20, 1)
sliderEl(TabSlime, "slimeSpeed", "Tween Speed", 10, 150, 5)
sliderEl(TabSlime, "skipAfter", "Skip Stuck Target After (s)", 0, 60, 1)

-- Combat tab
toggleEl(TabCombat, "autoM1", "Auto M1", "Swings your equipped tool. Press K to stop everything.", function(state)
    if not state then m1Up() end
end)
sliderEl(TabCombat, "m1Delay", "M1 Delay (s)", 0.05, 1, 0.05)
toggleEl(TabCombat, "autoEquip", "Auto Equip", "Presses the hotbar slot below when nothing is equipped")
sliderEl(TabCombat, "swordSlot", "Hotbar Slot", 1, 9, 1)
TabCombat:Paragraph({
    Title = "Note",
    Desc = "The pink hunt turns M1 and equip on by itself while it's fighting, even if these toggles are off.",
})

-- Rejoin tab
toggleEl(TabRejoin, "autoExec", "Auto Execute",
    "Re-runs this script after every teleport/rejoin (needs queue_on_teleport)", function(state)
        setAutoExec(state)
    end)
inputEl(TabRejoin, "scriptUrl", "Script URL (for Auto Execute)",
    "Raw URL of this script. Leave empty to use " .. SCRIPT_FILE .. " from your workspace folder",
    "https://raw.githubusercontent.com/...", function()
        queuedThisSession = false
        if cfg.autoExec then setAutoExec(true) end
    end)
inputEl(TabRejoin, "privateLink", "Private Server Link", "Your private server link",
    "https://www.roblox.com/games/...?privateServerLinkCode=...")
dropdownEl(TabRejoin, "rejoinMethod", "Rejoin Method", { "Teleport", "Open Link" })
sliderEl(TabRejoin, "rejoinCooldown", "Min Time Between Rejoins (s)", 5, 300, 5)
toggleEl(TabRejoin, "rejoinOnClear", "Rejoin When All Slimes Are Dead",
    "Normal Slime Farming only: rejoin once every slime under Guardians is dead")
sliderEl(TabRejoin, "rejoinDelay", "Confirm All Dead For (s)", 1, 30, 1)
TabRejoin:Button({
    Title = "Rejoin Now",
    Desc = "Test the rejoin and resume right now",
    Callback = function() rejoinServer("manual") end,
})

-- Config tab
TabConfig:Button({
    Title = "Save Config",
    Desc = "Saves all settings to " .. FILE,
    Callback = function() saveConfig(false) end,
})
TabConfig:Button({
    Title = "Load Config",
    Desc = "Loads the saved settings",
    Callback = function() loadConfig(false) end,
})
toggleEl(TabConfig, "autoLoad", "Auto Load Config",
    "Loads the saved config automatically whenever the script starts", function(state)
        if writefile then pcall(writefile, AUTOLOAD_FLAG, state and "1" or "0") end
    end)

----------------------------------------------------------------------
-- UI sync / emergency stop
----------------------------------------------------------------------
local function pushUI(key, value)
    local u = UIEl[key]
    if not u then return end
    local methods = (u.kind == "dropdown") and { "Select", "Set" } or { "Set" }
    syncing = true
    for _, m in ipairs(methods) do
        local fn = u.el and u.el[m]
        if type(fn) == "function" and pcall(fn, u.el, value) then break end
    end
    task.defer(function() syncing = false end)
end

syncUI = function()
    for key in pairs(UIEl) do
        if cfg[key] ~= nil then pushUI(key, cfg[key]) end
    end
end

local function panic()
    S.farming, S.pinkFarm, S.forceCombat = false, false, false
    cfg.autoM1, cfg.autoEquip = false, false
    cancelTween()
    m1Up()

    -- Make sure nothing auto-resumes on the next teleport
    writeState({ resume = false, lastRejoin = S.lastRejoin, pinkKills = S.pinkKills })

    local _, h, r = chr()
    if h and r then pcall(function() h:MoveTo(r.Position) end) end

    pushUI("farming", false)
    pushUI("pinkFarm", false)
    pushUI("autoM1", false)
    pushUI("autoEquip", false)
    setStatus("Stopped (K)")
    notify("Panic (K)", "Everything stopped, auto-resume cancelled")
end

table.insert(conns, UIS.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.K and not UIS:GetFocusedTextBox() then
        panic()
    end
end))

env.__SlimeFarmStop = function()
    S.alive, S.farming, S.pinkFarm, S.forceCombat = false, false, false, false
    cfg.autoM1, cfg.autoEquip = false, false
    cancelTween()
    m1Up()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(function() Window:Destroy() end)
end

----------------------------------------------------------------------
-- Startup: auto load config, auto execute, resume after rejoin
----------------------------------------------------------------------
task.defer(function()
    local state = readState()
    S.lastRejoin = state.lastRejoin or 0
    S.pinkKills = state.pinkKills or 0
    local resuming = state.resume == true

    local autoLoadOn = readFlag(AUTOLOAD_FLAG) ~= "0"
    if autoLoadOn or resuming then
        if loadConfig(true) and not resuming then notify("Config", "Auto-loaded saved config") end
    end
    cfg.autoLoad = autoLoadOn
    pushUI("autoLoad", autoLoadOn)

    if readFlag(AUTOEXEC_FLAG) == "1" then
        cfg.autoExec = true
        pushUI("autoExec", true)
    end
    if cfg.autoExec then setAutoExec(true) end

    if resuming then
        writeState({ resume = false, lastRejoin = S.lastRejoin, pinkKills = S.pinkKills })

        if state.pinkFarm then
            S.pinkFarm = true
            pushUI("pinkFarm", true)
            setStatus("Resumed pink farm after rejoin")
        elseif state.farming then
            S.farming = true
            cfg.autoM1 = state.autoM1 == true
            cfg.autoEquip = state.autoEquip == true
            pushUI("farming", true)
            pushUI("autoM1", cfg.autoM1)
            pushUI("autoEquip", cfg.autoEquip)

            local r
            local t0 = os.clock()
            while os.clock() - t0 < 20 do
                local _, h, root = chr()
                if h and root then r = root break end
                task.wait(0.25)
            end
            local point = r and findHubPoint()
            if r and point then
                place(r, point)
                r.AssemblyLinearVelocity = Vector3.zero
            end
            notify("Rejoin", "Resumed slime farming")
        end
    end
end)
