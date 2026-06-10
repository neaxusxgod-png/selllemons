-- [[ SELL LEMONS v18.16 — стенд-камера ПКМ-орбитой (без мерцания) | сохранение убрано | FPS Save режим ]] --
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
local cashFarmActive   = true    -- v13.3: включён по умолчанию
local autoStandActive  = false
local autoDealActive   = true    -- v13.2: автопринятие сделок (телефон с Deal.)
local _standIsTapping  = false   -- Gate: true while AutoStand is in E-tap phase

local buyBlacklist    = {}
local failedButtons   = {}
local buyAttempt      = {}   -- v5.19: [key] = {tries=, next=} backoff (reemplaza blacklist permanente)

-- v18.15: ключ кэшируется по инстансу (кнопки статичны). Раньше каждый проход
-- очереди/скана читал Position и собирал строку заново - тысячи бридж-чтений
-- в секунду, на слабых ПК от этого лагало ВСЁ меню при автобае.
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

print("=== SELL LEMONS v18.16 ===")

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
    afkDelay  = 6,      -- сек без инпута до старта лимонки
    zoomTicks = 22,     -- щелчков скролла в первое лицо (лишние на максимуме безвредны)
    zoomStep  = 1,      -- если зум не в ту сторону - поставить -1
    standRest = 60,     -- АвтоСтенд проходится раз в минуту, когда лимонка включена
    vineCd    = 4 * 3600,   -- кулдаун Cash Vine (4 часа)
    buyStuck  = 6,      -- сек без новых покупок -> автобай застрял, лимонка берёт ход
    cheerY    = 0.85,   -- v18.12: высота клика CHEER (доля экрана; меньше = выше)
    exitY     = 0.76,   -- высота клика EXIT на экране результата
}

local S = {
    lastUser = tick_(), pmx = 0, pmy = 0, keyDown = {}, lastFire = {},
}
-- v12.5: таймер Cash Vine переживает перезапуски (tick() = unix-время)
pcall_(function()
    if type(readfile) == "function" then
        local v = tonumber(readfile("selllemons_vine.txt"))
        if v then CFG.vineT = v end
    end
end)
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
        local src = game:HttpGet("https://raw.githubusercontent.com/sharedechoes/Matcha-Luas/refs/heads/main/homesick.lua")
        -- v12.4: лимонная тема + без ''v1.4.0'' в футере. Патчим исходник до
        -- запуска; если либу обновят и строки изменятся - gsub молча пропустит.
        src = src:gsub('accent = c3%(232, 208, 162%),', 'accent = c3(255, 214, 60),')
        src = src:gsub('bg = c3%(36, 33, 31%),', 'bg = c3(33, 29, 17),')
        src = src:gsub('surface = c3%(30, 27, 25%),', 'surface = c3(27, 24, 14),')
        src = src:gsub('surface2 = c3%(44, 40, 37%),', 'surface2 = c3(45, 40, 22),')
        src = src:gsub('surface3 = c3%(54, 50, 46%),', 'surface3 = c3(58, 51, 28),')
        src = src:gsub('border = c3%(60, 55, 52%),', 'border = c3(78, 68, 36),')
        src = src:gsub('sub = c3%(150, 142, 135%),', 'sub = c3(168, 154, 112),')
        src = src:gsub('%(ProjectState%.badgeText %.%. " | v1%.4%.0"%)', '(ProjectState.badgeText)')
        src = src:gsub('or "v1%.4%.0"', 'or ""')
        -- v17.2: СТЕКЛЯННАЯ прозрачность. Drawing.Transparency = непрозрачность
        -- (1=плотно). Понижаем альфу ТОЛЬКО фонов в ThemeAlpha - текст/акцент/
        -- рамка остаются 1.0 (чёткие, читаемые). Получается стекло.
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
    pcall_(function() if S.saveState then S.saveState() end end)
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
    pcall_(function() if S.saveState then S.saveState() end end)
    print("[Hub] toggle slot " .. slot)
end

-- v15/v16: выбор стендов для авто-апгрейда. Позиции читаются из СВОЕГО тайкуна
-- В РАНТАЙМЕ (у каждого игрока свой тайкун, корды разные).
local STAND_NAMES = {"Lemon Stand", "LemonDash", "Lemon Depot", "Lemon Labs", "Lemon Trading", "Lemon Robotics", "Lemon Republic"}
local standEnabled = {}
local MG = { active = false, enabled = {} }   -- v17: Auto Minigame (всё в таблице = 1 регистр)
-- v18.16: сохранение состояния тогглов/позиции окна УДАЛЕНО (оператор: работало
-- криво - убрать). Все тогглы стартуют с дефолтов при каждой загрузке. No-op
-- оставлен, чтобы не трогать десяток вызовов в коллбэках.
S.saveState = function() end
-- v18.2: список минигеймов = папки в Purchases.Minigames (для чекбоксов-селектора)
MG.list = function()
    local out = {}
    if not myTycoon then return out end
    local pur; pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
    local mg = pur and pur:FindFirstChild("Minigames")
    if not mg then return out end
    pcall_(function()
        for _, c in ipairs_(mg:GetChildren()) do
            if c:IsA("Folder") or c:IsA("Model") then
                -- только ИГРАБЕЛЬНЫЕ: внутри есть ProximityPrompt (скамейка с E).
                -- Так отсекаем инфраструктуру вроде "Buttons".
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
-- v18.4: кулдаун включённого минигейма из живого мирового лейбла
-- (Purchases.Minigames.<name>...Gui.Label, формат Ч:ММ:СС). Возвращает секунды
-- или nil (готов / нет таймера). Читается ВСЕГДА, не только рядом (как лоза).
MG.timerSec = function()
    -- v18.15: кэш 1с. Эту функцию зовут статус-строка (была КАЖДЫЙ КАДР) и цикл
    -- минигейма - а внутри полный GetDescendants по моделям минигеймов (тысячи
    -- частей). Именно это клало FPS у людей при включённом Auto Minigame.
    local now = tick_()
    if MG.tsT and (now - MG.tsT) < 1.0 then return MG.tsVal end
    MG.tsT = now
    MG.tsVal = nil
    if not myTycoon then return nil end
    local pur; pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
    local mg = pur and pur:FindFirstChild("Minigames")
    if not mg then return nil end
    local rem
    pcall_(function()
        for _, c in ipairs_(mg:GetChildren()) do
            local nm = tostring_(c.Name)
            if MG.enabled[nm] ~= false then
                for _, d in ipairs_(c:GetDescendants()) do
                    if tostring_(d.ClassName) == "TextLabel" then
                        local t; pcall_(function() t = d.Text end)
                        local hh, mm, ss = tostring_(t or ""):match("^%s*(%d+):(%d%d):(%d%d)%s*$")
                        if hh then
                            local r = tonumber_(hh) * 3600 + tonumber_(mm) * 60 + tonumber_(ss)
                            if r > 0 then rem = r; return end
                        end
                    end
                end
            end
        end
    end)
    MG.tsVal = rem
    return rem
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
-- v16.1: ТП в точку, ГДЕ ЖМЁШЬ E (главный апгрейд-промпт), а не в центр площадки
-- из Locations (тот был в ~28 студах от стенда -> ''тепало далеко''). Промпт
-- лежит в Purchases.<name>.<name>.<name> (тройное имя) или в любом ProximityPrompt
-- ''Prompt'' внутри папки стенда.
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
        if low:find("lemon") and not low:find("lemonx") then
            -- v16.2: точка E (промпт) + сдвиг к центру площадки (Locations), чтобы
            -- персонаж вставал ПЕРЕД стендом, а не внутрь конструкции ("криво").
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
                    local step = m < 6 and m or 6   -- сдвиг к центру, максимум 6 студов
                    pos = pos + (d / m) * step
                end
            elseif not pos then
                pos = lpos
            end
            if pos then tinsert(out, {name = nm, pos = pos}) end
        end
    end
    return out
end

-- ---- Окно ----
if homesick then
    pcall_(function() homesick.changelogEnabled = false end)
    local window = homesick.createWindow("Sell Lemons", 480, 420)
    -- v18.16: autoloadConfig/autoloadTheme убраны вместе со всем сохранением -
    -- окно и тогглы каждый раз чистые, тема всегда наша жёлтая.
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

    pcall_(function() window:setBadge("Sell Lemons  |  by neaxus") end)
    UIRef.t.AutoDeal = right:addToggle("autoDeal", "Auto Deal", true, function(val)
        autoDealActive = val
        S.saveState()
    end)

    UIRef.t.AutoMini = right:addToggle("autoMini", "Auto Minigame", false, function(val)
        MG.active = val
        S.saveState()
        print("[Hub] toggle AutoMinigame = " .. tostring_(val))
    end)

    UIRef.t.CashVine = right:addToggle("cashVine", "Cash Vine TP", false, function(val)
        if val then
            CFG.vineGo = true    -- ВКЛ: запомнить место и ТП к лозе
        else
            CFG.vineBack = true  -- ВЫКЛ: вернуться, где был
        end
    end)

    -- v18.16: режим для слабых ПК - все фоновые циклы реже (статус, сканы
    -- телефона/минигейма, холостой автобай). Фарм-действия НЕ замедляет.
    UIRef.t.FpsSave = right:addToggle("fpsSave", "FPS Save (weak PC)", false, function(val)
        CFG.slow = val and true or false
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

    -- v18.2: вкладка "Auto" - выбор стендов И минигеймов (чекбоксы). Хэндлы
    -- храним в UIRef.standCb/miniCb, чтобы при загрузке отразить сохранённое.
    UIRef.standCb = {}
    UIRef.miniCb = {}
    pcall_(function()
        local autoTab = window:addTab("Auto")
        local sec = autoTab:addSection("Stands", "Left")
        local listed = {}
        for _, s in ipairs_(getStandLocations()) do listed[#listed + 1] = s.name end
        if #listed == 0 then listed = STAND_NAMES end
        for _, nm in ipairs_(listed) do
            if standEnabled[nm] == nil then standEnabled[nm] = true end
            UIRef.standCb[nm] = sec:addCheckbox("stand_" .. nm, nm, true, function(val)
                standEnabled[nm] = val
                S.saveState()
            end)
        end
        -- минигеймы: чекбокс на каждый (Auto Minigame играет только включённые)
        local mgList = MG.list()
        if #mgList > 0 then
            local mgSec = autoTab:addSection("Minigames", "Right")
            for _, nm in ipairs_(mgList) do
                local soon = nm:lower():find("trade") and true or false   -- Trade пока не готов
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

local _bScan = { t = 0, list = nil }
local function getButtonsRealTime()
    if not buttonsCacheReady then
        buildButtonsCache()
        if not buttonsCacheReady then return {} end
    end

    -- v16: микро-кэш 0.12с. НЕ меняет ЧТО сканируем (scan-логика священна) -
    -- только гасит лишние полные GetDescendants, когда worker + coordinator +
    -- allButtonsDead + anyGivenUp + _anyLiveButtons зовут скан пачкой за тик.
    -- Это главный источник лага при автобае. Вызыватели читают список только
    -- на чтение и фильтруют по btn.Parent, так что 0.12с-давность безопасна.
    local now = tick_()
    if _bScan.list and (now - _bScan.t) < 0.12 then
        return _bScan.list
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
    _bScan.list = temp
    _bScan.t = now
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
local LSM = { mode = "classic", annAfk = false, annBuy = false }   -- v12.5: ТОЛЬКО классика (ТП+камера+клик). Автодетект тихих режимов лочился на нерабочем touch/sig -> лимонка переставала смотреть вверх и кликать

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

-- v18.15: результат живёт 0.15с (поля в _bScan). Эти проверки зовутся воркером,
-- координатором и автостендом по многу раз в сек, каждая - полный проход по
-- кнопкам с pcall-чтением цвета. Свежесть 0.15с лишь задерживает РЕШЕНИЕ
-- (резет/уступить ход) на доли секунды - сам процесс покупки не трогает.
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

-- v7.0: ''все мертвы'' бывает по двум причинам: (а) все кнопки СЕРЫЕ -> просто
-- не хватает денег; резет блеклиста тут НИЧЕГО не даёт, надо тихо ждать кэш;
-- (б) есть given-up кнопки (6 реальных провалов) -> вот им резет даёт второй
-- шанс. Резетим только в случае (б) — убирает спам ''ALL DEAD! Reset'' каждые 2с.
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


-- ==================== AUTO STAND (TP a Purchases/* y spam E) ====================
local STAND_KEY            = 0x45             -- Windows VK_E.
local STAND_CYCLE_PAUSE    = 0.02
local STAND_TP_Y_OFFSET    = 3
local STAND_LOOP_DELAY     = 0.1

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


-- v15: апгрейд по Locations (реальные корды из СВОЕГО тайкуна) + селектор.
-- Заменяет старый поиск пустышек из Purchases, который не давал позиции для ТП.
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
    -- v18.14: стенд ОТДАЛЯЕТ камеру (третье лицо, как просил) и смотрит ВНИЗ на
    -- стенд - камера сверху-сзади над игроком. lookAt держим прямо перед каждым E.
    LSM.zoom(-1)
    local tapped = 0
    for _, s in ipairs_(locs) do
        if not ScriptActive or not autoStandActive then return "off" end
        if standEnabled[s.name] ~= false then
            if autoBuyActive and _anyLiveButtons() then return "done" end   -- уступаем автобаю
            if _tpHrpTo(s.pos) then   -- _tpHrpTo ставит LSM.standBusyT -> лимонка ждёт
                task_wait(0.05)
                -- v18.16: камеру вниз на стенд поворачиваем ПКМ-орбитой (без
                -- мерцания, угол ДЕРЖИТСЯ сам). lookAt каждый тик - только
                -- фоллбэк, если ПКМ недоступен/не в фокусе.
                local aimed = LSM.aimCam(s.pos)
                local eye, target
                if not aimed then
                    pcall_(function()
                        local h = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
                        if h then
                            local p = h.Position
                            eye = p + Vec3(0, 10, 16)     -- выше и за спиной = отдалено
                            target = p + Vec3(0, -1, 2)    -- смотрим вниз на стенд
                        end
                    end)
                end
                _standIsTapping = true   -- автобай-воркер уступает на время спама
                local t0 = tick_()
                while autoStandActive and (tick_() - t0) < STAND_E_SPAM_DURATION do
                    LSM.lastBot = tick_()
                    if not aimed and eye then pcall_(function() camera.lookAt(eye, target) end) end
                    if _windowFocused() then keypress(STAND_KEY); keyrelease(STAND_KEY) end
                    task_wait(0.05)
                end
                _standIsTapping = false
                tapped = tapped + 1
            end
            task_wait(STAND_CYCLE_PAUSE)
        end
    end
    -- v18.15: НИЧЕГО не зумим обратно здесь. Лемон сам зайдёт в 1-е лицо, когда
    -- получит ход (самовосстановление по LSM.zoomedIn в лемон-цикле) - это
    -- происходит через ~2-4с после стенда (пока LSM.standBusyT свежий, лемон
    -- ждёт), т.е. камера НЕ прыгает обратно мгновенно, как просил оператор.
    if firstRun then print("[Stand] pass end, tapped=" .. tapped) end
    return "done"
end

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
            -- v18.15: ХОЛОСТОЙ ход (покупать нечего) - 0.12с вместо 0.05с.
            -- Покупки не замедляет (когда очередь не пуста, сюда не попадаем),
            -- а холостые сканы режутся в ~2.5 раза. FPS Save -> ещё реже.
            task_wait(CFG.slow and 0.3 or 0.12)
            continue
        end

        emptyStreak = 0

        local key = item.key
        local btn = item.btn
        local pos = btn.Position
        local px, py, pz = pos.X, pos.Y, pos.Z

        -- v12.2: ТУРБО (firetouchinterest) ОТКАЧЕН ПОЛНОСТЬЮ - в этой игре он
        -- ломал покупки (пропуск кнопок). Ниже классика v5.21 один-в-один,
        -- та самая, что работала идеально. БОЛЬШЕ НЕ ТРОГАТЬ.
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
            -- кнопка посерела на середине (кончились деньги) - не упорствуем
            if isGreyedOut(btn) then break end
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

-- v13.7: ВОЗОБНОВЛЯЕМЫЙ цикл: семантика как у per-part pcall (ошибка на
-- одной части пропускает ТОЛЬКО её), но pcall один - без него подготовка
-- дерева занимала 10-15с, и камера всё это время не поднималась.
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
        if not ok then i = i + 1 end   -- пропустить проблемную часть, продолжить
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
    LSM.zoomedIn = dir > 0   -- v18.15: трекаем зум - лемон сам перезумится, когда получит ход
    LSM.lastBot = tick_()
    for _ = 1, CFG.zoomTicks do
        pcall_(mousescroll, CFG.zoomStep * dir)
        task_wait(0.02)
    end
end

-- v18.16: повернуть камеру В ТРЕТЬЕМ ЛИЦЕ на цель БЕЗ мерцания. lookAt в 3-м
-- лице дрётся с дефолтной камерой (экран мелькал, срабатывало через раз).
-- Канонический способ - как игрок: зажать ПКМ (mouse2press) и повести мышь
-- (mousemoverel) - камера орбитой поворачивается и ОСТАЁТСЯ. Доворачиваем с
-- проверкой через WorldToScreen (как прицел лемонки), максимум 5 коррекций.
-- true = цель в кадре у центра; false = ПКМ нет/не в фокусе -> фоллбэк lookAt.
function LSM.aimCam(pos)
    if not _windowFocused() then return false end
    if type(mouse2press) ~= "function" or type(mouse2release) ~= "function" then return false end
    local ok = false
    pcall_(function()
        local vps = camera.ViewportSize
        local cx, cy = vps.X * 0.5, vps.Y * 0.5
        for _ = 1, 5 do
            local sp, on = WorldToScreen(pos)
            if on and sp and mabs(sp.X - cx) < vps.X * 0.22 and mabs(sp.Y - cy) < vps.Y * 0.22 then
                ok = true
                break
            end
            LSM.lastBot = tick_()
            mouse2press()
            if on and sp then
                mousemoverel(mfloor((sp.X - cx) * 0.4), mfloor((sp.Y - cy) * 0.4))
            else
                mousemoverel(0, 200)   -- цель за кадром: ведём взгляд вниз
            end
            mouse2release()
            task_wait(0.03)
        end
    end)
    pcall_(function() mouse2release() end)   -- страховка: ПКМ не должен залипнуть
    return ok
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
    -- v18: НАМЕРЕННО отдаляем камеру обратно - зум-аут С ЗАПАСОМ (scroll всегда
    -- работает, не как mousemoverel в 3-м лице), гарантированно выходим из 1-го
    -- лица. Потом восстанавливаем точный ракурс.
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

    -- играешь -> лимонка ПОЛНОСТЬЮ стоит: ни ТП, ни камеры, ни кликов.
    if (tick_() - (S.lastUser or 0)) < CFG.afkDelay then return false end
    -- v11.2: игра не в фокусе -> не кликаем (клик ушёл бы в другое окно)
    if not _windowFocused() then return false end
    if autoStandActive and (tick_() - (LSM.standBusyT or 0)) < 4 then return false end   -- стенд занят

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
    -- золотой блок: ТП + lookAt (быстрая попытка)
    pcall_(function()
        hrp.CFrame = CF(tpX, tpY, tpZ)
        task_wait(LEMON_TP_WAIT)

        LSM.lastBot = tick_()
        camera.lookAt(Vec3(tpX, tpY, tpZ), vp)
        task_wait(LEMON_CAM_WAIT)
    end)

    -- v14: НАМЕРЕННАЯ ПРОВЕРКА прицела. Не верим lookAt на слово: через
    -- WorldToScreen проверяем, что фрукт реально в кадре около центра.
    -- Если нет - доворачиваем камеру РЕАЛЬНОЙ мышью (в 1-м лице mousemoverel
    -- вращает взгляд, это не может не сработать) и перепроверяем. До 6 раз.
    pcall_(function()
        local vps = camera.ViewportSize
        local cx, cy = vps.X * 0.5, vps.Y * 0.5
        for _ = 1, 6 do
            local sp, on = WorldToScreen(vp)
            if on and sp and mabs(sp.X - cx) < vps.X * 0.18 and mabs(sp.Y - cy) < vps.Y * 0.18 then
                break   -- прицел подтверждён: фрукт у центра кадра
            end
            LSM.lastBot = tick_()
            if on and sp then
                mousemoverel(mfloor((sp.X - cx) * 0.5), mfloor((sp.Y - cy) * 0.5))
            else
                mousemoverel(0, -260)   -- фрукт за кадром: задираем взгляд вверх
            end
            task_wait(0.012)
        end
    end)

    -- клик в центр (в 1-м лице курсор и есть прицел)
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
        if (tick_() - (S.lastUser or 0)) < CFG.afkDelay then break end   -- игрок вернулся -> мгновенно отпускаем
        if autoBuyActive and not LSM.lemonSlot and (#localQueue - queueIndex + 1) > 0 then break end   -- уступаем автобаю
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

        -- v8.0: автобай занят (очередь не пуста) -> лимонка ждёт, он покупает
        local buyBusy = lemonFarmActive and autoBuyActive and (#localQueue - queueIndex + 1) > 0
        if lemonFarmActive and LSM.annBuy ~= buyBusy then
            LSM.annBuy = buyBusy
            print(buyBusy and "[Lemon] pause: autobuy buying" or "[Lemon] autobuy done -> resume")
        end
        local afkNow = (tick_() - (S.lastUser or 0)) >= CFG.afkDelay
        -- v16: лимонка забирает ход ТОЛЬКО когда автобай реально ЗАСТРЯЛ
        -- (totalBought не растёт CFG.buyStuck сек = нет денег / всё серое), а
        -- НЕ по таймеру. Пока автобай покупает (счётчик растёт) - лимонка ждёт,
        -- чтобы он докупил всю пачку. Это убирает пинг-понг buy<->lemon.
        if buyBusy and afkNow then
            if totalBought ~= LSM.lastBoughtN then
                LSM.lastBoughtN = totalBought
                LSM.buyProgressT = tick_()   -- автобай купил -> прогресс есть
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
                -- запомнить место/камеру для возврата. v18.12: ТОЛЬКО если якоря
                -- ещё нет - иначе стенд-пасс (сброс annAfk) перезаписал бы якорь
                -- позицией стенда, и returnHome увёл бы игрока не туда.
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
                -- v18.15: сам зум переехал в начало фарма (блок LSM.zoomedIn ниже):
                -- так он срабатывает и после стенд-пасса (тот отдаляет камеру и
                -- может прерваться где угодно), и не дёргает камеру раньше, чем
                -- лемон реально получит ход.
                print("[Lemon] AFK -> zoom + farm")
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
        if lemonFarmActive and hrp and (not buyBusy or LSM.lemonSlot == true) and not standBusy and afkNow then
            -- v18.15: САМОВОССТАНОВЛЕНИЕ зума (золотой блок v13.5/13.7, перенесён
            -- сюда). Камера не в 1-м лице (старт, возврат после input, стенд её
            -- отдалял) -> зумимся и сразу смотрим вверх. Стенд держит standBusyT
            -- свежим, так что после стендов сюда попадаем через ~2-4с - камера
            -- НЕ прыгает обратно мгновенно.
            if not LSM.zoomedIn then
                pcall_(function() camera = Workspace.CurrentCamera end)   -- v14: камера могла пересоздаться при респавне
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

            -- v16: слот истрачен - отдаём персонажа автобаю и даём ему свежее
            -- окно (сбрасываем таймер застревания), чтобы он снова докупал пачку
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
            task_wait(CFG.slow and 0.6 or 0.3)
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
local statusTx3 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(222, 210, 170)})
local statusTx4 = D("Text", {Text = "", FontSize = 13, Size = 13, Font = (Drawing.Fonts.Monospace or Drawing.Fonts.System), Center = true, Outline = true, Visible = false, ZIndex = 5, Color = C3rgb(222, 210, 170)})

local function pollInput()
    if not ScriptActive then return end
    local nowA = tick_()
    -- v18.16: опрос ввода ~30 раз/сек, не каждый кадр. Каждое чтение клавиши/
    -- мыши - бридж-вызов эмулятора (их тут 8-9 за проход); на слабых ПК
    -- по-кадровый опрос сам по себе ел кадры. 33мс задержка для АФК-детекта
    -- и хоткеев неощутима.
    if (nowA - (S.pollT or 0)) < (CFG.slow and 0.06 or 0.03) then return end
    S.pollT = nowA
    local focused = _windowFocused()

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

        -- активность игрока (пауза лимонки) — клики самой лимонки не считаются
        local mx, my = S.pmx, S.pmy
        if mouse then pcall_(function() mx = mouse.X; my = mouse.Y end) end
        local m1 = false
        pcall_(function() m1 = ismouse1pressed() end)
        -- v12.5: КОРЕНЬ таймера по кругу: зум/ТП двигают камеру, а от этого
        -- в Матче дрейфует mouse.X/Y -> скрипт принимал СВОИ действия за игрока
        -- (фарм -> ''движение'' -> пауза -> зум-аут -> ''движение'' -> таймер...).
        -- Решение: пока идёт ФАРМ или автобай покупает - мышь и клик вообще
        -- не считаются активностью. Разбудить фарм: WASD/пробел.
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

    -- Cash Vine (v12.9): направление по ПОЗИЦИИ, а не по состоянию тоггла
    -- (тоггл рассинхронивался: со второго раза ''только возвращал''). Рядом
    -- с лозой = вернуться, далеко = запомнить место и ТП к лозе.
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

    -- v18.15: всё ниже (статус-строки, чтение лейблов лозы, таймер минигейма)
    -- обновляется ~7 раз/сек, а не каждый кадр - заметная часть лагов меню у
    -- людей. Ввод/активность выше остались частыми.
    if (nowA - (S.statusT or 0)) < (CFG.slow and 0.4 or 0.15) then return end
    S.statusT = nowA

    -- Статус-строки с делеями: лимонка + стенд + лоза
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
    -- v12.8: РЕАЛЬНОЕ состояние лозы из игры: VineKey видим = готова
    -- (нашли зондом: Workspace.Map.Sewer.CashVine.VineKey, Transparency 1<->0).
    -- Переход видим->невидим = момент сбора: настоящий старт 4ч кулдауна.
    local vReady
    pcall_(function()
        local k = LSM.vineKeyRef
        if not (k and k.Parent) then
            local map = Workspace:FindFirstChild("Map")
            local sewer = map and map:FindFirstChild("Sewer")
            local cv = sewer and sewer:FindFirstChild("CashVine")
            k = cv and cv:FindFirstChild("VineKey")
            LSM.vineKeyRef = k
        end
        if k then vReady = (k.Transparency < 0.5) end
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
    -- v13: НАСТОЯЩИЙ таймер - игра сама рисует отсчёт на замке (TextLabel
    -- ''02:32:08'' под Map.Sewer.CashVine). Читаем его текст напрямую.
    local vTimer
    pcall_(function()
        local lbl = LSM.vineLblRef
        if lbl and lbl.Parent then
            local t = tostring_(lbl.Text)
            if t:match("^%d+:%d%d:%d%d$") then
                if t ~= LSM.vineLblLast then
                    LSM.vineLblLast = t
                    LSM.vineLblChangeT = tick_()
                end
                -- v13.1: текст тикает только рядом с лозой; замороженный
                -- (ушёл далеко) для синхронизации НЕ берём
                if (tick_() - (LSM.vineLblChangeT or 0)) < 3 then
                    vTimer = t
                end
            end
        end
        if not vTimer and (tick_() - (LSM.vineScanT or 0)) > 3 then
            LSM.vineScanT = tick_()
            LSM.vineLblRef = nil
            local map = Workspace:FindFirstChild("Map")
            local sewer = map and map:FindFirstChild("Sewer")
            local cv = sewer and sewer:FindFirstChild("CashVine")
            if cv then
                for _, d in ipairs_(cv:GetDescendants()) do
                    if d:IsA("TextLabel") then
                        local t2 = tostring_(d.Text)
                        if t2:match("^%d+:%d%d:%d%d$") then
                            LSM.vineLblRef = d
                            LSM.vineLblLast = t2
                            LSM.vineLblChangeT = 0   -- доверяем после первого тика
                            break
                        end
                    end
                end
            end
        end
    end)
    if vTimer then
        -- синхронизируем локальную оценку с настоящим временем (для оффлайна)
        pcall_(function()
            local hh, mm, ss = vTimer:match("^(%d+):(%d%d):(%d%d)$")
            local remS = tonumber_(hh) * 3600 + tonumber_(mm) * 60 + tonumber_(ss)
            local newT = tick_() - (CFG.vineCd - remS)
            if not CFG.vineT or mabs(newT - CFG.vineT) > 60 then
                CFG.vineT = newT
                if type(writefile) == "function" then
                    writefile("selllemons_vine.txt", tostring_(CFG.vineT))
                end
            end
        end)
    end
    -- v13.1: показываем СВОЙ тикающий отсчёт всегда (замок обновляется
    -- игрой только рядом с лозой). Лейбл - только для синхронизации.
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
    -- v18.13: таймер минигейма. Лейбл стримится (виден только вблизи), поэтому
    -- ведём ЛОКАЛЬНЫЙ отсчёт MG.miniEnd и синкаем когда лейбл доступен (как лоза).
    if MG.active then
        local cd = MG.timerSec()
        if cd and cd > 0 then MG.miniEnd = tick_() + cd end
        local rem = MG.miniEnd and (MG.miniEnd - tick_()) or nil
        if rem and rem > 0 then
            statusTx4.Text = sformat("minigame  |  %d:%02d", mfloor(rem / 60), mfloor(rem % 60))
            statusTx4.Color = C3rgb(222, 210, 170)
            MG.miniNotif = false
        elseif not MG.miniEnd then
            statusTx4.Text = "minigame  |  --"   -- таймер ещё не синкнут (далеко от скамейки)
            statusTx4.Color = C3rgb(222, 210, 170)
        else
            statusTx4.Text = "minigame  |  READY"
            statusTx4.Color = C3rgb(255, 214, 60)
            if not MG.miniNotif then
                MG.miniNotif = true
                pcall_(function() notify("Minigame is READY", "Sell Lemons", 4) end)
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

-- ==================== AUTO DEAL v3 (точный путь: PlayerGui.Phone) ====================
-- Зонд показал: телефон = ScreenGui "Phone" в PlayerGui. Тексты верхних кнопок
-- каждый раз разные, нижняя всегда отказ (No./Nvm.) - жмём ВЕРХНЮЮ по позиции.
-- ВАЖНО (уроки зондов): IsA и чтение .Visible в Матче ненадёжны - классы
-- сравниваем по ClassName, видимость читаем через pcall (nil = не блокирует).
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
                local pg = player:FindFirstChildOfClass("PlayerGui")
                if not pg then return end
                local phone = pg:FindFirstChild("Phone")
                if not phone then return end
                -- v18.15: телефон выключен (Enabled=false) -> не обходим его дерево
                -- зря каждые полсекунды. Семантика та же: shownB всё равно отбросил
                -- бы все кнопки выключенного ScreenGui.
                local phEn; pcall_(function() phEn = phone.Enabled end)
                if phEn == false then return end
                -- кандидаты: все кнопки телефона с текстом
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
                if bn < 2 then return end   -- телефон закрыт/пустой
                -- верхняя по экрану
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
                -- v14.2: firesignal/хуки/getgc в Matcha недоступны -> принять
                -- сделку можно ТОЛЬКО реальным кликом. Делаем его НЕВИДИМЫМ:
                -- запоминаем курсор, прыгаем на кнопку, нажал-отпустил, сразу
                -- возвращаем курсор - одним проходом без пауз, кадр не успевает
                -- отрисовать промежуточное положение.
                local apos, asz
                pcall_(function() apos = best.AbsolutePosition; asz = best.AbsoluteSize end)
                if apos and asz then
                    local inset = 0
                    pcall_(function() inset = game:GetService("GuiService"):GetGuiInset().Y end)
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
                    -- не зарегалось с первого раза -> вторая попытка с микропаузой
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

-- ==================== AUTO MINIGAME (v18.1) ====================
-- Зонд раскрыл структуру: PLAY = PromptGui (или E у скамейки); PICK = 4 кнопки
-- в PlayerGui.PickGui; CHEER = PlayerGui.MinigameRace.Button (текст exit<->cheer).
-- Ищем кнопки по тексту по ВСЕМУ PlayerGui (v17 искал только в MinigameRace ->
-- не находил PICK). Спамим CHEER, жмём любой PICK, на скамейке - E/PLAY.
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
-- найти кнопку по тексту; needPos=true -> только с реальной экранной позицией.
-- v18.15: сперва ищем в ИЗВЕСТНЫХ контейнерах минигейма (зонды: CHEER/EXIT в
-- MinigameRace, PICK в PickGui, PLAY в PromptGui) - они маленькие. Полный обход
-- PlayerGui (тысячи элементов, лагал меню по 3-4 раза за тик) остался лишь
-- страховкой не чаще раза в 1.5с.
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
function MG.findBtn(want, needPos)
    local pg = player:FindFirstChildOfClass("PlayerGui")
    if not pg then return nil end
    for _, nm in ipairs_({"MinigameRace", "PickGui", "PromptGui"}) do
        local g
        pcall_(function() g = pg:FindFirstChild(nm) end)
        if g then
            local hit = MG.scanBtns(g, want, needPos)
            if hit then return hit end
        end
    end
    -- страховка ПО-КНОПОЧНО (аудит: общий таймер отдавал весь бюджет CHEER'у,
    -- и EXIT/PICK/PLAY никогда не добирались до полного скана)
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
    if ap.X <= 1 and ap.Y <= 1 then return end   -- ещё не отрисована -> не кликаем в угол
    -- v18.11: БЕЗ GuiInset. AbsolutePosition уже в экранных координатах; +inset
    -- уводил клик на ~36px НИЖЕ кнопки (CHEER/EXIT мимо, "криво").
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    LSM.lastBot = tick_()
    pcall_(function()
        mousemoveabs(mfloor(ap.X + az.X / 2), mfloor(ap.Y + az.Y / 2))
        mouse1press(); mouse1release()
        if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end
    end)
end
-- v18.2: позиция входа = промпт ТОЛЬКО включённого минигейма (селектор), чтобы
-- не лезть во "вторую игру", которую отключили.
function MG.entryPos()
    if not myTycoon then return nil end
    local pur; pcall_(function() pur = myTycoon:FindFirstChild("Purchases") end)
    local mg = pur and pur:FindFirstChild("Minigames")
    if not mg then return nil end
    local pos
    pcall_(function()
        for _, c in ipairs_(mg:GetChildren()) do
            local nm = tostring_(c.Name)
            -- v18.9: Trade пока НЕ играем (coming soon) - жёстко пропускаем
            if MG.enabled[nm] ~= false and not nm:lower():find("trade") then
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
-- v18.2: PICK-кнопки = BillboardGui под мячами, у них AbsolutePosition 0,0 ->
-- кликаем по 4 экранным позициям внизу (где они отрисованы). Любой PICK годится.
-- v18.6: PICK-кнопки = билборды под 4 мячами (поз 0,0). Кликаем по экранным
-- позициям. Раньше один ряд на 0.84 высоты - оказался НИЖЕ кнопок. Теперь
-- НЕСКОЛЬКО рядов (0.74/0.78/0.82), один точно попадёт. Любой PICK годится.
function MG.clickSlots()
    local vw, vh = 1920, 1080
    pcall_(function() local v = camera.ViewportSize; vw = v.X; vh = v.Y end)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    for _, fy in ipairs_({0.74, 0.78, 0.82}) do
        for _, fx in ipairs_({0.14, 0.35, 0.56, 0.78}) do
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
-- v18.12: клик по доле экрана (для CHEER/EXIT - AbsolutePosition давал не ту точку)
function MG.clickRatio(fx, fy)
    local vw, vh = 1920, 1080
    pcall_(function() local v = camera.ViewportSize; vw = v.X; vh = v.Y end)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    LSM.lastBot = tick_()
    pcall_(function()
        mousemoveabs(mfloor(vw * fx), mfloor(vh * fy)); mouse1press(); mouse1release()
    end)
    pcall_(function() if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end end)
end
-- v18.5: НЕПРЕРЫВНЫЙ супербыстрый спам CHEER. Встаём на кнопку ОДИН раз, дальше
-- жмём мышь каждый кадр без движений курсора и без пауз - максимально часто.
-- Каждые 16 кликов проверяем, что кнопка ещё CHEER (не "exit"/исчезла = гонка всё).
function MG.spamCheer(btn)
    -- v18.12: AbsolutePosition CHEER-кнопки давал клик СЛИШКОМ НИЗКО (система
    -- координат не та; для PICK тоже пришлось перейти на доли экрана). Кликаем
    -- по доле экрана: центр по X, CFG.cheerY по высоте. btn нужен только чтобы
    -- понять, что гонка ещё идёт.
    local vw, vh = 1920, 1080
    pcall_(function() local v = camera.ViewportSize; vw = v.X; vh = v.Y end)
    local cx, cy = mfloor(vw * 0.5), mfloor(vh * CFG.cheerY)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    pcall_(function() mousemoveabs(cx, cy) end)   -- встаём на CHEER один раз
    local n = 0
    local tCap = tick_()   -- v18.15: страховка - гонка длится <1мин, дольше 75с не спамим
    while MG.active and ScriptActive and (tick_() - tCap) < 75 do
        LSM.lastBot = tick_()
        pcall_(function() mouse1press(); mouse1release() end)
        n = n + 1
        if n % 8 == 0 then
            local ok, still = pcall_(function() return btn.Parent and MG.text(btn):find("CHEER") end)
            if not (ok and still) then break end   -- гонка кончилась / кнопка пропала
            pcall_(function() mousemoveabs(cx, cy) end)   -- держим курсор на кнопке
            LSM.standBusyT = tick_()
        end
        task_wait(0.05)   -- v18.8: ≈20 кликов/сек - быстро, но БЕЗ фриза (раньше
        -- было каждый кадр + 2 клика -> FPS падал в пол)
    end
    pcall_(function() if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end end)
end
-- v18.9: после гонки -> экран "YOU GOT ...! EXIT" (resultUp) -> жмём EXIT ->
-- вылазит ЧЕК (Popup.Check) -> клик по центру, забираем деньги. Потом кулдаун
-- 5 мин, и если включено - стартуем заново (ветка входа при cd<=0).
function MG.resultUp()
    local pg = player:FindFirstChildOfClass("PlayerGui")
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
    local pg = player:FindFirstChildOfClass("PlayerGui")
    local popup = pg and pg:FindFirstChild("Popup")
    local chk = popup and popup:FindFirstChild("Check")
    return (chk and MG.shown(chk)) or false
end
-- v18.11: клик по чеку. Сначала реальная позиция самого большого видимого
-- элемента Popup.Check (на нём ловится клик), потом центр экрана - страховка.
-- По 2 клика каждый, чтобы точно зарегалось.
function MG.clickCheck()
    local vw, vh = 1920, 1080
    pcall_(function() local v = camera.ViewportSize; vw = v.X; vh = v.Y end)
    local ox, oy = S.mx, S.my
    pcall_(function() if mouse then ox = mouse.X; oy = mouse.Y end end)
    -- 1) точка на самом чеке
    pcall_(function()
        local pg = player:FindFirstChildOfClass("PlayerGui")
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
            mousemoveabs(mfloor(bx), mfloor(by)); mouse1press(); mouse1release()
            task_wait(0.05)
            mousemoveabs(mfloor(bx), mfloor(by)); mouse1press(); mouse1release()
        end
    end)
    -- 2) центр экрана - страховка
    pcall_(function()
        LSM.lastBot = tick_()
        mousemoveabs(mfloor(vw * 0.5), mfloor(vh * 0.5)); mouse1press(); mouse1release()
        task_wait(0.05)
        mousemoveabs(mfloor(vw * 0.5), mfloor(vh * 0.5)); mouse1press(); mouse1release()
    end)
    pcall_(function() if ox and ox > 0 and oy and oy > 0 then mousemoveabs(mfloor(ox), mfloor(oy)) end end)
end
_wrap("auto-minigame", function()
    while ScriptActive do
        if MG.active then
            pcall_(function()
                -- 1) ГОНКА: CHEER -> непрерывный спам.
                -- v18.15: БЕЗ needPos! У кнопки гонки AbsolutePosition бывает 0,0
                -- (как у PICK-билбордов; зависит от разрешения/клиента) -> CHEER
                -- не находился, raceEndT не ставился, и EXIT после гонки тоже не
                -- жался. Позиция кнопки и не нужна: спамим по доле экрана.
                local cheer = MG.findBtn("CHEER")
                if cheer then
                    LSM.standBusyT = tick_()
                    MG.exitTries = 0   -- новая гонка -> сбрасываем счётчики попыток
                    MG.checkTries = 0
                    MG.spamCheer(cheer)
                    MG.raceEndT = tick_()   -- гонка только что закончилась
                    return
                end
                -- v18.12: EXIT и чек жмём ПО НЕСКОЛЬКУ ПОПЫТОК ЗА ГОНКУ, а не
                -- бесконечно. Раньше checkUp/resultUp ложно срабатывали на скрытых
                -- лейблах -> скрипт 40с долбил курсор, нельзя было двигать камеру.
                local justRaced = (tick_() - (MG.raceEndT or 0)) < 40
                -- 2) КОНЕЦ ГОНКИ: видна кнопка EXIT (та же MinigameRace.Button, что
                -- была CHEER) -> кликаем ПО САМОЙ КНОПКЕ (если у неё есть позиция)
                -- плюс по нескольким высотам. Макс 6 попыток за гонку.
                -- v18.15: ВИДИМАЯ кнопка EXIT срабатывает и без justRaced (если
                -- CHEER-фаза была пропущена, гонку всё равно надо закрыть);
                -- ненадёжный resultUp остаётся под защитой justRaced.
                local exitBtn = (MG.exitTries or 0) < 6 and MG.findBtn("EXIT") or nil
                if (MG.exitTries or 0) < 6 and (exitBtn or (justRaced and MG.resultUp())) then
                    LSM.standBusyT = tick_()
                    MG.exitTries = (MG.exitTries or 0) + 1
                    if not justRaced then MG.raceEndT = tick_() - 30 end   -- короткое окно (10с) для чека
                    if exitBtn then MG.click(exitBtn) end
                    MG.clickRatio(0.5, 0.80); MG.clickRatio(0.5, 0.86); MG.clickRatio(0.5, 0.91)
                    task_wait(0.6)
                    return
                end
                -- 3) ЧЕК на экране -> клик (макс 6 раз за гонку)
                if justRaced and (MG.checkTries or 0) < 6 and MG.checkUp() then
                    LSM.standBusyT = tick_()
                    MG.checkTries = (MG.checkTries or 0) + 1
                    MG.clickCheck()
                    task_wait(0.6)
                    return
                end
                -- 4) ВЫБОР: PICK (билборды) -> клик по экранным долям
                if MG.findBtn("PICK") then
                    LSM.standBusyT = tick_()
                    MG.clickSlots()
                    task_wait(0.4)
                    return
                end
                -- 5) КУЛДАУН? ждём. Таймер-лейбл стримится (виден только вблизи),
                -- поэтому ведём ЛОКАЛЬНЫЙ отсчёт и синкаем когда лейбл доступен.
                local cd = MG.timerSec()
                if cd and cd > 0 then MG.miniEnd = tick_() + cd end   -- синк у скамейки
                local localCd = MG.miniEnd and (MG.miniEnd - tick_()) or nil
                if (cd and cd > 0) or (localCd and localCd > 0) then
                    task_wait(0.5)
                    return
                end
                -- 6) ВХОД: PLAY/E у скамейки включённого минигейма
                LSM.standBusyT = tick_()
                local play = MG.findBtn("PLAY", true)
                if play then MG.click(play) end
                local pos = MG.entryPos()
                if pos then pcall_(function() _tpHrpTo(pos) end) end
                for _ = 1, 12 do
                    if not MG.active then break end
                    if MG.findBtn("PICK") or MG.findBtn("CHEER") then break end   -- минигейм пошёл
                    keypress(0x45); task_wait(0.04); keyrelease(0x45); task_wait(0.06)
                end
                task_wait(0.3)
            end)
        end
        task_wait(CFG.slow and 0.5 or 0.2)
    end
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

        -- v15: только Locations-пасс (реальные корды из своего тайкуна + селектор).
        -- Старые manage/stand пассы искали пустышки без позиций -> не тепало.
        local res = runLocationsPass(firstRun)
        firstRun = false
        if res == "off" then
            task_wait(0.05)
            continue
        end
        -- v18: ПРЕРЫВАЕМОЕ ожидание. Раньше task_wait(60) блокировал на всю
        -- минуту - выключил лемон, а стенд всё равно ждёт минуту. Теперь длину
        -- паузы пересчитываем вживую: лемон выключили -> ждём только STAND_LOOP_DELAY.
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
    pcall_(LSM.returnHome)   -- выгрузили посреди АФК-фарма: вернуть игрока на место
    ScriptActive = false
    pcall_(function() if UIRef.win then UIRef.win.visible = false end end)
    for _, obj in ipairs_(drawObjs) do
        pcall_(function() obj:Remove() end)
    end
    print("[Hub] Cleanup done")
end

rprint("sell lemons loaded")
