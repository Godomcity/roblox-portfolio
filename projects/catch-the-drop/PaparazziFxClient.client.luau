local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local Lighting           = game:GetService("Lighting")
local TweenService       = game:GetService("TweenService")
local RunService         = game:GetService("RunService")
local Players            = game:GetService("Players")

local NetworkFolder  = ReplicatedStorage:WaitForChild("Network")
local RE_PaparazziFx = NetworkFolder:WaitForChild("RE_PaparazziFx")

local LocalPlayer = Players.LocalPlayer

-- ── 토큰 (중복 실행 방지) ─────────────────────────────────────
local activeBlurToken = 0
local activeBlur      = nil

-- ── Blur 정리 ────────────────────────────────────────────────
local function destroyActiveBlur()
	if activeBlur and activeBlur.Parent then
		activeBlur:Destroy()
	end
	activeBlur = nil
end

-- ── 1. 카메라 셰이크 ─────────────────────────────────────────
-- [FIX] 매 프레임 originalCFrame 기준으로 offset을 더하는 방식으로 교체
--       → 누적 드리프트 없이 셰이크가 끝나면 카메라가 정확히 원위치로 돌아옴
local function playCameraShake(duration, magnitude, frequency)
	duration  = duration  or 0.35
	magnitude = magnitude or 1.2
	frequency = frequency or 28

	local camera       = workspace.CurrentCamera
	local startTime    = tick()
	local originalCFrame = camera.CFrame
	local conn

	conn = RunService.RenderStepped:Connect(function()
		local elapsed = tick() - startTime
		if elapsed >= duration then
			conn:Disconnect()
			camera.CFrame = originalCFrame  -- 정확히 원위치 복구
			return
		end

		local decay   = 1 - (elapsed / duration)
		local offsetX = math.sin(elapsed * frequency * 1.3) * magnitude * decay
		local offsetY = math.cos(elapsed * frequency)       * magnitude * decay

		-- 기준 CFrame에서만 offset 적용 (누적 곱셈 X)
		camera.CFrame = originalCFrame
			* CFrame.new(offsetX, offsetY, 0)
			* CFrame.Angles(
				math.rad(offsetY * 0.4),
				math.rad(offsetX * 0.4),
				0
			)
	end)
end

-- ── 2. 플래시뱅 (ColorCorrection Brightness) ─────────────────
-- [FIX] 전용 인스턴스를 항상 새로 생성해 연속 피격 시 Brightness 고착 방지
local function playFlashbang()
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Brightness = 0
	cc.Parent = Lighting

	-- 즉시 최대 밝기
	cc.Brightness = 1

	local tween = TweenService:Create(
		cc,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Brightness = 0 }
	)
	tween:Play()
	tween.Completed:Connect(function()
		cc:Destroy()
	end)
end

-- ── 3. 뷰파인더 UI (카메라 테두리 + REC 불빛) ─────────────────
local function showViewfinderUI(duration)
	duration = duration or 2

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local old = playerGui:FindFirstChild("PaparazziViewfinder")
	if old then old:Destroy() end

	local sg = Instance.new("ScreenGui")
	sg.Name            = "PaparazziViewfinder"
	sg.ResetOnSpawn    = false
	sg.IgnoreGuiInset  = true
	sg.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
	sg.Parent          = playerGui

	local CORNER_SIZE_H = UDim2.new(0, 48, 0, 4)
	local CORNER_SIZE_V = UDim2.new(0, 4, 0, 48)
	local COLOR         = Color3.fromRGB(255, 255, 255)

	local corners = {
		{ UDim2.new(0, 20, 0, 20),   UDim2.new(0, 20, 0, 20)   },  -- 좌상
		{ UDim2.new(1, -68, 0, 20),  UDim2.new(1, -24, 0, 20)  },  -- 우상
		{ UDim2.new(0, 20, 1, -24),  UDim2.new(0, 20, 1, -68)  },  -- 좌하
		{ UDim2.new(1, -68, 1, -24), UDim2.new(1, -24, 1, -68) },  -- 우하
	}

	for _, c in ipairs(corners) do
		local h = Instance.new("Frame")
		h.Size                   = CORNER_SIZE_H
		h.Position               = c[1]
		h.BackgroundColor3       = COLOR
		h.BackgroundTransparency = 0
		h.BorderSizePixel        = 0
		h.Parent                 = sg

		local v = Instance.new("Frame")
		v.Size                   = CORNER_SIZE_V
		v.Position               = c[2]
		v.BackgroundColor3       = COLOR
		v.BackgroundTransparency = 0
		v.BorderSizePixel        = 0
		v.Parent                 = sg
	end

	local recFrame = Instance.new("Frame")
	recFrame.Size                   = UDim2.new(0, 72, 0, 28)
	recFrame.Position               = UDim2.new(1, -92, 0, 52)
	recFrame.BackgroundColor3       = Color3.fromRGB(20, 20, 20)
	recFrame.BackgroundTransparency = 0.3
	recFrame.BorderSizePixel        = 0
	recFrame.Parent                 = sg

	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0, 4)
	uiCorner.Parent = recFrame

	local dot = Instance.new("Frame")
	dot.Size             = UDim2.new(0, 10, 0, 10)
	dot.Position         = UDim2.new(0, 8, 0.5, -5)
	dot.BackgroundColor3 = Color3.fromRGB(255, 40, 40)
	dot.BorderSizePixel  = 0
	dot.Parent           = recFrame
	Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

	local recLabel = Instance.new("TextLabel")
	recLabel.Size                   = UDim2.new(1, -26, 1, 0)
	recLabel.Position               = UDim2.new(0, 24, 0, 0)
	recLabel.BackgroundTransparency = 1
	recLabel.Text                   = "REC"
	recLabel.TextColor3             = Color3.fromRGB(255, 40, 40)
	recLabel.TextScaled             = true
	recLabel.Font                   = Enum.Font.GothamBold
	recLabel.Parent                 = recFrame

	local blinkAlive = true
	task.spawn(function()
		local dotVisible = true
		while blinkAlive do
			dotVisible = not dotVisible
			if dot and dot.Parent then
				dot.BackgroundTransparency = dotVisible and 0 or 1
			end
			task.wait(0.5)
		end
	end)

	task.delay(duration, function()
		blinkAlive = false
		if sg and sg.Parent then
			for _, child in ipairs(sg:GetDescendants()) do
				if child:IsA("GuiObject") then
					TweenService:Create(child, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
				end
				if child:IsA("TextLabel") then
					TweenService:Create(child, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
				end
			end
			task.delay(0.35, function()
				if sg and sg.Parent then sg:Destroy() end
			end)
		end
	end)
end

-- ── 4. 블러 효과 ──────────────────────────────────────────────
-- [FIX] 서버가 Hold = 0.12를 넘겨도 최소 1.5초를 보장하도록 clamp 처리
local function playVictimBlur(data)
	activeBlurToken += 1
	local myToken = activeBlurToken

	destroyActiveBlur()

	local blur   = Instance.new("BlurEffect")
	blur.Name    = "PaparazziVictimBlur"
	blur.Size    = 0
	activeBlur   = blur
	blur.Parent  = Lighting

	local targetSize = tonumber(data and data.Size)    or 22
	local fadeIn     = tonumber(data and data.FadeIn)  or 0.05
	local fadeOut    = tonumber(data and data.FadeOut) or 0.28
	-- 서버에서 0.12가 넘어와도 최소 1.5초는 보장
	local hold       = math.max(tonumber(data and data.Hold) or 1.5, 1.5)

	local tweenIn = TweenService:Create(blur, TweenInfo.new(fadeIn), { Size = targetSize })
	tweenIn:Play()
	tweenIn.Completed:Wait()

	if myToken ~= activeBlurToken then return end

	task.wait(hold)

	if myToken ~= activeBlurToken then return end

	local tweenOut = TweenService:Create(blur, TweenInfo.new(fadeOut), { Size = 0 })
	tweenOut:Play()
	tweenOut.Completed:Wait()

	if myToken ~= activeBlurToken then return end

	destroyActiveBlur()
end

-- ── 이벤트 수신 ──────────────────────────────────────────────
RE_PaparazziFx.OnClientEvent:Connect(function(action, data)
	if action == "VictimBlur" then
		task.spawn(function()
			playCameraShake(0.35, 1.2, 28)
			playFlashbang()
			showViewfinderUI(2)
			playVictimBlur(data)
		end)
	end
end)
