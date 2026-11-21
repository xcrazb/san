-- ============================================================
--  AUTO GIFT CYCLE - COLLECT N → SWITCH → OPEN ONCE → RESET
--  Kumpulkan N box → switch pet 1 → buka semua → balik pet 0
-- ============================================================

local Players      = game:GetService("Players")
local Workspace    = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService   = game:GetService("RunService")

local player = Players.LocalPlayer

-- ============================================================
--  REMOTE CONTAINER
-- ============================================================
local container = ReplicatedStorage
    :WaitForChild("rbxts_include")
    :WaitForChild("node_modules")
    :WaitForChild("@rbxts")
    :WaitForChild("remo")
    :WaitForChild("src")
    :WaitForChild("container")

local switchPetLoadout = container:WaitForChild("pets.switchPetLoadout")

-- ============================================================
--  KONFIGURASI
-- ============================================================
local CONFIG = {
    BoxThreshold    = 15,       -- default, bisa diubah via input
    CountInterval   = 0.3,
    OpenSweepDelay  = 0.1,      -- delay antar sweep buka
    LandedThreshold = 15,
    GiftNameFilter  = "ChristmasGift",
    PromptAction    = "Open Gift",
    SlotPetA        = 0,        -- pet pengumpul
    SlotPetB        = 1,        -- pet pembuka
    SwitchDelay     = 1.0,
    ResetDelay      = 1.0,
    EmptyConfirm    = 3,        -- berapa kali cek kosong sebelum dianggap selesai
    MaxSweepRounds  = 5,        -- max sweep buka (jaga-jaga gift baru muncul)
}

-- ============================================================
--  STATE
-- ============================================================
local State = {
    running     = false,
    phase       = "IDLE",
    giftCount   = 0,
    openedCount = 0,
    failedCount = 0,
    cycleCount  = 0,
    lastOpened  = nil,
    maxSeen     = 0,
    destroyed   = false,
}

-- ============================================================
--  SWITCH PET
-- ============================================================
local function switchPetSlot(slotIndex)
    if State.destroyed then return false end
    local ok, err = pcall(function()
        switchPetLoadout:InvokeServer(slotIndex)
    end)
    if not ok then
        warn("[AUTO-GIFT] Gagal switch pet: " .. tostring(err))
        return false
    end
    print(string.format("[AUTO-GIFT] ✅ Switch pet ke slot %d", slotIndex))
    return true
end

-- ============================================================
--  DETEKSI BOX
-- ============================================================
local function countGifts()
    local gameFolder = Workspace:FindFirstChild("Game")
    if not gameFolder then return 0, {} end

    local count = 0
    local details = {}
    for _, obj in ipairs(gameFolder:GetChildren()) do
        if obj:IsA("Model") and obj.Name == CONFIG.GiftNameFilter then
            local prompt = obj:FindFirstChildOfClass("ProximityPrompt")
            if prompt and prompt.ActionText == CONFIG.PromptAction then
                count += 1
                local pos = obj:GetPivot().Position
                table.insert(details, {
                    model = obj,
                    prompt = prompt,
                    pos = string.format("%.1f, %.1f, %.1f", pos.X, pos.Y, pos.Z),
                    y = pos.Y,
                    landed = pos.Y <= CONFIG.LandedThreshold,
                })
            end
        end
    end
    return count, details
end

-- Buka SEMUA gift yang ada saat ini (satu pass)
local function openAllGiftsOnce()
    local n, list = countGifts()
    if n == 0 then return 0 end

    local opened = 0
    for _, g in ipairs(list) do
        if g.prompt and g.prompt.Enabled then
            local ok = pcall(function()
                fireproximityprompt(g.prompt)
            end)
            if ok then
                opened += 1
                State.openedCount += 1
                State.lastOpened = g.pos
            else
                State.failedCount += 1
            end
        end
    end
    return opened
end

-- ============================================================
--  SIKLUS UTAMA
-- ============================================================
local function cycleLoop()
    if State.running or State.destroyed then return end
    State.running = true

    task.spawn(function()
        while State.running and not State.destroyed do
            -- ===== FASE 1: WAITING (kumpulkan N box) =====
            State.phase = "WAITING"
            print(string.format("[AUTO-GIFT] Menunggu %d box terkumpul...", CONFIG.BoxThreshold))
            while State.running and State.phase == "WAITING" and not State.destroyed do
                local n, _ = countGifts()
                State.giftCount = n
                if n > State.maxSeen then State.maxSeen = n end
                if n >= CONFIG.BoxThreshold then break end
                task.wait(CONFIG.CountInterval)
            end
            if not State.running or State.destroyed then break end

            -- ===== FASE 2: SWITCHING (slot 0 → 1) =====
            State.phase = "SWITCHING"
            print(string.format("[AUTO-GIFT] %d box terkumpul! Switch pet %d→%d",
                State.giftCount, CONFIG.SlotPetA, CONFIG.SlotPetB))
            switchPetSlot(CONFIG.SlotPetB)
            task.wait(CONFIG.SwitchDelay)
            if not State.running or State.destroyed then break end

            -- ===== FASE 3: OPENING (buka semua SEKALI, lalu selesai) =====
            State.phase = "OPENING"
            print("[AUTO-GIFT] Membuka semua gift (satu kali sapu)...")
            local emptyStreak = 0
            local sweepRound = 0
            while State.running and State.phase == "OPENING" and not State.destroyed do
                local n, _ = countGifts()
                State.giftCount = n

                if n == 0 then
                    emptyStreak += 1
                    -- Konfirmasi kosong beberapa kali agar yakin semua sudah terbuka
                    if emptyStreak >= CONFIG.EmptyConfirm then break end
                else
                    emptyStreak = 0
                    sweepRound += 1
                    local opened = openAllGiftsOnce()
                    print(string.format("[AUTO-GIFT] Sweep #%d: buka %d gift (sisa %d)",
                        sweepRound, opened, n - opened))

                    -- Batas pengaman: jangan loop selamanya jika gift terus muncul
                    if sweepRound >= CONFIG.MaxSweepRounds then
                        print("[AUTO-GIFT] ⚠️ Max sweep tercapai, lanjut reset")
                        break
                    end
                end
                task.wait(CONFIG.OpenSweepDelay)
            end
            if not State.running or State.destroyed then break end

            -- ===== FASE 4: RESETTING (balik slot 0) =====
            State.phase = "RESETTING"
            print("[AUTO-GIFT] Semua gift terbuka. Balik ke slot pet 0...")
            task.wait(CONFIG.ResetDelay)
            switchPetSlot(CONFIG.SlotPetA)
            State.cycleCount += 1
            print(string.format("[AUTO-GIFT] ✅ Siklus #%d selesai. Mulai kumpulkan lagi...", State.cycleCount))
            task.wait(0.5)
        end
        State.phase = "IDLE"
        State.running = false
    end)
end

local function stopCycle()
    State.running = false
    State.phase = "IDLE"
end

-- ============================================================
--  GUI THEME
-- ============================================================
local C = {
    Bg = Color3.fromRGB(10, 10, 16), Panel = Color3.fromRGB(20, 20, 32),
    Element = Color3.fromRGB(32, 32, 48), Accent = Color3.fromRGB(140, 110, 255),
    Accent2 = Color3.fromRGB(90, 210, 255), Text = Color3.fromRGB(255, 255, 255),
    Sub = Color3.fromRGB(160, 160, 195), Stroke = Color3.fromRGB(60, 60, 90),
    Success = Color3.fromRGB(100, 240, 160), Danger = Color3.fromRGB(255, 100, 120),
    Warn = Color3.fromRGB(255, 180, 80),
}

for _, n in ipairs({"UltraGiftGUI", "AutoGiftGUI", "GiftOpenerGUI", "GiftCycleGUI"}) do
    local o = player.PlayerGui:FindFirstChild(n)
    if o then o:Destroy() end
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "GiftCycleGUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = player:WaitForChild("PlayerGui")

local Main = Instance.new("Frame")
Main.Size = UDim2.new(0, 340, 0, 0); Main.Position = UDim2.new(0, 20, 0, 20)
Main.BackgroundColor3 = C.Bg; Main.BorderSizePixel = 0; Main.ClipsDescendants = true
Main.Parent = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 16)
local ms = Instance.new("UIStroke", Main)
ms.Color = C.Stroke; ms.Thickness = 1.5; ms.Transparency = 0.25

local TopBar = Instance.new("Frame")
TopBar.Size = UDim2.new(1, 0, 0, 54); TopBar.BackgroundColor3 = C.Panel; TopBar.BorderSizePixel = 0; TopBar.Parent = Main
Instance.new("UICorner", TopBar).CornerRadius = UDim.new(0, 16)

local Title = Instance.new("TextLabel", TopBar)
Title.Size = UDim2.new(1, -140, 0, 22); Title.Position = UDim2.new(0, 16, 0, 8)
Title.BackgroundTransparency = 1; Title.Text = "🔄 AUTO GIFT CYCLE"
Title.TextColor3 = C.Text; Title.Font = Enum.Font.GothamBlack; Title.TextSize = 16
Title.TextXAlignment = Enum.TextXAlignment.Left

local Subtitle = Instance.new("TextLabel", TopBar)
Subtitle.Size = UDim2.new(1, -140, 0, 14); Subtitle.Position = UDim2.new(0, 16, 0, 32)
Subtitle.BackgroundTransparency = 1; Subtitle.Text = "Collect N → Switch Pet → Open All → Reset"
Subtitle.TextColor3 = C.Sub; Subtitle.Font = Enum.Font.GothamBold; Subtitle.TextSize = 10
Subtitle.TextXAlignment = Enum.TextXAlignment.Left

local FpsCounter = Instance.new("TextLabel", TopBar)
FpsCounter.Size = UDim2.new(0, 44, 0, 22); FpsCounter.Position = UDim2.new(1, -100, 0.5, -11)
FpsCounter.BackgroundColor3 = C.Element; FpsCounter.Text = "-- FPS"
FpsCounter.TextColor3 = C.Success; FpsCounter.Font = Enum.Font.GothamBold; FpsCounter.TextSize = 10; FpsCounter.BorderSizePixel = 0
Instance.new("UICorner", FpsCounter).CornerRadius = UDim.new(0, 6)

local MinBtn = Instance.new("TextButton", TopBar)
MinBtn.Size = UDim2.new(0, 26, 0, 26); MinBtn.Position = UDim2.new(1, -64, 0.5, -13)
MinBtn.BackgroundColor3 = C.Element; MinBtn.Text = "—"; MinBtn.TextColor3 = C.Sub
MinBtn.Font = Enum.Font.GothamBold; MinBtn.TextSize = 14; MinBtn.BorderSizePixel = 0; MinBtn.AutoButtonColor = false
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(1, 0)

local CloseBtn = Instance.new("TextButton", TopBar)
CloseBtn.Name = "CloseBtn"
CloseBtn.Size = UDim2.new(0, 26, 0, 26); CloseBtn.Position = UDim2.new(1, -34, 0.5, -13)
CloseBtn.BackgroundColor3 = C.Danger; CloseBtn.Text = "✕"; CloseBtn.TextColor3 = C.Text
CloseBtn.Font = Enum.Font.GothamBold; CloseBtn.TextSize = 14; CloseBtn.BorderSizePixel = 0; CloseBtn.AutoButtonColor = false
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(1, 0)

local Body = Instance.new("Frame")
Body.Size = UDim2.new(1, -20, 0, 0); Body.Position = UDim2.new(0, 10, 0, 62)
Body.BackgroundTransparency = 1; Body.Parent = Main
local BodyLayout = Instance.new("UIListLayout", Body)
BodyLayout.Padding = UDim.new(0, 8); BodyLayout.SortOrder = Enum.SortOrder.LayoutOrder

local order = 0
local function nextOrder() order += 1; return order end

-- KOMPONEN UI
local function makeSection(text)
    local f = Instance.new("Frame", Body)
    f.Size = UDim2.new(1, 0, 0, 22); f.BackgroundTransparency = 1; f.LayoutOrder = nextOrder()
    local bar = Instance.new("Frame", f)
    bar.Size = UDim2.new(0, 3, 0, 12); bar.Position = UDim2.new(0, 0, 0.5, -6); bar.BackgroundColor3 = C.Accent2; bar.BorderSizePixel = 0
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)
    local l = Instance.new("TextLabel", f)
    l.Size = UDim2.new(1, -10, 1, 0); l.Position = UDim2.new(0, 10, 0, 0)
    l.BackgroundTransparency = 1; l.Text = text:upper(); l.TextColor3 = C.Sub; l.Font = Enum.Font.GothamBlack; l.TextSize = 10; l.TextXAlignment = Enum.TextXAlignment.Left
end

local function makeToggle(text, default, callback)
    local toggled = default and true or false
    local f = Instance.new("Frame", Body)
    f.Size = UDim2.new(1, 0, 0, 44); f.BackgroundColor3 = C.Element; f.BackgroundTransparency = 0.25; f.BorderSizePixel = 0; f.LayoutOrder = nextOrder()
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 9)
    local stroke = Instance.new("UIStroke", f)
    stroke.Color = C.Stroke; stroke.Thickness = 1; stroke.Transparency = 0.5
    local lbl = Instance.new("TextLabel", f)
    lbl.Size = UDim2.new(1, -76, 1, 0); lbl.Position = UDim2.new(0, 14, 0, 0); lbl.BackgroundTransparency = 1
    lbl.Text = text; lbl.TextColor3 = C.Text; lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 12; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.TextWrapped = true
    local tb = Instance.new("TextButton", f)
    tb.Size = UDim2.new(0, 44, 0, 22); tb.Position = UDim2.new(1, -56, 0.5, -11); tb.BackgroundColor3 = C.Stroke; tb.Text = ""; tb.BorderSizePixel = 0; tb.AutoButtonColor = false
    Instance.new("UICorner", tb).CornerRadius = UDim.new(1, 0)
    local circle = Instance.new("Frame", tb)
    circle.Size = UDim2.new(0, 16, 0, 16); circle.Position = UDim2.new(0, 3, 0.5, -8); circle.BackgroundColor3 = Color3.new(1, 1, 1); circle.BorderSizePixel = 0
    Instance.new("UICorner", circle).CornerRadius = UDim.new(1, 0)
    local function visual(a)
        local pos = toggled and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
        local col = toggled and C.Accent or C.Stroke
        if a then
            TweenService:Create(circle, TweenInfo.new(0.22, Enum.EasingStyle.Back), {Position=pos}):Play()
            TweenService:Create(tb, TweenInfo.new(0.18), {BackgroundColor3=col}):Play()
            TweenService:Create(stroke, TweenInfo.new(0.18), {Color=toggled and C.Accent or C.Stroke, Transparency=toggled and 0.3 or 0.5}):Play()
        else circle.Position = pos; tb.BackgroundColor3 = col end
    end
    visual(false)
    tb.MouseButton1Click:Connect(function()
        toggled = not toggled; visual(true)
        if callback then callback(toggled) end
    end)
    return {Set=function(v) toggled=v; visual(true) end, Get=function() return toggled end}
end

local function makeStatus(height)
    local l = Instance.new("TextLabel", Body)
    l.Size = UDim2.new(1, 0, 0, height or 50); l.BackgroundColor3 = C.Element; l.BackgroundTransparency = 0.55; l.BorderSizePixel = 0
    l.Text = "..."; l.TextColor3 = C.Success; l.Font = Enum.Font.GothamBold; l.TextSize = 11; l.TextWrapped = true; l.LayoutOrder = nextOrder()
    Instance.new("UICorner", l).CornerRadius = UDim.new(0, 9)
    local pad = Instance.new("UIPadding", l)
    pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.PaddingTop = UDim.new(0, 4); pad.PaddingBottom = UDim.new(0, 4)
    return l
end

-- ============================================================
--  ISI GUI
-- ============================================================
makeSection("Cycle Control")

local toggleCycle = makeToggle("Auto Cycle", false, function(v)
    if v then cycleLoop() else stopCycle() end
end)

-- INPUT BOX THRESHOLD
makeSection("Box Threshold")

local inputFrame = Instance.new("Frame", Body)
inputFrame.Size = UDim2.new(1, 0, 0, 40); inputFrame.BackgroundColor3 = C.Element; inputFrame.BackgroundTransparency = 0.25
inputFrame.BorderSizePixel = 0; inputFrame.LayoutOrder = nextOrder()
Instance.new("UICorner", inputFrame).CornerRadius = UDim.new(0, 9)
local inputStroke = Instance.new("UIStroke", inputFrame)
inputStroke.Color = C.Stroke; inputStroke.Thickness = 1; inputStroke.Transparency = 0.5

local inputLabel = Instance.new("TextLabel", inputFrame)
inputLabel.Size = UDim2.new(0.55, 0, 1, 0); inputLabel.Position = UDim2.new(0, 14, 0, 0)
inputLabel.BackgroundTransparency = 1; inputLabel.Text = "Kumpulkan N Box:"
inputLabel.TextColor3 = C.Text; inputLabel.Font = Enum.Font.GothamBold; inputLabel.TextSize = 12
inputLabel.TextXAlignment = Enum.TextXAlignment.Left

local inputBox = Instance.new("TextBox", inputFrame)
inputBox.Size = UDim2.new(0.4, -14, 0, 26); inputBox.Position = UDim2.new(0.6, 0, 0.5, -13)
inputBox.BackgroundColor3 = C.Bg; inputBox.Text = tostring(CONFIG.BoxThreshold)
inputBox.TextColor3 = C.Success; inputBox.Font = Enum.Font.GothamBold; inputBox.TextSize = 14
inputBox.BorderSizePixel = 0; inputBox.ClearTextOnFocus = false
inputBox.PlaceholderText = "15"
Instance.new("UICorner", inputBox).CornerRadius = UDim.new(0, 6)
local ibStroke = Instance.new("UIStroke", inputBox)
ibStroke.Color = C.Stroke; ibStroke.Thickness = 1; ibStroke.Transparency = 0.4

inputBox.FocusLost:Connect(function()
    local num = tonumber(inputBox.Text)
    if num and num >= 1 and num <= 999 then
        CONFIG.BoxThreshold = math.floor(num)
        inputBox.Text = tostring(CONFIG.BoxThreshold)
        print(string.format("[AUTO-GIFT] Threshold diubah ke %d box", CONFIG.BoxThreshold))
    else
        inputBox.Text = tostring(CONFIG.BoxThreshold)
    end
end)

-- Panel counter box
makeSection("Box Counter")

local counterPanel = Instance.new("Frame", Body)
counterPanel.Size = UDim2.new(1, 0, 0, 70); counterPanel.BackgroundColor3 = C.Element; counterPanel.BackgroundTransparency = 0.3
counterPanel.BorderSizePixel = 0; counterPanel.LayoutOrder = nextOrder()
Instance.new("UICorner", counterPanel).CornerRadius = UDim.new(0, 9)
local cpStroke = Instance.new("UIStroke", counterPanel)
cpStroke.Color = C.Accent; cpStroke.Thickness = 1.5; cpStroke.Transparency = 0.4

local countBig = Instance.new("TextLabel", counterPanel)
countBig.Size = UDim2.new(0, 80, 1, 0); countBig.Position = UDim2.new(0, 0, 0, 0)
countBig.BackgroundTransparency = 1; countBig.Text = "0"
countBig.TextColor3 = C.Success; countBig.Font = Enum.Font.GothamBlack; countBig.TextSize = 40
countBig.Parent = counterPanel

local countLabel = Instance.new("TextLabel", counterPanel)
countLabel.Size = UDim2.new(1, -90, 0, 20); countLabel.Position = UDim2.new(0, 85, 0, 12)
countLabel.BackgroundTransparency = 1; countLabel.Text = "BOX IN POND / 15"
countLabel.TextColor3 = C.Sub; countLabel.Font = Enum.Font.GothamBlack; countLabel.TextSize = 11
countLabel.TextXAlignment = Enum.TextXAlignment.Left
countLabel.Parent = counterPanel

local countDetail = Instance.new("TextLabel", counterPanel)
countDetail.Size = UDim2.new(1, -90, 0, 34); countDetail.Position = UDim2.new(0, 85, 0, 30)
countDetail.BackgroundTransparency = 1; countDetail.Text = "Max seen: 0"
countDetail.TextColor3 = C.Text; countDetail.Font = Enum.Font.GothamBold; countDetail.TextSize = 10
countDetail.TextXAlignment = Enum.TextXAlignment.Left; countDetail.TextWrapped = true
countDetail.Parent = counterPanel

local statusLabel = makeStatus(140)

-- AUTO ENABLE
task.spawn(function()
    task.wait(0.5)
    if State.destroyed then return end
    toggleCycle.Set(true)
    cycleLoop()
end)

-- FPS COUNTER
local fpsFrames, fpsTime = 0, os.clock()
RunService.RenderStepped:Connect(function()
    fpsFrames += 1
    local now = os.clock()
    if now - fpsTime >= 1 then
        local fpsValue = math.floor(fpsFrames / (now - fpsTime))
        fpsFrames = 0; fpsTime = now
        FpsCounter.Text = fpsValue .. " FPS"
        FpsCounter.TextColor3 = fpsValue >= 50 and C.Success or (fpsValue >= 30 and C.Warn or C.Danger)
    end
end)

-- LIVE COUNTER + STATUS LOOP
task.spawn(function()
    while ScreenGui.Parent and not State.destroyed do
        local n, _ = countGifts()
        State.giftCount = n
        if n > State.maxSeen then State.maxSeen = n end

        countBig.Text = tostring(n)
        countBig.TextColor3 = n >= CONFIG.BoxThreshold and C.Success or (n > 0 and C.Warn or C.Sub)
        countLabel.Text = string.format("BOX IN POND / %d", CONFIG.BoxThreshold)

        if n >= CONFIG.BoxThreshold then
            cpStroke.Transparency = 0.2 + 0.2 * math.sin(tick() * 6)
        else
            cpStroke.Transparency = 0.5
        end

        countDetail.Text = string.format("Max seen: %d\nPhase: %s", State.maxSeen, State.phase)

        local phaseColors = {
            IDLE = C.Sub,
            WAITING = C.Accent2,
            SWITCHING = C.Warn,
            OPENING = C.Success,
            RESETTING = C.Accent,
        }
        statusLabel.TextColor3 = phaseColors[State.phase] or C.Text
        statusLabel.Text = string.format(
            "Phase: %s\nCycle: %d | Opened: %d | Failed: %d\nBox: %d / %d\nLast: %s\nRunning: %s",
            State.phase, State.cycleCount, State.openedCount, State.failedCount,
            n, CONFIG.BoxThreshold,
            State.lastOpened or "—",
            State.running and "YES" or "NO"
        )

        task.wait(CONFIG.CountInterval)
    end
end)

-- DRAG + MINIMIZE
local dragging, dragStart, startPos
TopBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = Main.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - dragStart
        Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
end)

local minimized = false
local function refreshHeight()
    if State.destroyed then return end
    local h = BodyLayout.AbsoluteContentSize.Y
    local target = minimized and 54 or (62 + h + 12)
    TweenService:Create(Main, TweenInfo.new(0.25, Enum.EasingStyle.Quart), {
        Size = UDim2.new(0, 340, 0, target),
    }):Play()
end
BodyLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(refreshHeight)

MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized; Body.Visible = not minimized
    MinBtn.Text = minimized and "+" or "—"; refreshHeight()
end)

-- TOMBOL CLOSE
CloseBtn.MouseButton1Click:Connect(function()
    print("[AUTO-GIFT] 🛑 Close ditekan. Menghentikan semua...")

    State.destroyed = true
    State.running = false
    State.phase = "IDLE"

    local function fadeAll(parent, transparency)
        for _, d in ipairs(parent:GetDescendants()) do
            if d:IsA("GuiObject") and d.BackgroundTransparency < 1 then
                TweenService:Create(d, TweenInfo.new(0.2), { BackgroundTransparency = transparency }):Play()
            end
            if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
                TweenService:Create(d, TweenInfo.new(0.2), { TextTransparency = transparency }):Play()
            end
        end
    end
    fadeAll(Main, 1)

    task.delay(0.25, function()
        pcall(function()
            ScreenGui:Destroy()
        end)
        print("[AUTO-GIFT] ✅ GUI dihapus. Script berhenti.")
    end)
end)

Main.Size = UDim2.new(0, 0, 0, 0)
task.wait(0.05); refreshHeight()
