
if _G.MatchaCleanup then pcall(_G.MatchaCleanup) end
local ScriptActive = true

local mfloor, mabs            = math.floor, math.abs
local msin                    = math.sin
local tinsert                 = table.insert
local ipairs_, pairs_         = ipairs, pairs
local tostring_, tonumber_    = tostring, tonumber
local pcall_                  = pcall
local task_wait, task_spawn   = task.wait, task.spawn
local tick_                   = tick
local sformat                 = string.format
local Vec2, Vec3              = Vector2.new, Vector3.new
local CF                      = CFrame.new
local C3rgb                   = Color3.fromRGB

local function clamp(x, a, b)
    if x < a then return a elseif x > b then return b else return x end
end
local function lerp(a, b, t) return a + (b - a) * t end

local DEBUG = false
local rprint = print
local print = function(...)
    if DEBUG then rprint(...) end
end

local Players, RunService, Workspace, player, camera
local initAttempts = 0
while not player and initAttempts < 50 do
    initAttempts = initAttempts + 1
    pcall_(function()
        Players    = game:GetService("Players")
        RunService = game:GetService("RunService")
        Workspace  = game:GetService("Workspace")
        player     = Players.LocalPlayer
        if player then camera = Workspace.CurrentCamera end
    end)
    if not player then task_wait(0.1) end
end
if not player then warn("[Hub] No LocalPlayer"); return end
if not camera then camera = Workspace.CurrentCamera end

local GuiService; pcall_(function() GuiService = game:GetService("GuiService") end)

setrobloxinput(true)

local mouse = nil
pcall_(function() mouse = player:GetMouse() end)

local errCounts = {}
local function reportErr(tag, err)
    local msg = "[" .. tag .. "] " .. tostring_(err)
    local n = (errCounts[msg] or 0) + 1
    errCounts[msg] = n
    if n <= 3 or n % 50 == 0 then
        rprint("[Hub][ERROR]" .. msg .. (n > 1 and ("  (x" .. n .. ")") or ""))
    end
end
local function _wrap(tag, fn)
    task_spawn(function()
        while ScriptActive do
            local ok, err = pcall_(fn)
            if ok then break end
            reportErr(tag, err)
            task_wait(0.5)
        end
    end)
end

local autoBuyActive    = false
local skipDecorActive  = false
local lemonFarmActive  = false
local cashFarmActive   = true
local autoStandActive  = false
local autoDealActive   = true
local autoRebirthActive = false
local autoEvolveActive  = false
local keyEspActive      = false
local _standIsTapping  = false

local buyBlacklist    = {}
local failedButtons   = {}
local buyAttempt      = {}

-- short, self-clearing per-button buy cooldown, weak-keyed by INSTANCE so it can't wedge (GC'd on buy, fresh
-- instance on respawn, timestamp always expires). Used by the stateless autobuy worker AND _anyLiveButtons.
local buyCooldown = {}
pcall_(function() setmetatable(buyCooldown, { __mode = "k" }) end)
local BUY_RETRY = 2.0

local keyMemo = {}
pcall_(function() setmetatable(keyMemo, { __mode = "k" }) end)
local function getButtonKey(v)
    if not v then return nil end
    local k = keyMemo[v]
    if k then return k end
    local pos = v.Position
    if not pos then return nil end
    k = sformat("%d,%d,%d", mfloor(pos.X + 0.5), mfloor(pos.Y + 0.5), mfloor(pos.Z + 0.5))
    keyMemo[v] = k
    return k
end

local function resetBuyBlacklist()
    buyBlacklist  = {}
    failedButtons = {}
    buyAttempt    = {}
    print("[Hub] Blacklist RESET!")
end

local function buyReady(key, v)
    local a = buyAttempt[key]
    if not a then return true end
    if v and a.inst and a.inst ~= v then
        buyAttempt[key] = nil
        return true
    end

    return tick_() >= a.next
end
local function markBuyFail(key, v)
    local a = buyAttempt[key]
    if not a then a = { n = 0, next = 0 }; buyAttempt[key] = a end
    a.inst = v or a.inst
    a.n = a.n + 1
    -- gentle linear cooldown capped at 2s (was exponential up to a 20s lockout that skipped buttons you
    -- could already afford a moment later, as cash keeps coming in)
    local d = 0.5 + 0.25 * a.n
    if d > 2 then d = 2 end
    a.next = tick_() + d
end

local function isBlacklisted(key, v)
    local bl = buyBlacklist[key]
    if not bl then return false end
    if v and bl ~= true and bl ~= v then
        buyBlacklist[key] = nil
        return false
    end
    return true
end

local myTycoon = nil
local function findMyTycoon()
    local pname = player.Name

    for _, tycoon in ipairs_(Workspace:GetChildren()) do
        if tostring_(tycoon.Name):find("Tycoon") then
            local owner = tycoon:FindFirstChild("Owner")
            if owner then
                local ov; pcall_(function() ov = owner.Value end)
                if ov == player or (ov and tostring_(ov):find(pname, 1, true)) then return tycoon end
            end
        end
    end

    local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local hp; pcall_(function() hp = hrp and hrp.Position end)
    if hp then
        local best, bestD
        for _, tycoon in ipairs_(Workspace:GetChildren()) do
            if tostring_(tycoon.Name):find("Tycoon") then
                local pur = tycoon:FindFirstChild("Purchases")
                if pur then
                    pcall_(function()
                        for _, d in ipairs_(pur:GetDescendants()) do
                            if d.Name == "Button" and d:IsA("BasePart") and d.Parent then
                                local dd = (d.Position - hp).Magnitude
                                if not bestD or dd < bestD then bestD = dd; best = tycoon end
                            end
                        end
                    end)
                end
            end
        end
        if best and bestD and bestD < 300 then return best end
    end
    return nil
end
myTycoon = findMyTycoon()

local drawObjs = {}
local function D(typ, props)
    local obj = Drawing.new(typ)
    for k, v in pairs_(props) do pcall_(function() obj[k] = v end) end
    tinsert(drawObjs, obj)
    return obj
end

local CFG = {
    buyWindow = 0.45,
    afkDelay  = 6,
    zoomTicks = 22,
    zoomStep  = 1,
    standRest = 60,
    vineCd    = 4 * 3600,
    buyStuck  = 6,
    cheerY    = 0.85,
    exitY     = 0.76,
}

local S = {
    lastUser = tick_(), pmx = 0, pmy = 0, keyDown = {}, lastFire = {},
}

local function _osNow() if type(os) == "table" and type(os.time) == "function" then return os.time() end return nil end
local function _saveVineReady()
    pcall_(function()
        if type(writefile) ~= "function" or not CFG.vineT then return end
        local rem = CFG.vineCd - (tick_() - CFG.vineT)
        if rem < 0 then rem = 0 end
        local onow = _osNow()
        writefile("selllemons_vine.txt", tostring_(mfloor((onow or tick_()) + rem)))
    end)
end
pcall_(function()
    if type(readfile) ~= "function" then return end
    local saved = tonumber(readfile("selllemons_vine.txt"))
    if not saved then return end
    local onow = _osNow()
    if onow then
        local rem = saved - onow
        if rem > 0 and rem < CFG.vineCd + 60 then
            CFG.vineT = tick_() - (CFG.vineCd - rem)
        end

    elseif saved <= tick_() and (tick_() - saved) < 7 * 24 * 3600 then
        CFG.vineT = saved
    end
end)
local UX = {}
function UX.fire(id)
    local now = tick_()
    if S.lastFire[id] and (now - S.lastFire[id]) < 0.30 then return false end
    S.lastFire[id] = now
    return true
end

local FX = { on = false, mods = {}, n = 0 }
local FX_PLASTIC; pcall_(function() FX_PLASTIC = Enum.Material.Plastic end)
function FX.set(inst, prop, val)
    pcall_(function()
        local old = inst[prop]
        if old == val then return end
        inst[prop] = val
        FX.n = FX.n + 1
        FX.mods[FX.n] = { i = inst, p = prop, v = old }
    end)
end
function FX.apply()
    if FX.on then return end
    FX.on = true
    FX.gen = (FX.gen or 0) + 1
    local gen = FX.gen
    task_spawn(function()
        pcall_(function()
            local lt = game:GetService("Lighting")
            FX.set(lt, "GlobalShadows", false)
            FX.set(lt, "FogStart", 1e9)
            FX.set(lt, "FogEnd", 1e9)
            for _, e in ipairs_(lt:GetChildren()) do
                local cn = tostring_(e.ClassName)
                if cn == "BloomEffect" or cn == "BlurEffect" or cn == "SunRaysEffect"
                   or cn == "ColorCorrectionEffect" or cn == "DepthOfFieldEffect" or cn == "Atmosphere" then
                    if cn == "Atmosphere" then
                        FX.set(e, "Density", 0)
                    else
                        FX.set(e, "Enabled", false)
                    end
                end
            end
        end)
        pcall_(function()
            local tr = Workspace:FindFirstChildOfClass("Terrain")
            if tr then
                FX.set(tr, "Decoration", false)
                FX.set(tr, "WaterWaveSize", 0)
                FX.set(tr, "WaterWaveSpeed", 0)
                FX.set(tr, "WaterReflectance", 0)
                FX.set(tr, "WaterTransparency", 1)
                local cl; pcall_(function() cl = tr:FindFirstChildOfClass("Clouds") end)
                if cl then FX.set(cl, "Cover", 0); FX.set(cl, "Density", 0) end
            end
        end)

        local skipSet = {}
        pcall_(function()
            local ch = player.Character
            if ch then
                skipSet[ch] = true
                for _, pp in ipairs_(ch:GetDescendants()) do skipSet[pp] = true end
            end
        end)
        local desc
        pcall_(function() desc = Workspace:GetDescendants() end)
        if desc then
            local i = 1
            while i <= #desc and FX.on and FX.gen == gen and ScriptActive do
                local ok = pcall_(function()
                    local stop = i + 600
                    while i <= #desc and i < stop do
                        local d = desc[i]
                        if not skipSet[d] then
                            local cn = tostring_(d.ClassName)
                            if cn == "ParticleEmitter" or cn == "Trail" or cn == "Beam"
                               or cn == "Smoke" or cn == "Fire" or cn == "Sparkles" then
                                FX.set(d, "Enabled", false)
                            elseif cn == "Decal" or cn == "Texture" then
                                FX.set(d, "Transparency", 1)
                            else
                                local isPart = false
                                pcall_(function() isPart = d:IsA("BasePart") end)
                                if isPart then
                                    if FX_PLASTIC then FX.set(d, "Material", FX_PLASTIC) end
                                    FX.set(d, "CastShadow", false)
                                    FX.set(d, "Reflectance", 0)
                                end
                            end
                        end
                        i = i + 1
                    end
                end)
                if not ok then i = i + 1 end
                task_wait()
            end
        end
        if FX.on and FX.gen == gen then print("[FPS] low graphics ON (" .. FX.n .. " changed)") end
    end)
end
function FX.restore()
    if not FX.on and FX.n == 0 then return end
    FX.on = false
    local mods, n = FX.mods, FX.n
    FX.mods, FX.n = {}, 0

    task_spawn(function()
        local i = 1
        while i <= n do
            local ok = pcall_(function()
                local stop = i + 400
                while i <= n and i < stop do
                    local m = mods[i]
                    m.i[m.p] = m.v
                    i = i + 1
                end
            end)
            if not ok then i = i + 1 end
            task_wait()
        end
        print("[FPS] graphics restored (" .. n .. ")")
    end)
end

local Lib
do
    -- HttpGet can return a TRUNCATED body on a big file. Only run a body that downloaded fully (it ends with
    -- the INSUI_FILE_END marker) - running a partial body can start a half-built render loop (flicker) or
    -- return nil ("Lib nil"). Retry until we get a complete one; best-effort on the last body as a fallback.
    local lastBody
    for _ = 1, 8 do
        local body = nil
        pcall_(function() body = game:HttpGet("https://raw.githubusercontent.com/neaxusxgod-png/INS-ui/main/uilib.min.lua") end)
        if type(body) == "string" and #body > 1000 then
            lastBody = body
            if body:find("INSUI_FILE_END", 1, true) then
                local ok, res = pcall_(function() return loadstring(body)() end)
                if ok and type(res) == "table" then Lib = res; break end
            end
        end
        task_wait(0.4)
    end
    if type(Lib) ~= "table" and type(lastBody) == "string" then
        pcall_(function() local r = loadstring(lastBody)(); if type(r) == "table" then Lib = r end end)
    end
    if type(Lib) ~= "table" then pcall_(function() Lib = INSui end) end
    if type(Lib) ~= "table" then
        print("[Hub] INS ui ne zagruzilsya - klavishi 1-5 rabotayut kak follbek")
    end
end

local UIRef = { win = nil, t = {} }

local function syncFromUI() end
local function syncToUI()
    pcall_(function() if UIRef.t.AutoBuy   then UIRef.t.AutoBuy:Set(autoBuyActive)     end end)
    pcall_(function() if UIRef.t.LemonFarm then UIRef.t.LemonFarm:Set(lemonFarmActive) end end)
    pcall_(function() if UIRef.t.AutoStand then UIRef.t.AutoStand:Set(autoStandActive) end end)
    pcall_(function() if UIRef.t.CashFarm  then UIRef.t.CashFarm:Set(cashFarmActive)   end end)
    pcall_(function() if UIRef.t.AutoRebirth then UIRef.t.AutoRebirth:Set(autoRebirthActive) end end)
    pcall_(function() if UIRef.t.AutoEvolve then UIRef.t.AutoEvolve:Set(autoEvolveActive) end end)
    pcall_(function() if UIRef.t.AutoDeal  then UIRef.t.AutoDeal:Set(autoDealActive)   end end)
end

local function stopAll(save)
    if save == nil then save = (S.stopSaved == nil) end
    if save then
        S.stopSaved = {
            ab = autoBuyActive, lf = lemonFarmActive, cf = cashFarmActive,
            as = autoStandActive, ar = autoRebirthActive, ad = autoDealActive, ae = autoEvolveActive,
        }
        autoBuyActive, lemonFarmActive, cashFarmActive, autoStandActive, autoRebirthActive = false, false, false, false, false
        autoDealActive = false; autoEvolveActive = false
        resetBuyBlacklist()
        syncToUI()
        print("[Hub] Stop All ON - всё остановлено (состояние сохранено)")
    else
        local s = S.stopSaved
        if s then
            autoBuyActive, lemonFarmActive, cashFarmActive = s.ab, s.lf, s.cf
            autoStandActive, autoRebirthActive, autoDealActive = s.as, s.ar, s.ad
            autoEvolveActive = s.ae
            S.stopSaved = nil
        end
        syncToUI()
        print("[Hub] Stop All OFF - фичи возвращены")
    end
    pcall_(function() if S.saveState then S.saveState() end end)
end

local function toggleFeature(slot)
    if not UX.fire("slot" .. slot) then return end
    if     slot == 1 then autoBuyActive   = not autoBuyActive
    elseif slot == 2 then lemonFarmActive = not lemonFarmActive
    elseif slot == 3 then autoStandActive = not autoStandActive
    elseif slot == 4 then cashFarmActive  = not cashFarmActive
    elseif slot == 5 then stopAll(); return
    else return end
    syncToUI()
    pcall_(function() if S.saveState then S.saveState() end end)
    print("[Hub] toggle slot " .. slot)
end

local STAND_NAMES = {"Lemon Stand", "LemonDash", "Lemon Depot", "Lemon Trading", "Lemon Labs", "Lemon Robotics", "Lemon Republic", "LemonX"}
local standEnabled = {}
local MG = { active = false, enabled = {} }

MG.lemBusy = function()
    if not MG.active then return false end
    local t = tick_()
    return (t - (MG.busyT or 0)) < 4 or (t - (MG.entryT or 0)) < 4
end

local RB = { mult = 2, lastPeek = 0, lastReb = 0, goSince = 0, peekEvery = 60, go = false, status = "off" }

-- ── Session stats. Declared HERE (before the menu) so the live :Label closures can capture STATS; the farm
-- loops below write into it. Buttons live in STATS.bought (was the old `STATS.bought`). ──
local STATS = { bought = 0, deals = 0, lemons = 0, bags = 0, rebirths = 0, evolves = 0 }
local statsStartT = tick_()
local _bagSeen = {}
pcall_(function() setmetatable(_bagSeen, { __mode = "k" }) end)   -- weak: counts each cash bag once, no leak
local _lemonPending = {}
pcall_(function() setmetatable(_lemonPending, { __mode = "k" }) end)  -- lemons we clicked; tallied once they actually vanish
local function fmtN(n)
    local s = tostring_(mfloor(tonumber(n) or 0))
    s = s:reverse():gsub("(%d%d%d)", "%1,")
    s = s:reverse()
    return (s:gsub("^,", ""))
end
local function fmtClock(sec)
    sec = mfloor(sec or 0)
    local h, m, s = mfloor(sec / 3600), mfloor((sec % 3600) / 60), sec % 60
    if h > 0 then return sformat("%d:%02d:%02d", h, m, s) end
    return sformat("%d:%02d", m, s)
end
local _cashCache = { t = -1, v = nil }
local function readCashText()   -- the live $balance text from the game HUD; cached 0.5s (per-frame DOM walk is costly)
    local now = tick_()
    if _cashCache.t >= 0 and (now - _cashCache.t) < 0.5 then return _cashCache.v end
    _cashCache.t = now
    local pg = player and player:FindFirstChild("PlayerGui")
    local hud = pg and pg:FindFirstChild("HUD")
    if not hud then _cashCache.v = nil; return nil end
    local t; pcall_(function() t = RB.text(RB.node(hud, "Balance/Main/Cash")) end)
    _cashCache.v = (type(t) == "string" and t ~= "") and t or nil
    return _cashCache.v
end

pcall_(function()
    if type(readfile) ~= "function" then return end
    local saved = tonumber(readfile("selllemons_mini.txt"))
    if not saved then return end
    local onow = _osNow()
    if onow then
        local rem = saved - onow
        if rem > -24 * 3600 and rem < 2 * 3600 then MG.miniEnd = tick_() + rem end
    elseif saved > tick_() - 24 * 3600 and saved < tick_() + 2 * 3600 then
        MG.miniEnd = saved
    end
end)
MG.saveMiniEnd = function()
    if not MG.miniEnd then return end
    if (tick_() - (MG.saveT or 0)) < 20 then return end
    MG.saveT = tick_()
    pcall_(function()
        if type(writefile) ~= "function" then return end
        local onow = _osNow()
        local rem = MG.miniEnd - tick_()
        writefile("selllemons_mini.txt", tostring_(mfloor((onow or tick_()) + rem)))
    end)
end

S.saveState = function() end

MG.list = function()
    local out = {}
    if not myTycoon then return out end
    local pur; pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
    local mg = pur and pur:FindFirstChild("Minigames")
    if not mg then return out end
    pcall_(function()
        for _, c in ipairs_(mg:GetChildren()) do
            if c:IsA("Folder") or c:IsA("Model") then

                local ok = false
                pcall_(function()
                    for _, d in ipairs_(c:GetDescendants()) do
                        if tostring_(d.ClassName) == "ProximityPrompt" then ok = true; break end
                    end
                end)
                if ok then out[#out + 1] = tostring_(c.Name) end
            end
        end
    end)
    return out
end

MG.timerSec = function()

    local now = tick_()
    if MG.tsT and (now - MG.tsT) < 1.0 then return MG.tsVal end
    MG.tsT = now
    MG.tsVal = nil
    if not myTycoon then return nil end
    local pur; pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
    local mg = pur and pur:FindFirstChild("Minigames")
    if not mg then return nil end
    MG.lblSeen = MG.lblSeen or {}
    local rem, ready
    pcall_(function()
        for _, c in ipairs_(mg:GetChildren()) do
            local nm = tostring_(c.Name)

            if MG.enabled[nm] ~= false and nm:lower():find("minigame") and not nm:lower():find("trade") then
                for _, d in ipairs_(c:GetDescendants()) do
                    if tostring_(d.ClassName) == "TextLabel" then
                        local t; pcall_(function() t = d.Text end)
                        t = tostring_(t or "")

                        if (t:upper():gsub("[%s%p]", "")) == "READY" then
                            if MG.shown(d) then ready = true end
                        else
                            local hh, mm, ss = t:match("^%s*(%d+):(%d%d):(%d%d)%s*$")
                            if hh then
                                local r = tonumber_(hh) * 3600 + tonumber_(mm) * 60 + tonumber_(ss)

                                if r > 0 and r < 2 * 3600 then

                                    local k; pcall_(function() k = d:GetFullName() end)
                                    k = k or nm
                                    local rec = MG.lblSeen[k]
                                    if not rec then
                                        rec = { txt = t, t = 0, seen = now }
                                        MG.lblSeen[k] = rec
                                    elseif rec.txt ~= t then
                                        rec.txt = t

                                        rec.t = (now - rec.seen) <= 2.5 and now or 0
                                    end
                                    rec.seen = now
                                    if (now - rec.t) < 3 then rem = r end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    if not rem and ready then
        MG.miniEnd = now
    end
    MG.tsVal = rem
    return rem
end

MG.name = function()
    if MG.nameVal and (tick_() - (MG.nameT or 0)) < 5 then return MG.nameVal end
    MG.nameT = tick_()
    local out
    if myTycoon then
        local pur; pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
        local mg = pur and pur:FindFirstChild("Minigames")
        if mg then
            pcall_(function()
                for _, c in ipairs_(mg:GetChildren()) do
                    local cn = tostring_(c.Name)

                    if MG.enabled[cn] ~= false and cn:lower():find("minigame") and not cn:lower():find("trade") then
                        for _, d in ipairs_(c:GetDescendants()) do
                            if tostring_(d.ClassName) == "ProximityPrompt" then
                                local ot; pcall_(function() ot = d.ObjectText end)
                                ot = tostring_(ot or "")
                                if ot ~= "" and ot ~= "nil" then out = ot; return end
                            end
                        end
                        out = (cn:gsub("^[Mm]inigame%s+", ""))
                        return
                    end
                end
            end)
        end
    end
    MG.nameVal = out
    return out
end
local function _standPartPos(c)
    local pos
    pcall_(function() pos = c.Position end)
    if pos then return pos end
    pcall_(function()
        for _, d in ipairs_(c:GetDescendants()) do
            if d:IsA("BasePart") then pos = d.Position; return end
        end
    end)
    if not pos then pcall_(function() if c.PrimaryPart then pos = c.PrimaryPart.Position end end) end
    return pos
end

local function _standUpgradePos(folder, nm)
    local pos
    pcall_(function()
        local n2 = folder:FindFirstChild(nm)
        local n3 = n2 and n2:FindFirstChild(nm)
        if n3 then pos = _standPartPos(n3) end
    end)
    if not pos then
        pcall_(function()
            for _, d in ipairs_(folder:GetDescendants()) do
                if tostring_(d.ClassName) == "ProximityPrompt" and tostring_(d.Name) == "Prompt" and d.Parent then
                    pos = _standPartPos(d.Parent); break
                end
            end
        end)
    end
    return pos
end

local STAND_ORDER = {"stand", "dash", "depot", "trading", "labs", "robotics", "republic", "lemonx"}
local function standRank(low)
    for i = 1, #STAND_ORDER do
        if low:find(STAND_ORDER[i], 1, true) then return i end
    end
    return 99
end
local function getStandLocations()
    local out = {}
    if not myTycoon then return out end
    local pur, loc
    pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
    pcall_(function() loc = myTycoon:FindFirstChild("Locations") end)
    if not pur then return out end
    for _, folder in ipairs_(pur:GetChildren()) do
        local nm = tostring_(folder.Name)
        local low = nm:lower()
        local rank = standRank(low)
        if rank < 99 and not low:find("ground") then

            local pos = _standUpgradePos(folder, nm)
            local lpos = nil
            if loc then
                local lc = loc:FindFirstChild(nm)
                if lc then lpos = _standPartPos(lc) end
            end
            if pos and lpos then
                local d = lpos - pos
                local m = d.Magnitude
                if m > 0.1 then
                    local step = m < 6 and m or 6
                    pos = pos + (d / m) * step
                end
            elseif not pos then
                pos = lpos
            end
            if pos then tinsert(out, {name = nm, pos = pos, rank = rank}) end
        end
    end
    table.sort(out, function(a, b) return a.rank < b.rank end)
    return out
end

local function getBuyLocations()
    local out = {}
    if not myTycoon then return out end
    local pur, loc
    pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
    pcall_(function() loc = myTycoon:FindFirstChild("Locations") end)
    if not pur then return out end
    for _, cat in ipairs_(pur:GetChildren()) do
        local nm = tostring_(cat.Name)
        local pos
        if loc then
            local lc = loc:FindFirstChild(nm)
            if lc then pos = _standPartPos(lc) end
        end
        if not pos then pcall_(function() pos = _standPartPos(cat) end) end
        if pos then out[#out + 1] = { name = nm, pos = pos } end
    end
    return out
end

if Lib then
    Lib:SetTheme({
        accentA = C3rgb(252, 211, 49),   -- lemon yellow
        accentB = C3rgb(240, 165, 25),   -- golden amber
        bg      = C3rgb(18, 17, 13),     -- warm dark
        sidebar = C3rgb(18, 17, 13),
    })
    local window = Lib:CreateWindow({
        title = "Sell Lemons",
        subtitle = "auto",
        size = Vec2(580, 542),
        badge = "v22",
        menuKey = "q",
        gameInput = "always",   -- never grab game input: menu is click-through, so a VM Restart can't leave the game frozen
        logo = "https://cdn.jsdelivr.net/gh/twitter/twemoji@14.0.2/assets/72x72/1f34b.png",
    })
    UIRef.win = window

    local tab1 = window:Tab("Main", "gauge")

    -- one card with the main toggles (hotkeys 1-5); each chooser sits right under its toggle
    local farm = tab1:Section("Farming", "Left", "auto-farms, stands & rebirth")
    UIRef.t.AutoBuy = farm:Toggle("Auto Buy", false, function(val)
        autoBuyActive = val
        if val then pcall_(function() myTycoon = findMyTycoon(); buildButtonsCache(); localQueue = {}; queueIndex = 1 end)
        else pcall_(function() localQueue = {}; queueIndex = 1 end) end
        pcall_(function() if Lib and Lib.SetPerformance then Lib:SetPerformance(val) end end)   -- lite GUI (60fps, no glow) while auto-buying frees the single Lua thread -> no freeze/lag
        S.saveState()
    end):AddKeybind("1", "Toggle")
    UIRef.t.SkipDecor = farm:Toggle("Skip Decor", false, function(val)
        skipDecorActive = val; S.saveState()
    end):Tooltip("skip decoration buttons while auto-buying")

    farm:Divider()
    UIRef.t.LemonFarm = farm:Toggle("Lemon Farm", false, function(val)
        lemonFarmActive = val; S.saveState()
    end):AddKeybind("2", "Toggle")
    UIRef.t.AfkDelay = farm:Slider("AFK delay", CFG.afkDelay or 6, 1, 1, 30, "s", function(val)
        local s = mfloor(tonumber_(val) or 6); if s < 1 then s = 1 elseif s > 30 then s = 30 end; CFG.afkDelay = s
    end)

    farm:Divider()
    UIRef.t.AutoStand = farm:Toggle("Auto Stand", false, function(val)
        autoStandActive = val; S.saveState()
    end):AddKeybind("3", "Toggle")
    pcall_(function()   -- stand chooser, right under Auto Stand
        local listed = {}
        for _, s in ipairs_(getStandLocations()) do listed[#listed + 1] = s.name end
        if #listed == 0 then listed = STAND_NAMES end
        local standSel = {}
        for _, nm in ipairs_(listed) do
            if standEnabled[nm] == nil then standEnabled[nm] = true end
            if standEnabled[nm] ~= false then standSel[#standSel + 1] = nm end
        end
        UIRef.standDd = farm:Dropdown("Active stands", standSel, listed, true, function(v)
            local set = {}
            for _, nm in ipairs_(v) do set[nm] = true end
            for _, nm in ipairs_(listed) do standEnabled[nm] = set[nm] == true end
            S.saveState()
        end, "which stands the bot upgrades", true)
    end)
    UIRef.t.CashFarm = farm:Toggle("Cash Bags Farm", true, function(val)
        cashFarmActive = val; S.saveState()
    end):AddKeybind("4", "Toggle")

    farm:Divider()
    UIRef.t.AutoRebirth = farm:Toggle("Auto Rebirth", false, function(val)
        autoRebirthActive = val
        if val then
            RB.lastPeek = tick_() - ((RB.peekEvery or 60) - 10)
        else
            RB.go = false; RB.wantSlot = false; RB.status = "off"; RB.goSince = 0; RB.openedAt = nil; RB.pct = nil; RB.lastInfo = nil; RB.goN = 0; RB.needCur = false
        end
    end):AddKeybind("5", "Toggle")
    RB.thBoost = 1
    farm:Slider("Rebirth at", 25, 0.001, 0.001, 10000, "%", function(val)
        local m = tonumber_(val) or 25; if m < 0.001 then m = 0.001 elseif m > 10000 then m = 10000 end; RB.gainPct = m
    end)
    UIRef.t.AutoEvolve = farm:Toggle("Auto Evolve", false, function(val)
        autoEvolveActive = val; S.saveState()
    end):AddKeybind("7", "Toggle"):Tooltip("auto-presses Evolve when progress hits 100%")

    local autoR = tab1:Section("Automation", "Right", "deals, minigames, vine")
    UIRef.t.AutoDeal = autoR:Toggle("Auto Deal", true, function(val)
        autoDealActive = val; S.saveState()
    end)
    UIRef.t.AutoMini = autoR:Toggle("Auto Minigame", false, function(val)
        MG.active = val; if not val then MG.sessPost = 0 end; S.saveState()
    end)
    pcall_(function()   -- minigame chooser, right under Auto Minigame
        local mgList = MG.list()
        local realMg = {}
        for _, nm in ipairs_(mgList) do
            if nm:lower():find("trade") then
                MG.enabled[nm] = false
            else
                if MG.enabled[nm] == nil then MG.enabled[nm] = true end
                realMg[#realMg + 1] = nm
            end
        end
        if #realMg > 0 then
            local mgSel = {}
            for _, nm in ipairs_(realMg) do if MG.enabled[nm] ~= false then mgSel[#mgSel + 1] = nm end end
            UIRef.miniDd = autoR:Dropdown("Active minigames", mgSel, realMg, true, function(v)
                local set = {}
                for _, nm in ipairs_(v) do set[nm] = true end
                for _, nm in ipairs_(realMg) do MG.enabled[nm] = set[nm] == true end
                S.saveState()
            end, "which minigames the bot plays", true)
        end
    end)
    autoR:Button("Cash Vine TP", function() CFG.vineGo = true end)
    autoR:Divider("Visuals")
    UIRef.t.KeyEsp = autoR:Toggle("Key / Lever ESP", false, function(val)
        keyEspActive = val; S.saveState()
    end)

    local sysR = tab1:Section("System", "Right", "performance & stop-all")
    UIRef.t.FpsSave = sysR:Toggle("FPS Save", false, function(val)
        CFG.slow = val and true or false
        if val then FX.apply() else FX.restore() end
    end):Tooltip("strip graphics for weak PCs")
    UIRef.t.StopAll = sysR:Toggle("Stop All", false, function(val)
        if val then
            S.stopSavedMini = MG.active; MG.active = false
            pcall_(function() if UIRef.t.AutoMini then UIRef.t.AutoMini:Set(false) end end)
            stopAll(true)
        else
            if S.stopSavedMini ~= nil then MG.active = S.stopSavedMini; S.stopSavedMini = nil end
            pcall_(function() if UIRef.t.AutoMini then UIRef.t.AutoMini:Set(MG.active) end end)
            stopAll(false)
        end
    end):AddKeybind("6", "Toggle"):SetRisk()

    local tabS = window:Tab("Session", "activity")
    local stOv = tabS:Section("Overview", "Left", "live stats this session")
    stOv:Label(function() return "Runtime:  " .. fmtClock(tick_() - statsStartT) end)
    stOv:Label(function() return "Cash:  " .. (readCashText() or "...") end)
    local stCol = tabS:Section("Collected", "Left", "auto-farm totals")
    stCol:Label(function() return "Buttons bought:  " .. fmtN(STATS.bought) end)
    stCol:Label(function() return "Lemons collected:  " .. fmtN(STATS.lemons) end)
    stCol:Label(function() return "Cash bags:  " .. fmtN(STATS.bags) end)
    local stAuto = tabS:Section("Automation", "Right", "deals & rebirths")
    stAuto:Label(function() return "Deals accepted:  " .. fmtN(STATS.deals) end)
    stAuto:Label(function() return "Rebirths:  " .. fmtN(STATS.rebirths) end)
    stAuto:Label(function() return "Evolves:  " .. fmtN(STATS.evolves) end)

    window:AddSettingsTab("cog")

    -- floating status HUD, built on the lib's CreateBox: Stat = "label | value" + auto status dot, Bar = rebirth %
    do
        local vx = 1920; pcall_(function() vx = camera.ViewportSize.X end)
        local sbox = Lib:CreateBox({ title = "Sell Lemons", position = Vec2(vx - 306, 50), width = 288 })
        UIRef.statusBox = sbox
        for i = 1, 5 do sbox:Stat(function() return (S.slot and S.slot[i]) or "" end) end
        sbox:Bar(function()
            local gm = S.barGeom
            if not gm or (tick_() - (RB.checkStartT or 0)) < 30 then return nil end
            return gm.pct or 0
        end)
    end

    Lib:Notify("Sell Lemons", "v22  -  Q to toggle  -  by Inspecttor", 5)
    print("[Hub] INS ui loaded")
end

local function normalizeColor(c)
    local r, g, b = c.R, c.G, c.B
    if r <= 1 and g <= 1 and b <= 1 then
        r, g, b = r * 255, g * 255, b * 255
    end
    return r, g, b
end

local function isGreyedOut(v)
    local ok, color3 = pcall_(function() return v.Color end)
    if not ok or not color3 then return false end
    local r, g, b = normalizeColor(color3)

    return mabs(r - g) < 14 and mabs(g - b) < 14 and mabs(r - b) < 14 and mabs(r - 102) <= 22
end

local decorFolderMemo = {}
local function _isDecorBtn(btn, key)
    if not btn then return false end
    key = key or getButtonKey(btn)
    local inDecor = key and decorFolderMemo[key]
    if inDecor == nil then
        inDecor = false
        pcall_(function()
            local cur, prev = btn.Parent, nil
            for _ = 1, 8 do
                if not cur then break end
                local nm = tostring_(cur.Name)
                if nm == "Buttons" then
                    if prev == "Decor" then inDecor = true end
                    return
                end
                prev = nm
                cur = cur.Parent
            end
        end)
        if key then decorFolderMemo[key] = inDecor end
    end
    if inDecor then return true end
    local red = false
    pcall_(function()
        local c = btn.Color
        if c then
            local r, g, b = normalizeColor(c)
            if r >= 140 and g <= 75 and b <= 75 then red = true end
        end
    end)
    return red
end

local buttonsCacheReady = true
local _acache = { t = 0, list = nil }

local function buildButtonsCache()

    _acache.list = nil; _acache.deadT = nil; _acache.liveT = nil
    if not myTycoon or not myTycoon.Parent then myTycoon = findMyTycoon() or myTycoon end
    buttonsCacheReady = true
end
buildButtonsCache()

local function getButtonsRealTime()
    local now = tick_()
    if _acache.list and (now - _acache.t) < 0.12 then return _acache.list end
    local temp = {}
    local t = myTycoon
    if not t or not t.Parent then t = findMyTycoon(); if t then myTycoon = t end end
    if t then
        pcall_(function()
            local purchases = t:FindFirstChild("Purchases")
            if not purchases then return end
            for _, cat in ipairs_(purchases:GetChildren()) do
                local bf = cat:FindFirstChild("Buttons")
                if bf then
                    for _, model in ipairs_(bf:GetChildren()) do
                        local btn = model:FindFirstChild("Button")
                        if btn and btn:IsA("BasePart") and btn.Parent then tinsert(temp, btn) end
                        for _, child in ipairs_(model:GetDescendants()) do
                            if child.Name == "Button" and child ~= btn and child:IsA("BasePart") and child.Parent then
                                tinsert(temp, child)
                            end
                        end
                    end
                end
            end
        end)
    end
    _acache.list = temp; _acache.t = now
    return temp
end

local lemonTrees       = {}
local lemonTreeSet     = {}
local lemonTreeCacheReady = false

local function _removeTree(folder)
    if not lemonTreeSet[folder] then return end
    lemonTreeSet[folder] = nil
    for i = #lemonTrees, 1, -1 do
        if lemonTrees[i] == folder then
            table.remove(lemonTrees, i)
            break
        end
    end
end

local function addLemonTree(tree)
    if not tree or lemonTreeSet[tree] then return end
    lemonTreeSet[tree] = true
    tinsert(lemonTrees, tree)
    pcall_(function()
        tree.AncestryChanged:Connect(function(_, parent)
            if not parent then _removeTree(tree) end
        end)
    end)
end

local function hookTreesFolder(treesFolder)
    if not treesFolder then return end
    for _, t in ipairs_(treesFolder:GetChildren()) do
        addLemonTree(t)
    end
    pcall_(function()
        treesFolder.ChildAdded:Connect(function(newTree)
            addLemonTree(newTree)
        end)
    end)
end

local function hookTycoonForTrees(tycoon)
    if not tycoon or not tycoon.Name then return end
    if not tycoon.Name:find("Tycoon") then return end
    local constant = tycoon:FindFirstChild("Constant")
    if constant then
        local trees = constant:FindFirstChild("Trees")
        if trees then hookTreesFolder(trees) end
        pcall_(function()
            constant.ChildAdded:Connect(function(child)
                if child.Name == "Trees" then hookTreesFolder(child) end
            end)
        end)
    end
    pcall_(function()
        tycoon.ChildAdded:Connect(function(child)
            if child.Name == "Constant" then
                local trees = child:FindFirstChild("Trees")
                if trees then hookTreesFolder(trees) end
                pcall_(function()
                    child.ChildAdded:Connect(function(c2)
                        if c2.Name == "Trees" then hookTreesFolder(c2) end
                    end)
                end)
            end
        end)
    end)
end

local function buildLemonTreeCache()
    lemonTrees, lemonTreeSet = {}, {}

    local rootLT = Workspace:FindFirstChild("LemonTree")
    if rootLT then addLemonTree(rootLT) end
    pcall_(function()
        Workspace.ChildAdded:Connect(function(child)
            if child.Name == "LemonTree" then
                addLemonTree(child)
            elseif child.Name and child.Name:find("Tycoon") then
                hookTycoonForTrees(child)
            end
        end)
    end)

    for _, tycoon in ipairs_(Workspace:GetChildren()) do
        hookTycoonForTrees(tycoon)
    end

    lemonTreeCacheReady = true
end

buildLemonTreeCache()

local LEMON_MAX_FRUIT_HEIGHT = 14

local function getLemonsFast()
    if not lemonTreeCacheReady then buildLemonTreeCache() end
    local temp = {}
    local trees = lemonTrees
    for ti = 1, #trees do
        local tree = trees[ti]
        if tree and tree.Parent then
            for _, fruit in ipairs_(tree:GetChildren()) do
                if fruit.Name == "Fruit" then
                    local clickPart = fruit:FindFirstChild("ClickPart")
                    if clickPart and clickPart:IsA("BasePart")
                       and clickPart.Position.Y <= LEMON_MAX_FRUIT_HEIGHT then
                        tinsert(temp, clickPart)
                    end
                end
            end
        end
    end
    return temp
end

local _pGui
local function getPlayerGui()
    local pg = _pGui
    if not pg or not pg.Parent then
        pcall_(function() pg = player:FindFirstChildOfClass("PlayerGui") end)
        _pGui = pg
    end
    return pg
end

local _cashFolder
local function getCashDropsFast()
    local folder = _cashFolder
    if not folder or not folder.Parent then
        folder = Workspace:FindFirstChild("CashDrops")
        _cashFolder = folder
    end
    if not folder then return {} end
    local temp = {}
    for _, v in ipairs_(folder:GetDescendants()) do
        if v.Name == "TouchInterest" then
            local parent = v.Parent
            if parent and parent:IsA("BasePart") then
                tinsert(temp, parent)
            end
        end
    end
    return temp
end

local lastButtonCount = 0
local lastLemonCount  = 0
local lastCashCount   = 0

local LSM = { mode = "classic", annAfk = false, annBuy = false }

pcall_(function()
    player.CharacterAdded:Connect(function()
        LSM.zoomedIn = false
        pcall_(function() camera = Workspace.CurrentCamera end)
    end)
end)

local ANTIGRAV_VEL = Vec3(0, 2, 0)
RunService.RenderStepped:Connect(function()
    if not ScriptActive then return end
    if lemonFarmActive and LSM.mode ~= "cd" and LSM.mode ~= "sig" and (tick_() - (S.lastUser or 0)) >= CFG.afkDelay then
        local chr = player.Character
        local hrp = chr and chr:FindFirstChild("HumanoidRootPart")
        if hrp then
            pcall_(function() hrp.AssemblyLinearVelocity = ANTIGRAV_VEL end)
        end
    end
end)

local localQueue   = {}
local queueIndex   = 1
local queueLock    = false
local totalFailed  = 0
local lastResetTime = 0

local function appendNewButtons()

    local waitT = tick_()
    while queueLock do
        if (tick_() - waitT) > 1 then queueLock = false; break end
        task_wait(0.001)
    end
    queueLock = true
    local added = 0
    pcall_(function()
        if not myTycoon or not myTycoon.Parent then return end
        local buttons = getButtonsRealTime()
        lastButtonCount = #buttons
        local existingKeys = {}
        local lq = localQueue
        for i = queueIndex, #lq do
            local it = lq[i]
            if it and it.key then existingKeys[it.key] = true end
        end
        local chr = player.Character
        local hrp = chr and chr:FindFirstChild("HumanoidRootPart")
        local hrpPos = hrp and hrp.Position or nil
        for _, v in ipairs_(buttons) do
            local key = getButtonKey(v)
            if key then
                if not existingKeys[key] and buyReady(key, v) and not isGreyedOut(v) and not buyBlacklist[key]
                   and not (skipDecorActive and _isDecorBtn(v, key)) then
                    local dist = hrpPos and (v.Position - hrpPos).Magnitude or 999999
                    tinsert(lq, { btn = v, key = key, dist = dist, fails = fails })
                    added = added + 1
                end
            end
        end
    end)
    queueLock = false
    return added
end

local function allButtonsDead()
    local now = tick_()
    if _acache.deadT and (now - _acache.deadT) < 0.15 then return _acache.dead end
    local buttons = getButtonsRealTime()
    local dead = (#buttons > 0)
    for _, v in ipairs_(buttons) do
        local key = getButtonKey(v)
        if key then
            if buyReady(key, v) and not buyBlacklist[key] and not isGreyedOut(v)
               and not (skipDecorActive and _isDecorBtn(v, key)) then dead = false; break end
        end
    end
    _acache.deadT = now; _acache.dead = dead
    return dead
end

local function cleanupQueue()

    local waitT = tick_()
    while queueLock do
        if (tick_() - waitT) > 1 then queueLock = false; break end
        task_wait(0.001)
    end
    queueLock = true
    pcall_(function()
        if queueIndex > 20 then
            local newQueue = {}
            local lq = localQueue
            local n = 0
            for i = queueIndex, #lq do n = n + 1; newQueue[n] = lq[i] end
            localQueue = newQueue
            queueIndex = 1
        end
    end)
    queueLock = false
end

local STAND_KEY            = 0x45
local STAND_CYCLE_PAUSE    = 0.02
local STAND_TP_Y_OFFSET    = 3
local STAND_LOOP_DELAY     = 0.1

local function _tpHrpTo(pos)

    if autoStandActive then LSM.standBusyT = tick_() end
    local character = player.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    local ok = pcall_(function()
        hrp.CFrame = CF(pos.X, pos.Y + STAND_TP_Y_OFFSET, pos.Z)
    end)
    return ok
end

local function _windowFocused()
    if type(isrbxactive) ~= "function" then return true end
    local ok, r = pcall_(isrbxactive)
    if not ok then return true end
    return r ~= false
end

local function _anyLiveButtons()
    local now = tick_()
    if _acache.liveT and (now - _acache.liveT) < 0.15 then return _acache.live end
    local buttons = getButtonsRealTime()
    local live = false
    for _, v in ipairs_(buttons) do
        local key = getButtonKey(v)
        if key then
            -- "work" = a button we could actually buy now: live, not greyed/unaffordable, not on cooldown.
            -- (cooldown-aware so the lemon farm doesn't keep pausing for a button auto-buy has shelved)
            if not (buyCooldown[v] and tick_() < buyCooldown[v]) and not isGreyedOut(v)
               and not (skipDecorActive and _isDecorBtn(v, key)) then live = true; break end
        end
    end
    _acache.liveT = now; _acache.live = live
    return live
end

local function _anyBuyableNowButtons()

    if (tick_() % 25) < 5 then return false end
    return _anyLiveButtons()
end
local function _autobuyHasWork() return _anyLiveButtons() end  -- stateless: live scan, not the (now-unused) queue
local STAND_E_SPAM_DURATION = 3.0

local function runLocationsPass(firstRun)
    local locs = getStandLocations()
    if #locs == 0 then
        if firstRun then print("[Stand] Locations пуст (тайкун не прогружен?)") end
        return "done"
    end
    if firstRun then
        for _, s in ipairs_(locs) do
            print("[Stand] " .. s.name .. (standEnabled[s.name] == false and "  OFF" or "  ON"))
        end
    end

    LSM.standBusyT = tick_()
    LSM.standPassT = tick_()

    LSM.zoom(-1)

    local tilted = LSM.tiltDown()
    local tapped = 0
    for _, s in ipairs_(locs) do
        if not ScriptActive or not autoStandActive then return "off" end
        LSM.standPassT = tick_()
        if standEnabled[s.name] ~= false then
            if autoBuyActive and _anyBuyableNowButtons() then return "yield" end
            if _tpHrpTo(s.pos) then
                task_wait(0.05)

                local eye, target
                if not tilted then
                    pcall_(function()
                        local h = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                        if h then
                            local p = h.Position
                            eye = p + Vec3(0, 10, 16)
                            target = p + Vec3(0, -1, 2)
                        end
                    end)
                end
                _standIsTapping = true
                local t0 = tick_()
                while autoStandActive and (tick_() - t0) < STAND_E_SPAM_DURATION do
                    LSM.lastBot = tick_()
                    if not tilted and eye then pcall_(function() camera.lookAt(eye, target) end) end
                    if _windowFocused() then keypress(STAND_KEY); keyrelease(STAND_KEY) end
                    task_wait(0.05)
                end
                _standIsTapping = false
                tapped = tapped + 1
            end
            task_wait(STAND_CYCLE_PAUSE)
        end
    end

    if firstRun then print("[Stand] pass end, tapped=" .. tapped) end
    return "done"
end

-- ============================================================================
-- STATELESS auto-buy. Every pass re-scans the LIVE buttons and TP-touches any
-- that is buyable right now. There is no persistent queue / blacklist / backoff
-- / decor-memo, so nothing can wedge across passes - a button that was skipped
-- (unaffordable, busy, far) is re-evaluated from scratch next pass. This removes
-- the whole class of "one button stays skipped until a full restart" bugs that
-- the old queue + two-worker + blacklist machinery could produce.
-- ============================================================================

-- live decor test (no memo: a stale decorFolderMemo key was a permanent-skip risk)
local function isDecorLive(btn)
    if not btn then return false end
    local inDecor = false
    pcall_(function()
        local cur, prev = btn.Parent, nil
        for _ = 1, 8 do
            if not cur then break end
            local nm = tostring_(cur.Name)
            if nm == "Buttons" then if prev == "Decor" then inDecor = true end return end
            prev = nm; cur = cur.Parent
        end
    end)
    if inDecor then return true end
    local red = false
    pcall_(function()
        local c = btn.Color
        if c then local r, g, b = normalizeColor(c); if r >= 140 and g <= 75 and b <= 75 then red = true end end
    end)
    return red
end

-- TP onto the button so the character touches it; poll until it disappears.
-- Touch -> server removes the button -> replicates back = a network round-trip;
-- the deadline is generous so a slow PC / high ping still registers before timeout.
local function tpTouchBuy(hrp, btn)
    local pos = btn.Position
    local px, py, pz = pos.X, pos.Y, pos.Z
    LSM.lastBot = tick_(); LSM.buySweepT = tick_()
    pcall_(function() hrp.CFrame = CF(px, py + 2.5, pz) end)
    task_wait(0.03)
    local deadline = tick_() + 0.5
    repeat
        pcall_(function() hrp.CFrame = CF(px, py + 0.8, pz) end)
        LSM.lastBot = tick_(); LSM.buySweepT = tick_()
        task_wait(0.03)
        local gone = false
        pcall_(function() gone = not (btn and btn.Parent and btn:IsDescendantOf(myTycoon)) end)
        if gone then return true end
    until tick_() >= deadline
    return false
end

_wrap("autobuy-worker", function()
    while ScriptActive do
        syncFromUI()
        if not autoBuyActive then task_wait(0.1); continue end
        if _standIsTapping or (tick_() - (RB.busyT or 0)) < 4 or MG.lemBusy()
           or (autoRebirthActive and RB.wantSlot) then task_wait(0.05); continue end

        local character = player.Character
        local hrp = character and character:FindFirstChild("HumanoidRootPart")
        if not hrp then task_wait(0.1); continue end

        local buttons = getButtonsRealTime()   -- self-finds myTycoon, cached 0.12s; always the LIVE set
        lastButtonCount = #buttons
        local didBuy = false
        for _, btn in ipairs_(buttons) do
            if not autoBuyActive then break end
            -- yield to stand / rebirth / minigame mid-pass so auto-buy doesn't fight them for the character
            if _standIsTapping or (autoRebirthActive and RB.wantSlot) or MG.lemBusy() then break end
            local cd = buyCooldown[btn]
            if cd and tick_() < cd then continue end   -- couldn't buy it recently (e.g. not enough cash yet) - skip for now
            local live = false
            pcall_(function() live = btn and btn.Parent and (not myTycoon or btn:IsDescendantOf(myTycoon)) end)
            if live and not isGreyedOut(btn) and not (skipDecorActive and isDecorLive(btn)) then
                local key = getButtonKey(btn)
                if tpTouchBuy(hrp, btn) then
                    buyCooldown[btn] = nil
                    didBuy = true
                    STATS.bought = STATS.bought + 1
                    print("[Buy] " .. tostring(key) .. " | Total: " .. STATS.bought)
                else
                    buyCooldown[btn] = tick_() + BUY_RETRY   -- can't buy now; retry in ~2s once cash builds
                    totalFailed = totalFailed + 1
                end
            end
        end
        task_wait(didBuy and 0.02 or 0.15)
    end
end)

_wrap("autobuy-coord", function()
    -- keep myTycoon fresh during idle/closed-menu periods (getButtonsRealTime also self-heals it)
    while ScriptActive do
        if not myTycoon or not myTycoon.Parent then myTycoon = findMyTycoon() or myTycoon end
        task_wait(0.5)
    end
end)

local lemonFailCount  = {}
local LEMON_MAX_FAILS = 3
local LEMON_MAX_PASSES = 6

local LEMON_HITBOX_ENABLED = true
local LEMON_HITBOX_SIZE    = Vec3(50, 50, 50)

local LEMON_TP_WAIT      = 0.008
local LEMON_CAM_WAIT     = 0.008
local LEMON_CLICK_GAP    = 0.005
local LEMON_POST_WAIT    = 0
local LEMON_PASS_WAIT    = 0.04
local LEMON_DOUBLE_CLICK = true

local function lemonKey(v)
    local pos = v.Position
    return mfloor(pos.X + 0.5) .. "," .. mfloor(pos.Y + 0.5) .. "," .. mfloor(pos.Z + 0.5)
end

local function findTreeOf(clickPart)
    local n = clickPart.Parent
    if n then return n.Parent end
    return nil
end

local function disableTreeCanQuery(tree, excludeSet)
    local modified, n = {}, 0
    local parts
    pcall_(function() parts = tree:GetDescendants() end)
    if not parts then return modified, 0 end
    local i = 1
    while i <= #parts do
        local ok = pcall_(function()
            while i <= #parts do
                local part = parts[i]
                if part:IsA("BasePart") and not excludeSet[part] and part.CanQuery then
                    part.CanQuery = false
                    n = n + 1
                    modified[n] = part
                end
                i = i + 1
            end
        end)
        if not ok then i = i + 1 end
    end
    return modified, n
end

local function restoreTreeCanQuery(modified, n)
    local i = 1
    while i <= n do
        local ok = pcall_(function()
            while i <= n do
                modified[i].CanQuery = true
                i = i + 1
            end
        end)
        if not ok then i = i + 1 end
    end
end

function LSM.gone(v)
    return not (v and v.Parent and v:IsDescendantOf(Workspace))
end
function LSM.findCD(v)
    local cd
    pcall_(function() cd = v:FindFirstChildOfClass("ClickDetector") end)
    if cd then return cd end
    pcall_(function()
        local par = v.Parent
        if par then
            for _, d in ipairs_(par:GetDescendants()) do
                if d:IsA("ClickDetector") then cd = d; break end
            end
        end
    end)
    return cd
end
function LSM.silent(v)
    local cd = LSM.findCD(v)
    if not cd then return false end
    if (LSM.mode == nil or LSM.mode == "cd") and type(fireclickdetector) == "function" then
        local ok = pcall_(fireclickdetector, cd)
        if ok then
            task_wait(0.12)
            if LSM.gone(v) then
                if LSM.mode == nil then
                    LSM.mode = "cd"
                    print("[Lemon] SILENT: fireclickdetector — без ТП, камеры и мыши")
                end
                return true
            end
        end
    end
    if (LSM.mode == nil or LSM.mode == "sig") and type(firesignal) == "function" then
        local ok = pcall_(function() firesignal(cd.MouseClick, player) end)
        if ok then
            task_wait(0.12)
            if LSM.gone(v) then
                if LSM.mode == nil then
                    LSM.mode = "sig"
                    print("[Lemon] SILENT: firesignal MouseClick — без ТП, камеры и мыши")
                end
                return true
            end
        end
    end
    return false
end
function LSM.touch(v, hrp)
    if not hrp then return false end
    local vp = v.Position
    pcall_(function() hrp.CFrame = CF(vp.X, vp.Y, vp.Z) end)
    task_wait(0.12)
    if LSM.gone(v) then
        if LSM.mode == nil then
            LSM.mode = "touch"
            print("[Lemon] режим TOUCH: ТП в фрукт, камера и мышь свободны")
        end
        return true
    end
    return false
end

function LSM.clickAt(v)
    local sp, on
    local okW = pcall_(function() sp, on = WorldToScreen(v.Position) end)
    if not okW or not on or not sp then return false end
    local ox, oy = S.mx, S.my
    mousemoveabs(mfloor(sp.X), mfloor(sp.Y))
    mouse1click()
    if LEMON_DOUBLE_CLICK then
        task_wait(LEMON_CLICK_GAP)
        mouse1click()
    end
    if ox and oy and ox > 0 then
        pcall_(function() mousemoveabs(mfloor(ox), mfloor(oy)) end)
    end
    return true
end

function LSM.zoom(dir)
    if LSM.mode == "cd" or LSM.mode == "sig" then return end
    if type(mousescroll) ~= "function" then return end

    if not _windowFocused() then return end

    LSM.zoomGen = (LSM.zoomGen or 0) + 1
    local gen = LSM.zoomGen
    LSM.zoomedIn = dir > 0
    for _ = 1, CFG.zoomTicks do
        if LSM.zoomGen ~= gen then return end
        LSM.lastBot = tick_()
        pcall_(mousescroll, CFG.zoomStep * dir)
        task_wait(0.02)
    end
end

local function _camFirstPerson(hrp)
    if not hrp then return false end
    local ok, d = pcall_(function()
        if camera and camera.Position then
            return (camera.Position - hrp.Position).Magnitude
        end
        return nil
    end)
    if not ok or type(d) ~= "number" then return nil end
    return d < (LSM.FP_DIST or 6)
end
LSM.FP_DIST = 6

function LSM.tiltDown()
    if not _windowFocused() then return false end
    if type(mouse2press) ~= "function" or type(mouse2release) ~= "function"
       or type(mousemoverel) ~= "function" then return false end
    local ok = false
    pcall_(function()
        LSM.lastBot = tick_()
        mouse2press()
        for _ = 1, 6 do
            mousemoverel(0, 250)
            LSM.lastBot = tick_()
            task_wait(0.02)
        end
        mouse2release()
        ok = true
    end)
    pcall_(function() mouse2release() end)
    return ok
end

function LSM.returnHome()
    local a = LSM.anchor
    LSM.anchor = nil
    if a then
        pcall_(function()
            local chr = player.Character
            local h = chr and chr:FindFirstChild("HumanoidRootPart")
            if h then
                h.CFrame = CF(a.X, a.Y + 1, a.Z)
                h.AssemblyLinearVelocity = Vec3(0, 0, 0)
            end
        end)
    end

    LSM.zoom(-1)
    LSM.lastBot = tick_()
    if type(mousescroll) == "function" and _windowFocused() then
        pcall_(function()
            for _ = 1, 12 do mousescroll(-CFG.zoomStep); task_wait(0.012) end
        end)
    end
    if a and LSM.anchorCam then
        pcall_(function()
            camera.lookAt(a + LSM.anchorCam, a)
        end)
    end
    LSM.anchorCam = nil
    if a then print("[Lemon] returned to your spot") end
end

local function processLemon(v, hrp)
    if not v or not v:IsDescendantOf(Workspace) then return false end

    if (tick_() - (S.lastUser or 0)) < CFG.afkDelay then return false end

    if not _windowFocused() then return false end
    if (autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4) or (tick_() - (RB.busyT or 0)) < 4 or MG.lemBusy() or (tick_() - (LSM.buySweepT or 0)) < 4 then return false end

    if not LSM.zoomedIn then return false end

    if _camFirstPerson(hrp) == false then LSM.zoomedIn = false; return false end

    local origSize, origTransp, origCanColl = nil, nil, nil
    local hitboxApplied = false
    if LEMON_HITBOX_ENABLED then
        pcall_(function()
            origSize    = v.Size
            origTransp  = v.Transparency
            origCanColl = v.CanCollide
            v.CanCollide   = false
            v.Transparency = 1
            v.Size         = LEMON_HITBOX_SIZE
            hitboxApplied  = true
        end)
    end

    local vp = v.Position
    local tpX, tpY, tpZ = vp.X, vp.Y - 4, vp.Z

    pcall_(function()
        hrp.CFrame = CF(tpX, tpY, tpZ)
        task_wait(LEMON_TP_WAIT)

        LSM.lastBot = tick_()
        camera.lookAt(Vec3(tpX, tpY, tpZ), vp)
        task_wait(LEMON_CAM_WAIT)
    end)

    pcall_(function()
        local vps = camera.ViewportSize
        local cx, cy = vps.X * 0.5, vps.Y * 0.5
        for _ = 1, 6 do
            if not LSM.zoomedIn then break end
            local sp, on = WorldToScreen(vp)
            if on and sp and mabs(sp.X - cx) < vps.X * 0.18 and mabs(sp.Y - cy) < vps.Y * 0.18 then
                break
            end
            LSM.lastBot = tick_()

            if on and sp and sp.X == sp.X and mabs(sp.X) < vps.X * 4 and mabs(sp.Y) < vps.Y * 4 then
                mousemoverel(mfloor((sp.X - cx) * 0.5), mfloor((sp.Y - cy) * 0.5))
            elseif on then
                mousemoverel(0, -260)
            else
                break
            end
            task_wait(0.012)
        end
    end)

    pcall_(function()
        LSM.lastBot = tick_()
        local vps = camera.ViewportSize
        mousemoveabs(mfloor(vps.X / 2), mfloor(vps.Y / 2))
        mouse1click()
        if LEMON_DOUBLE_CLICK then
            task_wait(LEMON_CLICK_GAP)
            mouse1click()
        end
    end)

    local collected = not (v and v.Parent and v:IsDescendantOf(Workspace))
    pcall_(function() if v then _lemonPending[v] = true end end)  -- count it for real in the worker once it vanishes

    if hitboxApplied and not collected then
        pcall_(function()
            if origSize    ~= nil then v.Size         = origSize    end
            if origTransp  ~= nil then v.Transparency = origTransp  end
            if origCanColl ~= nil then v.CanCollide   = origCanColl end
        end)
    end

    if LEMON_POST_WAIT > 0 then task_wait(LEMON_POST_WAIT) end
    return collected
end

local LEMON_VERIFY_WAIT       = 0.15
local LEMON_VERIFY_MAX_PASSES = 3

local function processSnapshot(snapshot, hrp)
    local count = #snapshot
    if count == 0 then return 0 end

    local groups, groupOrder = {}, {}
    for i = 1, count do
        local v = snapshot[i]
        if v and v:IsDescendantOf(Workspace) then
            local tree = findTreeOf(v) or v.Parent
            local g = groups[tree]
            if not g then
                g = {}
                groups[tree] = g
                tinsert(groupOrder, tree)
            end
            tinsert(g, v)
        end
    end

    local collectedCount = 0
    for _, tree in ipairs_(groupOrder) do
        if not lemonFarmActive then break end
        if (tick_() - (S.lastUser or 0)) < CFG.afkDelay then break end
        if autoBuyActive and not LSM.lemonSlot and _autobuyHasWork() then break end
        if (autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4) or (tick_() - (RB.busyT or 0)) < 4 or MG.lemBusy() or (tick_() - (LSM.buySweepT or 0)) < 4 then break end
        if not LSM.zoomedIn then break end
        if not _windowFocused() then break end
        local fruits = groups[tree]
        local excludeSet = {}
        for i = 1, #fruits do excludeSet[fruits[i]] = true end

        local modified, modN
        if tree and LSM.mode ~= "cd" and LSM.mode ~= "sig" then
            modified, modN = disableTreeCanQuery(tree, excludeSet)
        else
            modified, modN = {}, 0
        end

        for i = 1, #fruits do
            if not lemonFarmActive then break end
            if (tick_() - (S.lastUser or 0)) < CFG.afkDelay then break end
            if autoBuyActive and not LSM.lemonSlot and _autobuyHasWork() then break end
            if (autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4) or (tick_() - (RB.busyT or 0)) < 4 or MG.lemBusy() or (tick_() - (LSM.buySweepT or 0)) < 4 then break end
            if not LSM.zoomedIn then break end
            if not _windowFocused() then break end

            if (tick_() - (LSM.zoomInT or 0)) >= 3 and type(mousescroll) == "function" and _camFirstPerson(hrp) ~= false then
                LSM.zoomInT = tick_()
                LSM.lastBot = tick_()
                pcall_(function() for _ = 1, 8 do mousescroll(CFG.zoomStep); task_wait(0.01) end end)
            end
            local v = fruits[i]
            if v and v:IsDescendantOf(Workspace) then
                local lk    = lemonKey(v)
                local fails = lemonFailCount[lk] or 0
                if fails < LEMON_MAX_FAILS then
                    local ok = processLemon(v, hrp)
                    if ok then
                        lemonFailCount[lk] = nil
                        collectedCount = collectedCount + 1
                    else
                        lemonFailCount[lk] = fails + 1
                    end
                end
            end
        end

        if modN > 0 then restoreTreeCanQuery(modified, modN) end
    end
    return collectedCount
end

_wrap("lemon-farm", function()
    while ScriptActive do
        syncFromUI()
        local character = player.Character
        local hrp = character and character:FindFirstChild("HumanoidRootPart")

        local buyBusy = lemonFarmActive and autoBuyActive and _autobuyHasWork()
        if lemonFarmActive and LSM.annBuy ~= buyBusy then
            LSM.annBuy = buyBusy
            print(buyBusy and "[Lemon] pause: autobuy buying" or "[Lemon] autobuy done -> resume")
        end
        local afkNow = (tick_() - (S.lastUser or 0)) >= CFG.afkDelay

        if buyBusy and afkNow then
            if STATS.bought ~= LSM.lastBoughtN then
                LSM.lastBoughtN = STATS.bought
                LSM.buyProgressT = tick_()
            end
            if not LSM.buyProgressT then LSM.buyProgressT = tick_() end

            if (tick_() - LSM.buyProgressT) > CFG.buyStuck and (tick_() - (LSM.buySweepT or 0)) >= 4 then LSM.lemonSlot = true end
        else
            LSM.buyProgressT = nil
            LSM.lastBoughtN = STATS.bought
        end
        if not (lemonFarmActive and autoBuyActive) then LSM.lemonSlot = false end
        if lemonFarmActive and LSM.annAfk ~= afkNow then
            LSM.annAfk = afkNow
            if afkNow then

                if not LSM.anchor then
                    pcall_(function()
                        local chr2 = player.Character
                        local h2 = chr2 and chr2:FindFirstChild("HumanoidRootPart")
                        if h2 then
                            LSM.anchor = h2.Position
                            LSM.anchorCam = camera.Position - h2.Position
                        end
                    end)
                end

                print("[Lemon] AFK -> zoom + farm")
            else
                print("[Lemon] input detected -> back to your spot")
                LSM.returnHome()
            end
        end
        if not lemonFarmActive and LSM.annAfk then
            LSM.annAfk = false
            LSM.returnHome()
        end

        local rbBusy = (tick_() - (RB.busyT or 0)) < 4 and (tick_() - (RB.checkStartT or 0)) < 30
        local standBusy = (autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4) or rbBusy or MG.lemBusy() or (tick_() - (LSM.buySweepT or 0)) < 4

        if standBusy then LSM.wasBusy = true elseif LSM.wasBusy then LSM.wasBusy = false; LSM.zoomInT = 0 end

        if lemonFarmActive and hrp and (not buyBusy or LSM.lemonSlot == true) and not standBusy and afkNow and _windowFocused() then

            if not LSM.zoomedIn or (tick_() - (LSM.zoomInT or 0)) >= 3 then
                LSM.zoomInT = tick_()
                pcall_(function() camera = Workspace.CurrentCamera end)

                pcall_(function() if type(mouse2release) == "function" then mouse2release() end end)

                pcall_(function()
                    local vp = camera.ViewportSize
                    if vp then mousemoveabs(mfloor(vp.X / 2), mfloor(vp.Y * 0.12)) end
                end)
                LSM.zoom(1)

                local chrA = player.Character
                local hA = chrA and chrA:FindFirstChild("HumanoidRootPart")
                if _camFirstPerson(hA) == false then
                    pcall_(function()
                        local vp = camera.ViewportSize
                        if vp then mousemoveabs(mfloor(vp.X / 2), mfloor(vp.Y * 0.08)) end
                    end)
                    if type(mousescroll) == "function" and _windowFocused() then
                        pcall_(function() for _ = 1, CFG.zoomTicks do mousescroll(CFG.zoomStep); task_wait(0.02) end end)
                    end
                    local fp = _camFirstPerson(hA)
                    if fp ~= nil then LSM.zoomedIn = fp end
                end
                pcall_(function()
                    if hA then
                        camera.lookAt(hA.Position, hA.Position + Vec3(0, 12, 3))
                    end
                end)
                pcall_(function()
                    if type(mousemoverel) == "function" and _windowFocused() and _camFirstPerson(hA) ~= false then
                        for _ = 1, 6 do mousemoverel(0, -250); LSM.lastBot = tick_(); task_wait(0.02) end
                    end
                end)
            end
            lemonFailCount = {}

            local pass            = 0
            local lastSeenCount   = -1
            local sameCountStreak = 0

            while ScriptActive and lemonFarmActive and pass < LEMON_MAX_PASSES do
                pass = pass + 1
                local snapshot = getLemonsFast()
                local count    = #snapshot
                lastLemonCount = count

                if count == 0 then break end

                if count == lastSeenCount then
                    sameCountStreak = sameCountStreak + 1
                    if sameCountStreak >= 2 then break end
                else
                    sameCountStreak = 0
                    lastSeenCount = count
                end

                local chr2 = player.Character
                hrp = chr2 and chr2:FindFirstChild("HumanoidRootPart")
                if not hrp then break end

                processSnapshot(snapshot, hrp)
                -- tally lemons that actually vanished (the click's collect replicates a beat after
                -- processLemon's instant check, so we count confirmed-gone lemons here)
                for lv in pairs(_lemonPending) do
                    if not (lv and lv.Parent and lv:IsDescendantOf(Workspace)) then
                        STATS.lemons = STATS.lemons + 1; _lemonPending[lv] = nil
                    end
                end

                task_wait(LEMON_PASS_WAIT)
            end

            if lemonFarmActive then
                for vp = 1, LEMON_VERIFY_MAX_PASSES do
                    if not lemonFarmActive then break end
                    lemonFailCount = {}
                    task_wait(LEMON_VERIFY_WAIT)

                    local chr3 = player.Character
                    local hrp3 = chr3 and chr3:FindFirstChild("HumanoidRootPart")
                    if not hrp3 then break end

                    local verifySnap  = getLemonsFast()
                    local verifyCount = #verifySnap
                    lastLemonCount    = verifyCount
                    if verifyCount == 0 then break end

                    local collected = processSnapshot(verifySnap, hrp3)
                    if collected == 0 then
                        break
                    end
                end
            end

            if LSM.lemonSlot then
                LSM.lemonSlot = false
                LSM.buyProgressT = tick_()
                LSM.lastBoughtN = STATS.bought
            end
            task_wait(0.1)
        else
            task_wait(0.05)
        end
    end
end)

_wrap("cash-farm", function()
    while ScriptActive do
        syncFromUI()
        local character = player.Character
        local head = character and character:FindFirstChild("Head")

        if cashFarmActive and head then
            local snapshot = getCashDropsFast()
            local count    = #snapshot
            lastCashCount  = count

            local headPos = head.Position
            for i = 1, count do
                if not cashFarmActive then break end
                local parent = snapshot[i]
                if parent and parent.Parent then
                    pcall_(function() parent.Position = headPos end)
                    if not _bagSeen[parent] then _bagSeen[parent] = true; STATS.bags = STATS.bags + 1 end
                end
            end
            task_wait(CFG.slow and 0.6 or 0.3)
        else
            task_wait(0.2)
        end
    end
end)

local statusTx = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = false, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(236, 238, 242)})
local statusTx2 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = false, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(196, 198, 206)})
local statusTx3 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = false, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(196, 198, 206)})
local statusTx4 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = false, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(196, 198, 206)})
local statusTx5 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = false, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(196, 198, 206)})
local stUI = { lbl = {}, dot = {} }
stUI.panel = D("Square", {Size = Vec2(0, 0), Position = Vec2(0, 0), Filled = true, Thickness = 1, Corner = 10, Rounding = 10, Color = C3rgb(15, 15, 18), Transparency = 0.5, Visible = false, ZIndex = 2})
stUI.ln = D("Square", {Size = Vec2(0, 0), Position = Vec2(0, 0), Filled = false, Thickness = 1, Corner = 10, Rounding = 10, Color = C3rgb(236, 238, 242), Transparency = 0.18, Visible = false, ZIndex = 3})
stUI.title = D("Text", {Text = "SELL LEMONS", FontSize = 10, Size = 10, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(236, 238, 242), Transparency = 0.7})
for i = 1, 5 do
    stUI.lbl[i] = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = false, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(142, 144, 152)})
    stUI.dot[i] = D("Circle", {Radius = 3, NumSides = 12, Filled = true, Position = Vec2(0, 0), Color = C3rgb(255, 200, 40), Transparency = 1, Visible = false, ZIndex = 4})
end

-- status lines now feed the INS ui CreateBox (S.slot[i] = "label | value", "" hides) instead of raw Drawing
S.slot = {}
function S.stLine(valObj, i, fullTxt)
    S.slot[i] = tostring_(fullTxt)
end
function S.stHide(valObj, i)
    S.slot[i] = ""
end

local rbBarBg = D("Square", {Size = Vec2(0, 0), Position = Vec2(0, 0), Filled = true, Thickness = 1, Corner = 4, Rounding = 4, Color = C3rgb(28, 28, 33), Transparency = 0.72, Visible = false, ZIndex = 4})
local rbBarLn = D("Square", {Size = Vec2(0, 0), Position = Vec2(0, 0), Filled = false, Thickness = 1, Corner = 4, Rounding = 4, Color = C3rgb(236, 238, 242), Transparency = 0.3, Visible = false, ZIndex = 6})
local rbBarSegs = {}
for _ = 1, 12 do
    rbBarSegs[#rbBarSegs + 1] = D("Square", {Size = Vec2(0, 0), Position = Vec2(0, 0), Filled = true, Thickness = 1, Corner = 2, Rounding = 2, Color = C3rgb(236, 238, 242), Transparency = 1, Visible = false, ZIndex = 5})
end

local ESP = { keys = {
    { path = {"Map", "Sewer", "CashVine", "VineKey"},      name = "VINE KEY",     rgb = {110, 245, 180} },
    { path = {"Map", "Sewer", "SewerAlien", "UFOKey"},     name = "UFO KEY",      rgb = {170, 130, 255} },
    { path = {"Map", "Sewer", "DoorsRed",    "Lever (Red)",    "Root", "Lever"}, name = "RED LEVER",    rgb = {255, 95,  95}  },
    { path = {"Map", "Sewer", "DoorsPurple", "Lever (Purple)", "Root", "Lever"}, name = "PURPLE LEVER", rgb = {200, 120, 255} },
    { path = {"Map", "Sewer", "DoorsGreen",  "Lever (Green)",  "Root", "Lever"}, name = "GREEN LEVER",  rgb = {120, 255, 130} },
    { path = {"Map", "Sewer", "DoorsBlue",   "Lever (Blue)",   "Root", "Lever"}, name = "BLUE LEVER",   rgb = {90,  175, 255} },
} }
local _espFont = (Drawing.Fonts and (Drawing.Fonts.Monospace or Drawing.Fonts.System)) or nil
for i = 1, #ESP.keys do
    local k = ESP.keys[i]
    local col = C3rgb(k.rgb[1], k.rgb[2], k.rgb[3])
    k.glow  = D("Square", {Filled = false, Thickness = 4, Corner = 5, Rounding = 5, Size = Vec2(0, 0), Position = Vec2(0, 0), Color = col, Transparency = 0, Visible = false, ZIndex = 6})
    k.box   = D("Square", {Filled = false, Thickness = 2, Corner = 4, Rounding = 4, Size = Vec2(0, 0), Position = Vec2(0, 0), Color = col, Transparency = 0, Visible = false, ZIndex = 8})
    k.label = D("Text",   {Text = "", FontSize = 14, Size = 14, Font = _espFont, Center = true, Outline = true, OutlineColor = C3rgb(0, 0, 0), Color = col, Transparency = 0, Visible = false, ZIndex = 9})
end
local function _espHide(k)
    k.glow.Visible = false; k.box.Visible = false; k.label.Visible = false
end

local function _espGather(k)
    local ps = {}
    pcall_(function()
        local function consider(d)
            if not d then return end
            local sz; pcall_(function() sz = d.Size end)
            if sz == nil then return end
            local okv = pcall_(function() return sz.X + sz.Y + sz.Z end)
            if not okv then return end
            local tr = 0; pcall_(function() tr = d.Transparency end)
            if (tr or 0) >= 1 then return end
            ps[#ps + 1] = {p = d, hx = sz.X / 2, hy = sz.Y / 2, hz = sz.Z / 2}
        end
        consider(k.ref)
        for _, d in ipairs_(k.ref:GetDescendants()) do consider(d) end
    end)
    if #ps == 0 then
        pcall_(function() local sz = k.ref.Size; if sz then ps[1] = {p = k.ref, hx = sz.X / 2, hy = sz.Y / 2, hz = sz.Z / 2} end end)
    end
    k.parts = ps
    if DEBUG then rprint("[ESP] " .. tostring_(k.name) .. ": видимых партов=" .. #ps) end
end
function ESP.update()
    if not keyEspActive then
        for i = 1, #ESP.keys do _espHide(ESP.keys[i]) end
        return
    end
    if CFG.slow then local n = tick_(); if (n - (ESP.throt or 0)) < 0.016 then return end; ESP.throt = n end
    local vp; pcall_(function() vp = camera.ViewportSize end)
    if not vp then return end
    local chr = player.Character
    local hrp = chr and chr:FindFirstChild("HumanoidRootPart")
    local hp; pcall_(function() hp = hrp and hrp.Position end)
    for i = 1, #ESP.keys do
        local k = ESP.keys[i]
        if not (k.ref and k.ref.Parent) and (tick_() - (k.refT or 0) > 0.5) then
            k.refT = tick_()
            local cur = Workspace
            pcall_(function() for _, seg in ipairs_(k.path) do cur = cur and cur:FindFirstChild(seg) end end)
            k.ref = cur; k.parts = nil
        end
        if k.ref and not k.parts then _espGather(k) end
        if k.parts and #k.parts > 0 then
            local cpos, live = nil, 0
            pcall_(function()
                for pi = 1, #k.parts do
                    local e = k.parts[pi]
                    if e.p and e.p.Parent then live = live + 1; if not cpos then cpos = e.p.Position end end
                end
            end)
            if live == 0 then
                k.parts = nil; _espHide(k)
            else
                local csp, con; pcall_(function() csp, con = WorldToScreen(cpos) end)

                local centerOn = csp and con and csp.X >= 0 and csp.X <= vp.X and csp.Y >= 0 and csp.Y <= vp.Y
                if centerOn then
                    local minX, minY, maxX, maxY, nOn = 1e9, 1e9, -1e9, -1e9, 0
                    pcall_(function()
                        for pi = 1, #k.parts do
                            local e = k.parts[pi]
                            if e.p and e.p.Parent then
                                local pp = e.p.Position
                                for ox = -1, 1, 2 do
                                    for oy = -1, 1, 2 do
                                        for oz = -1, 1, 2 do
                                            local sp, on = WorldToScreen(Vec3(pp.X + ox * e.hx, pp.Y + oy * e.hy, pp.Z + oz * e.hz))
                                            if sp and on then
                                                nOn = nOn + 1
                                                if sp.X < minX then minX = sp.X end
                                                if sp.X > maxX then maxX = sp.X end
                                                if sp.Y < minY then minY = sp.Y end
                                                if sp.Y > maxY then maxY = sp.Y end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end)
                    if nOn > 0 and maxX > minX then

                        if minX < 0 then minX = 0 end
                        if minY < 0 then minY = 0 end
                        if maxX > vp.X then maxX = vp.X end
                        if maxY > vp.Y then maxY = vp.Y end
                        local x0, y0, x1, y1 = minX, minY, maxX, maxY
                        if x1 - x0 < 10 then local c = (x0 + x1) / 2; x0 = c - 5; x1 = c + 5 end
                        if y1 - y0 < 10 then local c = (y0 + y1) / 2; y0 = c - 5; y1 = c + 5 end
                        local w, h = x1 - x0, y1 - y0
                        local breath = 0.5 + 0.5 * msin(tick_() * 2.0)
                        k.glow.Position = Vec2(x0 - 2, y0 - 2); k.glow.Size = Vec2(w + 4, h + 4); k.glow.Transparency = 0.14 + 0.12 * breath; k.glow.Visible = true
                        k.box.Position  = Vec2(x0, y0);         k.box.Size  = Vec2(w, h);         k.box.Transparency = 1;                    k.box.Visible = true
                        local dist = hp and mfloor((cpos - hp).Magnitude) or 0
                        k.label.Text = k.name .. "   " .. dist .. "m"
                        k.label.Position = Vec2((x0 + x1) / 2, y0 - 18); k.label.Transparency = 1; k.label.Visible = true
                    else
                        _espHide(k)
                    end
                else
                    _espHide(k)
                end
            end
        else
            _espHide(k)
        end
    end
end

function LSM.findVine()
    local c = LSM.vineRef
    if c and c.Parent then return c end
    if (tick_() - (LSM.vineFindT or 0)) < 3 then return nil end
    LSM.vineFindT = tick_()
    local found
    pcall_(function()
        local map = Workspace:FindFirstChild("Map")
        local sewer = map and map:FindFirstChild("Sewer")

        if sewer then
            found = sewer:FindFirstChild("CashVine")
            if not found then
                for _, d in ipairs_(sewer:GetChildren()) do
                    local ln = tostring_(d.Name):lower()
                    if ln:find("cash") and ln:find("vine") then found = d; break end
                end
            end
            if not found then
                for _, d in ipairs_(sewer:GetChildren()) do
                    if tostring_(d.Name):lower():find("vine") then found = d; break end
                end
            end
        end

        if not found and map then
            for _, d in ipairs_(map:GetDescendants()) do
                local ln = tostring_(d.Name):lower()
                if ln:find("cash") and ln:find("vine") then found = d; break end
            end
        end
    end)
    LSM.vineRef = found
    return found
end

function LSM.findVineLabel()
    local l = LSM.vineLblRef
    if l and l.Parent then return l end
    if (tick_() - (LSM.vineScanT or 0)) < 2 then return nil end
    LSM.vineScanT = tick_()
    local cv = LSM.findVine()
    if not cv then return nil end
    local found
    pcall_(function()
        for _, d in ipairs_(cv:GetDescendants()) do
            if tostring_(d.ClassName) == "TextLabel" then
                local t; pcall_(function() t = d.Text end)
                t = tostring_(t or "")
                if t:match("^%s*%d+:%d%d:%d%d%s*$") or t:upper():find("READY") or t:upper():find("HARVEST") then
                    found = d; break
                end
            end
        end
    end)
    LSM.vineLblRef = found
    return found
end

local function pollInput()
    if not ScriptActive then return end
    local nowA = tick_()

    if (nowA - (S.pollT or 0)) < (CFG.slow and 0.06 or 0.03) then return end
    S.pollT = nowA
    local focused = _windowFocused()

    if focused then

        if not UIRef.win then
            for i = 1, 5 do
                local vk = 48 + i
                if iskeypressed(vk) then
                    if not S.keyDown[vk] then
                        S.keyDown[vk] = true
                        toggleFeature(i)
                    end
                else
                    S.keyDown[vk] = false
                end
            end
        end

        if iskeypressed(0x77) then
            if not S.keyDown[0x77] then
                S.keyDown[0x77] = true
                pcall_(function()
                    local btns = getButtonsRealTime()
                    local inQ = {}
                    for i = queueIndex, #localQueue do
                        local it = localQueue[i]; if it and it.key then inQ[it.key] = true end
                    end
                    local nBl, nG, nF, nQ, nLive = 0, 0, 0, 0, 0
                    rprint("[DUMP] ===== видимых кнопок: " .. #btns .. " | в очереди: " .. (#localQueue - queueIndex + 1) .. " =====")
                    for _, v in ipairs_(btns) do
                        local key = getButtonKey(v)
                        if key then
                            local g  = isGreyedOut(v)
                            local bl = buyBlacklist[key] and true or false
                            local f  = (buyAttempt[key] and buyAttempt[key].n) or 0
                            local q  = inQ[key] and true or false
                            local nm = "?"; pcall_(function() nm = tostring_(v.Parent and v.Parent.Name) end)
                            local reason
                            if bl then reason = "BLACKLIST(уже куплена?)"; nBl = nBl + 1
                            elseif g then reason = "grey(не по карману)"; nG = nG + 1
                            elseif f >= 2 then reason = "failed2x"; nF = nF + 1
                            elseif q then reason = "в очереди"; nQ = nQ + 1
                            else reason = "ЖИВАЯ - бот ДОЛЖЕН купить"; nLive = nLive + 1 end
                            rprint("[DUMP] " .. nm .. " @" .. key .. " | " .. reason .. " | fails=" .. f)
                        end
                    end
                    rprint("[DUMP] ИТОГ: blacklist=" .. nBl .. " grey=" .. nG .. " failed=" .. nF .. " вОчереди=" .. nQ .. " ЖИВЫХ=" .. nLive)
                end)
            end
        else
            S.keyDown[0x77] = false
        end

        local mx, my = S.pmx, S.pmy
        if mouse then pcall_(function() mx = mouse.X; my = mouse.Y end) end
        local m1 = false
        pcall_(function() m1 = ismouse1pressed() end)

        if autoBuyActive and _autobuyHasWork() then
            S.busyT = nowA
        end
        local botPhase = (lemonFarmActive and LSM.annAfk == true)
            or (nowA - (S.busyT or 0)) < 1.0
            or (nowA - (LSM.lastBot or 0)) <= 0.35
        if not botPhase then
            local moved = mabs(mx - S.pmx) + mabs(my - S.pmy)
            if moved > 3 or m1 then S.lastUser = nowA end
        end
        S.pmx, S.pmy = mx, my
        if iskeypressed(0x57) or iskeypressed(0x41) or iskeypressed(0x53) or iskeypressed(0x44) or iskeypressed(0x20) then
            S.lastUser = nowA
        end
    end

    if CFG.vineGo then   -- one-way teleport to the cash vine (button); no teleport-back
        CFG.vineGo = false
        pcall_(function()
            local chr = player.Character
            local h = chr and chr:FindFirstChild("HumanoidRootPart")
            if not h then return end
            h.CFrame = CF(39.7, -41.0, -77.5)
            h.AssemblyLinearVelocity = Vec3(0, 0, 0)
            print("[Vine] teleported to the cash vine")
        end)
    end

    if (nowA - (S.statusT or 0)) < (CFG.slow and 0.4 or 0.15) then return end
    S.statusT = nowA

    local vx = 1920
    pcall_(function() vx = camera.ViewportSize.X end)
    local vy0 = 58
    S.stX = vx - 314
    S.stY = vy0 + 16
    if lemonFarmActive then
        local txt
        if autoBuyActive and _autobuyHasWork() then
            txt = "lemon farm  |  paused: buy"
        elseif autoStandActive and (nowA - (LSM.standBusyT or 0)) < 4 then
            txt = "lemon farm  |  paused: stand"
        elseif (nowA - (RB.busyT or 0)) < 4 then
            txt = "lemon farm  |  paused: rebirth"
        else
            local idleT = nowA - (S.lastUser or 0)
            if idleT < CFG.afkDelay then
                txt = sformat("lemon farm  |  starts in %ds", mfloor(CFG.afkDelay - idleT) + 1)
            else
                txt = "lemon farm  |  FARMING (WASD stops)"
            end
        end
        S.stLine(statusTx, 1, txt)
    else
        S.stHide(statusTx, 1)
    end
    if autoStandActive then
        local txt2
        if (nowA - (LSM.standBusyT or 0)) < 4 then
            txt2 = "auto stand  |  upgrading..."
        elseif LSM.standNextT and LSM.standNextT > nowA then
            txt2 = sformat("auto stand  |  pass in %ds", mfloor(LSM.standNextT - nowA) + 1)
        else
            txt2 = "auto stand  |  ON"
        end
        S.stLine(statusTx2, 2, txt2)
    else
        S.stHide(statusTx2, 2)
    end

    local vReady, vTimer
    pcall_(function()
        local lbl = LSM.findVineLabel()
        if lbl and lbl.Parent then
            local t; pcall_(function() t = lbl.Text end)
            t = tostring_(t or "")
            local tm = t:match("^%s*(%d+:%d%d:%d%d)%s*$")
            if tm then
                vReady = false
                if t ~= LSM.vineLblLast then
                    LSM.vineLblLast = t
                    LSM.vineLblChangeT = tick_()
                end
                if (tick_() - (LSM.vineLblChangeT or 0)) < 3 then vTimer = tm end
            elseif t:upper():find("READY") or t:upper():find("HARVEST") then
                vReady = true
            end
        end
    end)
    if vReady ~= nil then
        if LSM.vineWasReady == true and vReady == false then
            CFG.vineT = tick_()
            CFG.vineNotif = false
            _saveVineReady()
            print("[Vine] collected -> 4h cooldown started")
        end
        LSM.vineWasReady = vReady
    end

    if vTimer then

        pcall_(function()
            local hh, mm, ss = vTimer:match("^(%d+):(%d%d):(%d%d)$")
            local remS = tonumber_(hh) * 3600 + tonumber_(mm) * 60 + tonumber_(ss)

            if remS > CFG.vineCd + 60 then return end
            local newT = tick_() - (CFG.vineCd - remS)
            if not CFG.vineT or mabs(newT - CFG.vineT) > 60 then
                CFG.vineT = newT
                _saveVineReady()
            end
        end)
    end

    if CFG.vineT and CFG.vineT > tick_() + 60 then
        CFG.vineT = nil
        pcall_(function()
            if type(writefile) == "function" then writefile("selllemons_vine.txt", "") end
        end)
    end

    if vReady == true then
        statusTx3.Color = C3rgb(236, 238, 242)
        if not CFG.vineNotif then
            CFG.vineNotif = true
            pcall_(function() notify("Cash Vine is READY", "Sell Lemons", 4) end)
        end
        S.stLine(statusTx3, 3, "cash vine  |  READY")
    elseif CFG.vineT then
        local rem = CFG.vineCd - (tick_() - CFG.vineT)
        local t3
        if rem > 0 then
            t3 = sformat("cash vine  |  %d:%02d:%02d", mfloor(rem / 3600), mfloor((rem % 3600) / 60), mfloor(rem % 60))
            statusTx3.Color = C3rgb(196, 198, 206)
        elseif vReady == false then
            t3 = "cash vine  |  soon..."
            statusTx3.Color = C3rgb(196, 198, 206)
        else
            t3 = "cash vine  |  READY"
            statusTx3.Color = C3rgb(236, 238, 242)
            if not CFG.vineNotif then
                CFG.vineNotif = true
                pcall_(function() notify("Cash Vine is READY", "Sell Lemons", 4) end)
            end
        end
        S.stLine(statusTx3, 3, t3)
    else
        S.stHide(statusTx3, 3)
    end

    local mgName = MG.active and MG.name() or nil   -- HUD minigame row only while Auto Minigame is enabled
    if mgName then
        local cd = MG.timerSec()
        if cd and cd > 0 then MG.miniEnd = tick_() + cd; MG.saveMiniEnd() end
        local rem = MG.miniEnd and (MG.miniEnd - tick_()) or nil
        local t4
        if rem and rem > 0 then
            t4 = sformat("%s  |  %d:%02d", mgName, mfloor(rem / 60), mfloor(rem % 60))
            statusTx4.Color = C3rgb(196, 198, 206)
            MG.miniNotif = false
        elseif not MG.miniEnd then
            t4 = mgName .. "  |  --"
            statusTx4.Color = C3rgb(196, 198, 206)
        else
            t4 = mgName .. "  |  READY"
            statusTx4.Color = C3rgb(236, 238, 242)
            if MG.active and not MG.miniNotif then
                MG.miniNotif = true
                pcall_(function() notify(mgName .. " is READY", "Sell Lemons", 4) end)
            end
        end
        S.stLine(statusTx4, 4, t4)
    else
        S.stHide(statusTx4, 4)
    end

    if autoRebirthActive then

        local txt5
        if RB.status == "idle" then
            local remP = (RB.peekEvery or 60) - (tick_() - (RB.lastPeek or 0))
            if remP < 0 then remP = 0 end
            if RB.lastInfo then
                txt5 = sformat("%s  |  %s  |  %ds", RB.thStr(), RB.lastInfo, mfloor(remP) + 1)
            else
                txt5 = sformat("%s  |  %ds", RB.thStr(), mfloor(remP) + 1)
            end
        elseif RB.status == "cooldown" then
            local remC = 30 - (tick_() - (RB.lastReb or 0))
            if remC < 0 then remC = 0 end
            txt5 = sformat("done  |  %ds", mfloor(remC) + 1)
        else
            txt5 = tostring_(RB.status or "...")
        end

        if RB.go then
            statusTx5.Color = RB.pctColor(100)
        elseif RB.pct then
            statusTx5.Color = RB.pctColor(RB.pct)
        else
            statusTx5.Color = C3rgb(196, 198, 206)
        end
        S.stLine(statusTx5, 5, "rebirth  |  " .. txt5)

        S.barGeom = { bx = S.stX + 50, by = S.stY + 1, pct = (RB.go and 100 or (RB.pct or 0)) }
        S.stY = S.stY + 16
    else
        S.stHide(statusTx5, 5)
        S.barGeom = nil
    end

end

RunService.RenderStepped:Connect(function()
    if not ScriptActive then return end
    pcall_(ESP.update)
    local ok, err = pcall_(pollInput)
    if not ok then reportErr("ui-input", err) end
end)

_wrap("auto-deal", function()
    local function btnText(b)
        local t
        pcall_(function() t = b.Text end)
        if t and t ~= "" then return tostring_(t) end
        pcall_(function()
            for _, c in ipairs_(b:GetDescendants()) do
                if tostring_(c.ClassName) == "TextLabel" then
                    t = c.Text
                    break
                end
            end
        end)
        return tostring_(t or "")
    end
    local function isReject(s)
        s = s:lower():gsub("[%s%.%!]", "")
        return s == "no" or s == "nvm" or s == "bye"
    end
    local function shownB(o)
        local cur = o
        for _ = 1, 20 do
            if not cur then return true end
            local cn = tostring_(cur.ClassName)
            if cn == "ScreenGui" then
                local en
                pcall_(function() en = cur.Enabled end)
                return en ~= false
            end
            if cn == "PlayerGui" or cn == "Player" then return true end
            local vis
            pcall_(function() vis = cur.Visible end)
            if vis == false then return false end
            cur = cur.Parent
        end
        return true
    end
    while ScriptActive do
        if autoDealActive then
            pcall_(function()
                local pg = getPlayerGui()
                if not pg then return end
                local phone = pg:FindFirstChild("Phone")
                if not phone then return end

                local phEn; pcall_(function() phEn = phone.Enabled end)
                if phEn == false then return end

                local btns, bn = {}, 0
                for _, d in ipairs_(phone:GetDescendants()) do
                    local cn = tostring_(d.ClassName)
                    if cn == "TextButton" or cn == "ImageButton" then
                        local t = btnText(d)
                        if t ~= "" and t ~= "nil" and shownB(d) then
                            bn = bn + 1
                            btns[bn] = d
                        end
                    end
                end
                if bn < 2 then return end

                local best, bestY
                for i = 1, bn do
                    local y
                    pcall_(function() y = btns[i].AbsolutePosition.Y end)
                    if y and (not bestY or y < bestY) then
                        bestY = y
                        best = btns[i]
                    end
                end
                if not best or isReject(btnText(best)) then return end

                local rmb = false
                pcall_(function() if type(ismouse2pressed) == "function" then rmb = ismouse2pressed() end end)
                if rmb or not _windowFocused() then return end

                local apos, asz
                pcall_(function() apos = best.AbsolutePosition; asz = best.AbsoluteSize end)
                if apos and asz then
                    local inset = 0
                    pcall_(function() if GuiService then inset = GuiService:GetGuiInset().Y end end)
                    local bx = mfloor(apos.X + asz.X / 2)
                    local by = mfloor(apos.Y + asz.Y / 2 + inset)
                    local ox, oy = S.mx, S.my
                    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
                    LSM.lastBot = tick_()
                    pcall_(function()
                        mousemoveabs(bx, by)
                        mouse1press()
                        mouse1release()
                        if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end
                    end)

                    task_wait(0.12)
                    if best.Parent and shownB(best) then
                        LSM.lastBot = tick_()
                        pcall_(function()
                            mousemoveabs(bx, by)
                            mouse1click()
                            if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end
                        end)
                    end
                end
                print("[Deal] accepted: " .. btnText(best))
                STATS.deals = STATS.deals + 1
                task_wait(1)
            end)
        end
        task_wait(CFG.slow and 1.2 or 0.5)
    end
end)

local _log10 = math.log10 or function(x) return math.log(x) / math.log(10) end

local function _logAdd(a, b)
    if not a then return b end
    if not b then return a end
    local hi, lo = (a > b) and a or b, (a > b) and b or a
    return hi + _log10(1 + 10 ^ (lo - hi))
end

local function _logSub(a, b)
    if not a or not b or b >= a - 1e-9 then return nil end
    local d = 1 - 10 ^ (b - a)
    if d <= 0 then return nil end
    return a + _log10(d)
end
local HUGE_EXP = {}
do
    local BASE = {[0]="thousand","million","billion","trillion","quadrillion","quintillion","sextillion","septillion","octillion","nonillion","decillion","undecillion","duodecillion","tredecillion","quattuordecillion","quindecillion","sexdecillion","septendecillion","octodecillion","novemdecillion"}
    local ROOT = {[2]="vigintillion",[3]="trigintillion",[4]="quadragintillion",[5]="quinquagintillion",[6]="sexagintillion",[7]="septuagintillion",[8]="octogintillion",[9]="nonagintillion",[10]="centillion"}
    local PREF = {[0]="",[1]="un",[2]="duo",[3]="tres",[4]="quattuor",[5]="quin",[6]="sex",[7]="septen",[8]="octo",[9]="novem"}
    for m = 0, 19 do HUGE_EXP[BASE[m]] = (m + 1) * 3 end
    for m = 20, 100 do
        local nm = (PREF[m % 10] or "") .. (ROOT[m // 10] or "")
        if nm ~= "" then HUGE_EXP[nm] = (m + 1) * 3 end
    end
end

local function parseHugeLog(s)
    if not s then return nil end
    s = tostring_(s):gsub("<[^>]*>", " ")
    local mant, suf = s:match("([%d][%d%.,]*)%s*(%a+)")
    if mant and suf then
        local e = HUGE_EXP[suf:lower()]
        if e then
            local n = tonumber_((mant:gsub(",", "")))
            if n and n > 0 then return _log10(n) + e end
        end
    end

    local num = s:match("[%d][%d%.,]*")
    if num then
        local n = tonumber_((num:gsub(",", "")))
        if n and n > 0 then return _log10(n) end
    end
    return nil
end

local HUGE_ABBR_IDX = {}
do
    local BASE = {[0]="K","M","B","T","Qd","Qn","Sx","Sp","Oc","No","Dc","Ud","Dd","Td","Qtd","Qnd","Sxd","Spd","Ocd","Nod"}
    local ROOT = {[2]="Vg",[3]="Tg",[4]="Qdg",[5]="Qng",[6]="Sxg",[7]="Spg",[8]="Ocg",[9]="Nog",[10]="Ce"}
    local PREF = {[0]="",[1]="U",[2]="D",[3]="T",[4]="Qt",[5]="Qn",[6]="Sx",[7]="Sp",[8]="Oc",[9]="No"}
    for i = 0, 19 do HUGE_ABBR_IDX[i] = BASE[i] end
    for i = 20, 100 do
        local r = ROOT[i // 10]
        if r then local p = PREF[i % 10] or ""; HUGE_ABBR_IDX[i] = (p == "") and r or (p .. r:lower()) end
    end
end

local function fmtAbbr(L)
    if not L then return "?" end
    if L < 3 then return sformat("%.0f", 10 ^ (L > 0 and L or 0)) end
    local grp = mfloor(mfloor(L) / 3)
    local ab = HUGE_ABBR_IDX[grp - 1] or ("e" .. (grp * 3))
    return sformat("%.2f", 10 ^ (L - grp * 3)) .. ab
end

function RB.node(root, p)
    local cur = root
    for seg in p:gmatch("[^/]+") do
        if not cur then return nil end
        local n; pcall_(function() n = cur:FindFirstChild(seg) end)
        cur = n
    end
    return cur
end

function RB.gui()
    local pg = getPlayerGui(); if not pg then return nil end
    local best
    pcall_(function()
        for _, c in ipairs_(pg:GetChildren()) do
            if tostring_(c.Name) == "Rebirth" then
                local alive = false
                pcall_(function()
                    local m = c:FindFirstChild("InvestorsMenu")
                    local ap = m and m.AbsolutePosition
                    if ap and type(ap.X) == "number" then alive = true end
                end)

                if alive and not best then best = c end
            end
        end
    end)
    if best then return best end
    local g; pcall_(function() g = pg:FindFirstChild("Rebirth") end)
    return g
end
function RB.text(node)
    if not node then return "" end
    local t; pcall_(function() t = node.Text end)
    return tostring_(t or "")
end

function RB.curFromAttr()
    local v
    pcall_(function()
        local t = myTycoon
        if not t or not t.Parent then t = findMyTycoon(); myTycoon = t or myTycoon end
        local vals = t and t:FindFirstChild("Values")
        local inner = vals and vals:FindFirstChild("Values")
        if inner then v = inner:GetAttribute("Investors") end
    end)
    if not RB.attrRawShown then
        RB.attrRawShown = true
        print("[Rebirth] attr Investors raw=" .. tostring_(v):sub(1, 24) .. " type=" .. type(v))
    end
    local L, Z
    if type(v) == "number" then
        if v <= 0 then Z = true else L = _log10(v) end
    elseif type(v) == "string" then

        local s = v:gsub("^%s+", ""):gsub("%s+$", "")
        if s:match("^[%d%.,]+$") then
            local n = tonumber_((s:gsub(",", "")))
            if n and n > 0 then L = _log10(n) elseif n == 0 then Z = true end
        elseif s:match("^[%d%.]+[eE][%+%-]?%d+$") then
            local n = tonumber_(s)
            if n and n > 0 then L = _log10(n) end
        else
            local mant, suf = s:match("^([%d][%d%.,]*)%s+(%a+)$")
            if mant and suf and HUGE_EXP[suf:lower()] then L = parseHugeLog(s) end
        end
    end

    if L and RB.curLog and L < RB.curLog - 6 then
        print("[Rebirth] attr looks bogus (way below cache) -> fallback")
        return nil, nil
    end
    if L then return L, false end
    if Z then return nil, true end
    return nil, nil
end

function RB.numText(node)
    if not node then return "" end
    local best = ""
    for _, prop in ipairs_({"ContentText", "Text"}) do
        local t; pcall_(function() t = node[prop] end)
        t = tostring_(t or "")
        if parseHugeLog(t) or RB.isZero(t) then return t end
        if t ~= "" and best == "" then best = t end
    end
    return best
end

function RB.strictLog(t)
    local s = tostring_(t or ""):gsub("<[^>]*>", " "):gsub("^[%s%+%$]+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if s:match("^[%d%.,]+$") then
        local n = tonumber_((s:gsub(",", "")))
        if n and n > 0 then return _log10(n) end
        return nil
    end
    local mant, suf = s:match("^([%d][%d%.,]*)%s+(%a+)$")
    if mant and suf and HUGE_EXP[suf:lower()] then
        local n = tonumber_((mant:gsub(",", "")))
        if n and n > 0 then return _log10(n) + HUGE_EXP[suf:lower()] end
    end
    return nil
end

function RB.curFromLabel()
    local n = RB.node(RB.gui(), "InvestorsMenu/Body/Amount/Quantity")
    if not n then return nil, false end
    local t = RB.numText(n)
    local L = RB.strictLog(t)
    if not L then return nil, RB.isZero(t) end
    if RB.curLog and L < RB.curLog - 6 then return nil, false end
    return L, false
end

RB.U2LOG = 17.255272505103306
RB.U3 = 0.44
function RB.calcGainLog(cLog, pLog)
    if not cLog then return nil end
    if not pLog then return RB.U3 * (cLog - RB.U2LOG) end
    local v8Log = cLog - RB.U2LOG - pLog / RB.U3
    if v8Log < -8 then
        return pLog + _log10(RB.U3) + v8Log
    elseif v8Log > 30 then
        return pLog + RB.U3 * v8Log
    end
    local v8 = 10 ^ v8Log
    local m = (1 + v8) ^ RB.U3 - 1
    if m <= 0 then return nil end
    return pLog + _log10(m)
end

function RB.calibrate(gainLog, pLog, cashLog)
    if not (gainLog and cashLog) then return end
    local cT
    if not pLog then
        cT = gainLog / RB.U3 + RB.U2LOG
    else
        local m = 10 ^ (gainLog - pLog)
        if m <= 0 then return end
        local v8 = (1 + m) ^ (1 / RB.U3) - 1
        if v8 <= 0 then return end
        cT = _log10(v8) + RB.U2LOG + pLog / RB.U3
    end

    if (not RB.earnLog) or cT > RB.earnLog then RB.earnLog = cT end
    RB.lastCashLog = cashLog
    RB.spentEstT = tick_()
    print("[Rebirth] calibrated: total earned ~" .. fmtAbbr(cT))
end

function RB.computeDecision()
    RB.needCur = false
    local cashLog = RB.cashLog()
    if not cashLog then
        RB.goN = 0
        RB.compFailN = (RB.compFailN or 0) + 1
        if RB.compFailN >= 4 then RB.go = false; RB.status = "cash unreadable" end
        return
    end
    RB.compFailN = 0

    local curLog, curZero, curSrc
    local lLog, lZero = RB.curFromLabel()
    if lLog then curLog, curSrc = lLog, "label"
    elseif lZero then curZero, curSrc = true, "label0"
    else
        local aLog = RB.curFromAttr()
        if aLog then curLog, curSrc = aLog, "attr"
        elseif RB.curLog then curLog, curSrc = RB.curLog, "cache" end
    end
    if curLog then RB.curLog = curLog end
    if not curLog and not curZero then
        RB.go = false; RB.goN = 0; RB.needCur = true
        RB.status = "reading investors..."
        return
    end

    if not RB.earnLog then
        RB.earnLog = cashLog
    elseif RB.lastCashLog and cashLog > RB.lastCashLog + 1e-12 then
        local d = _logSub(cashLog, RB.lastCashLog)
        if d then RB.earnLog = _logAdd(RB.earnLog, d) end
    end
    RB.lastCashLog = cashLog
    local cEff = (RB.earnLog and RB.earnLog > cashLog) and RB.earnLog or cashLog
    local gainLog = RB.calcGainLog(cEff, curLog)
    local go, pct
    if not (gainLog and gainLog > 0.01) then
        go, pct = false, 0
    elseif curZero then
        go, pct = true, 100
    else
        local th = _log10(RB.thPct() / 100) + curLog
        go = gainLog >= th
        pct = math.min(999, 10 ^ (gainLog - th) * 100)
    end

    local stale = (not RB.spentEstT) or ((tick_() - RB.spentEstT) > 900)
    local probe = stale and pct >= 2 and (tick_() - (RB.probeTryT or 0)) > 300
    local fire = go or (pct >= 100) or probe
    RB.go = fire
    RB.goN = fire and ((RB.goN or 0) + 1) or 0
    RB.pct = pct

    RB.lastInfo = ((RB.spentEstT or pct < 2) and "" or "~") .. RB.fmtPct(pct)
    RB.status = sformat("%s  |  %s  |  %s", RB.thStr(), RB.lastInfo,
        (pct >= 100) and "GO" or (fire and "verify" or "wait"))

    if (tick_() - (RB.diagT or 0)) >= 60 then
        RB.diagT = tick_()
        local offT = RB.numText(RB.node(RB.gui(), "Sidebar/Container/Investors/Offset"))
        print("[RB peek] est=" .. RB.fmtPct(pct) .. "  gain~" .. (gainLog and fmtAbbr(gainLog) or "?")
            .. "  cur=" .. (curLog and fmtAbbr(curLog) or (curZero and "0" or "?")) .. "(" .. tostring_(curSrc or "?") .. ")"
            .. "  cash=" .. fmtAbbr(cashLog) .. "  earned~" .. (RB.earnLog and fmtAbbr(RB.earnLog) or "?")
            .. "  offset='" .. tostring_(offT):sub(1, 24) .. "'")
    end
end

function RB.shortStr(s)
    local L = parseHugeLog(s)
    if L then return fmtAbbr(L) end
    return (tostring_(s):match("[%d][%d%.,]*")) or "?"
end

function RB.alertMsg()
    local pg = getPlayerGui(); if not pg then return "" end
    local imp; pcall_(function() imp = pg:FindFirstChild("Important") end)
    if not imp then return "" end
    return RB.text(RB.node(imp, "Alert/Main/Message"))
end

function RB.cashLog()
    local pg = getPlayerGui(); if not pg then return nil end
    local hud; pcall_(function() hud = pg:FindFirstChild("HUD") end)
    if not hud then return nil end
    return parseHugeLog(RB.text(RB.node(hud, "Balance/Main/Cash")))
end

function RB.findConfirm()
    local pg = getPlayerGui(); if not pg then return nil end
    local imp; pcall_(function() imp = pg:FindFirstChild("Important") end)
    if not imp then return nil end
    local box = RB.node(imp, "Alert/Main/Buttons")
    if not box then return nil end
    local best, bx
    pcall_(function()
        for _, d in ipairs_(box:GetChildren()) do
            if tostring_(d.ClassName) == "TextButton" then
                local ap; pcall_(function() ap = d.AbsolutePosition end)
                if ap and (ap.X > 1 or ap.Y > 1) and (not bx or ap.X < bx) then
                    bx = ap.X; best = d
                end
            end
        end
    end)
    return best
end

function RB.prepClick()
    RB.busyT = tick_()

    if lemonFarmActive or LSM.zoomedIn then
        LSM.zoomedIn = false
        pcall_(function() LSM.zoom(-1) end)
        local chr = player.Character
        local hrp = chr and chr:FindFirstChild("HumanoidRootPart")
        if type(mousescroll) == "function" and _windowFocused() then
            for _ = 1, 30 do
                if _camFirstPerson(hrp) == false then break end
                pcall_(function() mousescroll(-CFG.zoomStep) end)
                task_wait(0.02); RB.busyT = tick_()
            end
        end
        RB.busyT = tick_()
    end
end

function RB.click(node)
    local ap, az
    pcall_(function() ap = node.AbsolutePosition; az = node.AbsoluteSize end)
    if not ap or not az then return false end
    if ap.X <= 1 and ap.Y <= 1 then return false end

    local inset = 0
    pcall_(function() if GuiService then inset = GuiService:GetGuiInset().Y end end)
    local cx, cy = mfloor(ap.X + az.X / 2), mfloor(ap.Y + az.Y / 2 + inset)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    RB.busyT = tick_(); LSM.lastBot = tick_()
    pcall_(function()

        mousemoveabs(cx - 4, cy); task_wait(0.03)
        mousemoveabs(cx, cy); RB.busyT = tick_(); task_wait(0.14)
        mouse1press(); RB.busyT = tick_(); task_wait(0.28)
        mouse1release(); task_wait(0.1)
        if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end
    end)
    return true
end

function RB.panelOpen(g)
    g = RB.gui() or g
    local ap, vp
    pcall_(function()
        local b = RB.node(g, "InvestorsMenu/Body/Rebirth")
        ap = b and b.AbsolutePosition
        vp = camera.ViewportSize
    end)
    if not ap or not vp then return false end
    return ap.X > 1 and ap.X < vp.X * 0.92
end

function RB.gainFromMsg(msg)
    local m = tostring_(msg):gsub("<[^>]*>", " ")

    local seg = m:match("[Ff]or%s+([%d][%d%.,]*%s*%a+)")
            or m:match("[Gg]ain%s+([%d][%d%.,]*%s*%a+)")
            or m:match("[Rr]eceive%s+([%d][%d%.,]*%s*%a+)")
            or m:match("%+%s*([%d][%d%.,]*%s*%a+)%s*[Ii]nvestor")
            or m:match("([%d][%d%.,]*%s*%a+)%s*[Nn]ew%s*[Ii]nvestor")
    if not seg then return nil end
    return parseHugeLog(seg)
end

function RB.dismissAlert()
    local pg = getPlayerGui()
    local imp; pcall_(function() imp = pg and pg:FindFirstChild("Important") end)
    if not imp then return end
    for _ = 1, 5 do
        if not RB.findConfirm() then return end
        local x = RB.node(imp, "Alert/Main/Close")
        if x then RB.click(x) end
        task_wait(0.35); RB.busyT = tick_()
    end
end

function RB.confirmRebirth(cf)
    if not autoRebirthActive then RB.status = "off"; return end

    pcall_(function()
        local inset = 0
        if GuiService then pcall_(function() inset = GuiService:GetGuiInset().Y end) end
        local c = RB.findConfirm() or cf
        if c then
            local nm; pcall_(function() nm = c.Name end)
            local ap = c.AbsolutePosition; local az = c.AbsoluteSize
            rprint(sformat("[CONFIRM-DIAG] btn='%s' ap=(%d,%d) size=(%d,%d) RBclick=(%d,%d) inset=%d click+inset_y=%d",
                tostring_(nm), mfloor(ap.X), mfloor(ap.Y), mfloor(az.X), mfloor(az.Y),
                mfloor(ap.X + az.X / 2), mfloor(ap.Y + az.Y / 2), mfloor(inset), mfloor(ap.Y + az.Y / 2 + inset)))
        else
            rprint("[CONFIRM-DIAG] findConfirm = nil (кнопок попапа не видно)")
        end
    end)
    local function pressConfirm()
        RB.prepClick()
        local c = RB.findConfirm() or cf
        if c then RB.click(c) end
    end
    local cashBefore = RB.cashLog()
    pressConfirm()
    local done = false
    for i = 1, 2 do
        task_wait(1.2); RB.busyT = tick_()
        local cashNow = RB.cashLog()
        rprint(sformat("[CONFIRM-DIAG] try=%d cashBefore=%s cashNow=%s popupStill=%s",
            i, tostring_(cashBefore and mfloor(cashBefore)), tostring_(cashNow and mfloor(cashNow)),
            tostring_(RB.findConfirm() ~= nil)))
        if cashBefore and cashNow and cashNow < cashBefore - 3 then done = true; break end
        if not RB.findConfirm() then done = true; break end
        if i == 1 then pressConfirm() end
    end
    if done then
        RB.lastReb = tick_(); RB.lastPeek = tick_(); RB.goSince = 0; RB.go = false
        STATS.rebirths = STATS.rebirths + 1
        RB.goN = 0; RB.sideLog = nil
        RB.earnLog = nil; RB.lastCashLog = nil; RB.spentEstT = tick_()

        if RB.curLog and RB.pendGain then RB.curLog = _logAdd(RB.curLog, RB.pendGain) end

        if not RB.findConfirm() then
            RB.busyT = 0; RB.checkStartT = 0
            LSM.zoomedIn = false; LSM.zoomInT = 0
        end

        pcall_(function()
            resetBuyBlacklist()
            localQueue = {}; queueIndex = 1
            task_wait(3)
            buildButtonsCache()
        end)
        RB.status = "REBIRTHED!"
        rprint("[Rebirth] confirmed (" .. RB.thStr() .. ")")
    else
        RB.status = "confirm stuck - dismissed"
        print("[Rebirth] confirm did not register, dismissing alert")
        RB.dismissAlert()
        RB.lastPeek = tick_()
    end
end

function RB.isZero(s)
    s = tostring_(s or ""):gsub("<[^>]*>", "")
    return s:match("^[%s%$%+]*0[%.,]?0*%s*$") ~= nil
end
function RB.decide(curT, gainT)
    local curLog, gainLog = parseHugeLog(curT), parseHugeLog(gainT)

    if not gainLog then
        if RB.isZero(gainT) then return false, 0 end
        return nil
    end
    if not curLog then
        if RB.isZero(curT) then return true, 100 end
        return nil
    end
    local th = _log10(RB.thPct() / 100) + curLog

    return (gainLog >= th), math.min(999, 10 ^ (gainLog - th) * 100)
end

function RB.fmtPct(p)
    if not p then return "?" end
    if p >= 100 then return "100%" end
    if p < 0.1 then return "<0.1%" end
    return sformat("%.1f%%", p)
end

function RB.pctRGB(p)
    p = p or 0
    if p < 0 then p = 0 elseif p > 100 then p = 100 end

    local v = mfloor(108 + (p / 100) * 147)
    if v > 255 then v = 255 end
    local b = v + 6; if b > 255 then b = 255 end
    return v, v, b
end
function RB.pctColor(p)
    return C3rgb(RB.pctRGB(p))
end

function RB.thPct()
    return math.min(10000, (RB.gainPct or 25) * (RB.thBoost or 1))
end

function RB.thStr()
    local t = RB.thPct()
    if t < 100 then return "+" .. t .. "%" end
    return "x" .. (sformat("%g", 1 + t / 100))
end

function RB.closePanel(g)
    g = RB.gui() or g

    for _ = 1, 6 do
        if not RB.panelOpen(g) then return end
        local close = RB.node(g, "InvestorsMenu/Close")
        if close then RB.click(close) end
        task_wait(0.45); RB.busyT = tick_()
    end
end

function RB.ensureClosed(g)
    g = g or RB.gui(); if not g then return end
    RB.busyT = tick_()
    if RB.findConfirm() then RB.dismissAlert() end
    RB.closePanel(g)
end

function RB.runCheck(g)
    RB.status = "checking..."
    RB.wantSlot = false
    RB.checkStartT = tick_()
    RB.busyT = tick_()

    if lemonFarmActive and LSM.zoomedIn then
        for _ = 1, 4 do task_wait(0.4); RB.busyT = tick_() end
    end

    if autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4 then
        RB.status = "waiting: auto stand"
        RB.busyT = 0
        RB.lastPeek = tick_() - (RB.peekEvery or 60) + 5
        return
    end
    RB.prepClick()
    local sb = RB.node(g, "Sidebar/Container/Investors")
    if not sb then RB.status = "Investors button not found"; print("[Rebirth] sidebar Investors missing"); return end

    if not RB.panelOpen(g) then
        local ok = false
        for att = 1, 2 do
            if not autoRebirthActive then return end
            RB.status = sformat("opening panel %d/2...", att)
            RB.click(RB.node(RB.gui() or g, "Sidebar/Container/Investors") or sb)
            for _ = 1, 6 do
                task_wait(0.4); RB.busyT = tick_()
                if RB.panelOpen(g) then ok = true; break end
            end
            if ok then break end
        end
        if not ok then

            for _ = 1, 5 do
                task_wait(0.3); RB.busyT = tick_()
                if RB.panelOpen(g) then ok = true; break end
            end
        end
        if not ok then
            RB.go = false; RB.status = "couldn't open panel"
            print("[Rebirth] panel didn't slide in (click eaten) - retry in 60s")
            return
        end
    end

    local curLog, curZero = nil, false
    do
    local curT

    local zeroHits, valHits = 0, 0

    local curTries = RB.curLog and 4 or 8
    for _ = 1, curTries do
        curT = RB.numText(RB.node(RB.gui() or g, "InvestorsMenu/Body/Amount/Quantity"))
        if RB.strictLog(curT) then
            valHits = valHits + 1
            if valHits >= 2 then break end
        elseif RB.isZero(curT) then
            zeroHits = zeroHits + 1
        else
            zeroHits = 0; valHits = 0
        end
        task_wait(0.4); RB.busyT = tick_()
    end
    if RB.isZero(curT) and zeroHits >= 3 and valHits == 0 then
        curZero = true; RB.curLog = nil
    elseif RB.strictLog(curT) then
        curLog = RB.strictLog(curT); RB.curLog = curLog
    elseif RB.curLog then
        curLog = RB.curLog
        print("[Rebirth] cur garbled -> using cached")
    else

        local aLog = RB.curFromAttr()
        if aLog then
            curLog = aLog; RB.curLog = aLog
            print("[Rebirth] investors source = attribute (" .. fmtAbbr(aLog) .. ")")
        else
        RB.go = false
        local raw = tostring_(curT)
        RB.status = "cur=[" .. (raw == "" and "<пусто>" or raw:sub(1, 16)) .. "](" .. #raw .. ")"
        print("[Rebirth] Amount unreadable & no cache, retry in 8s")
        RB.closePanel(g)

        RB.lastPeek = tick_() - (RB.peekEvery or 60) + 8
        return
        end
    end
    end

    local cashLog = RB.cashLog()
    local cEff = (cashLog and RB.earnLog and RB.earnLog > cashLog) and RB.earnLog or cashLog
    local estGain = cEff and RB.calcGainLog(cEff, curLog) or nil
    local th = curZero and 0.01 or (_log10(RB.thPct() / 100) + (curLog or 0))

    if not autoRebirthActive then RB.status = "off"; return end
    RB.status = "verifying via popup..."
    RB.probeTryT = tick_()
    local rbBtn = RB.node(RB.gui() or g, "InvestorsMenu/Body/Rebirth")
    local cf
    for _ = 1, 3 do
        if not autoRebirthActive then RB.dismissAlert(); RB.status = "off"; return end
        if rbBtn then RB.click(rbBtn) end
        for _ = 1, 6 do
            task_wait(0.4); RB.busyT = tick_()
            cf = RB.findConfirm()
            if cf then break end
        end
        if cf then break end
    end
    if not cf then
        RB.status = "confirm popup not found"
        print("[Rebirth] REBIRTH pressed, no confirm popup - retry in 60s")
        RB.dismissAlert(); RB.lastPeek = tick_()
        if (tick_() - (RB.lastReb or 0)) >= 5 then RB.closePanel(g) end
        return
    end
    local trueGain = RB.gainFromMsg(RB.alertMsg())
    if trueGain then
        RB.pct = curZero and 100 or math.min(999, 10 ^ (trueGain - th) * 100)
        RB.lastInfo = RB.fmtPct(RB.pct)
        if trueGain < th then

            RB.calibrate(trueGain, curLog, cashLog)
            RB.go = false; RB.goN = 0
            RB.status = sformat("%s  |  %s  |  wait", RB.thStr(), RB.lastInfo)
            print("[Rebirth] popup says " .. RB.lastInfo .. " (early) - calibrated, waiting")
            RB.dismissAlert(); RB.closePanel(g)
            RB.lastPeek = tick_()
            return
        end
    else

        if not (estGain and estGain >= th) then
            RB.status = "popup unreadable - safe abort"
            print("[Rebirth] popup gain unreadable, est below threshold - abort, retry in 60s")
            RB.dismissAlert(); RB.closePanel(g); RB.lastPeek = tick_()
            return
        end
    end
    RB.pendGain = trueGain or estGain
    RB.go = true
    RB.confirmRebirth(cf)

    if (tick_() - (RB.lastReb or 0)) >= 5 then RB.closePanel(g) end
end

function RB.tick()
    local rmb = false
    pcall_(function() if type(ismouse2pressed) == "function" then rmb = ismouse2pressed() end end)
    if rmb or not _windowFocused() then return end
    local now = tick_()
    if (now - (RB.lastReb or 0)) < 30 then RB.go = false; RB.status = "cooldown"; return end

    if (now - (RB.softT or 0)) >= 6 then
        RB.softT = now
        pcall_(RB.computeDecision)
    end

    local fire = ((RB.go and (RB.goN or 0) >= 2) or RB.needCur) and true or false

    if (now - (S.lastUser or 0)) < 5 then return end

    if MG.active and (now - (MG.busyT or 0)) < 5 then RB.status = "waiting: minigame"; return end

    if autoStandActive and (LSM.standBusyT or 0) ~= 0 and ((now - (LSM.standPassT or 0)) < 3 or (now - (LSM.standBusyT or 0)) < 4) then

        if fire and (now - (RB.lastPeek or 0)) >= (RB.peekEvery or 60) then RB.wantSlot = true end
        RB.status = "waiting: auto stand"; return
    end
    if (not fire) or ((now - (RB.lastPeek or 0)) < (fire and 3 or (RB.peekEvery or 60))) then

        local g = RB.gui()
        if g and (RB.panelOpen(g) or RB.findConfirm()) then RB.ensureClosed(g) end
        return
    end
    local g = RB.gui()
    if not g then RB.status = "Rebirth gui not found"; return end
    RB.lastPeek = now
    pcall_(function() RB.runCheck(g) end)
    RB.busyT = 0; RB.checkStartT = 0
    LSM.zoomInT = 0
    RB.openedAt = nil
end
_wrap("auto-rebirth", function()
    while ScriptActive do
        if autoRebirthActive then
            pcall_(RB.tick)
        else
            RB.go = false
        end
        task_wait(CFG.slow and 1.4 or 0.8)
    end
end)

-- Auto Evolve: same idea as rebirth but simple - EvolutionMenu/Body/Progress shows "NN%", and the
-- Evolve button (EvolutionMenu/Body/Evolve) is pressable at 100%. Reuse RB's GUI helpers.
_wrap("auto-evolve", function()
    while ScriptActive do
        syncFromUI()
        if not autoEvolveActive then task_wait(0.6); continue end
        if _standIsTapping or RB.go or (tick_() - (RB.busyT or 0)) < 4 then task_wait(0.4); continue end
        local g = RB.gui()
        local prog = g and RB.node(g, "EvolutionMenu/Body/Progress")
        local pct = tonumber((prog and RB.text(prog) or ""):match("(%d+)")) or 0
        if pct >= 100 then
            RB.busyT = tick_()
            RB.prepClick()                                          -- exit lemon-farm zoom so the mouse can click GUI
            local side = RB.node(g, "Sidebar/Container/Evolution")
            if side then RB.click(side); task_wait(0.3) end         -- open the Evolution menu
            local btn = RB.node(RB.gui(), "EvolutionMenu/Body/Evolve")
            if btn and RB.click(btn) then
                STATS.evolves = STATS.evolves + 1
                print("[Evolve] pressed Evolve (progress " .. pct .. "%)")
            end
            task_wait(2.5)                                          -- let it apply + progress reset
        else
            task_wait(0.8)
        end
    end
end)

function MG.text(d)
    local t; pcall_(function() t = d.Text end)
    if not t or t == "" then
        pcall_(function()
            for _, c in ipairs_(d:GetDescendants()) do
                if tostring_(c.ClassName) == "TextLabel" then t = c.Text; return end
            end
        end)
    end
    return tostring_(t or ""):upper()
end
function MG.shown(o)
    local cur = o
    for _ = 1, 20 do
        if not cur then return true end
        local cn = tostring_(cur.ClassName)
        if cn == "ScreenGui" then local en; pcall_(function() en = cur.Enabled end); return en ~= false end
        if cn == "PlayerGui" then return true end
        local vis; pcall_(function() vis = cur.Visible end)
        if vis == false then return false end
        cur = cur.Parent
    end
    return true
end

function MG.scanBtns(root, want, needPos)
    local hit
    pcall_(function()
        for _, d in ipairs_(root:GetDescendants()) do
            local cn = tostring_(d.ClassName)
            if (cn == "TextButton" or cn == "ImageButton") and MG.shown(d) and MG.text(d):find(want) then
                if needPos then
                    local ap = d.AbsolutePosition
                    if ap and (ap.X > 1 or ap.Y > 1) then hit = d; return end
                else
                    hit = d; return
                end
            end
        end
    end)
    return hit
end
local MG_CONTAINERS = {"MinigameRace", "PickGui", "PromptGui"}
function MG.findBtn(want, needPos)
    local pg = getPlayerGui()
    if not pg then return nil end
    for _, nm in ipairs_(MG_CONTAINERS) do
        local g
        pcall_(function() g = pg:FindFirstChild(nm) end)
        if g then
            local hit = MG.scanBtns(g, want, needPos)
            if hit then return hit end
        end
    end

    local now = tick_()
    if type(MG.fsT) ~= "table" then MG.fsT = {} end
    if (now - (MG.fsT[want] or 0)) < 1.5 then return nil end
    MG.fsT[want] = now
    return MG.scanBtns(pg, want, needPos)
end
function MG.click(btn)
    local ap, az
    pcall_(function() ap = btn.AbsolutePosition; az = btn.AbsoluteSize end)
    if not ap or not az then return end
    if ap.X <= 1 and ap.Y <= 1 then return end

    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    LSM.lastBot = tick_()
    pcall_(function()
        mousemoveabs(mfloor(ap.X + az.X / 2), mfloor(ap.Y + az.Y / 2))
        mouse1press(); mouse1release()
        if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end
    end)
end

function MG.entryPos()
    if not myTycoon then return nil end
    local pur; pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
    local mg = pur and pur:FindFirstChild("Minigames")
    if not mg then return nil end
    local pos
    pcall_(function()
        for _, c in ipairs_(mg:GetChildren()) do
            local nm = tostring_(c.Name)

            if MG.enabled[nm] ~= false and nm:lower():find("minigame") and not nm:lower():find("trade") then
                for _, d in ipairs_(c:GetDescendants()) do
                    if tostring_(d.ClassName) == "ProximityPrompt" and d.Parent then
                        pos = _standPartPos(d.Parent); return
                    end
                end
            end
        end
    end)
    return pos
end

local MG_PICK_ROWS = {0.74, 0.78, 0.82}
local MG_PICK_COLS = {0.14, 0.35, 0.56, 0.78}
function MG.clickSlots()
    local vw, vh = 1920, 1080
    pcall_(function() local v = camera.ViewportSize; vw = v.X; vh = v.Y end)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    for _, fy in ipairs_(MG_PICK_ROWS) do
        for _, fx in ipairs_(MG_PICK_COLS) do
            if not MG.active then break end
            LSM.lastBot = tick_()
            pcall_(function()
                mousemoveabs(mfloor(vw * fx), mfloor(vh * fy))
                mouse1press(); mouse1release()
            end)
            task_wait(0.03)
        end
    end
    pcall_(function() if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end end)
end

function MG.clickRatio(fx, fy)
    local vw, vh = 1920, 1080
    pcall_(function() local v = camera.ViewportSize; vw = v.X; vh = v.Y end)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    LSM.lastBot = tick_()
    pcall_(function() mousemoveabs(mfloor(vw * fx), mfloor(vh * fy)) end)
    MG.tap()
    pcall_(function() if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end end)
end

function MG.tap()
    pcall_(function() mouse1press() end)
    task_wait()
    pcall_(function() mouse1release() end)
end

function MG.spamCheer(btn)

    local vw, vh = 1920, 1080
    pcall_(function() local v = camera.ViewportSize; vw = v.X; vh = v.Y end)
    local cx, cy = mfloor(vw * 0.5), mfloor(vh * CFG.cheerY)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    pcall_(function() mousemoveabs(cx, cy) end)
    local n = 0
    local tCap = tick_()
    while MG.active and ScriptActive and (tick_() - tCap) < 75 do
        LSM.lastBot = tick_()
        MG.busyT = tick_()
        MG.tap()
        n = n + 1
        if n % 8 == 0 then
            local ok, still = pcall_(function() return btn.Parent and MG.text(btn):find("CHEER") end)
            if not (ok and still) then break end
            pcall_(function() mousemoveabs(cx, cy) end)
            LSM.standBusyT = tick_()
        end
        task_wait(0.02)
    end
    pcall_(function() if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end end)
end

function MG.resultUp()
    local pg = getPlayerGui()
    local mr = pg and pg:FindFirstChild("MinigameRace")
    if not mr then return false end
    local found = false
    pcall_(function()
        for _, d in ipairs_(mr:GetDescendants()) do
            if tostring_(d.ClassName) == "TextLabel" then
                local t; pcall_(function() t = d.Text end)
                t = tostring_(t or ""):upper()
                if t:find("REWARD") or t:find("GOT") or t:find("PLACE") then found = true; return end
            end
        end
    end)
    return found
end
function MG.checkUp()
    local pg = getPlayerGui()
    local popup = pg and pg:FindFirstChild("Popup")
    local chk = popup and popup:FindFirstChild("Check")
    return (chk and MG.shown(chk)) or false
end

function MG.clickCheck()
    local vw, vh = 1920, 1080
    pcall_(function() local v = camera.ViewportSize; vw = v.X; vh = v.Y end)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)

    pcall_(function()
        local pg = getPlayerGui()
        local popup = pg and pg:FindFirstChild("Popup")
        local chk = popup and popup:FindFirstChild("Check")
        if not chk then return end
        local bx, by, area
        for _, d in ipairs_(chk:GetDescendants()) do
            local cn = tostring_(d.ClassName)
            if cn == "Frame" or cn == "ImageButton" or cn == "ImageLabel" or cn == "TextButton" then
                local ap = d.AbsolutePosition; local az = d.AbsoluteSize
                if ap and az and az.X > 50 and az.Y > 50 and (ap.X > 1 or ap.Y > 1) then
                    local a = az.X * az.Y
                    if not area or a > area then area = a; bx = ap.X + az.X / 2; by = ap.Y + az.Y / 2 end
                end
            end
        end
        if bx then
            LSM.lastBot = tick_()
            mousemoveabs(mfloor(bx), mfloor(by)); MG.tap()
            mousemoveabs(mfloor(bx), mfloor(by)); MG.tap()
        end
    end)

    pcall_(function()
        LSM.lastBot = tick_()
        mousemoveabs(mfloor(vw * 0.5), mfloor(vh * 0.5)); MG.tap()
        mousemoveabs(mfloor(vw * 0.5), mfloor(vh * 0.5)); MG.tap()
    end)
    pcall_(function() if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end end)
end
_wrap("auto-minigame", function()
    while ScriptActive do
        if MG.active then
            pcall_(function()

                local cheer = MG.findBtn("CHEER")
                if cheer then
                    LSM.standBusyT = tick_()
                    MG.sessPost = 0
                    MG.spamCheer(cheer)
                    MG.raceEndT = tick_()
                    return
                end

                local justRaced = (tick_() - (MG.raceEndT or 0)) < 30

                if justRaced then
                    local exitBtn = MG.findBtn("EXIT")
                    local chequeShown = false
                    pcall_(function()
                        local pg = getPlayerGui()
                        local main = pg and pg:FindFirstChild("Popup")
                        main = main and main:FindFirstChild("Check")
                        main = main and main:FindFirstChild("Main")
                        if main and MG.shown(main) then chequeShown = true end
                    end)
                    if exitBtn or chequeShown then
                        MG.sessPost = (MG.sessPost or 0) + 1
                        if MG.sessPost <= 8 then
                            LSM.standBusyT = tick_(); MG.busyT = tick_()
                            if exitBtn then MG.click(exitBtn) end
                            if chequeShown then MG.clickCheck() end
                            task_wait(0.4)
                        else task_wait(0.5) end
                        return
                    end
                end

                if MG.findBtn("PICK") then
                    LSM.standBusyT = tick_(); MG.busyT = tick_()
                    MG.clickSlots()
                    task_wait(0.4)
                    return
                end

                local cd = MG.timerSec()
                if cd and cd > 0 then MG.miniEnd = tick_() + cd end
                local localCd = MG.miniEnd and (MG.miniEnd - tick_()) or nil
                if (cd and cd > 0) or (localCd and localCd > 0) then
                    task_wait(0.5)
                    return
                end

                if not MG.miniEnd then
                    local synced = false
                    for _ = 1, 6 do
                        if not MG.active then break end
                        MG.tsT = 0
                        local cd2 = MG.timerSec()
                        if cd2 and cd2 > 0 then MG.miniEnd = tick_() + cd2; synced = true; break end
                        if MG.findBtn("PICK") or MG.findBtn("CHEER") then break end
                        task_wait(0.5)
                    end
                    if synced then task_wait(0.5); return end
                end

                if (tick_() - (MG.lastEntryTry or 0)) < 6 then task_wait(0.5); return end

                if (tick_() - (RB.busyT or 0)) < 4 then task_wait(0.5); return end
                MG.lastEntryTry = tick_()
                LSM.standBusyT = tick_()
                MG.entryT = tick_()
                local pos = MG.entryPos()
                if pos then pcall_(function() _tpHrpTo(pos) end) end
                local started = false
                local play = MG.findBtn("PLAY", true)
                if play then MG.click(play) end
                for _ = 1, 12 do
                    if not MG.active then break end
                    MG.entryT = tick_()
                    if MG.findBtn("PICK") or MG.findBtn("CHEER") then started = true; break end
                    keypress(0x45); task_wait(0.04); keyrelease(0x45); task_wait(0.06)
                end
                task_wait(started and 0.3 or 2)
            end)
        end
        task_wait(CFG.slow and 0.5 or 0.2)
    end
end)

_wrap("auto-stand", function()
    local lastDiag = 0
    local firstRun = true
    while ScriptActive do
        syncFromUI()
        if not autoStandActive then
            firstRun = true
            task_wait(0.25)
            continue
        end

        if not myTycoon or not myTycoon.Parent then
            myTycoon = findMyTycoon()
            if not myTycoon then
                if tick_() - lastDiag > 3 then
                    print("[Stand] esperando tycoon...")
                    lastDiag = tick_()
                end
                task_wait(0.5)
                continue
            end
        end

        if autoBuyActive and _anyBuyableNowButtons() then
            task_wait(0.3)
            continue
        end

        if (tick_() - (LSM.buySweepT or 0)) < 4 then
            task_wait(0.3)
            continue
        end

        if (tick_() - (RB.busyT or 0)) < 4 then
            task_wait(0.5)
            continue
        end

        if autoRebirthActive and RB.wantSlot then
            local w0 = tick_()
            while ScriptActive and autoStandActive and autoRebirthActive
                  and RB.wantSlot and (tick_() - w0) < 35 do
                task_wait(0.3)
            end
            if RB.wantSlot and (tick_() - w0) >= 35 then
                RB.wantSlot = false
            else
                continue
            end
        end

        if MG.lemBusy() then
            task_wait(0.5)
            continue
        end

        local res = runLocationsPass(firstRun)
        firstRun = false

        LSM.standBusyT = 0; LSM.zoomInT = 0
        if res == "off" then
            task_wait(0.05)
            continue
        end

        if res == "yield" then
            local w0 = tick_()
            while ScriptActive and autoStandActive and autoBuyActive
                  and _anyBuyableNowButtons() and (tick_() - w0) < 15 do
                task_wait(0.3)
            end
            continue
        end

        local t0 = tick_()
        while ScriptActive and autoStandActive do
            local rest = lemonFarmActive and CFG.standRest or STAND_LOOP_DELAY
            LSM.standNextT = t0 + rest
            if (tick_() - t0) >= rest then break end
            task_wait(0.25)
        end
    end
end)

_wrap("cancel-prompt", function()
    while ScriptActive do
        task_wait(0.25)
        local cancel
        pcall_(function()
            local pg = getPlayerGui()
            local pr = pg and pg:FindFirstChild("Prompt")
            local cl = pr and pr:FindFirstChild("ChangeLabel")
            local bt = cl and cl:FindFirstChild("Buttons")
            cancel = bt and bt:FindFirstChild("Cancel")
        end)
        if cancel and _windowFocused() and (tick_() - (S.cancelT or 0)) > 1.5 then
            local ap, az, vp
            pcall_(function() ap = cancel.AbsolutePosition; az = cancel.AbsoluteSize; vp = camera.ViewportSize end)
            if ap and az and vp and az.X > 10
               and ap.X > 1 and ap.X < vp.X and ap.Y > 1 and ap.Y < vp.Y then
                S.cancelT = tick_()
                RB.busyT = tick_(); LSM.lastBot = tick_()
                pcall_(function() RB.click(cancel) end)
                rprint("[CancelPrompt] ChangeLabel -> Cancel")
            end
        end
    end
end)

_G.MatchaCleanup = function()
    pcall_(LSM.returnHome)
    pcall_(FX.restore)
    ScriptActive = false
    pcall_(function() if UIRef.win then UIRef.win:Destroy() end end)
    for _, obj in ipairs_(drawObjs) do
        pcall_(function() obj:Remove() end)
    end
    print("[Hub] Cleanup done")
end

rprint("sell lemons v22 loaded  |  by Inspecttor")

