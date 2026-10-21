local TeleportService = game:GetService("TeleportService")
local zoneModule = require(game.ReplicatedStorage.Zone)

local zonePart = script.Parent
local zone = zoneModule.new(zonePart)
local belongingGameStartModel = zonePart.Parent

local enterSpawnPart = zonePart.Parent:WaitForChild("EnterSpawn")
local exitSpawnPart = zonePart.Parent:WaitForChild("ExitSpawn")

local surfaceGui = zonePart:WaitForChild("SurfaceGui")
local enterPlayerText = surfaceGui:WaitForChild("EnterPlayer")
local countDownText = surfaceGui:WaitForChild("CountDown")

local playerTable = {}
local entered = {}

local canCountDown = false
local countdownRunning = false
local countDown = 10

local exitEvent = game.ReplicatedStorage:WaitForChild("ExitEvent")
local toggleShiftLockUIEvent = game.ReplicatedStorage:WaitForChild("ToggleShiftLockUIEvent")
local forceCloseSelfieModeEvent = game.ReplicatedStorage:WaitForChild("ForceCloseSelfieModeEvent")

local soundManager = require(game.ReplicatedStorage.SoundManager)

local zominPart = zonePart.Parent:WaitForChild("ZomInCameraPos").CFrame
local camPos = zonePart.Parent:WaitForChild("CameraPos").CFrame

local isteleport = false

soundManager.PlayBGM()

local function updatePlayerCount()
	enterPlayerText.Text = #playerTable .. " / 4"

	if #playerTable == 0 then
		canCountDown = false
		countDown = 10
		countDownText.Text = tostring(countDown)
		countdownRunning = false
	end
end

-- 카운트다운 코루틴 (한 번만 실행됨)
local function StartCountdown()
	if countdownRunning then return end
	countdownRunning = true

	while canCountDown do
		wait(1)

		if #playerTable == 0 then
			countDown = 10
			countDownText.Text = tostring(countDown)
			countdownRunning = false
			break
		end

		-- 플레이어가 4명일 때 짧은 카운트다운
		if #playerTable >= 4 then
			countDown = math.min(countDown, 3)
		end

		countDown -= 1
		countDownText.Text = tostring(countDown)

		if countDown <= 0 then
			local destinationPlaceId = 75443815153614 -- 실제 플레이스 ID

			for i, player in ipairs(playerTable) do
				if player and player:IsDescendantOf(game.Players) then
					local accessCode = TeleportService:ReserveServer(destinationPlaceId)
					TeleportService:TeleportToPrivateServer(destinationPlaceId, accessCode, playerTable)
					isteleport = true
				end
			end

			playerTable = {}
			enterPlayerText.Text = "0 / 4"
			countDown = 10
			countDownText.Text = tostring(countDown)
			countdownRunning = false
			canCountDown = false
			break
		end
	end
end

zone.playerEntered:Connect(function(player)
	-- [추가된 코드] 4명 이상이면 더 이상 플레이어를 받지 않음
	if #playerTable >= 4 or isteleport then
		return
	end

	if entered[player] then return end
	entered[player] = true

	print(player.Name .. "이 처음으로 구역에 들어왔습니다!")
	forceCloseSelfieModeEvent:FireClient(player)
	-- 위치 이동 및 설정
	player.Character:SetPrimaryPartCFrame(enterSpawnPart.CFrame)
	game.ReplicatedStorage.Camevent:FireClient(player, true, zominPart, camPos, zonePart.Parent)

	toggleShiftLockUIEvent:FireClient(player, false)

	table.insert(playerTable, player)
	enterPlayerText.Text = #playerTable .. " / 4"

	canCountDown = true
	StartCountdown()
end)

exitEvent.OnServerEvent:Connect(function(player, targetGameStartModel)
	-- 클라이언트가 보낸 모델과 이 스크립트가 속한 모델이 일치할 때만 실행
	if targetGameStartModel == belongingGameStartModel then

		local index = table.find(playerTable, player)
		if index then
			table.remove(playerTable, index)
		end

		entered[player] = nil

		player.Character:SetPrimaryPartCFrame(exitSpawnPart.CFrame)
		game.ReplicatedStorage.Camevent:FireClient(player, false)
		player.PlayerGui.ExitGui.ExitButton.Visible = false

		toggleShiftLockUIEvent:FireClient(player, true)

		enterPlayerText.Text = #playerTable .. " / 4"

		-- 리셋 
		if #playerTable == 0 then
			canCountDown = false
			countDown = 10
			countDownText.Text = tostring(countDown)
			countdownRunning = false
		end
	end
end)

game.Players.PlayerRemoving:Connect(function(pl)
	local i = table.find(playerTable, pl)
	if i then
		table.remove(playerTable, i)
		updatePlayerCount()
	end
	entered[pl] = nil
	if #playerTable == 0 then
		isteleport = false
	end
end)