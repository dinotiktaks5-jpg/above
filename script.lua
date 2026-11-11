--[[
    FarmHub - Lane Farming, Multi-Slime Farming, & Block Breaker Script
    UI Library: WindUI
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local LP = Players.LocalPlayer

local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)

-- Load WindUI using the official release loader
local success, WindUI = pcall(function()
    return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
end)

if not success or not WindUI then
    warn("Failed to load WindUI library! Check your executor's http-get support.")
    return
end

----------------------------------------------------------------------
-- State & Configurations
----------------------------------------------------------------------
local S = { 
    farming = false, lane = 1, inLane = false, c1 = nil, c2 = nil, picking = nil, alive = true, msg = "Ready",
    slimeFarming = false
}
local cfg = {
    axis = "Vertical",      -- Vertical = lanes run along Z | Horizontal = lanes run along X
    mode = "Legit",         -- Legit (MoveTo) | Obvious (tween)
    tweenSpeed = 25,
    laneDelay = 0.0,
    laneWidth = 4,
    fSpam = 3,
    wsOn = false,
    wsIdx = 1,
    
    -- Slime Farm Config
    slimeSelection = { Pink = true, Orange = true, Blue = true, Green = true },
    skipAfter = 15,         -- give up on a target that isn't taking damage after this many seconds (0 = off)
    farmAll = false,        -- Targets every slime under workspace.Hub.Guardians (nearest first)
    rejoinOnClear = false,  -- rejoin the private server once every slime is dead
    privateLink = "",       -- private server link
    rejoinMethod = "Teleport", -- Teleport | Open Link
    rejoinDelay = 5,        -- slimes must stay dead this long before rejoining (s)
    rejoinCooldown = 60,    -- minimum time between rejoins (s)
    slimeMode = "Above",    -- Above, Infront, Behind, Below
    slimeMove = "Tween",    -- Walk To, Tween, Teleport
    slimeOffset = 4,        -- Distance offset from slime
    slimeSpeed = 35,        -- Speed for slime movement/tweens
    
    -- Auto M1 (independent of slime farm)
    autoM1 = false,
    m1Delay = 0.1,          -- Delay between swings (s)
    chargeM1 = false,       -- Hold M1 then release (bows)
    chargeTime = 1.0,       -- How long to hold M1 when charging (s)
    
    -- Auto Load / Auto Execute
    autoLoad = true,        -- load the saved config automatically on startup
    autoExec = false,
    scriptUrl = "",

    -- Block Breaker
    pickSlot = 2,           
    reach = 12,             
    hitDelay = 0.1,         
    maxBlock = 8,           
    yStep = 1,              
    breakTimeout = 3,       
}
local SPEEDS = { 16, 25, 35, 50, 75, 100 }
local FILE = "FarmHubConfig.json"

local function chr()
    local c = LP.Character
    return c, c and c:FindFirstChildOfClass("Humanoid"), c and c:FindFirstChild("HumanoidRootPart")
end

----------------------------------------------------------------------
-- Zone / Lane Math
----------------------------------------------------------------------
local function getZone()
    if not (S.c1 and S.c2) then return end
    local z = {
        minX = math.min(S.c1.X, S.c2.X), maxX = math.max(S.c1.X, S.c2.X),
        minZ = math.min(S.c1.Z, S.c2.Z), maxZ = math.max(S.c1.Z, S.c2.Z),
    }
    z.sx, z.sz = z.maxX - z.minX, z.maxZ - z.minZ
    local v = cfg.axis == "Vertical"
    z.laneMin, z.laneMax = v and z.minX or z.minZ, v and z.maxX or z.maxZ
    z.alongMin, z.alongMax = v and z.minZ or z.minX, v and z.maxZ or z.maxX
    z.count = math.max(1, math.ceil((z.laneMax - z.laneMin) / cfg.laneWidth - 1e-6))
    return z
end

local function laneCenter(z, i)
    return math.clamp(z.laneMin + (i - 0.5) * cfg.laneWidth, z.laneMin, z.laneMax)
end

local function toWorld(lane, along, y)
    if cfg.axis == "Vertical" then return Vector3.new(lane, y, along) end
    return Vector3.new(along, y, lane)
end

local function splitPos(p) 
    if cfg.axis == "Vertical" then return p.X, p.Z end
    return p.Z, p.X
end

----------------------------------------------------------------------
-- Floor Raycast & Highlights
----------------------------------------------------------------------
local hlFolder = Instance.new("Folder")
hlFolder.Name = "FarmLanes"
hlFolder.Parent = workspace

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
local lastFloor

local function floorHeight(x, z, refY)
    rayParams.FilterDescendantsInstances = { LP.Character, hlFolder }
    local r = workspace:Raycast(Vector3.new(x, refY + 4, z), Vector3.new(0, -80, 0), rayParams)
    if r then lastFloor = r.Position.Y end
    return lastFloor
end

local function standY(x, z)
    local _, h, r = chr()
    if not r then return end
    local f = floorHeight(x, z, r.Position.Y)
    if not f then return r.Position.Y end
    local hip = 2
    if h then hip = (h.RigType == Enum.HumanoidRigType.R6) and 2 or h.HipHeight end
    return f + hip + r.Size.Y / 2
end

local function place(r, pos)
    local rot = r.CFrame - r.CFrame.Position
    r.CFrame = CFrame.new(pos) * rot
end

local hlParts, hlState = {}, {}

local function rebuildHighlights()
    hlFolder:ClearAllChildren()
    hlParts, hlState = {}, {}
    local z = getZone()
    if not z then return end
    local ref = (S.c1.Y + S.c2.Y) / 2
    local len = math.max(z.alongMax - z.alongMin, 0.5)
    local mid = (z.alongMin + z.alongMax) / 2
    local w = math.max(cfg.laneWidth - 0.3, 0.2)
    for i = 1, z.count do
        local c = laneCenter(z, i)
        local p = Instance.new("Part")
        p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
        p.Material = Enum.Material.Neon
        p.Transparency = 1
        p.Size = (cfg.axis == "Vertical") and Vector3.new(w, 0.2, len) or Vector3.new(len, 0.2, w)
        local probe = toWorld(c, mid, ref)
        p.Position = Vector3.new(probe.X, (floorHeight(probe.X, probe.Z, ref) or ref) + 0.15, probe.Z)
        p.Parent = hlFolder
        hlParts[i] = p
    end
end

local function updateHighlights()
    for i, p in ipairs(hlParts) do
        local st = (i == S.lane and "active") or (i > S.lane and "pending") or "done"
        if hlState[i] ~= st then
            hlState[i] = st
            if st == "active" then
                p.Color, p.Transparency = Color3.fromRGB(0, 140, 255), 0.35
            elseif st == "pending" then
                p.Color, p.Transparency = Color3.fromRGB(255, 40, 40), 0.55
            else
                p.Transparency = 1
            end
        end
    end
end

local function zoneChanged()
    S.lane, S.inLane = 1, false
    rebuildHighlights()
    updateHighlights()
end

----------------------------------------------------------------------
-- Slime Target Resolver
-- Farm All  -> every child of workspace.Hub.Guardians, nearest first
-- Otherwise -> Pink > Orange > Blue
----------------------------------------------------------------------
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

local function getGuardians()
    local hub = workspace:FindFirstChild("Hub")
    return hub and hub:FindFirstChild("Guardians")
end

local SLIME_PRIORITY = { "Pink", "Orange", "Blue", "Green" }

local function slimeKind(name)
    local l = name:lower()
    for _, k in ipairs(SLIME_PRIORITY) do
        if l:find(k:lower(), 1, true) then return k end
    end
end

local slimeBlacklist = {}   -- part -> time until which it is ignored (stuck / unkillable targets)

-- Reads the health bar fill so we can tell whether a target is actually taking damage
local function healthSig(part)
    local g = part and part:FindFirstChild("Health")
    local bar = g and g:FindFirstChild("Bar")
    if bar and bar:IsA("GuiObject") then return bar.Size.X.Scale end
    return 0
end

-- A slime is dead when its Health billboard is disabled or its meshes are fully invisible
-- (dead ones stay parked at their spawn point / underground until they respawn).
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

-- Every slime is a Part directly under Hub.Guardians (PinkSlime / BlueSlime / GreenSlime ...).
-- Dead ones and recently blacklisted (stuck) ones are skipped.
local function collectSlimes(ignoreBlacklist)
    local g = getGuardians()
    if not g then return {} end
    local now = os.clock()
    local out = {}
    for _, child in ipairs(g:GetChildren()) do
        local part = partFrom(child)
        if part and part.Parent and not isDead(child) and slimeAlive(child)
            and (ignoreBlacklist or not (slimeBlacklist[part] and slimeBlacklist[part] > now)) then
            table.insert(out, { inst = child, part = part, kind = slimeKind(child.Name) })
        end
    end
    return out
end

-- total = slimes matching your target settings that exist right now, alive = how many are alive
local function slimeCensus()
    local g = getGuardians()
    if not g then return 0, 0 end
    local total, alive = 0, 0
    for _, child in ipairs(g:GetChildren()) do
        local kind = slimeKind(child.Name)
        if partFrom(child) and (cfg.farmAll or (kind and cfg.slimeSelection[kind])) then
            total += 1
            if slimeAlive(child) and not isDead(child) then alive += 1 end
        end
    end
    return total, alive
end

local function countFarmTargets()
    local n = 0
    for _, it in ipairs(collectSlimes()) do
        if cfg.farmAll or (it.kind and cfg.slimeSelection[it.kind]) then n += 1 end
    end
    return n
end

-- Debug: copies the Guardians hierarchy so the exact layout can be checked
local function dumpGuardians()
    local g = getGuardians()
    if not g then
        WindUI:Notify({ Title = "Debug", Content = "workspace.Hub.Guardians not found", Duration = 3 })
        return
    end
    local lines, count = {}, 0
    local function walk(inst, depth)
        if depth > 5 then return end
        for i, c in ipairs(inst:GetChildren()) do
            if count >= 400 then return end
            count += 1
            local extra = ""
            if c:IsA("BasePart") then
                extra = " pos=" .. tostring(c.Position) .. " transp=" .. tostring(c.Transparency)
                    .. " anchored=" .. tostring(c.Anchored) .. " canCollide=" .. tostring(c.CanCollide)
            end
            if c:IsA("BillboardGui") then extra = " enabled=" .. tostring(c.Enabled) end
            if c:IsA("GuiObject") then extra = " size=" .. tostring(c.Size) .. " visible=" .. tostring(c.Visible) end
            if c:IsA("Humanoid") then extra = " hp=" .. tostring(c.Health) end
            table.insert(lines, string.rep("  ", depth) .. "[" .. i .. "] " .. c.Name .. " (" .. c.ClassName .. ")" .. extra)
            walk(c, depth + 1)
        end
    end
    walk(g, 0)
    if count >= 400 then table.insert(lines, "... truncated at 400 entries") end
    local text = "workspace.Hub.Guardians\n" .. table.concat(lines, "\n")
    print(text)
    local copied = false
    if setclipboard then copied = pcall(setclipboard, text) end
    WindUI:Notify({
        Title = "Debug",
        Content = copied and ("Copied " .. count .. " entries to clipboard") or ("Printed " .. count .. " entries to console (F9)"),
        Duration = 3,
    })
end

-- Farm All: nearest slime of any kind.
-- Otherwise: Pink > Orange > Blue > Green, nearest slime within the first enabled kind.
local function getTargetSlimePart()
    local _, _, r = chr()
    local rp = r and r.Position
    local bestAll, bestAllD
    local bestKind = {}

    for _, it in ipairs(collectSlimes()) do
        local d = rp and (it.part.Position - rp).Magnitude or 0
        if cfg.farmAll then
            if not bestAllD or d < bestAllD then bestAll, bestAllD = it.part, d end
        elseif it.kind and cfg.slimeSelection[it.kind] then
            local cur = bestKind[it.kind]
            if not cur or d < cur.d then bestKind[it.kind] = { part = it.part, d = d } end
        end
    end

    if cfg.farmAll then return bestAll end
    for _, k in ipairs(SLIME_PRIORITY) do
        if bestKind[k] then return bestKind[k].part end
    end
    return nil
end

local function calculateSlimeTargetPosition(slimePart)
    if not slimePart then return nil end
    local pos = slimePart.Position
    local offset = cfg.slimeOffset
    local m = cfg.slimeMode
    
    if m == "Above" then
        return pos + Vector3.new(0, offset, 0)
    elseif m == "Below" then
        return pos - Vector3.new(0, offset, 0)
    elseif m == "Infront" then
        return pos + (slimePart.CFrame.LookVector * offset)
    elseif m == "Behind" then
        return pos - (slimePart.CFrame.LookVector * offset)
    end
    return pos + Vector3.new(0, offset, 0)
end

----------------------------------------------------------------------
-- Farming Loops & Auto M1 (Swing)
----------------------------------------------------------------------
local function farmLane()
    local z = getZone()
    local _, h, r = chr()
    if not (z and h and r and h.Health > 0) then task.wait(0.2) return end
    if S.lane > z.count then S.lane, S.inLane = 1, false end

    local lane = laneCenter(z, S.lane)
    local forward = S.lane % 2 == 1
    local a0 = forward and z.alongMin or z.alongMax
    local a1 = forward and z.alongMax or z.alongMin

    if not S.inLane then 
        local p = toWorld(lane, a0, 0)
        place(r, Vector3.new(p.X, standY(p.X, p.Z) or r.Position.Y, p.Z))
        S.inLane = true
        updateHighlights()
    end

    while S.farming and not S.slimeFarming and S.alive do
        local _, hh, rr = chr()
        if not (hh and rr) then break end
        local _, al = splitPos(rr.Position)
        local dist = math.abs(a1 - al)
        if dist < 0.75 then
            S.lane += 1
            S.inLane = false
            if S.lane > z.count then S.lane = 1 end
            updateHighlights()
            if cfg.laneDelay > 0 then task.wait(cfg.laneDelay) end
            return
        end
        if cfg.mode == "Legit" then
            hh:MoveTo(toWorld(lane, a1, rr.Position.Y))
            RunService.Heartbeat:Wait()
        else
            local dt = RunService.Heartbeat:Wait()
            local na = al + math.sign(a1 - al) * math.min(cfg.tweenSpeed * dt, dist)
            local p = toWorld(lane, na, 0)
            place(rr, Vector3.new(p.X, standY(p.X, p.Z) or rr.Position.Y, p.Z))
            rr.AssemblyLinearVelocity = Vector3.zero
        end
    end
end

-- Walk To: humanoid:MoveTo plus automatic jumping over obstacles / when stuck
local walkState = { pos = nil, t = 0, lastJump = 0 }

local function walkStep(h, r, dest)
    h:MoveTo(dest)

    local now = os.clock()
    local flat = Vector3.new(dest.X - r.Position.X, 0, dest.Z - r.Position.Z)
    if flat.Magnitude <= 3 then
        walkState.pos = nil
        return
    end
    local dir = flat.Unit
    local jump = false

    local ignore = { r.Parent }
    local g = getGuardians()
    if g then table.insert(ignore, g) end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignore

    -- something solid right in front of our feet / knees -> hop over it
    for _, dy in ipairs({ -1.5, 0 }) do
        local hit = workspace:Raycast(r.Position + Vector3.new(0, dy, 0), dir * 4, params)
        if hit and hit.Instance.CanCollide then
            jump = true
            break
        end
    end

    -- barely moved for 0.6s while we still have somewhere to go -> jump
    local flatPos = Vector3.new(r.Position.X, 0, r.Position.Z)
    if walkState.pos == nil or now - walkState.t > 0.6 then
        if walkState.pos and (flatPos - walkState.pos).Magnitude < 0.8 then jump = true end
        walkState.pos = flatPos
        walkState.t = now
    end

    if jump and now - walkState.lastJump > 0.5 then
        walkState.lastJump = now
        h.Jump = true
        pcall(function() h:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
end

-- Slime Farm Loop Thread
task.spawn(function()
    local lastWarn = 0
    local curTarget, curSince, curSig
    while S.alive do
        if S.slimeFarming then
            local _, h, r = chr()
            local targetPart = getTargetSlimePart()
            if targetPart then
                local now = os.clock()
                if targetPart ~= curTarget then
                    curTarget, curSince, curSig = targetPart, now, healthSig(targetPart)
                else
                    local sig = healthSig(targetPart)
                    if sig ~= curSig then curSig, curSince = sig, now end
                    if cfg.skipAfter > 0 and now - curSince > cfg.skipAfter then
                        slimeBlacklist[targetPart] = now + 30
                        curTarget = nil
                        targetPart = getTargetSlimePart()
                    end
                end
            end
            if h and r and targetPart then
                local dest = calculateSlimeTargetPosition(targetPart)
                if dest then
                    local moveStyle = cfg.slimeMove
                    if moveStyle == "Teleport" then
                        place(r, dest)
                        r.AssemblyLinearVelocity = Vector3.zero
                        task.wait(0.1)
                    elseif moveStyle == "Tween" then
                        local dist = (r.Position - dest).Magnitude
                        local timeTaken = math.max(dist / math.max(cfg.slimeSpeed, 1), 0.05)
                        local tweenInfo = TweenInfo.new(timeTaken, Enum.EasingStyle.Linear)
                        local tween = game:GetService("TweenService"):Create(r, tweenInfo, {CFrame = CFrame.new(dest)})
                        tween:Play()
                        while tween.PlaybackState == Enum.PlaybackState.Playing and S.slimeFarming and S.alive do
                            RunService.Heartbeat:Wait()
                        end
                    else
                        walkStep(h, r, dest)
                        task.wait(0.1)
                    end
                else
                    task.wait(0.2)
                end
            else
                if h and r and os.clock() - lastWarn > 5 then
                    lastWarn = os.clock()
                    warn("[FarmHub] Slime farm: no valid target found")
                end
                task.wait(0.2)
            end
        else
            task.wait(0.1)
        end
    end
end)

local function notify(title, content)
    pcall(function() WindUI:Notify({ Title = title, Content = content, Duration = 3 }) end)
end

----------------------------------------------------------------------
-- Auto M1 (separate from slime farm) + Charge M1 for bows
----------------------------------------------------------------------
-- Real left click through VirtualInputManager, sent on the right side of the screen
-- so it doesn't land on the menu.
local function m1Pos()
    local cam = workspace.CurrentCamera
    local vs = cam and cam.ViewportSize or Vector2.new(800, 600)
    return vs.X * 0.8, vs.Y * 0.5
end

local m1Held = false

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

task.spawn(function()
    while S.alive do
        if cfg.autoM1 then
            local _, h = chr()
            if h and h.Health > 0 then
                m1Down()
                if cfg.chargeM1 then
                    -- hold to charge (stops early if toggled off), then release to fire
                    local t0 = os.clock()
                    while cfg.autoM1 and S.alive and os.clock() - t0 < cfg.chargeTime do
                        task.wait(0.05)
                    end
                else
                    task.wait(0.03)
                end
                m1Up()
                task.wait(math.max(cfg.m1Delay, 0.05))
            else
                task.wait(0.2)
            end
        else
            task.wait(0.1)
        end
    end
end)

task.spawn(function()
    while S.alive do
        if S.farming and not S.slimeFarming and getZone() then farmLane() else task.wait(0.1) end
    end
end)

local heartbeatConn = RunService.Heartbeat:Connect(function()
    local _, h, r = chr()
    if cfg.wsOn and h then h.WalkSpeed = SPEEDS[cfg.wsIdx] end
    if S.farming and not S.slimeFarming and S.inLane and r then
        local z = getZone()
        if not z then return end
        local lane = laneCenter(z, math.min(S.lane, z.count))
        local lc, al = splitPos(r.Position)
        local na = math.clamp(al, z.alongMin, z.alongMax)
        local pos = r.Position
        local y = pos.Y
        local p = toWorld(lane, na, 0)
        local target = standY(p.X, p.Z)
        if target and math.abs(target - y) > 1.5 then y = target end
        if math.abs(lc - lane) > 0.001 or na ~= al or y ~= pos.Y then
            place(r, Vector3.new(p.X, y, p.Z))
        end
    end
end)

----------------------------------------------------------------------
-- Harvesting: ProximityPrompt + F spam
----------------------------------------------------------------------
local prompts = {}
for _, d in ipairs(workspace:GetDescendants()) do
    if d:IsA("ProximityPrompt") then prompts[d] = true end
end
local addConn = workspace.DescendantAdded:Connect(function(d)
    if d:IsA("ProximityPrompt") then prompts[d] = true end
end)
local remConn = workspace.DescendantRemoving:Connect(function(d) prompts[d] = nil end)

local function promptPos(p)
    local par = p.Parent
    if not par then return end
    if par:IsA("Attachment") then return par.WorldPosition end
    if par:IsA("PVInstance") then return par:GetPivot().Position end
end

task.spawn(function()
    while S.alive do
        if S.farming then
            local _, _, r = chr()
            if r then
                local near = false
                for p in pairs(prompts) do
                    if p.Enabled then
                        local pp = promptPos(p)
                        if pp and (pp - r.Position).Magnitude <= p.MaxActivationDistance + 1 then
                            near = true
                            if fireproximityprompt then pcall(fireproximityprompt, p) end
                        end
                    end
                end
                if near and VIM then
                    for _ = 1, cfg.fSpam do
                        pcall(function()
                            VIM:SendKeyEvent(true, Enum.KeyCode.F, false, game)
                            VIM:SendKeyEvent(false, Enum.KeyCode.F, false, game)
                        end)
                    end
                end
            end
        end
        task.wait(0.1)
    end
end)

LP.CharacterAdded:Connect(function() S.inLane = false end)

----------------------------------------------------------------------
-- Building: Block Breaker
----------------------------------------------------------------------
local BB = { c1 = nil, c2 = nil, yMin = nil, yMax = nil, running = false, count = 0, skip = {}, target = nil, needFresh = true }
local bbFolder = Instance.new("Folder")
bbFolder.Name = "BreakerPreview"
bbFolder.Parent = workspace

local SLOT_KEYS = {
    Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five,
    Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight, Enum.KeyCode.Nine,
}
local MAX_HIGHLIGHTS = 500

local function bbBox()
    if not (BB.c1 and BB.c2 and BB.yMin and BB.yMax) then return end
    local lo = Vector3.new(math.min(BB.c1.X, BB.c2.X), math.min(BB.yMin, BB.yMax), math.min(BB.c1.Z, BB.c2.Z))
    local hi = Vector3.new(math.max(BB.c1.X, BB.c2.X), math.max(BB.yMin, BB.yMax), math.max(BB.c1.Z, BB.c2.Z))
    return lo, hi
end

local function scanBlocks()
    local lo, hi = bbBox()
    if not lo then return {} end
    local ex = { hlFolder, bbFolder }
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl.Character then table.insert(ex, pl.Character) end
    end
    local op = OverlapParams.new()
    op.FilterType = Enum.RaycastFilterType.Exclude
    op.FilterDescendantsInstances = ex
    local parts = workspace:GetPartBoundsInBox(CFrame.new((lo + hi) / 2), (hi - lo) + Vector3.new(1, 1, 1), op)

    local tol = 0.5
    local out = {}
    for _, p in ipairs(parts) do
        local s, c = p.Size, p.Position
        if p.ClassName ~= "Terrain" and not BB.skip[p] and p.Transparency < 1
            and math.max(s.X, s.Y, s.Z) <= cfg.maxBlock
            and c.X >= lo.X - tol and c.X <= hi.X + tol
            and c.Y >= lo.Y - tol and c.Y <= hi.Y + tol
            and c.Z >= lo.Z - tol and c.Z <= hi.Z + tol then
            table.insert(out, p)
        end
    end
    local _, _, r = chr()
    local rp = r and r.Position or Vector3.zero
    table.sort(out, function(a, b)
        local ay, by = math.floor(a.Position.Y + 0.5), math.floor(b.Position.Y + 0.5)
        if ay ~= by then return ay > by end
        return (a.Position - rp).Magnitude < (b.Position - rp).Magnitude
    end)
    return out
end

local function rebuildBreaker()
    bbFolder:ClearAllChildren()
    local blocks = scanBlocks()
    BB.count = #blocks
    for i = 1, math.min(#blocks, MAX_HIGHLIGHTS) do
        local p = blocks[i]
        local a = Instance.new("BoxHandleAdornment")
        a.Adornee = p
        a.Size = p.Size + Vector3.new(0.05, 0.05, 0.05)
        a.AlwaysOnVisible = true
        a.ZIndex = 1
        a.Transparency = 0.55
        a.Color3 = Color3.fromRGB(255, 150, 0)
        a.Parent = bbFolder
    end
end

local function cleanPreview() 
    for _, a in ipairs(bbFolder:GetChildren()) do
        if not (a.Adornee and a.Adornee.Parent) then a:Destroy() end
    end
end

local function breakerZoneChanged()
    BB.skip = {}
    rebuildBreaker()
end

local function pressKey(key)
    if not VIM then return end
    pcall(function()
        VIM:SendKeyEvent(true, key, false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, key, false, game)
    end)
end

local function equipPick(force)
    local c, h = chr()
    if not (c and h) then return end
    if force then h:UnequipTools() task.wait(0.15) end
    local tool = c:FindFirstChildOfClass("Tool")
    if tool then return tool end
    pressKey(SLOT_KEYS[cfg.pickSlot])
    task.wait(0.2)
    tool = c:FindFirstChildOfClass("Tool")
    if not tool then 
        local list = {}
        for _, t in ipairs(LP.Backpack:GetChildren()) do
            if t:IsA("Tool") then table.insert(list, t) end
        end
        if list[cfg.pickSlot] then
            h:EquipTool(list[cfg.pickSlot])
            task.wait(0.15)
            tool = c:FindFirstChildOfClass("Tool")
        end
    end
    return tool
end

local function moveMouseTo(part)
    if not VIM or not part or not part.Parent then return false end
    local cam = workspace.CurrentCamera
    if not cam then return false end
    local v, onScreen = cam:WorldToViewportPoint(part.Position)
    if not onScreen or v.Z <= 0 then return false end
    local ok = pcall(function()
        VIM:SendMouseMoveEvent(v.X, v.Y, game)
    end)
    return ok
end

local mouseHeld = false
local function setMiningMouse(part, down)
    if not VIM then return false end
    if down then
        if not moveMouseTo(part) then return false end
        if not mouseHeld then
            local v = workspace.CurrentCamera:WorldToViewportPoint(part.Position)
            local ok = pcall(function()
                VIM:SendMouseButtonEvent(v.X, v.Y, 0, true, game, 0)
            end)
            mouseHeld = ok
        end
        return mouseHeld
    elseif mouseHeld then
        local cam = workspace.CurrentCamera
        local v = cam and cam:WorldToViewportPoint(part and part.Position or Vector3.zero)
        pcall(function()
            VIM:SendMouseButtonEvent(v and v.X or 0, v and v.Y or 0, 0, false, game, 0)
        end)
        mouseHeld = false
    end
    return true
end

RunService:BindToRenderStep("FarmHubBreakerAim", Enum.RenderPriority.Camera.Value + 1, function()
    local t = BB.target
    if BB.running and t and t.Parent then
        local cam = workspace.CurrentCamera
        cam.CFrame = CFrame.lookAt(cam.CFrame.Position, t.Position)
    end
end)

local function mineBlock(part, tool)
    local t0 = os.clock()
    BB.target = part
    while BB.running and S.alive and part.Parent and os.clock() - t0 < cfg.breakTimeout do
        local c, h, r = chr()
        if not (c and h and r and h.Health > 0) then
            setMiningMouse(part, false)
            BB.target = nil
            return nil
        end
        if not tool or tool.Parent ~= c then
            tool = equipPick(false)
            if not tool then
                setMiningMouse(part, false)
                BB.target = nil
                return nil
            end
        end
        if (part.Position - r.Position).Magnitude > cfg.reach then
            place(r, part.Position + Vector3.new(0, part.Size.Y / 2 + 3.5, 0))
            r.AssemblyLinearVelocity = Vector3.zero
        end
        if setMiningMouse(part, true) then end
        task.wait(cfg.hitDelay)
    end
    setMiningMouse(part, false)
    if part.Parent and BB.running then BB.skip[part] = true end 
    BB.target = nil
    return tool
end

task.spawn(function()
    while S.alive do
        if BB.running then
            local blocks = scanBlocks()
            if #blocks == 0 then
                BB.running = false
                S.msg = "Block Breaker: finished"
                rebuildBreaker()
            else
                local tool = equipPick(true)
                BB.needFresh = false
                if not tool then
                    BB.running = false
                    S.msg = "No pickaxe found in slot " .. cfg.pickSlot
                else
                    for _, part in ipairs(blocks) do
                        if not (BB.running and S.alive) then break end
                        if part.Parent then
                            tool = mineBlock(part, tool)
                            if not tool then task.wait(0.5) break end
                            cleanPreview()
                        end
                    end
                end
            end
        else
            setMiningMouse(nil, false)
            task.wait(0.1)
        end
    end
end)

----------------------------------------------------------------------
-- Save / Load Config, Auto Execute
----------------------------------------------------------------------
local UIEl = {}      -- key -> { el = element, kind = "toggle" | "slider" | "dropdown" | "input" }
local syncUI         -- assigned after the UI is built


local function saveConfig(silent)
    if not writefile then notify("Config", "Your executor doesn't support writefile") return end
    local function v3(v) return v and { v.X, v.Y, v.Z } end
    local ok = pcall(writefile, FILE, HttpService:JSONEncode({
        c1 = v3(S.c1), c2 = v3(S.c2), cfg = cfg,
        bb = { c1 = v3(BB.c1), c2 = v3(BB.c2), yMin = BB.yMin, yMax = BB.yMax },
    }))
    if not silent then notify("Config", ok and ("Saved to " .. FILE) or "Save failed") end
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
    local ok, raw = pcall(readfile, FILE)
    if not ok then if not silent then notify("Config", "Couldn't read config") end return false end
    local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)
    if not ok2 or type(data) ~= "table" then
        if not silent then notify("Config", "Config file is corrupted") end
        return false
    end
    S.c1 = data.c1 and Vector3.new(data.c1[1], data.c1[2], data.c1[3]) or nil
    S.c2 = data.c2 and Vector3.new(data.c2[1], data.c2[2], data.c2[3]) or nil
    local keepAutoLoad = cfg.autoLoad
    if type(data.cfg) == "table" then
        for k, v in pairs(data.cfg) do
            if cfg[k] ~= nil and type(cfg[k]) == type(v) then cfg[k] = v end
        end
    end
    cfg.autoLoad = keepAutoLoad
    -- never start swinging / farming just because of a saved file
    cfg.autoM1 = false
    cfg.farmAll = false
    for _, k in ipairs(SLIME_PRIORITY) do
        if cfg.slimeSelection[k] == nil then cfg.slimeSelection[k] = true end
    end
    if type(data.bb) == "table" then
        local b = data.bb
        BB.c1 = b.c1 and Vector3.new(b.c1[1], b.c1[2], b.c1[3]) or nil
        BB.c2 = b.c2 and Vector3.new(b.c2[1], b.c2[2], b.c2[3]) or nil
        BB.yMin, BB.yMax = b.yMin, b.yMax
    end
    zoneChanged()
    breakerZoneChanged()
    if syncUI then syncUI() end
    if not silent then notify("Config", "Config loaded") end
    return true
end

-- Auto Execute: re-runs this script after every teleport / server hop.
-- Needs queue_on_teleport plus a way to re-fetch the script: either a Script URL
-- (raw link) or this script saved as FarmHub.lua in the executor's workspace folder.
local AUTOEXEC_FLAG = "FarmHub_autoexec.txt"
local AUTOLOAD_FLAG = "FarmHub_autoload.txt"
local SCRIPT_FILE = "FarmHub.lua"
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
        notify("Auto Execute", "Paste a Script URL below, or save this script as " .. SCRIPT_FILE .. " in your workspace folder")
        return
    end
    if not queuedThisSession then
        queuedThisSession = pcall(qot, src)
    end
    notify("Auto Execute", queuedThisSession and "Enabled - script will re-run after teleport" or "Failed to queue script")
end

----------------------------------------------------------------------
-- Auto Rejoin (private server) + resume farming
----------------------------------------------------------------------
-- Roblox has no script API to join a VIP server from a link. So "Teleport" relies on
-- TeleportService:Teleport(placeId): Roblox documents that a plain teleport returns you
-- to the VIP server you recently joined. "Open Link" opens the link in your browser,
-- which launches a fresh Roblox client (your executor's autoexec must start the script).
local TeleportService = game:GetService("TeleportService")
local STATE_FILE = "FarmHub_state.json"

local function readState()
    if isfile and readfile and isfile(STATE_FILE) then
        local ok, raw = pcall(readfile, STATE_FILE)
        if ok then
            local ok2, d = pcall(HttpService.JSONDecode, HttpService, raw)
            if ok2 and type(d) == "table" then return d end
        end
    end
    return {}
end

local function writeState(d)
    if writefile then pcall(writefile, STATE_FILE, HttpService:JSONEncode(d)) end
end

local function openPrivateLink()
    local link = cfg.privateLink
    if link == "" then
        notify("Rejoin", "Set your private server link first")
        return false
    end
    if setclipboard then pcall(setclipboard, link) end
    local ok = pcall(function() game:GetService("GuiService"):OpenBrowserWindow(link) end)
    notify("Rejoin", ok and "Opened the link in your browser (also copied)" or "Couldn't open the browser - link copied, open it manually")
    return ok
end

local failedConn
local function rejoinServer(manual)
    if S.rejoining then return end
    S.rejoining = true
    S.lastRejoin = os.time()

    saveConfig(true)
    writeState({ resume = true, farmAll = cfg.farmAll, autoM1 = cfg.autoM1, lastRejoin = S.lastRejoin })
    setAutoExec(true) -- the script has to re-run in the new server to keep farming

    notify("Rejoin", manual and "Rejoining..." or "All slimes cleared - rejoining...")
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

-- Watcher: every targeted slime exists but is dead for a while -> rejoin
task.spawn(function()
    local startedAt = os.clock()
    local clearedSince
    while S.alive do
        if cfg.rejoinOnClear and S.slimeFarming and not S.rejoining then
            local total, alive = slimeCensus()
            if total > 0 and alive == 0 then
                clearedSince = clearedSince or os.clock()
                if os.clock() - clearedSince >= cfg.rejoinDelay
                    and os.clock() - startedAt >= 15
                    and os.time() - (S.lastRejoin or 0) >= cfg.rejoinCooldown then
                    rejoinServer(false)
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
-- WindUI Setup
----------------------------------------------------------------------
local Window = WindUI:CreateWindow({
    Title = "FarmHub [WindUI]",
    Icon = "rbxassetid://6023426915",
    Author = "Automation Hub",
    Folder = "FarmHubConfig",
    Size = UDim2.fromOffset(580, 420),
    Transparent = true,
    Theme = "Dark",
    SideBarWidth = 150,
    HasOutline = true,
    ToggleKey = Enum.KeyCode.RightShift,
})
pcall(function() Window:SetToggleKey(Enum.KeyCode.RightShift) end)

local TabFarm = Window:Tab({ Title = "Farm", Icon = "home" })
local TabSlime = Window:Tab({ Title = "Slime Farm", Icon = "shield" })
local TabCombat = Window:Tab({ Title = "Combat", Icon = "sword" })
local TabSettings = Window:Tab({ Title = "Settings", Icon = "settings" })
local TabConfig = Window:Tab({ Title = "Config", Icon = "map" })
local TabBuilding = Window:Tab({ Title = "Building", Icon = "hammer" })

TabFarm:Select()

-- Helpers that build an element AND remember it, so loading a config can refresh it
local function sliderEl(tab, key, title, min, max, step, onChange)
    UIEl[key] = { kind = "slider", el = tab:Slider({
        Title = title,
        Value = { Min = min, Max = max, Default = cfg[key] },
        Step = step,
        Callback = function(v)
            cfg[key] = v
            if onChange then onChange(v) end
        end,
    }) }
end

local function toggleEl(tab, key, title, desc, onChange)
    UIEl[key] = { kind = "toggle", el = tab:Toggle({
        Title = title,
        Desc = desc,
        Value = cfg[key],
        Callback = function(state)
            cfg[key] = state
            if onChange then onChange(state) end
        end,
    }) }
end

local function dropdownEl(tab, key, title, values, onChange)
    UIEl[key] = { kind = "dropdown", el = tab:Dropdown({
        Title = title,
        Values = values,
        Value = cfg[key],
        Callback = function(item)
            cfg[key] = item
            if onChange then onChange(item) end
        end,
    }) }
end

----------------------------------------------------------------------
-- Farm Tab
----------------------------------------------------------------------
TabFarm:Toggle({
    Title = "Berry Farm Status",
    Desc = "Toggle automatic lane berry farming",
    Value = false,
    Callback = function(state)
        if state and not getZone() then
            WindUI:Notify({ Title = "Warning", Content = "Set Corner 1 & 2 in Config first!", Duration = 3 })
            return
        end
        S.farming = state
        S.msg = S.farming and "Farming..." or "Paused (progress kept)"
    end
})

dropdownEl(TabFarm, "axis", "Berry Farm Axis", { "Vertical", "Horizontal" }, function() zoneChanged() end)
dropdownEl(TabFarm, "mode", "Berry Farm Mode", { "Legit", "Obvious" })

TabFarm:Button({
    Title = "Reset Lane Progress",
    Desc = "Reset lane index back to 1",
    Callback = function()
        S.lane, S.inLane = 1, false
        updateHighlights()
        WindUI:Notify({ Title = "Info", Content = "Lane progress has been reset", Duration = 2 })
    end
})

----------------------------------------------------------------------
-- Slime Farm Tab
----------------------------------------------------------------------
UIEl.slimeFarming = { kind = "toggle", el = TabSlime:Toggle({
    Title = "Slime Farm Status",
    Desc = "Moves to slimes. Turn on Auto M1 in the Combat tab to attack",
    Value = false,
    Callback = function(state)
        S.slimeFarming = state
        if state then S.farming = true end
        local msg = state and "Started" or "Stopped"
        if state then
            local n = countFarmTargets()
            msg = n > 0 and ("Started - " .. n .. " targets found") or "Started - NO targets found (check target toggles / Farm All)"
        end
        WindUI:Notify({ Title = "Slime Farm", Content = msg, Duration = 3 })
    end
}) }

toggleEl(TabSlime, "farmAll", "Farm All",
    "Targets every slime under Hub.Guardians (all colors), nearest first. Overrides the toggles below")
sliderEl(TabSlime, "skipAfter", "Skip Stuck Target After (s)", 0, 60, 1)

TabSlime:Section({ Title = "Auto Rejoin (private server)" })

toggleEl(TabSlime, "rejoinOnClear", "Rejoin When All Slimes Are Dead",
    "When every targeted slime is dead, rejoin and resume farming automatically (turns on Auto Execute)")

UIEl.privateLink = { kind = "input", el = TabSlime:Input({
    Title = "Private Server Link",
    Desc = "Your private server link (used by 'Open Link' and as the fallback)",
    Value = cfg.privateLink,
    Placeholder = "https://www.roblox.com/games/...?privateServerLinkCode=...",
    Callback = function(text)
        local t = tostring(text or "")
        cfg.privateLink = t:gsub("^%s+", ""):gsub("%s+$", "")
    end
}) }

dropdownEl(TabSlime, "rejoinMethod", "Rejoin Method", { "Teleport", "Open Link" })
sliderEl(TabSlime, "rejoinDelay", "Confirm All Dead For (s)", 1, 30, 1)
sliderEl(TabSlime, "rejoinCooldown", "Min Time Between Rejoins (s)", 30, 600, 10)

TabSlime:Button({
    Title = "Rejoin Now",
    Desc = "Test the rejoin and resume right now",
    Callback = function() rejoinServer(true) end
})

TabSlime:Paragraph({
    Title = "How it works",
    Desc = "Teleport sends you back to the private server you're in (Roblox returns you to a VIP server you recently joined). Open Link launches a new client from your link - your executor's autoexec must start the script there. Join your private server through the link once first.",
})

----------------------------------------------------------------------
-- Combat Tab (Auto M1 / Charge M1)
----------------------------------------------------------------------
toggleEl(TabCombat, "autoM1", "Auto M1",
    "Swings your equipped tool. Works on its own. Panic key: K turns everything off",
    function(state) if not state then m1Up() end end)

toggleEl(TabCombat, "chargeM1", "Charge M1 (Bows)", "Auto M1 holds to charge, then releases to fire")
sliderEl(TabCombat, "chargeTime", "Charge Time (s)", 0.1, 5, 0.1)
sliderEl(TabCombat, "m1Delay", "M1 Delay (s)", 0.05, 1, 0.05)
TabCombat:Paragraph({
    Title = "Note",
    Desc = "Auto M1 sends real clicks on the right side of the screen. If the menu is ever in the way, press K to stop everything.",
})

----------------------------------------------------------------------
-- Settings Tab
----------------------------------------------------------------------
sliderEl(TabSettings, "tweenSpeed", "Tween Speed", 5, 150, 1)
sliderEl(TabSettings, "laneDelay", "Lane Delay (s)", 0, 1, 0.1)
sliderEl(TabSettings, "laneWidth", "Lane Width", 1, 20, 1, function() zoneChanged() end)
sliderEl(TabSettings, "fSpam", "F-Spam Count", 0, 10, 1)

toggleEl(TabSettings, "wsOn", "WalkSpeed Override", nil, function(state)
    if not state then
        local _, h = chr()
        if h then h.WalkSpeed = 16 end
    end
end)

UIEl.wsIdx = { kind = "dropdown", el = TabSettings:Dropdown({
    Title = "WalkSpeed Value",
    Values = { "16", "25", "35", "50", "75", "100" },
    Value = tostring(SPEEDS[cfg.wsIdx]),
    Callback = function(item)
        for idx, val in ipairs(SPEEDS) do
            if tostring(val) == item then
                cfg.wsIdx = idx
                break
            end
        end
    end
}) }

----------------------------------------------------------------------
-- Config Tab
----------------------------------------------------------------------
TabConfig:Button({
    Title = "Set Corner 1",
    Desc = "Click a block in the world",
    Callback = function() 
        S.picking = 1 
        WindUI:Notify({Title="Prompt", Content="Click a block in the world", Duration=2}) 
    end
})

TabConfig:Button({
    Title = "Set Corner 2",
    Desc = "Click a block in the world",
    Callback = function() 
        S.picking = 2 
        WindUI:Notify({Title="Prompt", Content="Click a block in the world", Duration=2}) 
    end
})

TabConfig:Button({
    Title = "Clear Zone",
    Callback = function()
        S.farming, S.c1, S.c2 = false, nil, nil
        zoneChanged()
        WindUI:Notify({Title="Info", Content="Zone cleared", Duration=2})
    end
})

TabConfig:Section({ Title = "Save / Load" })

TabConfig:Button({
    Title = "Save Config",
    Desc = "Saves all settings, zones and block breaker area to " .. FILE,
    Callback = function() saveConfig(false) end
})

TabConfig:Button({
    Title = "Load Config",
    Desc = "Loads the saved file and refreshes every setting",
    Callback = function() loadConfig(false) end
})

toggleEl(TabConfig, "autoLoad", "Auto Load Config",
    "Loads your saved config automatically every time the script starts",
    function(state)
        if writefile then pcall(writefile, AUTOLOAD_FLAG, state and "1" or "0") end
    end)

TabConfig:Section({ Title = "Auto Execute" })

toggleEl(TabConfig, "autoExec", "Auto Execute",
    "Re-runs this script after teleports / server hops (needs queue_on_teleport)",
    function(state) setAutoExec(state) end)

UIEl.scriptUrl = { kind = "input", el = TabConfig:Input({
    Title = "Script URL (raw link)",
    Desc = "Where to re-download the script from. Leave empty to use " .. SCRIPT_FILE .. " from your workspace folder",
    Value = cfg.scriptUrl,
    Placeholder = "https://raw.githubusercontent.com/...",
    Callback = function(text)
        cfg.scriptUrl = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
        queuedThisSession = false
        if cfg.autoExec then setAutoExec(true) end
    end
}) }

----------------------------------------------------------------------
-- Building Tab (Block Breaker)
----------------------------------------------------------------------
TabBuilding:Button({
    Title = "Set Block Corner 1",
    Callback = function() 
        if BB.running then return end
        S.picking = 3 
        WindUI:Notify({Title="Prompt", Content="Click first block breaker corner", Duration=2}) 
    end
})

TabBuilding:Button({
    Title = "Set Block Corner 2",
    Callback = function() 
        if BB.running then return end
        S.picking = 4 
        WindUI:Notify({Title="Prompt", Content="Click second block breaker corner", Duration=2}) 
    end
})

sliderEl(TabBuilding, "pickSlot", "Pickaxe Hotbar Slot", 1, 9, 1, function(v)
    cfg.pickSlot = math.floor(v)
    BB.needFresh = true
end)

UIEl.bbRunning = { kind = "toggle", el = TabBuilding:Toggle({
    Title = "Block Breaker Status",
    Value = false,
    Callback = function(state)
        if state then
            if not (BB.c1 and BB.c2 and BB.yMin and BB.yMax) then
                WindUI:Notify({Title="Error", Content="Set corners & Y levels first!", Duration=3})
                return
            end
            if not VIM then
                WindUI:Notify({Title="Error", Content="VirtualInputManager unavailable", Duration=3})
                return
            end
            S.farming = false
            BB.skip = {}
            rebuildBreaker()
            BB.needFresh = true
            BB.running = true
        else
            BB.running, BB.target = false, nil
        end
    end
}) }

-- Refresh every element from cfg (used after Load Config)
local function pushUI(key, value)
    local u = UIEl[key]
    if not u then return end
    local methods = (u.kind == "dropdown") and { "Select", "Set" } or { "Set" }
    for _, m in ipairs(methods) do
        local fn = u.el and u.el[m]
        if type(fn) == "function" and pcall(fn, u.el, value) then return end
    end
end

syncUI = function()
    for key, u in pairs(UIEl) do
        if key == "wsIdx" then
            pushUI(key, tostring(SPEEDS[cfg.wsIdx]))
        elseif key:sub(1, 3) == "sel" and cfg.slimeSelection[key:sub(4)] ~= nil then
            pushUI(key, cfg.slimeSelection[key:sub(4)])
        elseif cfg[key] ~= nil then
            pushUI(key, cfg[key])
        end
    end
end

-- Panic key: K stops Auto M1 and all farming instantly
local function panic()
    cfg.autoM1, cfg.farmAll = false, false
    S.slimeFarming, S.farming = false, false
    BB.running, BB.target = false, nil
    m1Up()
    pushUI("autoM1", false)
    notify("Panic", "Auto M1 and farming stopped")
end

UIS.InputBegan:Connect(function(i, gp)
    if not gp and i.KeyCode == Enum.KeyCode.K then panic() end
end)

-- Startup: auto load config, re-arm auto execute, resume farming after a rejoin
task.defer(function()
    local function flag(name)
        if isfile and readfile and isfile(name) then
            local ok, v = pcall(readfile, name)
            if ok then return v end
        end
    end

    local state = readState()
    S.lastRejoin = state.lastRejoin or 0
    local resuming = state.resume == true

    -- the switch lives in its own tiny file (the config itself can't say whether to load it);
    -- a rejoin always loads the config so your settings carry over
    local autoLoadOn = flag(AUTOLOAD_FLAG) ~= "0"
    if autoLoadOn or resuming then
        if loadConfig(true) and not resuming then notify("Config", "Auto-loaded saved config") end
    end
    cfg.autoLoad = autoLoadOn
    pushUI("autoLoad", autoLoadOn)

    -- keep auto execute armed across teleports even if the config wasn't loaded
    if flag(AUTOEXEC_FLAG) == "1" then cfg.autoExec = true end
    if cfg.autoExec then setAutoExec(true) end

    if resuming then
        writeState({ resume = false, lastRejoin = S.lastRejoin })
        cfg.farmAll = state.farmAll == true
        cfg.autoM1 = state.autoM1 == true
        S.slimeFarming, S.farming = true, true
        pushUI("farmAll", cfg.farmAll)
        pushUI("autoM1", cfg.autoM1)
        pushUI("slimeFarming", true)
        notify("Rejoin", "Resumed farming after rejoin")
    end
end)

----------------------------------------------------------------------
-- Listeners & Input Handlers
----------------------------------------------------------------------
local pickParams = RaycastParams.new()
pickParams.FilterType = Enum.RaycastFilterType.Exclude

local inputConn = UIS.InputBegan:Connect(function(i, gp)
    if S.picking and not gp and i.UserInputType == Enum.UserInputType.MouseButton1 then
        local cam = workspace.CurrentCamera
        local loc = UIS:GetMouseLocation()
        local ray = cam:ViewportPointToRay(loc.X, loc.Y)
        pickParams.FilterDescendantsInstances = { LP.Character, hlFolder }
        local res = workspace:Raycast(ray.Origin, ray.Direction * 1000, pickParams)
        if res then
            local picked = S.picking
            if picked == 1 then
                S.c1 = res.Position
                zoneChanged()
            elseif picked == 2 then
                S.c2 = res.Position
                zoneChanged()
            elseif picked == 3 then
                BB.c1 = res.Position
                BB.yMin = math.floor(res.Position.Y + 0.5)
                BB.yMax = BB.yMax or BB.yMin
                breakerZoneChanged()
            elseif picked == 4 then
                BB.c2 = res.Position
                local y = math.floor(res.Position.Y + 0.5)
                BB.yMin = BB.yMin or y
                BB.yMax = y
                breakerZoneChanged()
            end
            WindUI:Notify({Title = "Success", Content = "Corner " .. picked .. " set successfully!", Duration = 2})
            S.picking = nil
        end
    end
end)
