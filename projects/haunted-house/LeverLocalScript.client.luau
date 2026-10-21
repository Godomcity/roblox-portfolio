-- LeverLocalScript (전체 내용)

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LeverClientController = require(ReplicatedStorage:WaitForChild("LeverClientController"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local character = player.Character or player.CharacterAdded:Wait()
local humanoidRootPart = character:WaitForChild("HumanoidRootPart")

local basePart = Workspace:WaitForChild("laver"):WaitForChild("Lever_G"):WaitForChild("Lever_Body")
local leverConfigs = {
	{ part = Workspace.laver.Lever_G:WaitForChild("Lever_Handle"), remote = ReplicatedStorage.RemoteEvents.SetLeverYPosition1 },
	{ part = Workspace.laver.Lever_G:WaitForChild("Lever_Handle1"), remote = ReplicatedStorage.RemoteEvents.SetLeverYPosition2 },
	{ part = Workspace.laver.Lever_G:WaitForChild("Lever_Handle2"), remote = ReplicatedStorage.RemoteEvents.SetLeverYPosition3 },
	{ part = Workspace.laver.Lever_G:WaitForChild("Lever_Handle3"), remote = ReplicatedStorage.RemoteEvents.SetLeverYPosition4 },
}

local controller = LeverClientController.new(leverConfigs, basePart)
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

if isMobile then
	-- ================== 모바일 입력 처리 ==================
	print("모바일: 입력 시스템을 컨트롤러에 연결합니다.")

	local triggerPart = Workspace:WaitForChild("LeverUITrigger")
	local inZone = false
	local TRIGGER_DISTANCE = 10

	local screenGui = playerGui:WaitForChild("MobileLeverUI")
	local upButton = screenGui:WaitForChild("UpButton")
	local downButton = screenGui:WaitForChild("DownButton")
	local resetButton = screenGui:WaitForChild("ResetLeverButton")
	local leverSelectButtons = {}
	for i=1, 4 do leverSelectButtons[i] = screenGui:WaitForChild("LeverSelect" .. i) end

	screenGui.Enabled = false

	-- [추가] 버튼 테두리 색상 변경 함수
	local function updateButtonBorders(selectedIndex)
		for i, button in ipairs(leverSelectButtons) do
			local stroke = button:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = (i == selectedIndex) and Color3.fromRGB(255, 255, 0) or Color3.fromRGB(46, 16, 64)
			end
		end
	end

	-- 각 레버 선택 버튼에 grabLever 기능 연결
	for i = 1, 4 do
		leverSelectButtons[i].MouseButton1Click:Connect(function()
			if controller.dragging and controller.currentIndex == i then return end -- 이미 같은 레버 선택 시 무시

			if controller.dragging then controller:releaseLever() end

			if controller:grabLever(i) then
				updateButtonBorders(i) -- [추가] 잡기 성공 시 테두리 업데이트
			end
		end)
	end

	-- 리셋 버튼에 releaseLever 기능 연결
	resetButton.MouseButton1Click:Connect(function()
		controller:releaseLever()
		updateButtonBorders(nil) -- [추가] 리셋 시 테두리 초기화
	end)

	-- [수정] 위/아래 버튼에 moveLeverStep 기능 연결
	upButton.MouseButton1Click:Connect(function() controller:moveLeverStep(1) end)
	downButton.MouseButton1Click:Connect(function() controller:moveLeverStep(-1) end)

	RunService.Heartbeat:Connect(function()
		local distance = (triggerPart.Position - humanoidRootPart.Position).Magnitude
		local shouldBeInZone = distance <= TRIGGER_DISTANCE

		if shouldBeInZone and not inZone then
			inZone = true
			screenGui.Enabled = true
		elseif not shouldBeInZone and inZone then
			inZone = false

			controller:releaseLever()
			updateButtonBorders(nil) -- [추가] 존 벗어날 때 테두리 초기화

			screenGui.Enabled = false
		end
	end)

else
	-- ================== PC 입력 처리 ==================
	print("PC: 입력 시스템을 컨트롤러에 연결합니다.")

	local mouse = player:GetMouse()
	local HOVER_CURSOR = "rbxassetid://16297520389"

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

		for i, config in ipairs(leverConfigs) do
			if mouse.Target == config.part then
				controller:grabLever(i)
				break
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			controller:releaseLever()
		end
	end)

	RunService.RenderStepped:Connect(function()
		if controller.dragging then
			controller:updateLeverPosition(mouse.Hit.Position.Y)
		else
			local isHovering = false
			for _, config in ipairs(leverConfigs) do
				if mouse.Target == config.part then
					isHovering = true
					break
				end
			end
			local currentIcon = isHovering and HOVER_CURSOR or ""
			if mouse.Icon ~= currentIcon then
				mouse.Icon = currentIcon
			end
		end
	end)
end