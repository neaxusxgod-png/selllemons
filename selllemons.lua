-- [[ SELL LEMONS v12 — TURBO buy (firetouchinterest автодетект) | возврат на место после АФК ]] --
if _G.MatchaCleanup then pcall(_G.MatchaCleanup) end
local ScriptActive = true

-- ==================== LOCAL CACHE (hot paths) ====================
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

-- v11.1: РЕЛИЗ-РЕЖИМ. homesick показывает каждый print() тостом на экране —
-- для паблика всё глушим. DEBUG = true вернёт логи. rprint = настоящий print
-- (им пишутся только реальные ошибки и одно сообщение о загрузке).
local DEBUG = false
local rprint = print
local print = function(...)
    if DEBUG then rprint(...) end
end

-- ==================== INIT ====================
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

setrobloxinput(true)

-- Cache del mouse (evita GetMouse() por frame)
local mouse = nil
pcall_(function() mouse = player:GetMouse() end)

-- ==================== ERROR REPORTS (v7.2) ====================
-- Любая ошибка в циклах больше не убивает корутину молча: печатается в
-- консоль с тегом, повторы схлопываются (x N), цикл перезапускается.
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
            if ok then break end          -- цикл завершился штатно
            reportErr(tag, err)
            task_wait(0.5)                -- и перезапускаем после ошибки
        end
    end)
end

local autoBuyActive    = false
local lemonFarmActive  = false
local cashFarmActive   = false   -- v5.18: ya NO arranca solo; se activa con tecla 4 o GUI
local autoStandActive  = false
local _standIsTapping  = false   -- Gate: true while AutoStand is in E-tap phase

local buyBlacklist    = {}
local failedButtons   = {}
local buyAttempt      = {}   -- v5.19: [key] = {tries=, next=} backoff (reemplaza blacklist permanente)

local function getButtonKey(v)
    if not v then return nil end
    local pos = v.Position
    if not pos then return nil end
    return sformat("%d,%d,%d", mfloor(pos.X + 0.5), mfloor(pos.Y + 0.5), mfloor(pos.Z + 0.5))
end

local function resetBuyBlacklist()
    buyBlacklist  = {}
    failedButtons = {}
    buyAttempt    = {}
    print("[Hub] Blacklist RESET!")
end

-- v5.21: backoff temporal en vez de blacklist permanente por "2 fails".
-- Un boton que falla NUNCA se descarta para siempre: se reintenta mas tarde
-- (0.35s -> x2 -> tope 4s). Solo tras 6 fallos REALES se da por no-comprable.
-- Asi nada presente+comprable se "pierde" por un tick lento del server.
local function buyReady(key, v)
    local a = buyAttempt[key]
    if not a then return true end
    if v and a.inst and a.inst ~= v then
        buyAttempt[key] = nil   -- на этой позиции уже другая кнопка: запись протухла
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
-- v7.6: блеклист привязан к ИНСТАНСУ кнопки, а не к позиции навсегда.
-- Тайкуны переиспользуют позиции: после покупки на том же месте спавнится
-- НОВАЯ кнопка — раньше она наследовала бан по ключу-позиции и пропускалась
-- (симптом: q 0 при живой цветной кнопке). Другой инстанс = запись чистится.
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

print("=== SELL LEMONS v11 ===")

-- ==================== GUI v11: homesick (родная библиотека Матчи) ====================
-- Вместо самодельного Drawing-гуи — homesick: окно, вкладки, тогглы с
-- кейбиндами, автосохранение конфига. Поверх игры остаётся только одна
-- жёлтая статус-строка лимонки (кулдаун/FARMING).
local drawObjs = {}
local function D(typ, props)
    local obj = Drawing.new(typ)
    for k, v in pairs_(props) do pcall_(function() obj[k] = v end) end
    tinsert(drawObjs, obj)
    return obj
end

local CFG = {
    buyWindow = 0.45,   -- окно подтверждения покупки (worker)
    afkDelay  = 5,      -- сек без инпута до старта лимонки
    zoomTicks = 16,     -- щелчков скролла в первое лицо (было 10 - не хватало)
    zoomStep  = 1,      -- если зум не в ту сторону - поставить -1
    standRest = 60,     -- АвтоСтенд проходится раз в минуту, когда лимонка включена
}

local S = {
    lastUser = tick_(), pmx = 0, pmy = 0, keyDown = {}, lastFire = {},
}
local UX = {}
function UX.fire(id)
    local now = tick_()
    if S.lastFire[id] and (now - S.lastFire[id]) < 0.30 then return false end
    S.lastFire[id] = now
    return true
end

-- ---- Загрузка homesick ----
local homesick
do
    local ok, err = pcall_(function()
        loadstring(game:HttpGet("https://raw.githubusercontent.com/sharedechoes/Matcha-Luas/refs/heads/main/homesick.lua"))()
    end)
    homesick = _G.homesick
    if not homesick then pcall_(function() homesick = shared.homesick end) end
    if not homesick then
        print("[Hub] homesick UI не загрузился (" .. tostring(err) .. ") — клавиши 1-5 работают как фоллбэк")
    end
end

local UIRef = { win = nil, t = {} }

-- Состояние пишут коллбэки homesick напрямую; syncFromUI остался пустым,
-- потому что его зовут все воркеры (менять их не надо).
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
    print("[Hub] Everything stopped!")
end

-- Фоллбэк-тогглер (клавиши 1-5, если homesick не загрузился)
local function toggleFeature(slot)
    if not UX.fire("slot" .. slot) then return end
    if     slot == 1 then autoBuyActive   = not autoBuyActive
    elseif slot == 2 then lemonFarmActive = not lemonFarmActive
    elseif slot == 3 then autoStandActive = not autoStandActive
    elseif slot == 4 then cashFarmActive  = not cashFarmActive
    elseif slot == 5 then stopAll(); return
    else return end
    syncToUI()
    print("[Hub] toggle slot " .. slot)
end

-- ---- Окно ----
if homesick then
    pcall_(function() homesick.changelogEnabled = false end)
    local window = homesick.createWindow("sell lemons", 420, 360)
    pcall_(function() window:autoloadConfig("selllemons_config") end)
    pcall_(function() window:autoloadTheme("theme") end)
    UIRef.win = window

    local tab1 = window:addTab("automation")
    local left = tab1:addSection("automation", "Left")

    UIRef.t.AutoBuy = left:addToggle("autoBuy", "auto buy", false, function(val)
        autoBuyActive = val
        print("[Hub] toggle AutoBuy = " .. tostring_(val))
    end):addKeybind("1", "Toggle", true, function() end)

    UIRef.t.LemonFarm = left:addToggle("lemonFarm", "lemon farm", false, function(val)
        lemonFarmActive = val
        print("[Hub] toggle LemonFarm = " .. tostring_(val))
    end):addKeybind("2", "Toggle", true, function() end)

    UIRef.t.AutoStand = left:addToggle("autoStand", "auto stand", false, function(val)
        autoStandActive = val
        print("[Hub] toggle AutoStand = " .. tostring_(val))
    end):addKeybind("3", "Toggle", true, function() end)

    UIRef.t.CashFarm = left:addToggle("cashFarm", "cash farm", false, function(val)
        cashFarmActive = val
        print("[Hub] toggle CashFarm = " .. tostring_(val))
    end):addKeybind("4", "Toggle", true, function() end)

    local right = tab1:addSection("other", "Right")

    UIRef.t.StopAll = right:addToggle("stopAll", "stop all", false, function(val)
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

    window.visible = true
    window:render()
    print("[Hub] homesick UI loaded - keys 1-5 via keybinds")
end

-- ==================== AUTOBUY ====================
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

-- ==================== CACHE DE CARPETAS "Buttons" ====================
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

local function getButtonsRealTime()
    if not buttonsCacheReady then
        buildButtonsCache()
        if not buttonsCacheReady then return {} end
    end

    -- ORIGINAL (v5.17): junta TODOS los "Button" BasePart bajo cada model,
    -- incluyendo los anidados (model "Button" -> part "Button"). NO tocar:
    -- la version "optimizada" rompia el scan en este tycoon (encontraba 0-1).
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
    return temp
end

-- ==================== CACHE DE LEMON TREES ====================
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

local function getCashDropsFast()
    local folder = Workspace:FindFirstChild("CashDrops")
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

-- (v6.0) Хоткеи 1-5 и Insert теперь в INPUT-блоке внизу файла.

-- v7.4: режим сбора лимонов (автоопределяется на первых фруктах, см. ниже)
local LSM = { mode = nil, annAfk = false, annBuy = false }   -- nil=детект | "cd" | "sig" | "touch" | "classic"; ann-флаги СРАЗУ false (nil давал ложный переход)
-- v7.7: ручные точки стендов — клавиша 6 запоминает позицию персонажа,
-- АвтоСтенд ТПшится в каждую и жмёт E. Корды печатаются для хардкода.
local standManual = {
    Vec3(34.0, 6.7, -359.0),   -- Lemon stand (оператор дал корды 2026-06-09)
}

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

-- ==================== SISTEMA v5.2 - 1 WORKER + COLA LOCAL PERSISTENTE ====================
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
    local buttons = getButtonsRealTime()
    if #buttons == 0 then return false end
    for _, v in ipairs_(buttons) do
        local key = getButtonKey(v)
        if key then
            local a = buyAttempt[key]
            if a and a.inst and a.inst ~= v then buyAttempt[key] = nil; a = nil end
            local givenUp = a and a.n >= 6
            if not isBlacklisted(key, v) and not isGreyedOut(v) and not givenUp then
                return false
            end
        end
    end
    return true
end

-- v7.0: ''все мертвы'' бывает по двум причинам: (а) все кнопки СЕРЫЕ -> просто
-- не хватает денег; резет блеклиста тут НИЧЕГО не даёт, надо тихо ждать кэш;
-- (б) есть given-up кнопки (6 реальных провалов) -> вот им резет даёт второй
-- шанс. Резетим только в случае (б) — убирает спам ''ALL DEAD! Reset'' каждые 2с.
local function anyGivenUpButtons()
    local buttons = getButtonsRealTime()
    for _, v in ipairs_(buttons) do
        local key = getButtonKey(v)
        if key then
            local a = buyAttempt[key]
            if a and a.inst and a.inst ~= v then
                buyAttempt[key] = nil
            elseif a and a.n >= 6 and not isBlacklisted(key, v) then
                return true
            end
        end
    end
    return false
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


-- ==================== AUTO STAND (TP a Purchases/* y spam E) ====================
local STAND_KEY            = 0x45             -- Windows VK_E.
local STAND_PRESSES        = 1
local STAND_TP_SETTLE      = 0.05
local STAND_CYCLE_PAUSE    = 0.02
local STAND_TP_Y_OFFSET    = 3
local STAND_RECHECK_EVERY  = 1
local STAND_FOLDER_PREFIX  = "Lemon"
local STAND_LOOP_DELAY     = 0.1

local standCache = {}
local STAND_CACHE_TTL = 5.0
local STAND_USE_PRICE_GATE = true
local STAND_REQUIRE_PRICE  = false  -- v7.4: цена не нашлась -> всё равно ТП+E (чинит Lemon stand)
local STAND_PRICE_PATH     = {"Upgrade", "Price"}
local TIER_DIAGNOSTICS      = true
local TIER_REMOTE_FIRST     = true
local TIER_GUI_SIGNAL       = true
local TIER_PROXIMITY        = true
local TIER_FALLBACK_TP      = true

local tierStats = { remote = 0, gui = 0, proximity = 0, tp = 0, fail = 0 }


local function _modelPivotPos(model)
    if not model then return nil end
    local pp = model.PrimaryPart
    if pp then
        local ok2, p = pcall_(function() return pp.Position end)
        if p then return p end
    end
    local ok, piv = pcall_(function() return model:GetPivot() end)
    if piv then
        local ok2, p = pcall_(function() return piv.Position end)
        if p then return p end
    end
    local ok, desc = pcall_(function() return model:GetDescendants() end)
    if desc then
        for _, d in ipairs_(desc) do
            local isBase = d:IsA("BasePart")
            if isBase then
                local ok3, p = pcall_(function() return d.Position end)
                if p then return p end
            end
        end
    end
    local ok, cf = pcall_(function() return model:GetBoundingBox() end)
    if cf then
        local ok2, p = pcall_(function() return cf.Position end)
        if p then return p end
    end
    return nil
end

local function _isPlaceholderModel(model)
    if not model then return true end
    local ok, kids = pcall_(function() return model:GetChildren() end)
    if not ok or not kids or #kids == 0 then return true end
    if #kids > 1 then return false end
    local c = kids[1]
    local isBase = c:IsA("BasePart")
    if isBase then
        local sameName = c.Name == model.Name
        if sameName then return true end
        return false
    end
    local isMdl = c:IsA("Model")
    if isMdl then return _isPlaceholderModel(c) end
    return true
end

local function _findStandModel(folder)
    local ok, kids = pcall_(function() return folder:GetChildren() end)
    if kids then
        for _, c in ipairs_(kids) do
            local isModel = c:IsA("Model")
            if isModel and c.Name == folder.Name then
                if not _isPlaceholderModel(c) then return c end
            end
        end
        for _, c in ipairs_(kids) do
            local isModel = c:IsA("Model")
            if isModel and not _isPlaceholderModel(c) then return c end
        end
    end
    local ok, desc = pcall_(function() return folder:GetDescendants() end)
    if desc then
        for _, d in ipairs_(desc) do
            local isModel = d:IsA("Model")
            if isModel then
                local pp = d.PrimaryPart
                if pp and not _isPlaceholderModel(d) then return d end
            end
        end
    end
    return nil
end

local function getStandTargets(verbose)
    local out = {}
    if not myTycoon then
        if verbose then print("[Stand] myTycoon nil") end
        return out
    end
    local purchases
    pcall_(function() purchases = myTycoon:FindFirstChild("Purchases") end)
    if not purchases then
        if verbose then print("[Stand] Purchases folder no encontrado en " .. tostring(myTycoon:GetFullName())) end
        return out
    end
    local kids; pcall_(function() kids = purchases:GetChildren() end)
    if not kids then return out end
    local prefix = (STAND_FOLDER_PREFIX or ""):lower()
    local skipped, noModel, noPos = 0, 0, 0
    local now = tick_()
    for _, folder in ipairs_(kids) do
        local nm = tostring(folder.Name)
        if prefix ~= "" and nm:lower():sub(1, #prefix) ~= prefix then
            skipped = skipped + 1
        else
            local cached = standCache[folder]
            local model, pos
            if cached and (now - cached.ts) < STAND_CACHE_TTL then
                model = cached.model
                pos = cached.pos
            else
                model = _findStandModel(folder)
                if model then
                    pos = _modelPivotPos(model)
                end
                standCache[folder] = {model = model, pos = pos, ts = now}
            end
            if not model then
                noModel = noModel + 1
                if verbose then print("[Stand]   " .. nm .. " -> sin Model") end
            elseif not pos then
                noPos = noPos + 1
                if verbose then print("[Stand]   " .. nm .. " -> Model sin pos") end
            else
                tinsert(out, {folder = folder, model = model, pos = pos, name = nm})
            end
        end
    end
    if verbose then
        print(string.format("[Stand] Purchases hijos=%d  match-prefix=%d  no-model=%d  no-pos=%d  validos=%d",
            #kids, #kids - skipped, noModel, noPos, #out))
    end
    return out
end

local function _tpHrpTo(pos)
    -- v10: метка ''стенд работает'' — лимонка не дёргает персонажа 4с после
    -- каждого стендового ТП (защищено от зависания: метка протухает сама)
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

local function _parsePriceText(s)
    if not s then return nil end
    s = tostring(s):gsub("%s", "")
    local cleaned = s:gsub("[^%d%.kKmMbBtT]", "")
    if cleaned == "" then return nil end
    local mult = 1
    local last = cleaned:sub(-1):lower()
    if last == "k" then mult = 1e3
    elseif last == "m" then mult = 1e6
    elseif last == "b" then mult = 1e9
    elseif last == "t" then mult = 1e12 end
    if mult ~= 1 then cleaned = cleaned:sub(1, -2) end
    local n = tonumber(cleaned)
    if not n then return nil end
    return n * mult
end

local function _getCash()
    local ls; pcall_(function() ls = player:FindFirstChild("leaderstats") end)
    if not ls then return nil end
    local c; pcall_(function() c = ls:FindFirstChild("Cash") end)
    if not c then return nil end
    local v; pcall_(function() v = c.Value end)
    if type(v) == "number" then return v end
    return _parsePriceText(v)
end

local function _resolveStandGui(standName)
    local pg; pcall_(function() pg = player:FindFirstChildOfClass("PlayerGui") end)
    if not pg then return nil end
    local g; pcall_(function() g = pg:FindFirstChild(standName) end)
    if g then return g end
    local stripped = (standName or ""):gsub("%s+", "")
    if stripped ~= standName then
        pcall_(function() g = pg:FindFirstChild(stripped) end)
        if g then return g end
    end
    local low = stripped:lower()
    local kids; pcall_(function() kids = pg:GetChildren() end)
    if kids then
        for _, c in ipairs_(kids) do
            local nm = tostring(c.Name):gsub("%s+", ""):lower()
            if nm == low then return c end
        end
    end
    for _, suf in ipairs_({" Ground", " Top", " Base", " Floor", " Roof"}) do
        if standName:sub(-#suf):lower() == suf:lower() then
            local root = standName:sub(1, -#suf - 1)
            local sub = _resolveStandGui(root)
            if sub then return sub end
        end
    end
    return nil
end

local function _extractNumber(node)
    if not node then return nil end
    local isVal = node:IsA("ValueBase")
    if isVal then
        local v; pcall_(function() v = node.Value end)
        if type(v) == "number" then return v end
        local n = _parsePriceText(v)
        if n then return n end
    end
    local isText = node:IsA("GuiObject") and (node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox"))
    if isText then
        local t; pcall_(function() t = node.Text end)
        local n = _parsePriceText(t)
        if n then return n end
    end
    return nil
end

local _STAND_PRICE_DIAG_SHOWN = {}
local function _getStandPrice(standName, debugLog)
    local gui = _resolveStandGui(standName)
    if not gui then return nil end
    local node = gui
    for _, segment in ipairs_(STAND_PRICE_PATH) do
        local nxt; pcall_(function() nxt = node:FindFirstChild(segment) end)
        node = nxt
        if not node then break end
    end
    if node then
        local n = _extractNumber(node)
        if n then return n end
        local desc; pcall_(function() desc = node:GetDescendants() end)
        if desc then
            for _, d in ipairs_(desc) do
                local n2 = _extractNumber(d)
                if n2 then return n2 end
            end
        end
    end
    local altPaths = {
        {"Upgrade", "Cost"},
        {"Upgrade", "Amount"},
        {"Upgrade", "Price", "Amount"},
        {"Upgrade", "Price", "Value"},
        {"Cost"},
        {"Price"},
        {"Main", "Upgrade", "Price"},
        {"Frame", "Upgrade", "Price"},
    }
    for _, p in ipairs_(altPaths) do
        local cur = gui
        for _, seg in ipairs_(p) do
            local nxt; pcall_(function() nxt = cur:FindFirstChild(seg) end)
            cur = nxt
            if not cur then break end
        end
        if cur then
            local n = _extractNumber(cur)
            if n then return n end
        end
    end
    local desc; pcall_(function() desc = gui:GetDescendants() end)
    if desc then
        for _, d in ipairs_(desc) do
            local n = _extractNumber(d)
            if n then return n end
        end
    end
    if debugLog and not _STAND_PRICE_DIAG_SHOWN[standName] then
        _STAND_PRICE_DIAG_SHOWN[standName] = true
        print("[Stand][DIAG] " .. standName .. " GUI=" .. gui:GetFullName())
        local kids2; pcall_(function() kids2 = gui:GetDescendants() end)
        if kids2 then
            local shown = 0
            for _, d in ipairs_(kids2) do
                if shown >= 25 then break end
                local cls = d.ClassName
                local nm = tostring(d.Name)
                local txt; pcall_(function() txt = d.Text end)
                local val; pcall_(function() val = d.Value end)
                print(sformat("  - %s  [%s]  text=%s  value=%s",
                    nm, tostring(cls), tostring(txt), tostring(val)))
                shown = shown + 1
            end
        end
    end
    return nil
end

-- v5.18: helper de precio que faltaba (antes 'canAffordStand' era nil -> crash en runStandPass).
-- Devuelve (puedePagar:boolean|nil, precio:number|nil, cash:number|nil).
-- nil = no se pudo determinar el precio: si STAND_REQUIRE_PRICE es true, NO TPea.
local function canAffordStand(folder)
    if not folder then return nil, nil, nil end
    local name
    pcall_(function() name = tostring(folder.Name) end)
    local cash  = _getCash()
    local price = name and _getStandPrice(name, false) or nil
    if not price then
        if STAND_REQUIRE_PRICE then return false, nil, cash end
        return nil, nil, cash
    end
    if not cash then
        return nil, price, nil
    end
    return (cash >= price), price, cash
end

local function _tapKeyOnce(key)
    if not _windowFocused() then return false end
    keypress(key)
    task_wait()
    keyrelease(key)
    return true
end

local STAND_PRESS_HOLD = 0
local function _pressKeyMany(key, n)
    for i = 1, n do
        if not autoStandActive then return false end
        if not _windowFocused() then
            task_wait(0.2)
            return false
        end
        keypress(key)
        if STAND_PRESS_HOLD > 0 then
            task_wait(STAND_PRESS_HOLD)
        else
            task_wait()
        end
        keyrelease(key)
    end
    return true
end

local function _anyLiveButtons()
    local buttons = getButtonsRealTime()
    if #buttons == 0 then return false end
    for _, v in ipairs_(buttons) do
        local key = getButtonKey(v)
        if key then
            local a = buyAttempt[key]
            if a and a.inst and a.inst ~= v then buyAttempt[key] = nil; a = nil end
            local givenUp = a and a.n >= 6
            if not isBlacklisted(key, v) and not isGreyedOut(v) and not givenUp then
                return true
            end
        end
    end
    return false
end

-- ==================== AUTO STAND - MANAGE+TP HYBRID MODE ====================
local STAND_MODE = "manage"
local STAND_MANAGE_PATH = {"Manage", "ManageMenu", "Body", "Frame", "Manage"}
local STAND_MANAGE_BLANK_PREFIX = "Blank"
local STAND_MANAGE_CLICK_DELAY  = 0.05

local STAND_E_SPAM_DURATION = 1.5
local STAND_E_SPAM_INTERVAL = 0.018

local function _findScrollAncestor(obj)
    local cur = obj
    while cur and cur.Parent do
        cur = cur.Parent
        local isScroll = cur:IsA("ScrollingFrame")
        if isScroll then return cur end
        if cur:IsA("ScreenGui") then break end
    end
    return nil
end

local function _ensureVisibleInScroll(child)
    if not child or not child.Parent then return false end
    local sf = _findScrollAncestor(child)
    if not sf then return true end
    local ok, err = pcall_(function()
        local childY    = child.AbsolutePosition.Y
        local sfY       = sf.AbsolutePosition.Y
        local viewportH = sf.AbsoluteWindowSize.Y
        local childH    = child.AbsoluteSize.Y
        local relTop    = childY - sfY
        local relBot    = relTop + childH
        local cur       = sf.CanvasPosition
        if relTop < 0 then
            sf.CanvasPosition = Vec2(cur.X, math.max(0, cur.Y + relTop - 4))
        elseif relBot > viewportH then
            sf.CanvasPosition = Vec2(cur.X, cur.Y + (relBot - viewportH) + 4)
        end
    end)
    task_wait() ; task_wait()
    return ok
end

local GUI_BG_COLOR_OFFSET = 0x540

local STAND_INACTIVE_RGB    = {0.49, 0.49, 0.49}
local STAND_COLOR_TOLERANCE = 0.06

local function _readGuiBgColor(guiObject)
    if not guiObject then return nil end
    local addr; pcall_(function() addr = tonumber(guiObject.Address) end)
    if not addr or addr <= 4096 then return nil end
    if type(memory_read) ~= "function" then return nil end
    local okR, r = pcall_(memory_read, "float", addr + GUI_BG_COLOR_OFFSET)
    if not okR then return nil end
    local okG, g = pcall_(memory_read, "float", addr + GUI_BG_COLOR_OFFSET + 4)
    if not okG then return nil end
    local okB, b = pcall_(memory_read, "float", addr + GUI_BG_COLOR_OFFSET + 8)
    if not okB then return nil end
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
    if r < -0.01 or r > 1.01 or g < -0.01 or g > 1.01 or b < -0.01 or b > 1.01 then return nil end
    return r, g, b
end

local function _isUpgradeActive(upg)
    local r, g, b = _readGuiBgColor(upg)
    if not r then return nil end
    local tol = STAND_COLOR_TOLERANCE
    local ir, ig, ib = STAND_INACTIVE_RGB[1], STAND_INACTIVE_RGB[2], STAND_INACTIVE_RGB[3]
    if math.abs(r - ir) <= tol and math.abs(g - ig) <= tol and math.abs(b - ib) <= tol then
        return false, r, g, b
    end
    return true, r, g, b
end

local STAND_INACTIVE_RETEST_AFTER = 8
local _standInactiveSince = {}

local function _readUpgradeState(upgBtn)
    if not upgBtn then return "" end
    local parts = {}
    for _, childName in ipairs_({"Count", "Price", "Stack"}) do
        local c; pcall_(function() c = upgBtn:FindFirstChild(childName) end)
        if c then
            local t; pcall_(function() t = c.Text end)
            tinsert(parts, tostring(t or ""))
        else
            tinsert(parts, "")
        end
    end
    return table.concat(parts, "|")
end

local function _shouldSkipInactive(name)
    local t = _standInactiveSince[name]
    if not t then return false end
    if (tick_() - t) > STAND_INACTIVE_RETEST_AFTER then
        _standInactiveSince[name] = nil
        return false
    end
    return true
end

local function _markInactive(name) _standInactiveSince[name] = tick_() end
local function _markActive(name)   _standInactiveSince[name] = nil end

local function _findPurchaseFolderForStand(standName)
    if not myTycoon then return nil end
    local purchases; pcall_(function() purchases = myTycoon:FindFirstChild("Purchases") end)
    if not purchases then return nil end
    local f; pcall_(function() f = purchases:FindFirstChild(standName) end)
    if f then return f end
    local target = standName:gsub("%s+", ""):lower()
    local kids; pcall_(function() kids = purchases:GetChildren() end)
    if not kids then return nil end
    for _, c in ipairs_(kids) do
        local nm = tostring(c.Name):gsub("%s+", ""):lower()
        if nm == target then return c end
    end
    return nil
end

local function _spamKeyFor(key, durationSec, intervalSec)
    if key == 0x45 then
        if not _windowFocused() then
            task_wait(0.2)
            return false
        end

        _standIsTapping = true
        local t0 = tick_()
        while autoStandActive do
            if (tick_() - t0) >= durationSec then break end
            if not _windowFocused() then break end
            keypress(0x45)
            task_wait(0.015)
            keyrelease(0x45)
            task_wait(0.015)
        end
        keyrelease(0x45)
        _standIsTapping = false
        return true
    end

    local t0 = tick_()
    while autoStandActive and (tick_() - t0) < durationSec do
        if not _windowFocused() then
            task_wait(0.2)
            return false
        end
        keypress(key)
        task_wait()
        keyrelease(key)
        if intervalSec and intervalSec > 0 then
            task_wait(intervalSec)
        else
            task_wait()
        end
    end
    return true
end

local function _getManageRoot()
    local pg; pcall_(function() pg = player:FindFirstChildOfClass("PlayerGui") end)
    if not pg then return nil end
    local node = pg
    for _, seg in ipairs_(STAND_MANAGE_PATH) do
        local nxt; pcall_(function() nxt = node:FindFirstChild(seg) end)
        if not nxt then return nil end
        node = nxt
    end
    return node
end

local function _getManageStands()
    local out = {}
    local root = _getManageRoot()
    if not root then return out end
    local kids; pcall_(function() kids = root:GetChildren() end)
    if not kids then return out end
    for _, c in ipairs_(kids) do
        local isFrame = c:IsA("Frame")
        if isFrame then
            local nm = tostring(c.Name)
            if nm:sub(1, #STAND_MANAGE_BLANK_PREFIX) ~= STAND_MANAGE_BLANK_PREFIX then
                local upg; pcall_(function() upg = c:FindFirstChild("Upgrade") end)
                if upg then
                    local isBtn = upg:IsA("GuiButton")
                    if isBtn then
                        local priceLbl; pcall_(function() priceLbl = upg:FindFirstChild("Price") end)
                        local priceText = nil
                        if priceLbl then pcall_(function() priceText = priceLbl.Text end) end
                        tinsert(out, {frame=c, upgrade=upg, name=nm, priceText=priceText})
                    end
                end
            end
        end
    end
    return out
end

local function _clickGuiButton(btn)
    if not btn or not btn.Parent then return false end
    local fired = false
    if type(firesignal) == "function" then
        pcall_(function()
            if btn.Activated then
                firesignal(btn.Activated, Enum.UserInputType.MouseButton1)
                fired = true
            end
        end)
        pcall_(function()
            if btn.MouseButton1Click then
                firesignal(btn.MouseButton1Click)
                fired = true
            end
        end)
    end
    return fired
end

local function runManagePass(verbose)
    local stands = _getManageStands()
    if #stands == 0 then
        if verbose then
            print("[Stand][Manage+TP] Manage no encontrado o vacio. Abri el menu Manage al menos una vez.")
        end
        return "done"
    end
    print(sformat("[Stand][Manage+TP] Pasada start, %d desbloqueados", #stands))
    local tapped, skipped_color, skipped_cache, fallback_used = 0, 0, 0, 0
    for i, s in ipairs_(stands) do
        if not autoStandActive then return "off" end
        local active, cr, cg, cb = _isUpgradeActive(s.upgrade)
        if active == false then
            skipped_color = skipped_color + 1
            if verbose then
                print(sformat("[Stand][Manage+TP] [%d/%d] %s -> INACTIVO (gris %.2f,%.2f,%.2f)",
                    i, #stands, tostring(s.name), cr or 0, cg or 0, cb or 0))
            end
            task_wait(0.005)
            continue
        end
        local useFallback = (active == nil)
        if useFallback then
            fallback_used = fallback_used + 1
            if _shouldSkipInactive(s.name) then
                skipped_cache = skipped_cache + 1
                task_wait(0.005)
                continue
            end
        end
        local folder = _findPurchaseFolderForStand(s.name)
        if not folder then
            print(sformat("[Stand][Manage+TP] [%d/%d] %s -> no Purchases match",
                i, #stands, tostring(s.name)))
            task_wait(STAND_CYCLE_PAUSE)
            continue
        end
        local model = _findStandModel(folder)
        local pos   = model and _modelPivotPos(model) or nil
        if not pos then
            print(sformat("[Stand][Manage+TP] [%d/%d] %s -> sin pos TPeable",
                i, #stands, tostring(s.name)))
            task_wait(STAND_CYCLE_PAUSE)
            continue
        end
        local before = useFallback and _readUpgradeState(s.upgrade) or nil
        if not _tpHrpTo(pos) then
            print(sformat("[Stand][Manage+TP] [%d/%d] %s -> TP fallo",
                i, #stands, tostring(s.name)))
            task_wait(STAND_CYCLE_PAUSE)
            continue
        end
        _spamKeyFor(STAND_KEY, STAND_E_SPAM_DURATION, STAND_E_SPAM_INTERVAL)
        tapped = tapped + 1
        if useFallback then
            local after = _readUpgradeState(s.upgrade)
            if before == after then
                _markInactive(s.name)
                print(sformat("[Stand][Manage+TP] [%d/%d] %s -> [fallback] sin cambio, INACTIVO %ds",
                    i, #stands, tostring(s.name), STAND_INACTIVE_RETEST_AFTER))
            else
                _markActive(s.name)
                print(sformat("[Stand][Manage+TP] [%d/%d] %s -> [fallback] COMPRO! (%s->%s)",
                    i, #stands, tostring(s.name), tostring(before), tostring(after)))
            end
        else
            print(sformat("[Stand][Manage+TP] [%d/%d] %s -> ACTIVO TP+E %.1fs (color %.2f,%.2f,%.2f)",
                i, #stands, tostring(s.name), STAND_E_SPAM_DURATION, cr or 0, cg or 0, cb or 0))
        end
        task_wait(STAND_CYCLE_PAUSE)
    end
    print(sformat("[Stand][Manage+TP] Pasada end. tap=%d skip_color=%d skip_cache=%d fallback=%d",
        tapped, skipped_color, skipped_cache, fallback_used))
    return "done"
end

-- ==================== TIER 1: REMOTE SCAN (hookless) ====================
local ReplicatedStorage = nil
pcall_(function() ReplicatedStorage = game:GetService("ReplicatedStorage") end)

local cachedUpgradeRemotes = nil
local cachedRemoteScanTime = 0
local REMOTE_CACHE_TTL = 30

local function findUpgradeRemotes()
    local candidates = {}
    local function scan(parent)
        local kids
        pcall_(function() kids = parent:GetDescendants() end)
        if not kids then return end
        for _, d in ipairs_(kids) do
            local isRF = d:IsA("RemoteFunction")
            if isRF and d.Name:lower():match("upgrade") then
                tinsert(candidates, d)
            end
            local isRE = d:IsA("RemoteEvent")
            if isRE and d.Name:lower():match("upgrade") then
                tinsert(candidates, d)
            end
        end
    end
    if ReplicatedStorage then scan(ReplicatedStorage) end
    if myTycoon then pcall_(function() scan(myTycoon) end) end
    return candidates
end

local function getUpgradeRemotes()
    local now = tick_()
    if cachedUpgradeRemotes and (now - cachedRemoteScanTime) < REMOTE_CACHE_TTL then
        return cachedUpgradeRemotes
    end
    cachedUpgradeRemotes = findUpgradeRemotes()
    cachedRemoteScanTime = now
    return cachedUpgradeRemotes
end

local function tryRemoteUpgrade(standName, level)
    local remotes = getUpgradeRemotes()
    if not remotes or #remotes == 0 then return false, "no_remotes" end
    for _, remote in ipairs_(remotes) do
        local ok, res = pcall_(function()
            if remote:IsA("RemoteFunction") then
                return remote:InvokeServer(standName, level or 1)
            else
                remote:FireServer(standName, level or 1)
                return true
            end
        end)
        if ok then return true, "ok" end
    end
    return false, "all_remotes_failed"
end

-- ==================== TIER 2: GUI SIGNAL (hookless) ====================
local function fireUpgradeGui(standName)
    local playerGui
    pcall_(function() playerGui = player:WaitForChild("PlayerGui", 2) end)
    if not playerGui then return false, "no_playergui" end

    local function scanGui(parent)
        local kids
        pcall_(function() kids = parent:GetDescendants() end)
        if not kids then return false, "no_descendants" end
        for _, d in ipairs_(kids) do
            local ok, isButton = pcall_(function()
                return d:IsA("TextButton") or d:IsA("ImageButton")
            end)
            if isButton then
                local nameMatch = false
                pcall_(function()
                    local n = d.Name:lower()
                    nameMatch = n:match("upgrade") or n:match(standName:lower())
                end)
                if nameMatch then
                    local fired = false
                    pcall_(function()
                        if d.MouseButton1Click then
                            firesignal(d.MouseButton1Click)
                            fired = true
                        elseif d.Activated then
                            firesignal(d.Activated)
                            fired = true
                        end
                    end)
                    if fired then return true, "signal_fired" end
                end
            end
        end
        return false, "no_button_found"
    end
    return scanGui(playerGui)
end

-- ==================== TIER 3: PROXIMITY PROMPT (hookless) ====================
local function triggerProximityPrompt(standModel)
    local desc
    pcall_(function() desc = standModel:GetDescendants() end)
    if not desc then return false, "no_descendants" end
    for _, d in ipairs_(desc) do
        local isPrompt = d:IsA("ProximityPrompt")
        if isPrompt then
            local triggered = false
            pcall_(function()
                if fireproximityprompt then
                    fireproximityprompt(d)
                    triggered = true
                else
                    d:InputHoldBegin()
                    task_wait(d.HoldDuration + 0.05)
                    d:InputHoldEnd()
                    triggered = true
                end
            end)
            if triggered then return true, "prompt_fired" end
        end
    end
    return false, "no_prompt"
end

-- ==================== TIERED EXECUTION WITH DIAGNOSTICS ====================
local function tieredUpgrade(target, level)
    local name = target.name or "?"
    local pos = target.pos

    if TIER_REMOTE_FIRST then
        local ok, reason = tryRemoteUpgrade(name, level)
        if ok then
            if TIER_DIAGNOSTICS then print("[Tier] Remote OK: " .. name) end
            tierStats.remote = tierStats.remote + 1
            return true, "remote"
        else
            if TIER_DIAGNOSTICS then print("[Tier] Remote FAIL (" .. reason .. "): " .. name) end
        end
    end

    if TIER_GUI_SIGNAL then
        local ok2, reason2 = fireUpgradeGui(name)
        if ok2 then
            if TIER_DIAGNOSTICS then print("[Tier] GUI OK: " .. name) end
            tierStats.gui = tierStats.gui + 1
            return true, "gui"
        else
            if TIER_DIAGNOSTICS then print("[Tier] GUI FAIL (" .. reason2 .. "): " .. name) end
        end
    end

    if TIER_PROXIMITY then
        local ok3, reason3 = triggerProximityPrompt(target.model)
        if ok3 then
            if TIER_DIAGNOSTICS then print("[Tier] Proximity OK: " .. name) end
            tierStats.proximity = tierStats.proximity + 1
            return true, "proximity"
        else
            if TIER_DIAGNOSTICS then print("[Tier] Proximity FAIL (" .. reason3 .. "): " .. name) end
        end
    end

    if TIER_FALLBACK_TP then
        if pos and _tpHrpTo(pos) then
            task_wait(STAND_TP_SETTLE)
            for _ = 1, STAND_PRESSES do
                keypress(STAND_KEY)
                keyrelease(STAND_KEY)
            end
            if TIER_DIAGNOSTICS then print("[Tier] TP+Key OK: " .. name) end
            tierStats.tp = tierStats.tp + 1
            return true, "tp"
        else
            if TIER_DIAGNOSTICS then print("[Tier] TP FAIL: " .. name) end
        end
    end

    tierStats.fail = tierStats.fail + 1
    return false, "all_tiers_failed"
end

local function runStandPass(firstRun)
    local targets = getStandTargets(firstRun)
    if #targets == 0 then
        if firstRun then print("[Stand] No hay stands TPables (prefix='" .. (STAND_FOLDER_PREFIX or "") .. "')") end
        return "done"
    end

    -- v7.5: пропускаем стенды, которые уже обслуживает Manage-пасс,
    -- чтобы не ТПшиться к ним второй раз. Остаются только ''невидимые'' для
    -- Manage (как физический Lemon stand).
    local covered = {}
    for _, ms in ipairs_(_getManageStands()) do
        covered[tostring(ms.name):gsub("%s+", ""):lower()] = true
    end
    if firstRun then
        for i2, t2 in ipairs_(targets) do
            local cov = covered[tostring(t2.name):gsub("%s+", ""):lower()] and " (manage)" or " (TP+E)"
            print("[Stand] target " .. i2 .. ": " .. tostring(t2.name) .. cov)
        end
    end
    local tapped = 0
    local skipped_price = 0
    for i, t in ipairs_(targets) do
        if covered[tostring(t.name):gsub("%s+", ""):lower()] then
            continue
        end
        if not ScriptActive or not autoStandActive then return "off" end

        if STAND_USE_PRICE_GATE then
            local canAfford, price, cash = canAffordStand(t.folder)
            if canAfford == false then
                skipped_price = skipped_price + 1
                if firstRun then
                    print(string.format("[Stand] [%d/%d] SKIP precio: %s (necesita %.0f, tienes %.0f)",
                        i, #targets, tostring(t.name), price or 0, cash or 0))
                end
                continue
            end
        end

        if autoBuyActive and i % STAND_RECHECK_EVERY == 0 then
            local alive = not allButtonsDead()
            if alive then return "done" end
        end

        -- v7.5: тиры remote/gui-signal рапортовали ''успех'' без реального
        -- апгрейда, и ТП не запускался. Теперь как в Manage-пассе: ТП + спам E.
        local ok = false
        if t.pos and _tpHrpTo(t.pos) then
            task_wait(STAND_TP_SETTLE)
            _spamKeyFor(STAND_KEY, STAND_E_SPAM_DURATION, STAND_E_SPAM_INTERVAL)
            ok = true
            print(sformat("[Stand][TP+E] [%d/%d] %s", i, #targets, tostring(t.name)))
        else
            print(sformat("[Stand][TP+E] [%d/%d] %s -> TP fail", i, #targets, tostring(t.name)))
        end
        if ok then tapped = tapped + 1 end

        task_wait(STAND_CYCLE_PAUSE)
    end
    print(string.format("[Stand] Pasada end. tap=%d  skip_precio=%d  tiers=%s",
        tapped, skipped_price,
        "R:"..tierStats.remote.." G:"..tierStats.gui.." P:"..tierStats.proximity.." T:"..tierStats.tp))
    return "done"
end

-- v12 ТУРБО-покупка: firetouchinterest шлёт серверу событие касания сразу,
-- без ожидания физики. Автодетект: nil = пробуем, true = работает (летим),
-- false = в этой Матче нет эффекта (3 чистых провала) -> классика навсегда.
local TURBO = { mode = nil, fails = 0 }

-- ==================== AUTO BUY (ORIGINAL v5.17 - worker + coordinator) ====================
-- Restaurado tal cual el codigo que SI funcionaba. TP a la posicion del boton.
_wrap("autobuy-worker", function()
    local emptyStreak = 0

    while ScriptActive do
        syncFromUI()
        if not autoBuyActive then
            task_wait(0.05)
            continue
        end
        if _standIsTapping then
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
                -- v7.0: резет только если есть given-up кнопки; все серые = ждём кэш
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
            task_wait(0.03)
            continue
        end

        emptyStreak = 0

        local key = item.key
        local btn = item.btn
        local pos = btn.Position
        local px, py, pz = pos.X, pos.Y, pos.Z

        local bought = false
        local turboBought = false

        -- v12: ТУРБО-попытка (ТП к кнопке всё равно нужен - сервер проверяет
        -- дистанцию, но ждать физического Touched не надо)
        if TURBO.mode ~= false and type(firetouchinterest) == "function" then
            pcall_(function() hrp.CFrame = CF(px, py + 0.8, pz) end)
            task_wait()
            pcall_(function()
                firetouchinterest(btn, hrp, 0)
                firetouchinterest(btn, hrp, 1)
            end)
            local tt = tick_()
            while ScriptActive and (tick_() - tt) < 0.25 do
                task_wait(0.03)
                local gone = true
                pcall_(function()
                    gone = not (btn and btn.Parent and btn:IsDescendantOf(myTycoon))
                end)
                if gone then bought = true; turboBought = true; break end
            end
            if turboBought and TURBO.mode == nil then
                TURBO.mode = true
                print("[Worker] TURBO ON: firetouchinterest works")
            end
        end

        if not bought then
            -- классика v5.21 (проверенная): посадка + окно подтверждения с
            -- перестановкой HRP (иногда одного касания мало)
            pcall_(function() hrp.CFrame = CF(px, py + 2.5, pz) end)
            task_wait(0.02)
            local classicStart = tick_()
            local t0 = tick_()
            while ScriptActive and (tick_() - t0) < CFG.buyWindow do
                pcall_(function() hrp.CFrame = CF(px, py + 0.8, pz) end)
                task_wait(0.03)
                local gone = true
                pcall_(function()
                    gone = not (btn and btn.Parent and btn:IsDescendantOf(myTycoon))
                end)
                if gone then bought = true; break end
                -- кнопка посерела на середине (кончились деньги) - не упорствуем
                if isGreyedOut(btn) then break end
            end
            -- детект: классика добила то, что турбо не смог = чистый провал турбо
            -- если классика подтвердила почти мгновенно - это сработал ТУРБО-тач
            -- (просто сервер ответил позже окна), провалом турбо НЕ считаем
            if bought and TURBO.mode == nil and type(firetouchinterest) == "function"
               and (tick_() - classicStart) >= 0.15 then
                TURBO.fails = TURBO.fails + 1
                if TURBO.fails >= 3 then
                    TURBO.mode = false
                    print("[Worker] turbo off: firetouchinterest has no effect here")
                end
            end
        end

        if bought then
            buyBlacklist[key]  = btn   -- v7.6: храним инстанс — новая кнопка на этом месте не банится
            failedButtons[key] = nil
            buyAttempt[key]    = nil
            totalBought = totalBought + 1
            print("[Worker] BOUGHT: " .. key .. " | Total: " .. totalBought)
        else
            markBuyFail(key, btn)
            totalFailed = totalFailed + 1
            print("[Worker] retry-later: " .. key .. " | n=" .. (buyAttempt[key] and buyAttempt[key].n or 0))
        end

        if totalBought % 20 == 0 then
            cleanupQueue()
        end
    end
end)

-- Coordinador
_wrap("autobuy-coord", function()
    while ScriptActive do
        syncFromUI()
        if not autoBuyActive then
            task_wait(0.2)
            continue
        end
        if _standIsTapping then
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
                    task_wait(0.5)   -- все серые: ждём деньги молча
                end
            else
                task_wait(0.3)
            end
            continue
        end

        task_wait(0.3)
    end
end)

-- ==================== LEMON FARM ====================
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
    for _, part in ipairs_(tree:GetDescendants()) do
        if part:IsA("BasePart") and not excludeSet[part] then
            pcall_(function()
                if part.CanQuery then
                    part.CanQuery = false
                    n = n + 1
                    modified[n] = part
                end
            end)
        end
    end
    return modified, n
end

local function restoreTreeCanQuery(modified, n)
    for i = 1, n do
        local part = modified[i]
        pcall_(function() part.CanQuery = true end)
    end
end

-- ==================== LEMON SILENT MODES (v7.4) ====================
-- Каскад от самого тихого к грубому, рабочий режим липнет на сессию:
--   cd      = fireclickdetector: не трогает НИЧЕГО (ни ТП, ни камеру, ни мышь)
--   sig     = firesignal(MouseClick): то же самое
--   touch   = ТП в фрукт; камера и мышь свободны
--   classic = старый способ: ТП + камера вверх + клик (последний резерв)
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

-- v7.5: клик по экранной позиции фрукта через WorldToScreen — камера НЕ
-- трогается; курсор возвращается на место после клика.
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

-- v10: вместо camera.lookAt из 3-го лица (клик не попадает) — скроллом
-- зумимся В первое лицо перед фармом и обратно после. Направление/глубина
-- настраиваются: CFG.zoomStep (если зум не в ту сторону - поставить -1) и
-- CFG.zoomTicks.
function LSM.zoom(dir)
    if LSM.mode == "cd" or LSM.mode == "sig" then return end
    if type(mousescroll) ~= "function" then return end
    LSM.lastBot = tick_()
    for _ = 1, CFG.zoomTicks do
        pcall_(mousescroll, CFG.zoomStep * dir)
        task_wait(0.02)
    end
end

-- v12: умный возврат после АФК-фарма. Порядок важен:
-- 1) ТП на место, где игрок стоял + погасить скорость (антиграв давал +Y);
-- 2) зум-аут из первого лица;
-- 3) вернуть ракурс: камера на тот же оффсет от персонажа, что и до фарма.
-- Якорь одноразовый (чистится), без якоря просто зум-аут.
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

    -- играешь -> лимонка ПОЛНОСТЬЮ стоит: ни ТП, ни камеры, ни кликов.
    if (tick_() - (S.lastUser or 0)) < CFG.afkDelay then return false end
    -- v11.2: игра не в фокусе -> не кликаем (клик ушёл бы в другое окно)
    if not _windowFocused() then return false end
    if autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4 then return false end   -- стенд занят

    -- v7.4: сначала тихие режимы; classic только если ничего не сработало
    if LSM.mode ~= "classic" then
        if LSM.silent(v) then return true end
        if LSM.mode == "cd" or LSM.mode == "sig" then return false end
        if LSM.touch(v, hrp) then return true end
        if LSM.mode == "touch" then return false end
        if LSM.mode == nil then
            LSM.mode = "classic"
            print("[Lemon] тихие режимы не сработали -> CLASSIC (ТП+камера+клик)")
        end
    end

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

    -- v9: первый метод (как было изначально и работало надёжней всего):
    -- ТП под фрукт, камера смотрит вверх на фрукт, быстрый клик в центр.
    -- Запускается ТОЛЬКО когда ты AFK (см. гард выше), так что экран
    -- дёргается только пока тебя нет.
    local vp = v.Position
    local tpX, tpY, tpZ = vp.X, vp.Y - 4, vp.Z
    pcall_(function()   -- ошибки тут не должны ронять restoreTreeCanQuery выше по стеку
        hrp.CFrame = CF(tpX, tpY, tpZ)
        task_wait(LEMON_TP_WAIT)

        LSM.lastBot = tick_()
        camera.lookAt(Vec3(tpX, tpY, tpZ), vp)   -- в 1-м лице это разворачивает взгляд вверх на фрукт
        task_wait(LEMON_CAM_WAIT)

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
        if (tick_() - (S.lastUser or 0)) < CFG.afkDelay then break end   -- игрок вернулся -> мгновенно отпускаем
        if autoBuyActive and (#localQueue - queueIndex + 1) > 0 then break end   -- уступаем автобаю
        if autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4 then break end   -- уступаем стенду
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
            if autoBuyActive and (#localQueue - queueIndex + 1) > 0 then break end
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

        -- v8.0: автобай занят (очередь не пуста) -> лимонка ждёт, он покупает
        local buyBusy = lemonFarmActive and autoBuyActive and (#localQueue - queueIndex + 1) > 0
        if lemonFarmActive and LSM.annBuy ~= buyBusy then
            LSM.annBuy = buyBusy
            print(buyBusy and "[Lemon] pause: autobuy buying" or "[Lemon] autobuy done -> resume")
        end
        local afkNow = (tick_() - (S.lastUser or 0)) >= CFG.afkDelay
        if lemonFarmActive and LSM.annAfk ~= afkNow then
            LSM.annAfk = afkNow
            if afkNow then
                -- запомнить, где стоял игрок и как смотрела камера (для возврата)
                pcall_(function()
                    local chr2 = player.Character
                    local h2 = chr2 and chr2:FindFirstChild("HumanoidRootPart")
                    if h2 then
                        LSM.anchor = h2.Position
                        LSM.anchorCam = camera.Position - h2.Position
                    end
                end)
                print("[Lemon] AFK -> zoom to 1st person + farm")
                LSM.zoom(1)
            else
                print("[Lemon] input detected -> back to your spot")
                LSM.returnHome()
            end
        end
        if not lemonFarmActive and LSM.annAfk then
            LSM.annAfk = false
            LSM.returnHome()   -- лимонку выключили посреди фарма: домой + зум
        end
        local standBusy = autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4
        if lemonFarmActive and hrp and not buyBusy and not standBusy and afkNow then
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

            task_wait(0.1)
        else
            task_wait(0.05)
        end
    end
end)

-- ==================== CASH FARM ====================
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
            task_wait(0.3)
        else
            task_wait(0.2)
        end
    end
end)

-- ==================== STATUS + INPUT v11 ====================
-- Статус-строка лимонки сверху по центру + трекинг активности + клавиша 6.
-- ВАЖНО: всё чтение клавиш/мыши только когда окно игры в фокусе (isrbxactive):
-- свернул игру и печатаешь в другом окне -> ничего не считывается, а лимонка
-- продолжает фармить в фоне.
local statusTx = D("Text", {Text = "", FontSize = 14, Size = 14, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(255, 214, 60)})
local statusTx2 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(222, 210, 170)})

local function pollInput()
    if not ScriptActive then return end
    local focused = _windowFocused()
    local nowA = tick_()

    if focused then
        -- фоллбэк-хоткеи 1-5 (только без homesick, иначе двойное срабатывание)
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
        -- клавиша 6 — запомнить точку стенда (ТП + E)
        if iskeypressed(54) then
            if not S.keyDown[54] then
                S.keyDown[54] = true
                if UX.fire("cap6") then
                    local chr6 = player.Character
                    local hrp6 = chr6 and chr6:FindFirstChild("HumanoidRootPart")
                    if hrp6 then
                        local pp = hrp6.Position
                        tinsert(standManual, Vec3(pp.X, pp.Y, pp.Z))
                        print(sformat("[Stand] point #%d saved: %.1f, %.1f, %.1f", #standManual, pp.X, pp.Y, pp.Z))
                        pcall_(function() notify("Stand point saved", "Sell Lemons", 2) end)
                    end
                end
            end
        else
            S.keyDown[54] = false
        end

        -- активность игрока (пауза лимонки) — клики самой лимонки не считаются
        local mx, my = S.pmx, S.pmy
        if mouse then pcall_(function() mx = mouse.X; my = mouse.Y end) end
        local m1 = false
        pcall_(function() m1 = ismouse1pressed() end)
        if (nowA - (LSM.lastBot or 0)) > 0.35 then
            if mx ~= S.pmx or my ~= S.pmy or m1 then S.lastUser = nowA end
        end
        S.pmx, S.pmy = mx, my
        if iskeypressed(0x57) or iskeypressed(0x41) or iskeypressed(0x53) or iskeypressed(0x44) or iskeypressed(0x20) then
            S.lastUser = nowA
        end
    end

    -- Статус-строки с делеями (вместо спама тостов): лимонка + стенд
    local vx = 960
    pcall_(function() vx = camera.ViewportSize.X * 0.5 end)
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
                txt = "lemon farm  |  FARMING"
            end
        end
        statusTx.Text = txt
        statusTx.Position = Vec2(vx, 8)
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
        statusTx2.Position = Vec2(vx, lemonFarmActive and 28 or 8)
        statusTx2.Visible = true
    else
        statusTx2.Visible = false
    end
end

RunService.RenderStepped:Connect(function()
    if not ScriptActive then return end
    local ok, err = pcall_(pollInput)
    if not ok then reportErr("ui-input", err) end
end)

-- ==================== AUTO STAND standalone loop ====================
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

        local res
        if STAND_MODE == "manage" then
            res = runManagePass(firstRun)
            -- v7.4: Manage-меню не покрывает физические Lemon-стенды (туда надо
            -- ТП и жать E). Раньше TP-пасс запускался только при ПУСТОМ Manage,
            -- поэтому Lemon stand никогда не апгрейдился. Теперь обе пассы.
            if res ~= "off" then
                res = runStandPass(firstRun)
            end
            -- v7.7: ручные точки (клавиша 6): честный ТП + спам E
            if autoStandActive and #standManual > 0 then
                for mi = 1, #standManual do
                    if not autoStandActive then break end
                    local mp = standManual[mi]
                    if _tpHrpTo(mp) then
                        task_wait(STAND_TP_SETTLE)
                        _spamKeyFor(STAND_KEY, STAND_E_SPAM_DURATION, STAND_E_SPAM_INTERVAL)
                    end
                    task_wait(STAND_CYCLE_PAUSE)
                end
            end
        else
            res = runStandPass(firstRun)
        end
        firstRun = false
        if res == "off" then
            task_wait(0.05)
            continue
        end
        local rest = lemonFarmActive and CFG.standRest or STAND_LOOP_DELAY
        LSM.standNextT = tick_() + rest   -- v11.1: для статус-строки
        task_wait(rest)
    end
end)

_G.MatchaCleanup = function()
    pcall_(LSM.returnHome)   -- выгрузили посреди АФК-фарма: вернуть игрока на место
    ScriptActive = false
    pcall_(function() if UIRef.win then UIRef.win.visible = false end end)
    for _, obj in ipairs_(drawObjs) do
        pcall_(function() obj:Remove() end)
    end
    print("[Hub] Cleanup done")
end

rprint("sell lemons loaded")
