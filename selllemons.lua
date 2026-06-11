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
local lemonFarmActive  = false
local cashFarmActive   = true
local autoStandActive  = false
local autoDealActive   = true
local _standIsTapping  = false

local buyBlacklist    = {}
local failedButtons   = {}
local buyAttempt      = {}

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
    if a.n >= 6 then return false end
    return tick_() >= a.next
end
local function markBuyFail(key, v)
    local a = buyAttempt[key]
    if not a then a = { n = 0, next = 0 }; buyAttempt[key] = a end
    a.inst = v or a.inst
    a.n = a.n + 1
    local d = 0.35 * (2 ^ (a.n - 1))
    if d > 4 then d = 4 end
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
        if tycoon.Name:find("Tycoon") then
            local owner = tycoon:FindFirstChild("Owner")
            if owner then
                local ownerValue = nil
                pcall_(function() ownerValue = tostring_(owner.Value) end)
                if ownerValue and ownerValue:find(pname) then return tycoon end
            end
        end
    end
    return nil
end
myTycoon = findMyTycoon()

print("=== SELL LEMONS v18.33 ===")

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

pcall_(function()
    if type(readfile) == "function" then
        local v = tonumber(readfile("selllemons_vine.txt"))

        if v and v <= tick_() and (tick_() - v) < 7 * 24 * 3600 then CFG.vineT = v end
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
        if FX.on and FX.gen == gen then rprint("[FPS] low graphics ON (" .. FX.n .. " changed)") end
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
        rprint("[FPS] graphics restored (" .. n .. ")")
    end)
end

local homesick
do
    local ok, err = pcall_(function()
        local src = game:HttpGet("https://raw.githubusercontent.com/sharedechoes/Matcha-Luas/refs/heads/main/homesick.lua")

        src = src:gsub('accent = c3%(232, 208, 162%),', 'accent = c3(255, 214, 60),')
        src = src:gsub('bg = c3%(36, 33, 31%),', 'bg = c3(33, 29, 17),')
        src = src:gsub('surface = c3%(30, 27, 25%),', 'surface = c3(27, 24, 14),')
        src = src:gsub('surface2 = c3%(44, 40, 37%),', 'surface2 = c3(45, 40, 22),')
        src = src:gsub('surface3 = c3%(54, 50, 46%),', 'surface3 = c3(58, 51, 28),')
        src = src:gsub('border = c3%(60, 55, 52%),', 'border = c3(78, 68, 36),')
        src = src:gsub('sub = c3%(150, 142, 135%),', 'sub = c3(168, 154, 112),')
        src = src:gsub('%(ProjectState%.badgeText %.%. " | v1%.4%.0"%)', '(ProjectState.badgeText)')
        src = src:gsub('or "v1%.4%.0"', 'or ""')

        src = src:gsub('bg = 1%.0,', 'bg = 0.68,')
        src = src:gsub('surface = 1%.0,', 'surface = 0.70,')
        src = src:gsub('surface2 = 1%.0,', 'surface2 = 0.78,')
        src = src:gsub('surface3 = 1%.0,', 'surface3 = 0.82,')
        src = src:gsub('border = 1%.0,', 'border = 0.9,')
        loadstring(src)()
    end)
    homesick = _G.homesick
    if not homesick then pcall_(function() homesick = shared.homesick end) end
    if not homesick then
        print("[Hub] homesick UI не загрузился (" .. tostring(err) .. ") — клавиши 1-5 работают как фоллбэк")
    end
end

local UIRef = { win = nil, t = {} }

local function syncFromUI() end
local function syncToUI()
    pcall_(function() if UIRef.t.AutoBuy   then UIRef.t.AutoBuy:SetValue(autoBuyActive)     end end)
    pcall_(function() if UIRef.t.LemonFarm then UIRef.t.LemonFarm:SetValue(lemonFarmActive) end end)
    pcall_(function() if UIRef.t.AutoStand then UIRef.t.AutoStand:SetValue(autoStandActive) end end)
    pcall_(function() if UIRef.t.CashFarm  then UIRef.t.CashFarm:SetValue(cashFarmActive)   end end)
end
local function stopAll()
    autoBuyActive, lemonFarmActive, cashFarmActive, autoStandActive = false, false, false, false
    resetBuyBlacklist()
    syncToUI()
    pcall_(function() if S.saveState then S.saveState() end end)
    print("[Hub] Everything stopped!")
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

local STAND_NAMES = {"Lemon Stand", "LemonDash", "Lemon Depot", "Lemon Trading", "Lemon Labs", "Lemon Robotics", "Lemon Republic"}
local standEnabled = {}
local MG = { active = false, enabled = {} }

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

local STAND_ORDER = {"stand", "dash", "depot", "trading", "labs", "robotics", "republic"}
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
        if rank < 99 and not low:find("lemonx") then

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

if homesick then
    pcall_(function() homesick.changelogEnabled = false end)
    local window = homesick.createWindow("Sell Lemons", 480, 420)

    UIRef.win = window

    local tab1 = window:addTab("Main")
    local left = tab1:addSection("Farming", "Left")

    UIRef.t.AutoBuy = left:addToggle("autoBuy", "Auto Buy", false, function(val)
        autoBuyActive = val
        S.saveState()
        print("[Hub] toggle AutoBuy = " .. tostring_(val))
    end):addKeybind("1", "Toggle", true, function() end)

    UIRef.t.LemonFarm = left:addToggle("lemonFarm", "Lemon Farm", false, function(val)
        lemonFarmActive = val
        S.saveState()
        print("[Hub] toggle LemonFarm = " .. tostring_(val))
    end):addKeybind("2", "Toggle", true, function() end)

    UIRef.t.AutoStand = left:addToggle("autoStand", "Auto Stand", false, function(val)
        autoStandActive = val
        S.saveState()
        print("[Hub] toggle AutoStand = " .. tostring_(val))
    end):addKeybind("3", "Toggle", true, function() end)

    UIRef.t.CashFarm = left:addToggle("cashFarm", "Cash Farm", true, function(val)
        cashFarmActive = val
        S.saveState()
        print("[Hub] toggle CashFarm = " .. tostring_(val))
    end):addKeybind("4", "Toggle", true, function() end)

    local right = tab1:addSection("Control", "Right")

    pcall_(function() window:setBadge("Sell Lemons v18.33  |  by neaxus") end)
    UIRef.t.AutoDeal = right:addToggle("autoDeal", "Auto Deal", true, function(val)
        autoDealActive = val
        S.saveState()
    end)

    UIRef.t.AutoMini = right:addToggle("autoMini", "Auto Minigame", false, function(val)
        MG.active = val
        if not val then
            MG.sessExit = 0; MG.sessCheck = 0; MG.exitSeen = false; MG.popupSeen = false
        end
        S.saveState()
        print("[Hub] toggle AutoMinigame = " .. tostring_(val))
    end)

    UIRef.t.CashVine = right:addToggle("cashVine", "Cash Vine TP", false, function(val)
        if val then
            CFG.vineGo = true
        else
            CFG.vineBack = true
        end
    end)

    UIRef.t.FpsSave = right:addToggle("fpsSave", "FPS Save (weak PC)", false, function(val)
        CFG.slow = val and true or false
        if val then FX.apply() else FX.restore() end
    end)

    pcall_(function() right:addSeparator() end)

    UIRef.t.StopAll = right:addToggle("stopAll", "Stop All", false, function(val)
        if val then
            stopAll()
            task.delay(0.1, function()
                pcall_(function() UIRef.t.StopAll:SetValue(false) end)
            end)
        end
    end):addKeybind("5", "Toggle", true, function()
        stopAll()
        task.delay(0.1, function()
            pcall_(function() UIRef.t.StopAll:SetValue(false) end)
        end)
    end)

    UIRef.standCb = {}
    UIRef.miniCb = {}
    pcall_(function()
        local autoTab = window:addTab("Auto")
        local sec = autoTab:addSection("Stands", "Left")
        local listed = {}
        for _, s in ipairs_(getStandLocations()) do listed[#listed + 1] = s.name end
        if #listed == 0 then listed = STAND_NAMES end
        for idx, nm in ipairs_(listed) do
            if standEnabled[nm] == nil then standEnabled[nm] = true end

            UIRef.standCb[nm] = sec:addCheckbox("stand_" .. nm, idx .. ". " .. nm, true, function(val)
                standEnabled[nm] = val
                S.saveState()
            end)
        end

        local mgList = MG.list()
        if #mgList > 0 then
            local mgSec = autoTab:addSection("Minigames", "Right")
            for _, nm in ipairs_(mgList) do
                local soon = nm:lower():find("trade") and true or false
                if soon then
                    MG.enabled[nm] = false
                    mgSec:addCheckbox("mini_" .. nm, nm .. " (soon)", false, function() end)
                else
                    if MG.enabled[nm] == nil then MG.enabled[nm] = true end
                    UIRef.miniCb[nm] = mgSec:addCheckbox("mini_" .. nm, nm, true, function(val)
                        MG.enabled[nm] = val
                        S.saveState()
                    end)
                end
            end
        end
    end)

    window.visible = true
    window:render()
    print("[Hub] homesick UI loaded - keys 1-5 via keybinds")
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
    return mabs(r - g) < 30 and mabs(g - b) < 30 and mabs(r - b) < 30 and r < 200
end

local buttonsFolders   = {}
local buttonsFolderSet = {}
local buttonsCacheReady = false
local purchasesConnSet = {}

local function addButtonsFolder(folder)
    if not folder or buttonsFolderSet[folder] then return end
    buttonsFolderSet[folder] = true
    tinsert(buttonsFolders, folder)
    pcall_(function()
        folder.AncestryChanged:Connect(function(_, parent)
            if not parent then
                buttonsFolderSet[folder] = nil
                for i = #buttonsFolders, 1, -1 do
                    if buttonsFolders[i] == folder then
                        table.remove(buttonsFolders, i)
                        break
                    end
                end
            end
        end)
    end)
end

local function hookPurchaseCategory(cat)
    if not cat or purchasesConnSet[cat] then return end
    purchasesConnSet[cat] = true
    local bf = cat:FindFirstChild("Buttons")
    if bf then addButtonsFolder(bf) end
    pcall_(function()
        cat.ChildAdded:Connect(function(child)
            if child.Name == "Buttons" then addButtonsFolder(child) end
        end)
    end)
end

local function buildButtonsCache()
    buttonsFolders, buttonsFolderSet, purchasesConnSet = {}, {}, {}
    buttonsCacheReady = false
    if not myTycoon then return end
    local purchases = myTycoon:FindFirstChild("Purchases")
    if not purchases then return end

    for _, cat in ipairs_(purchases:GetChildren()) do
        hookPurchaseCategory(cat)
    end
    pcall_(function()
        purchases.ChildAdded:Connect(function(newCat)
            hookPurchaseCategory(newCat)
        end)
    end)
    buttonsCacheReady = true
end

buildButtonsCache()

local _bScan = { t = 0, list = nil }
local function getButtonsRealTime()
    if not buttonsCacheReady then
        buildButtonsCache()
        if not buttonsCacheReady then return {} end
    end

    local now = tick_()
    if _bScan.list and (now - _bScan.t) < 0.12 then
        return _bScan.list
    end

    local temp = {}
    local list = buttonsFolders
    for i = 1, #list do
        local bf = list[i]
        if bf and bf.Parent then
            for _, model in ipairs_(bf:GetChildren()) do
                local btn = model:FindFirstChild("Button")
                if btn and btn:IsA("BasePart") and btn.Parent then
                    tinsert(temp, btn)
                end
                for _, child in ipairs_(model:GetDescendants()) do
                    if child.Name == "Button" and child ~= btn
                       and child:IsA("BasePart") and child.Parent then
                        tinsert(temp, child)
                    end
                end
            end
        end
    end
    _bScan.list = temp
    _bScan.t = now
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
local totalBought  = 0
local totalFailed  = 0
local lastResetTime = 0

local function appendNewButtons()
    while queueLock do task_wait(0.001) end
    queueLock = true

    if not myTycoon or not myTycoon.Parent then
        queueLock = false
        return 0
    end

    local buttons = getButtonsRealTime()
    lastButtonCount = #buttons

    local existingKeys = {}
    local lq = localQueue
    local lqLen = #lq
    for i = queueIndex, lqLen do
        local it = lq[i]
        if it and it.key then existingKeys[it.key] = true end
    end

    local chr = player.Character
    local hrp = chr and chr:FindFirstChild("HumanoidRootPart")
    local hrpPos = hrp and hrp.Position or nil
    local added = 0

    for _, v in ipairs_(buttons) do
        local key = getButtonKey(v)
        if key then
            local fails = failedButtons[key] or 0
            if not existingKeys[key] and buyReady(key, v) and not isGreyedOut(v) and not isBlacklisted(key, v) then
                local dist = hrpPos and (v.Position - hrpPos).Magnitude or 999999
                tinsert(lq, {
                    btn   = v,
                    key   = key,
                    dist  = dist,
                    fails = fails
                })
                added = added + 1
            end
        end
    end

    queueLock = false
    return added
end

local function allButtonsDead()
    local now = tick_()
    if _bScan.deadT and (now - _bScan.deadT) < 0.15 then return _bScan.dead end
    local dead = true
    local buttons = getButtonsRealTime()
    if #buttons == 0 then
        dead = false
    else
        for _, v in ipairs_(buttons) do
            local key = getButtonKey(v)
            if key then
                local a = buyAttempt[key]
                if a and a.inst and a.inst ~= v then buyAttempt[key] = nil; a = nil end
                local givenUp = a and a.n >= 6
                if not isBlacklisted(key, v) and not isGreyedOut(v) and not givenUp then
                    dead = false
                    break
                end
            end
        end
    end
    _bScan.deadT = now
    _bScan.dead = dead
    return dead
end

local function anyGivenUpButtons()
    local now = tick_()
    if _bScan.giveT and (now - _bScan.giveT) < 0.15 then return _bScan.give end
    local found = false
    local buttons = getButtonsRealTime()
    for _, v in ipairs_(buttons) do
        local key = getButtonKey(v)
        if key then
            local a = buyAttempt[key]
            if a and a.inst and a.inst ~= v then
                buyAttempt[key] = nil
            elseif a and a.n >= 6 and not isBlacklisted(key, v) then
                found = true
                break
            end
        end
    end
    _bScan.giveT = now
    _bScan.give = found
    return found
end

local function cleanupQueue()
    while queueLock do task_wait(0.001) end
    queueLock = true

    if queueIndex > 20 then
        local newQueue = {}
        local lq = localQueue
        local n = 0
        for i = queueIndex, #lq do
            n = n + 1
            newQueue[n] = lq[i]
        end
        localQueue = newQueue
        queueIndex = 1
    end

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
    if _bScan.liveT and (now - _bScan.liveT) < 0.15 then return _bScan.live end
    local live = false
    local buttons = getButtonsRealTime()
    for _, v in ipairs_(buttons) do
        local key = getButtonKey(v)
        if key then
            local a = buyAttempt[key]
            if a and a.inst and a.inst ~= v then buyAttempt[key] = nil; a = nil end
            local givenUp = a and a.n >= 6
            if not isBlacklisted(key, v) and not isGreyedOut(v) and not givenUp then
                live = true
                break
            end
        end
    end
    _bScan.liveT = now
    _bScan.live = live
    return live
end

local STAND_E_SPAM_DURATION = 1.5

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

    LSM.zoom(-1)

    local tilted = LSM.tiltDown()
    local tapped = 0
    for _, s in ipairs_(locs) do
        if not ScriptActive or not autoStandActive then return "off" end
        if standEnabled[s.name] ~= false then
            if autoBuyActive and _anyLiveButtons() then return "done" end
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

_wrap("autobuy-worker", function()
    local emptyStreak = 0

    while ScriptActive do
        syncFromUI()
        if not autoBuyActive then
            task_wait(0.05)
            continue
        end
        if _standIsTapping or LSM.lemonSlot == true then
            task_wait(0.05)
            continue
        end

        local character = player.Character
        local hrp = character and character:FindFirstChild("HumanoidRootPart")
        if not hrp or not myTycoon then
            task_wait(0.05)
            continue
        end

        local item = nil
        local lq  = localQueue
        while queueIndex <= #lq do
            local candidate = lq[queueIndex]
            queueIndex = queueIndex + 1

            if candidate and candidate.btn and candidate.btn.Parent then
                local key = candidate.key
                if buyReady(key, candidate.btn) and not isGreyedOut(candidate.btn) and not isBlacklisted(key, candidate.btn) then
                    item = candidate
                    break
                end
            end
        end

        if not item then
            local remaining = #lq - queueIndex + 1
            if remaining <= 0 then
                local added = appendNewButtons()
                if added > 0 then
                    print("[Worker] Appended: +" .. added)
                    lq = localQueue
                    while queueIndex <= #lq do
                        local candidate = lq[queueIndex]
                        queueIndex = queueIndex + 1
                        if candidate and candidate.btn and candidate.btn.Parent then
                            local key = candidate.key
                            if buyReady(key, candidate.btn) and not isGreyedOut(candidate.btn) and not isBlacklisted(key, candidate.btn) then
                                item = candidate
                                break
                            end
                        end
                    end
                end
            end
        end

        if not item then
            if allButtonsDead() then

                if anyGivenUpButtons() then
                    local now = tick_()
                    if now - lastResetTime > 2 then
                        lastResetTime = now
                        print("[Worker] given-up retry -> reset")
                        resetBuyBlacklist()
                        localQueue = {}
                        queueIndex = 1
                        appendNewButtons()
                    end
                else
                    task_wait(0.3)
                end
            else
                emptyStreak = emptyStreak + 1
                if emptyStreak > 10 then
                    emptyStreak = 0
                    appendNewButtons()
                end
            end

            task_wait(CFG.slow and 0.3 or 0.12)
            continue
        end

        emptyStreak = 0

        local key = item.key
        local btn = item.btn
        local pos = btn.Position
        local px, py, pz = pos.X, pos.Y, pos.Z

        pcall_(function() hrp.CFrame = CF(px, py + 2.5, pz) end)
        task_wait(0.03)

        local bought = false
        local t0 = tick_()
        while ScriptActive and (tick_() - t0) < CFG.buyWindow do
            pcall_(function() hrp.CFrame = CF(px, py + 0.8, pz) end)
            task_wait(0.05)
            local gone = true
            pcall_(function()
                gone = not (btn and btn.Parent and btn:IsDescendantOf(myTycoon))
            end)
            if gone then bought = true; break end

            if isGreyedOut(btn) then break end
        end

        if bought then
            buyBlacklist[key]  = btn
            failedButtons[key] = nil
            buyAttempt[key]    = nil
            totalBought = totalBought + 1
            print("[Worker] BOUGHT: " .. key .. " | Total: " .. totalBought)
        else
            markBuyFail(key, btn)
            totalFailed = totalFailed + 1
            print("[Worker] retry-later: " .. key .. " | n=" .. (buyAttempt[key] and buyAttempt[key].n or 0))

            local a = buyAttempt[key]
            if a and a.n >= 6 and not isGreyedOut(btn) then
                a.n = 0
                task_spawn(function()
                    pcall_(function()
                        local model = btn.Parent
                        local pf = model and model:FindFirstChild("Purchase")
                        if pf and tostring_(pf.ClassName) == "RemoteFunction" then
                            pf:InvokeServer(false)
                            rprint("[Worker] Purchase remote rescue: " .. key)
                        end
                    end)
                end)
            end
        end

        if totalBought % 20 == 0 then
            cleanupQueue()
        end
    end
end)

_wrap("autobuy-coord", function()
    while ScriptActive do
        syncFromUI()
        if not autoBuyActive then
            task_wait(0.2)
            continue
        end
        if _standIsTapping or LSM.lemonSlot == true then
            task_wait(0.2)
            continue
        end

        if not myTycoon or not myTycoon.Parent then
            myTycoon = findMyTycoon()
            if myTycoon then
                resetBuyBlacklist()
                localQueue = {}
                queueIndex = 1
                print("[Coord] Tycoon re-found!")
            else
                task_wait(0.5)
                continue
            end
        end

        local remaining = #localQueue - queueIndex + 1
        if remaining == 0 then
            local added = appendNewButtons()
            if added > 0 then
                print("[Coord] Refill on empty: " .. added)
                task_wait(0.05)
            elseif allButtonsDead() then
                if anyGivenUpButtons() then
                    local now = tick_()
                    if now - lastResetTime > 2 then
                        lastResetTime = now
                        print("[Coord] given-up retry -> reset + scan")
                        resetBuyBlacklist()
                        localQueue = {}
                        queueIndex = 1
                        appendNewButtons()
                        task_wait(0.05)
                    else
                        task_wait(0.5)
                    end
                else
                    task_wait(0.5)
                end
            else
                task_wait(0.3)
            end
            continue
        end

        task_wait(0.3)
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
    LSM.zoomedIn = dir > 0
    for _ = 1, CFG.zoomTicks do
        LSM.lastBot = tick_()
        pcall_(mousescroll, CFG.zoomStep * dir)
        task_wait(0.02)
    end
end

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
    if type(mousescroll) == "function" then
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
    if autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4 then return false end

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
            local sp, on = WorldToScreen(vp)
            if on and sp and mabs(sp.X - cx) < vps.X * 0.18 and mabs(sp.Y - cy) < vps.Y * 0.18 then
                break
            end
            LSM.lastBot = tick_()
            if on and sp then
                mousemoverel(mfloor((sp.X - cx) * 0.5), mfloor((sp.Y - cy) * 0.5))
            else
                mousemoverel(0, -260)
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
        if autoBuyActive and not LSM.lemonSlot and (#localQueue - queueIndex + 1) > 0 then break end
        if autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4 then break end
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
            if autoBuyActive and not LSM.lemonSlot and (#localQueue - queueIndex + 1) > 0 then break end
            if autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4 then break end
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

        local buyBusy = lemonFarmActive and autoBuyActive and (#localQueue - queueIndex + 1) > 0
        if lemonFarmActive and LSM.annBuy ~= buyBusy then
            LSM.annBuy = buyBusy
            print(buyBusy and "[Lemon] pause: autobuy buying" or "[Lemon] autobuy done -> resume")
        end
        local afkNow = (tick_() - (S.lastUser or 0)) >= CFG.afkDelay

        if buyBusy and afkNow then
            if totalBought ~= LSM.lastBoughtN then
                LSM.lastBoughtN = totalBought
                LSM.buyProgressT = tick_()
            end
            if not LSM.buyProgressT then LSM.buyProgressT = tick_() end
            if (tick_() - LSM.buyProgressT) > CFG.buyStuck then LSM.lemonSlot = true end
        else
            LSM.buyProgressT = nil
            LSM.lastBoughtN = totalBought
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
        local standBusy = autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4
        if lemonFarmActive and hrp and (not buyBusy or LSM.lemonSlot == true) and not standBusy and afkNow then

            if not LSM.zoomedIn then
                pcall_(function() camera = Workspace.CurrentCamera end)
                LSM.zoom(1)
                pcall_(function()
                    local chrA = player.Character
                    local hA = chrA and chrA:FindFirstChild("HumanoidRootPart")
                    if hA then
                        camera.lookAt(hA.Position, hA.Position + Vec3(0, 12, 3))
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
                LSM.lastBoughtN = totalBought
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
                end
            end
            task_wait(CFG.slow and 0.6 or 0.3)
        else
            task_wait(0.2)
        end
    end
end)

local statusTx = D("Text", {Text = "", FontSize = 14, Size = 14, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(255, 214, 60)})
local statusTx2 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(222, 210, 170)})
local statusTx3 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(222, 210, 170)})
local statusTx4 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(222, 210, 170)})

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

        local mx, my = S.pmx, S.pmy
        if mouse then pcall_(function() mx = mouse.X; my = mouse.Y end) end
        local m1 = false
        pcall_(function() m1 = ismouse1pressed() end)

        if autoBuyActive and (#localQueue - queueIndex + 1) > 0 then
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

    if CFG.vineGo or CFG.vineBack then
        CFG.vineGo = false
        CFG.vineBack = false
        pcall_(function()
            local chr = player.Character
            local h = chr and chr:FindFirstChild("HumanoidRootPart")
            if not h then return end
            local nearVine = (h.Position - Vec3(39.7, -41.0, -77.5)).Magnitude < 40
            if nearVine then
                local ret = CFG.vineRet
                if ret then
                    h.CFrame = CF(ret.X, ret.Y + 1, ret.Z)
                    h.AssemblyLinearVelocity = Vec3(0, 0, 0)
                    CFG.vineRet = nil
                    rprint("[Vine] returned")
                end
            else
                CFG.vineRet = h.Position
                h.CFrame = CF(39.7, -41.0, -77.5)
                h.AssemblyLinearVelocity = Vec3(0, 0, 0)
                rprint("[Vine] at the vine - press again to return")
            end
        end)
    end

    if (nowA - (S.statusT or 0)) < (CFG.slow and 0.4 or 0.15) then return end
    S.statusT = nowA

    local vx = 960
    pcall_(function() vx = camera.ViewportSize.X * 0.5 end)
    local sy = 8
    if lemonFarmActive then
        local txt
        local qRem = #localQueue - queueIndex + 1
        if autoBuyActive and qRem > 0 then
            txt = "lemon farm  |  paused: auto buy working"
        elseif autoStandActive and (nowA - (LSM.standBusyT or 0)) < 4 then
            txt = "lemon farm  |  paused: auto stand working"
        else
            local idleT = nowA - (S.lastUser or 0)
            if idleT < CFG.afkDelay then
                txt = sformat("lemon farm  |  starts in %ds (stop moving)", mfloor(CFG.afkDelay - idleT) + 1)
            else
                txt = "lemon farm  |  FARMING (WASD = stop)"
            end
        end
        statusTx.Text = txt
        statusTx.Position = Vec2(vx, sy); sy = sy + 20
        statusTx.Visible = true
    else
        statusTx.Visible = false
    end
    if autoStandActive then
        local txt2
        if (nowA - (LSM.standBusyT or 0)) < 4 then
            txt2 = "auto stand  |  upgrading..."
        elseif LSM.standNextT and LSM.standNextT > nowA then
            txt2 = sformat("auto stand  |  next pass in %ds", mfloor(LSM.standNextT - nowA) + 1)
        else
            txt2 = "auto stand  |  ON"
        end
        statusTx2.Text = txt2
        statusTx2.Position = Vec2(vx, sy); sy = sy + 20
        statusTx2.Visible = true
    else
        statusTx2.Visible = false
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
            pcall_(function()
                if type(writefile) == "function" then
                    writefile("selllemons_vine.txt", tostring_(CFG.vineT))
                end
            end)
            rprint("[Vine] collected -> 4h cooldown started")
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
                if type(writefile) == "function" then
                    writefile("selllemons_vine.txt", tostring_(CFG.vineT))
                end
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
        statusTx3.Text = "cash vine  |  READY"
        statusTx3.Color = C3rgb(255, 214, 60)
        if not CFG.vineNotif then
            CFG.vineNotif = true
            pcall_(function() notify("Cash Vine is READY", "Sell Lemons", 4) end)
        end
        statusTx3.Position = Vec2(vx, sy); sy = sy + 20
        statusTx3.Visible = true
    elseif CFG.vineT then
        local rem = CFG.vineCd - (tick_() - CFG.vineT)
        if rem > 0 then
            statusTx3.Text = sformat("cash vine  |  %d:%02d:%02d", mfloor(rem / 3600), mfloor((rem % 3600) / 60), mfloor(rem % 60))
            statusTx3.Color = C3rgb(222, 210, 170)
        elseif vReady == false then
            statusTx3.Text = "cash vine  |  soon..."
            statusTx3.Color = C3rgb(222, 210, 170)
        else
            statusTx3.Text = "cash vine  |  READY"
            statusTx3.Color = C3rgb(255, 214, 60)
            if not CFG.vineNotif then
                CFG.vineNotif = true
                pcall_(function() notify("Cash Vine is READY", "Sell Lemons", 4) end)
            end
        end
        statusTx3.Position = Vec2(vx, sy); sy = sy + 20
        statusTx3.Visible = true
    else
        statusTx3.Visible = false
    end

    local mgName = MG.name()
    if mgName then
        local cd = MG.timerSec()
        if cd and cd > 0 then MG.miniEnd = tick_() + cd end
        local rem = MG.miniEnd and (MG.miniEnd - tick_()) or nil
        if rem and rem > 0 then
            statusTx4.Text = sformat("%s  |  %d:%02d", mgName, mfloor(rem / 60), mfloor(rem % 60))
            statusTx4.Color = C3rgb(222, 210, 170)
            MG.miniNotif = false
        elseif not MG.miniEnd then
            statusTx4.Text = mgName .. "  |  --"
            statusTx4.Color = C3rgb(222, 210, 170)
        else
            statusTx4.Text = mgName .. "  |  READY"
            statusTx4.Color = C3rgb(255, 214, 60)
            if MG.active and not MG.miniNotif then
                MG.miniNotif = true
                pcall_(function() notify(mgName .. " is READY", "Sell Lemons", 4) end)
            end
        end
        statusTx4.Position = Vec2(vx, sy)
        statusTx4.Visible = true
    else
        statusTx4.Visible = false
    end
end

RunService.RenderStepped:Connect(function()
    if not ScriptActive then return end
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
        return s == "no" or s == "nvm"
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

                local fired = false
                pcall_(function()
                    local rem = myTycoon and myTycoon:FindFirstChild("Remotes")
                    local po = rem and rem:FindFirstChild("PhoneOffer")
                    if po and tostring_(po.ClassName) == "RemoteEvent" then
                        po:FireServer("Accept")
                        fired = true
                    end
                end)
                if fired then
                    rprint("[Deal] accepted via remote")
                    task_wait(1)
                    return
                end

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
                rprint("[Deal] accepted: " .. btnText(best))
                task_wait(1)
            end)
        end
        task_wait(CFG.slow and 1.2 or 0.5)
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
                    MG.sessExit = 0; MG.sessCheck = 0
                    MG.spamCheer(cheer)
                    MG.raceEndT = tick_()
                    return
                end

                local justRaced = (tick_() - (MG.raceEndT or 0)) < 30

                local exitBtn = justRaced and MG.findBtn("EXIT") or nil
                if exitBtn then
                    MG.sessExit = (MG.sessExit or 0) + 1
                    if MG.sessExit <= 6 then
                        LSM.standBusyT = tick_()
                        MG.click(exitBtn)
                        task_wait(0.35)
                    else task_wait(0.5) end
                    return
                end

                local popUp = false
                if justRaced then
                    pcall_(function()
                        local pg = getPlayerGui()
                        local popup = pg and pg:FindFirstChild("Popup")
                        if popup then
                            local en; pcall_(function() en = popup.Enabled end)
                            if en ~= false and popup:FindFirstChild("Check") then popUp = true end
                        end
                    end)
                end
                if popUp then
                    MG.sessCheck = (MG.sessCheck or 0) + 1
                    if MG.sessCheck <= 6 then
                        LSM.standBusyT = tick_()
                        MG.clickCheck()
                        task_wait(0.35)
                    else task_wait(0.5) end
                    return
                end

                if MG.findBtn("PICK") then
                    LSM.standBusyT = tick_()
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
                MG.lastEntryTry = tick_()
                LSM.standBusyT = tick_()
                local pos = MG.entryPos()
                if pos then pcall_(function() _tpHrpTo(pos) end) end
                local started = false
                local play = MG.findBtn("PLAY", true)
                if play then MG.click(play) end
                for _ = 1, 12 do
                    if not MG.active then break end
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

        if autoBuyActive and _anyLiveButtons() then
            task_wait(0.3)
            continue
        end

        local res = runLocationsPass(firstRun)
        firstRun = false
        if res == "off" then
            task_wait(0.05)
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

_G.MatchaCleanup = function()
    pcall_(LSM.returnHome)
    pcall_(FX.restore)
    ScriptActive = false
    pcall_(function() if UIRef.win then UIRef.win.visible = false end end)
    for _, obj in ipairs_(drawObjs) do
        pcall_(function() obj:Remove() end)
    end
    print("[Hub] Cleanup done")
end

rprint("sell lemons v18.33 loaded")
