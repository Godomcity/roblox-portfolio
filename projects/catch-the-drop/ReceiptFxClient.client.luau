--[[
	ReceiptFxClient — StarterPlayerScripts
	툴 장착 여부와 무관하게 항상 실행됨.
	서버(ReceiptService)가 FireClient 하면 카메라 이펙트 + 영수증 UI를 재생.
]]

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local TweenService       = game:GetService("TweenService")
local UserInputService   = game:GetService("UserInputService")

local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local RE_ReceiptClientEffect = NetworkFolder:WaitForChild("RE_ReceiptClientEffect", 15)

if not RE_ReceiptClientEffect then
	warn("[ReceiptFxClient] RE_ReceiptClientEffect Remote를 찾지 못했습니다.")
	return
end

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- 카메라 이펙트 설정
--------------------------------------------------------------------------------
local CAM_FOV_NORMAL    = 70
local CAM_FOV_DISTORTED = 82
local CAM_ROLL_DEG      = 5
local CAM_SENSITIVITY   = 0.35   -- 정상 감도 대비 비율
local CAM_IN_TIME       = 0.35
local CAM_OUT_TIME      = 0.55

--------------------------------------------------------------------------------
-- 영수증 UI 설정
--------------------------------------------------------------------------------
local RECEIPT_LINES = {
	"*** SHOPPER RECEIPT ***",
	"------------------------",
	"TAG SCAN FEE:  $9,999",
	"STYLE TAX:     $99,999",
	"TREND PENALTY: $199,999",
	"GLAM SURCHARGE:$299,999",
	"------------------------",
	"TOTAL:         $999,999",
	"========================",
	"BARCODE: ||| || | || |||",
	"THANK YOU, COME AGAIN!",
	"========================",
}

local BORDER_DEFS = {
	{
		name = "ReceiptTop",
		anchorX = 0.5, anchorY = 0,
		posX = 0.5, posY = 0,
		sizeX = 1, sizeY = 0.25,
		slideAxis = "Y", slideDir = -1,
	},
	{
		name = "ReceiptBottom",
		anchorX = 0.5, anchorY = 1,
		posX = 0.5, posY = 1,
		sizeX = 1, sizeY = 0.25,
		slideAxis = "Y", slideDir = 1,
	},
	{
		name = "ReceiptLeft",
		anchorX = 0, anchorY = 0.5,
		posX = 0, posY = 0.5,
		sizeX = 0.22, sizeY = 1,
		slideAxis = "X", slideDir = -1,
	},
	{
		name = "ReceiptRight",
		anchorX = 1, anchorY = 0.5,
		posX = 1, posY = 0.5,
		sizeX = 0.22, sizeY = 1,
		slideAxis = "X", slideDir = 1,
	},
}

--------------------------------------------------------------------------------
-- GUI 헬퍼
--------------------------------------------------------------------------------
local function GetOrCreateReceiptGui()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("ReceiptEffectGui")
	if existing then return existing end

	local gui = Instance.new("ScreenGui")
	gui.Name = "ReceiptEffectGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui
	return gui
end

local function BuildReceiptFrame(gui, def)
	local startOffsetX = 0
	local startOffsetY = 0
	if def.slideAxis == "Y" then
		startOffsetY = def.slideDir * -1 * def.sizeY
	else
		startOffsetX = def.slideDir * -1 * def.sizeX
	end

	local frame = Instance.new("Frame")
	frame.Name = def.name
	frame.BackgroundColor3 = Color3.fromRGB(255, 252, 235)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(def.anchorX, def.anchorY)
	frame.Position = UDim2.new(def.posX + startOffsetX, 0, def.posY + startOffsetY, 0)
	frame.Size = UDim2.new(def.sizeX, 0, def.sizeY, 0)
	frame.ClipsDescendants = true
	frame.Parent = gui

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -8, 1, -4)
	label.Position = UDim2.new(0, 4, 0, 2)
	label.Font = Enum.Font.Code
	label.TextColor3 = Color3.fromRGB(30, 20, 10)
	label.TextTransparency = 0.1
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.RichText = false
	label.Text = table.concat(RECEIPT_LINES, "")
	label.Parent = frame

	-- 바코드 스트라이프
	for i = 1, 14 do
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
		bar.BackgroundTransparency = (i % 3 == 0) and 0.4 or 0.7
		bar.BorderSizePixel = 0
		local barWidth = (i % 2 == 0) and 0.025 or 0.012
		local barX = 0.01 + (i - 1) * 0.065
		bar.Size = UDim2.new(barWidth, 0, 0.12, 0)
		bar.Position = UDim2.new(barX, 0, 0.82, 0)
		bar.Parent = frame
	end

	return frame
end

--------------------------------------------------------------------------------
-- 카메라 이펙트
--------------------------------------------------------------------------------
local _originalSensitivity = nil
local effectToken = 0

local function ApplyReceiptCameraEffect(duration, gui)
	local camera = workspace.CurrentCamera
	if not camera then return end

	-- 1) FOV 왜곡
	TweenService:Create(
		camera,
		TweenInfo.new(CAM_IN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FieldOfView = CAM_FOV_DISTORTED }
	):Play()

	task.delay(duration - CAM_OUT_TIME, function()
		local cam = workspace.CurrentCamera
		if cam then
			TweenService:Create(
				cam,
				TweenInfo.new(CAM_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ FieldOfView = CAM_FOV_NORMAL }
			):Play()
		end
	end)

	-- 2) 마우스 감도 둔화
	if _originalSensitivity == nil then
		_originalSensitivity = UserInputService.MouseDeltaSensitivity
	end
	UserInputService.MouseDeltaSensitivity = _originalSensitivity * CAM_SENSITIVITY

	task.delay(duration - CAM_OUT_TIME, function()
		if _originalSensitivity == nil then return end
		local startVal = UserInputService.MouseDeltaSensitivity
		local endVal   = _originalSensitivity
		local steps    = 10
		for i = 1, steps do
			task.delay((CAM_OUT_TIME / steps) * i, function()
				UserInputService.MouseDeltaSensitivity =
					startVal + (endVal - startVal) * (i / steps)
			end)
		end
		task.delay(CAM_OUT_TIME + 0.05, function()
			UserInputService.MouseDeltaSensitivity = endVal
			_originalSensitivity = nil
		end)
	end)

	-- 3) 화면 기울기 (RollContainer Frame Rotation)
	if gui then
		local rollContainer = gui:FindFirstChild("RollContainer")
		if not rollContainer then
			rollContainer = Instance.new("Frame")
			rollContainer.Name = "RollContainer"
			rollContainer.BackgroundTransparency = 1
			rollContainer.BorderSizePixel = 0
			rollContainer.AnchorPoint = Vector2.new(0.5, 0.5)
			rollContainer.Position = UDim2.new(0.5, 0, 0.5, 0)
			rollContainer.Size = UDim2.new(1, 0, 1, 0)
			rollContainer.Rotation = 0
			rollContainer.Parent = gui
		end

		TweenService:Create(
			rollContainer,
			TweenInfo.new(CAM_IN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Rotation = CAM_ROLL_DEG }
		):Play()

		task.delay(duration - CAM_OUT_TIME, function()
			if rollContainer and rollContainer.Parent then
				TweenService:Create(
					rollContainer,
					TweenInfo.new(CAM_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ Rotation = 0 }
				):Play()
			end
		end)
	end
end

--------------------------------------------------------------------------------
-- 전체 이펙트
--------------------------------------------------------------------------------
local function PlayReceiptScreenEffect(duration)
	local myToken = effectToken + 1
	effectToken = myToken

	local gui = GetOrCreateReceiptGui()

	-- 기존 영수증 프레임 정리
	for _, child in ipairs(gui:GetChildren()) do
		if child:IsA("Frame") and child.Name:sub(1, 7) == "Receipt" then
			child:Destroy()
		end
	end

	ApplyReceiptCameraEffect(duration, gui)

	-- 4방향 슬라이드-인
	local slideDelays = {
		ReceiptTop = 0, ReceiptBottom = 0.07,
		ReceiptLeft = 0.13, ReceiptRight = 0.20,
	}
	for _, def in ipairs(BORDER_DEFS) do
		local frame = BuildReceiptFrame(gui, def)
		local targetPos = UDim2.new(def.posX, 0, def.posY, 0)

		task.delay(slideDelays[def.name] or 0, function()
			if effectToken ~= myToken then return end
			TweenService:Create(
				frame,
				TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Position = targetPos }
			):Play()
		end)
	end

	-- 슬라이드-아웃
	task.delay(duration - 0.6, function()
		if effectToken ~= myToken then return end
		for _, def in ipairs(BORDER_DEFS) do
			local frame = gui:FindFirstChild(def.name)
			if not frame then continue end

			local offX = 0
			local offY = 0
			if def.slideAxis == "Y" then
				offY = def.slideDir * -1 * def.sizeY
			else
				offX = def.slideDir * -1 * def.sizeX
			end

			TweenService:Create(
				frame,
				TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Position = UDim2.new(def.posX + offX, 0, def.posY + offY, 0) }
			):Play()
			game:GetService("Debris"):AddItem(frame, 0.6)
		end
	end)
end

--------------------------------------------------------------------------------
-- Remote 수신
--------------------------------------------------------------------------------
RE_ReceiptClientEffect.OnClientEvent:Connect(function(duration)
	task.spawn(function()
		PlayReceiptScreenEffect(tonumber(duration) or 5.0)
	end)
end)

--------------------------------------------------------------------------------
-- 리스폰 시 감도 안전 복구
--------------------------------------------------------------------------------
LocalPlayer.CharacterAdded:Connect(function()
	effectToken += 1
	if _originalSensitivity ~= nil then
		UserInputService.MouseDeltaSensitivity = _originalSensitivity
		_originalSensitivity = nil
	end
end)
