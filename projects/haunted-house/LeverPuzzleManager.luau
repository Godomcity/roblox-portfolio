local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local soundManager = require(ReplicatedStorage:WaitForChild("SoundManager"))

local LeverPuzzleManager = {}
LeverPuzzleManager.__index = LeverPuzzleManager

-- 생성자: 퍼즐 설정을 받아 퍼즐 관리자 객체를 생성하고 시작합니다.
function LeverPuzzleManager.new(config)
	local self = setmetatable({}, LeverPuzzleManager)

	-- 설정 및 상태 변수 초기화
	self.config = config
	self.remotes = config.remotes

	self.activePlayer = {}      -- { [leverIndex] = player }
	self.puzzleSolved = false   -- 퍼즐이 이미 풀렸는지 확인

	self.baseY = self.config.leverConfigs[1].part.Parent:FindFirstChild("Lever_Body").Position.Y
	self.possibleOffsets = { 4, 0.5, -3 }
	self.offsetToState = { [4] = "high", [0.5] = "middle", [-3] = "low" }
	self.currentAnswerOffsets = {}

	self:Initialize() -- 퍼즐 시작
	return self
end

-- 퍼즐 초기화 (이벤트 연결 및 정답 생성)
function LeverPuzzleManager:Initialize()
	self:_setupRandomPuzzle()

	-- RemoteEvent 및 RemoteFunction 연결
	self.remotes.RequestDrag.OnServerInvoke = function(player, leverIndex)
		return self:_onRequestDrag(player, leverIndex)
	end

	self.remotes.ReleaseDrag.OnServerEvent:Connect(function(player, leverIndex)
		self:_onReleaseDrag(player, leverIndex)
	end)

	for i, config in ipairs(self.config.leverConfigs) do
		config.remote.OnServerEvent:Connect(function(player, newY)
			self:_onUpdateLeverPosition(player, newY, i)
		end)
	end

	-- 플레이어 퇴장 시 처리
	Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end)
end

-------------------------------------------------
-- 핵심 로직 함수들 (비공개)
-------------------------------------------------

-- 무작위 퍼즐 생성
function LeverPuzzleManager:_setupRandomPuzzle()
	math.randomseed(os.time())
	local newAnswerOffsets, newHintImageIds = {}, {}

	for i = 1, #self.config.leverConfigs do
		local randomCorrectOffset = self.possibleOffsets[math.random(#self.possibleOffsets)]
		table.insert(newAnswerOffsets, randomCorrectOffset)

		local stateName = self.offsetToState[randomCorrectOffset]
		table.insert(newHintImageIds, self.config.imageIds[i][stateName])
	end

	self.currentAnswerOffsets = newAnswerOffsets
	for i, decal in ipairs(self.config.decalParts) do
		decal.Texture = newHintImageIds[i]
	end

	for i, config in ipairs(self.config.leverConfigs) do
		local randomStartOffset = self.possibleOffsets[math.random(#self.possibleOffsets)]
		local pos = config.part.Position
		config.part.Position = Vector3.new(pos.X, self.baseY + randomStartOffset, pos.Z)
	end
	print("레버 퍼즐이 동적으로 생성되었습니다. 정답:", table.unpack(self.currentAnswerOffsets))
end

-- 정답 확인
function LeverPuzzleManager:_checkAllAnswersCorrect()
	for i, config in ipairs(self.config.leverConfigs) do
		local expectedY = self.baseY + self.currentAnswerOffsets[i]
		if math.abs(expectedY - config.part.Position.Y) > 0.1 then
			return false
		end
	end
	return true
end

-- 보상 지급
function LeverPuzzleManager:_spawnRedKey(player)
	if self.puzzleSolved then return end
	self.puzzleSolved = true

	local redKey = self.config.redKey:Clone()
	redKey.Parent = workspace

	-- [수정] redKey가 Tool인 경우를 처리합니다.
	if redKey:IsA("Tool") then
		-- Tool은 Handle 파트의 위치를 지정해야 합니다.
		local handle = redKey:FindFirstChild("Handle")
		if handle then
			handle.CFrame = self.config.redKeySpawner.CFrame
		else
			warn("경고: RedKey Tool에 Handle 파트가 없습니다!")
		end
	elseif redKey:IsA("Model") and redKey.PrimaryPart then
		-- 모델인 경우 PrimaryPart의 위치를 지정합니다.
		redKey:SetPrimaryPartCFrame(self.config.redKeySpawner.CFrame)
	elseif redKey:IsA("BasePart") then
		-- 단일 파트인 경우 파트의 위치를 지정합니다.
		redKey.CFrame = self.config.redKeySpawner.CFrame
	end

	soundManager.PuzzleSolving()
	ReplicatedStorage.MissionFrame:FireAllClients("퍼즐을 성공하셨습니다. 빨간 키를 획득하여 빨간문을 열어주세요.")
	print("RedKey 소환 완료")
end

-------------------------------------------------
-- 이벤트 핸들러 함수들 (비공개)
-------------------------------------------------

function LeverPuzzleManager:_onRequestDrag(player, leverIndex)
	if not self.activePlayer[leverIndex] then
		self.activePlayer[leverIndex] = player
		self.config.leverConfigs[leverIndex].part.ActivePlayer.Value = player
		return true
	end
	return false
end

function LeverPuzzleManager:_onReleaseDrag(player, leverIndex)
	if self.activePlayer[leverIndex] == player then
		self.activePlayer[leverIndex] = nil
		self.config.leverConfigs[leverIndex].part.ActivePlayer.Value = nil
	end
end

function LeverPuzzleManager:_onUpdateLeverPosition(player, newY, leverIndex)
	local part = self.config.leverConfigs[leverIndex].part
	local pos = part.Position
	part.Position = Vector3.new(pos.X, newY, pos.Z)

	if self:_checkAllAnswersCorrect() then
		self:_spawnRedKey(player)
	end
end

function LeverPuzzleManager:_onPlayerRemoving(player)
	for i, active in pairs(self.activePlayer) do
		if active == player then
			self:_onReleaseDrag(player, i)
			break
		end
	end
end

return LeverPuzzleManager