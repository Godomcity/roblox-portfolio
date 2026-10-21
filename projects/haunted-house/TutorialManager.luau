-- ReplicatedStorage/Modules/TutorialManager.lua
-- 서버/클라이언트 겸용 모듈 (대사 재생/ACK, 문 열기, 텔레포트 등)

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local isServer = RunService:IsServer()

-- (기존 이벤트: 필요 시 사용)
local _tutorialEvent = ReplicatedStorage:FindFirstChild("TutorialEvent")
local imageEvent = ReplicatedStorage:FindFirstChild("ImageEvent")

-- 신규 이벤트(핸드셰이크). 서버에서 없으면 생성, 클라는 기다림
local DialogEvent = ReplicatedStorage:FindFirstChild("DialogEvent")
if not DialogEvent then
	if isServer then
		DialogEvent = Instance.new("RemoteEvent")
		DialogEvent.Name = "DialogEvent"
		DialogEvent.Parent = ReplicatedStorage
	else
		DialogEvent = ReplicatedStorage:WaitForChild("DialogEvent")
	end
end

local DialogAckEvent = ReplicatedStorage:FindFirstChild("DialogAckEvent")
if not DialogAckEvent then
	if isServer then
		DialogAckEvent = Instance.new("RemoteEvent")
		DialogAckEvent.Name = "DialogAckEvent"
		DialogAckEvent.Parent = ReplicatedStorage
	else
		DialogAckEvent = ReplicatedStorage:WaitForChild("DialogAckEvent")
	end
end

local TutorialManager = {}

----------------------------------------------------------------
-- 유틸: 열쇠 보유 판정 (버그 수정: 인자 누락 방지)
----------------------------------------------------------------
function TutorialManager.playerHasKey(player)
	if not player then return false end
	local function hasKeyIn(container)
		return container and container:FindFirstChild("PurpleKey") ~= nil
	end
	return hasKeyIn(player.Backpack) or hasKeyIn(player.Character)
end

----------------------------------------------------------------
-- 대사: 단일 사용자 ACK 대기 (서버에서만 사용)
----------------------------------------------------------------
local function waitAckFrom(player, dialogId, timeoutSec)
	if not isServer then
		-- 클라에서 호출될 일 없음. 그냥 성공 처리.
		return true
	end
	timeoutSec = timeoutSec or 60

	local finished = false
	local done = Instance.new("BindableEvent")

	local ackConn
	ackConn = DialogAckEvent.OnServerEvent:Connect(function(from, ackId)
		if from == player and ackId == dialogId then
			finished = true
			if ackConn then ackConn:Disconnect() end
			done:Fire(true)
		end
	end)

	local removeConn
	removeConn = Players.PlayerRemoving:Connect(function(plr)
		if plr == player then
			if ackConn then ackConn:Disconnect() end
			if removeConn then removeConn:Disconnect() end
			done:Fire(false) -- 퇴장: 실패/스킵 간주
		end
	end)

	task.delay(timeoutSec, function()
		if finished then return end
		if ackConn then ackConn:Disconnect() end
		if removeConn then removeConn:Disconnect() end
		done:Fire(false) -- 타임아웃
	end)

	local ok = done.Event:Wait()
	done:Destroy()
	if removeConn then removeConn:Disconnect() end
	return ok
end

----------------------------------------------------------------
-- 대사: 플레이어 1명에게 보내고 완료 ACK 기다림
----------------------------------------------------------------
function TutorialManager.playDialog(player, imageId, lines, timeoutSec)
	if not isServer then
		-- 클라에서 잘못 호출되면 무시
		warn("[TutorialManager.playDialog] must be called on the server.")
		return false
	end
	local dialogId = HttpService:GenerateGUID(false)
	DialogEvent:FireClient(player, dialogId, imageId, lines)
	return waitAckFrom(player, dialogId, timeoutSec or 60)
end

----------------------------------------------------------------
-- 대사: 모든 인원(또는 지정 배열) 완료 시까지 기다림 (선택)
----------------------------------------------------------------
function TutorialManager.playDialogForAll(imageId, lines, timeoutSec, playersArray)
	if not isServer then
		warn("[TutorialManager.playDialogForAll] must be called on the server.")
		return false
	end

	local targets = playersArray or Players:GetPlayers()
	if #targets == 0 then return true end

	local dialogId = HttpService:GenerateGUID(false)
	local pending = {}
	for _, plr in ipairs(targets) do
		pending[plr.UserId] = true
		DialogEvent:FireClient(plr, dialogId, imageId, lines)
	end

	local done = Instance.new("BindableEvent")
	local function tryFinish()
		for _, remain in pairs(pending) do
			if remain then return end
		end
		done:Fire(true)
	end

	local ackConn, removeConn
	ackConn = DialogAckEvent.OnServerEvent:Connect(function(from, ackId)
		if ackId == dialogId and pending[from.UserId] then
			pending[from.UserId] = nil
			tryFinish()
		end
	end)

	removeConn = Players.PlayerRemoving:Connect(function(plr)
		if pending[plr.UserId] then
			-- 퇴장은 스킵 처리(정책)
			pending[plr.UserId] = nil
			tryFinish()
		end
	end)

	task.delay(timeoutSec or 60, function()
		for uid, _ in pairs(pending) do
			pending[uid] = nil
		end
		tryFinish()
	end)

	local ok = done.Event:Wait()
	if ackConn then ackConn:Disconnect() end
	if removeConn then removeConn:Disconnect() end
	done:Destroy()
	return ok
end

----------------------------------------------------------------
-- 문 열기(클라/서버 겸용, 클라에서 호출되어도 안전)
----------------------------------------------------------------
local doorModelName = "doortest" -- 기존 작성과 동일
local baseCFrame -- 최초 기준 CFrame 저장
local isOpen = false

local function ensureDoorAndBase()
	local model = workspace:FindFirstChild(doorModelName)
	if not model or not model.PrimaryPart then
		return nil
	end
	if not baseCFrame then
		baseCFrame = model.PrimaryPart.CFrame
	end
	return model
end

function TutorialManager.openDoor()
	local model = ensureDoorAndBase()
	if not model then
		warn("[TutorialManager.openDoor] workspace." .. doorModelName .. " (PrimaryPart 포함) 를 찾지 못했습니다.")
		return
	end

	local goalCFrame
	if isOpen then
		goalCFrame = baseCFrame
	else
		-- Y축 -90도 회전(경첩 방향에 맞춰 조정)
		goalCFrame = baseCFrame * CFrame.Angles(0, math.rad(-90), 0)
	end

	local tween = TweenService:Create(model.PrimaryPart, TweenInfo.new(0.5), { CFrame = goalCFrame })
	tween:Play()

	isOpen = not isOpen
end

----------------------------------------------------------------
-- (선택) 이펙트 트리거
----------------------------------------------------------------
function TutorialManager.playImageEffect(player)
	if imageEvent then
		imageEvent:FireClient(player)
	end
end

----------------------------------------------------------------
-- (선택) 파티 텔레포트
----------------------------------------------------------------
local targetPlaceId = 106404008139210
function TutorialManager.teleportAllPlayers()
	if not isServer then return end
	local allPlayers = Players:GetPlayers()
	if #allPlayers > 0 then
		TeleportService:TeleportPartyAsync(targetPlaceId, allPlayers)
	end
end

----------------------------------------------------------------
-- (더미) 하위호환: 기존 코드에 남아있는 호출 무시용
----------------------------------------------------------------
function TutorialManager.handleDialogDone()
	-- 이전 BoolValue/ChangeValue 방식은 제거됨.
	-- 하위호환을 위해 빈 함수로 남김.
end

return TutorialManager
