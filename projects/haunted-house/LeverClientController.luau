local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundManager = require(ReplicatedStorage:WaitForChild("SoundManager"))

local LeverClientController = {}
LeverClientController.__index = LeverClientController

-- 생성자: 레버 설정을 받아 클라이언트 컨트롤러 객체를 생성합니다.
function LeverClientController.new(leverConfigs, basePart)
	local self = setmetatable({}, LeverClientController)

	self.player = Players.LocalPlayer
	self.leverConfigs = leverConfigs
	self.basePart = basePart

	self.RequestDrag = ReplicatedStorage.RemoteEvents:WaitForChild("RequestDrag")
	self.ReleaseDrag = ReplicatedStorage.RemoteEvents:WaitForChild("ReleaseDrag")

	self.dragging = false
	self.currentLever = nil
	self.currentIndex = nil
	self.nameplates = {}

	-- [수정] 스냅 포인트 및 높이 제한 설정
	self.SNAP_POINTS = {-3, 0.5, 4}
	table.sort(self.SNAP_POINTS) -- 계산을 위해 오름차순으로 정렬
	self.MIN_OFFSET = self.SNAP_POINTS[1]
	self.MAX_OFFSET = self.SNAP_POINTS[#self.SNAP_POINTS]

	self:Initialize()
	return self
end

-- 컨트롤러 초기화
function LeverClientController:Initialize()
	for i, config in ipairs(self.leverConfigs) do
		self:_createPlayerNameplate(i, config.part)

		local activePlayerValue = config.part:WaitForChild("ActivePlayer")
		activePlayerValue.Changed:Connect(function(playerValue)
			self:_updateNameplate(i, playerValue)
		end)
		self:_updateNameplate(i, activePlayerValue.Value)
	end

	UserInputService.WindowFocusReleased:Connect(function()
		if self.dragging then self:releaseLever() end
	end)
end

-------------------------------------------------
-- 공용 액션 함수 (PC/모바일 스크립트에서 호출될 함수들)
-------------------------------------------------

-- 레버 잡기 시도
function LeverClientController:grabLever(leverIndex)
	if self.dragging then return false end

	if self.RequestDrag:InvokeServer(leverIndex) then
		self.currentLever = self.leverConfigs[leverIndex]
		self.currentIndex = leverIndex
		self.dragging = true
		return true
	end
	return false
end

-- 레버 놓기
function LeverClientController:releaseLever()
	if not self.dragging or not self.currentLever then return end

	local finalY = self:getNearestSnapY(self.currentLever.part.Position.Y)
	self.currentLever.remote:FireServer(finalY)
	self.ReleaseDrag:FireServer(self.currentIndex)

	self.dragging = false
	self.currentLever = nil
	self.currentIndex = nil
end

-- 레버 위치 업데이트 (주로 드래그 중에 사용)
function LeverClientController:updateLeverPosition(newY)
	if not self.dragging or not self.currentLever then return end

	-- [추가] 최대/최소 높이 제한 로직
	local baseY = self.basePart.Position.Y
	local clampedY = math.clamp(newY, baseY + self.MIN_OFFSET, baseY + self.MAX_OFFSET)

	SoundManager.LeverSound()
	self.currentLever.remote:FireServer(clampedY) -- 제한된 값으로 서버에 전송
end

-------------------------------------------------
-- 헬퍼(Helper) 함수들
-------------------------------------------------

function LeverClientController:moveLeverStep(direction) -- direction은 1 (위로) 또는 -1 (아래로)
	if not self.dragging or not self.currentLever then return end

	local currentY = self.currentLever.part.Position.Y
	local currentSnapIndex = self:_getClosestSnapIndex(currentY)

	-- 다음 인덱스를 계산하고 1과 스냅 포인트 개수 사이로 제한
	local newSnapIndex = math.clamp(currentSnapIndex + direction, 1, #self.SNAP_POINTS)

	-- 인덱스가 변경되었을 때만 위치 업데이트
	if newSnapIndex ~= currentSnapIndex then
		local baseY = self.basePart.Position.Y
		local newY = baseY + self.SNAP_POINTS[newSnapIndex]
		self:updateLeverPosition(newY)
	end
end

function LeverClientController:_getClosestSnapIndex(y)
	local baseY = self.basePart.Position.Y
	local closestIndex = 1
	local minDist = math.abs(y - (baseY + self.SNAP_POINTS[1]))

	for i, offset in ipairs(self.SNAP_POINTS) do
		local dist = math.abs(y - (baseY + offset))
		if dist < minDist then
			closestIndex = i
			minDist = dist
		end
	end
	return closestIndex
end

-- 가장 가까운 스냅 지점 Y좌표 계산
function LeverClientController:getNearestSnapY(y)
	local baseY = self.basePart.Position.Y
	local nearest = self.SNAP_POINTS[1]
	local minDist = math.abs(y - (baseY + nearest))
	for _, offset in ipairs(self.SNAP_POINTS) do
		local dist = math.abs(y - (baseY + offset))
		if dist < minDist then
			nearest = offset
			minDist = dist
		end
	end
	return baseY + nearest
end

-- 이름표 UI 생성 (비공개 함수)
function LeverClientController:_createPlayerNameplate(index, parentPart)
	local billboardGui = Instance.new("BillboardGui")
	billboardGui.Size = UDim2.new(5, 0, 1.5, 0)
	billboardGui.StudsOffset = Vector3.new(0, 2, 0)
	billboardGui.AlwaysOnTop = true

	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.new(1, 0, 1, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.TextColor3 = Color3.new(1, 1, 1)
	textLabel.TextScaled = true
	textLabel.Font = Enum.Font.SourceSansBold
	textLabel.TextStrokeTransparency = 0
	textLabel.Parent = billboardGui

	billboardGui.Enabled = false
	billboardGui.Parent = parentPart

	self.nameplates[index] = billboardGui
end

-- 이름표 UI 업데이트 (비공개 함수)
function LeverClientController:_updateNameplate(index, playerValue)
	local nameplate = self.nameplates[index]
	if not nameplate then return end

	if playerValue and playerValue:IsA("Player") then
		nameplate.Enabled = true
		nameplate:FindFirstChild("TextLabel").Text = playerValue.DisplayName
	else
		nameplate.Enabled = false
	end
end

return LeverClientController