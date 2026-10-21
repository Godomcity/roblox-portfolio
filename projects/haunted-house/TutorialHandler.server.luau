-- Services
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")

-- Modules
local TutorialManager = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TutorialManager"))
local zoneModule = require(game.ReplicatedStorage.Zone)
local soundManager = require(game.ReplicatedStorage.SoundManager)

-- Events
local imageEvent = ReplicatedStorage:WaitForChild("ImageEvent")
local openDoorEvent = ReplicatedStorage:WaitForChild("OpenDoorEvent")
local arrowEvent = ReplicatedStorage:WaitForChild("ArrowEvent")
local nextDialogEvent = ReplicatedStorage:WaitForChild("nextDialogEvent")
local amyNextDialogEvent = ReplicatedStorage:WaitForChild("AmynextDialogEvent")
local proximityEnabled = ReplicatedStorage:WaitForChild("ProximityEnabled")
local tutotialInformation = ReplicatedStorage:WaitForChild("TutotialInformation")
local getKeyEvent = ReplicatedStorage:WaitForChild("GetKeyEvent")
local UpdateTimerEvent = ReplicatedStorage:WaitForChild("UpdateTimerEvent")
local tutorialEvent = ReplicatedStorage:WaitForChild("TutorialEvent")

-- Game Objects
local purpleKey = ReplicatedStorage:WaitForChild("PurpleKey")
local purpleDoor = workspace:WaitForChild("PurpleDisplay")
local amy = workspace:FindFirstChild("Amy")
local greenPig = workspace:FindFirstChild("GreenPig")
local aTarget = workspace:FindFirstChild("A_TargetPosition")
local amySpawn = workspace:FindFirstChild("AmySpawn")
local zonePart = workspace:WaitForChild("EnterPart")
local zone = zoneModule.new(zonePart)

-- Variables
local targetPlaceId = 75443815153614
local tutorialStarted = false
local playersReady = {}
local waitTime = 60

local STABLE_WINDOW = 2.0
local startEpoch = 0
local startTimer

local greenPigImageId = "rbxassetid://101709475337899"
local amyImageId = "rbxassetid://94554072826980"

local function countPresent(flagTable)
	local count = 0
	for _, pl in ipairs(Players:GetPlayers()) do
		if flagTable[pl] then
			count += 1
		end
	end
	return count, #Players:GetPlayers()
end

local function isAlive(plr)
	return typeof(plr) == "Instance" and plr.Parent == Players
end

local function pickAlive(pref)
	if isAlive(pref) then return pref end
	local list = Players:GetPlayers()
	return list[1]
end

-- 레거시 보강 대기 (지금은 사용 안 해도 무방)
local function waitDialogOrLeaveOrTimeout(player, dialogDone, timeoutSec)
	local done = false
	local c1, c2
	c1 = dialogDone:GetPropertyChangedSignal("Value"):Connect(function()
		if dialogDone.Value then done = true end
	end)
	c2 = Players.PlayerRemoving:Connect(function(p)
		if p == player then done = true end
	end)
	local t = task.delay(timeoutSec or 20, function() done = true end)

	repeat task.wait() until done
	if c1 then c1:Disconnect() end
	if c2 then c2:Disconnect() end
	pcall(task.cancel, t)
end

-- 최종 단계: 게임 시작 (텔레포트)
local function startFinalStep()
	local finalStepTriggered = false
	local connection
	local timer
	local remConn

	local function proceed()
		if finalStepTriggered then return end
		UpdateTimerEvent:FireAllClients("Stop")
		finalStepTriggered = true

		if connection then connection:Disconnect() end
		if remConn then remConn:Disconnect() end
		if timer then pcall(task.cancel, timer) end

		for _, playerInstance in pairs(Players:GetPlayers()) do
			local backpack = playerInstance:FindFirstChildOfClass("Backpack")
			local character = playerInstance.Character
			if character and character:FindFirstChild("PurpleKey") then
				character.PurpleKey:Destroy()
			end
			if backpack and backpack:FindFirstChild("PurpleKey") then
				backpack.PurpleKey:Destroy()
			end
		end
		imageEvent:FireAllClients()
	end

	local enteredPlayers = {}

	local function recheck()
		if finalStepTriggered then return end
		local count, total = countPresent(enteredPlayers)
		tutotialInformation:FireAllClients(total, count, "방에 들어온 인원")
		if count == total and total > 0 then
			proceed()
		end
	end

	connection = zone.playerEntered:Connect(function(player)
		if enteredPlayers[player] then return end
		enteredPlayers[player] = true
		recheck()
	end)

	remConn = Players.PlayerRemoving:Connect(function()
		task.defer(function() recheck() end)
	end)

	UpdateTimerEvent:FireAllClients("Start", waitTime)
	timer = task.delay(waitTime, proceed)
end

-- 6단계: 방으로 들어가기
local function startStepSix(player)
	local stepSixTriggered = false
	local connection
	local timer
	local remConn
	local doorOpenedPlayers = {}

	local function proceed(p)
		if stepSixTriggered then return end
		UpdateTimerEvent:FireAllClients("Stop")
		stepSixTriggered = true
		if connection then connection:Disconnect() end
		if remConn then remConn:Disconnect() end
		if timer then pcall(task.cancel, timer) end

		for _, playerInstance in pairs(Players:GetPlayers()) do
			if not doorOpenedPlayers[playerInstance] and TutorialManager.playerHasKey(playerInstance) then
				if playerInstance.Character and playerInstance.Character:FindFirstChild("PurpleKey") then
					playerInstance.Character.PurpleKey:Destroy()
				elseif playerInstance.Backpack and playerInstance.Backpack:FindFirstChild("PurpleKey") then
					playerInstance.Backpack.PurpleKey:Destroy()
				end
				openDoorEvent:FireClient(playerInstance, purpleDoor.ProximityPrompt)
			end
		end

		purpleDoor.ProximityPrompt.Enabled = false
		local currentPlayers = #Players:GetPlayers()
		tutotialInformation:FireAllClients(currentPlayers, currentPlayers, "2층 문 열기")
		task.wait(0.1)
		tutotialInformation:FireAllClients(currentPlayers, 0, "방에 들어가기")

		-- 🔁 전체 인원 대상 대사
		TutorialManager.playDialogForAll(greenPigImageId, {
			"잘했어!",
			"자물쇠는 같은 색을 가진 열쇠로만 열 수 있다는 거 명심해!",
			"방에 들어가면 게임을 시작할 수 있어 화이팅!"
		})

		TutorialManager.openDoor()
		purpleDoor:Destroy()
		workspace:WaitForChild("EnterCoilider").CanCollide = false
		startFinalStep()
	end

	local function recheck(pOpt)
		if stepSixTriggered then return end
		local count, total = countPresent(doorOpenedPlayers)
		tutotialInformation:FireAllClients(total, count, "2층 문 열기")
		if count == total and total > 0 then
			proceed(pOpt or Players:GetPlayers()[1])
		end
	end

	purpleDoor.ProximityPrompt.Enabled = true
	connection = purpleDoor.ProximityPrompt.Triggered:Connect(function(p)
		if not TutorialManager.playerHasKey(p) then
			soundManager.InteractionSound()
			return
		end
		if doorOpenedPlayers[p] then return end
		doorOpenedPlayers[p] = true
		soundManager.UseKey()
		openDoorEvent:FireClient(p, purpleDoor.ProximityPrompt)
		if p.Character and p.Character:FindFirstChild("PurpleKey") then
			p.Character.PurpleKey:Destroy()
		elseif p.Backpack and p.Backpack:FindFirstChild("PurpleKey") then
			p.Backpack.PurpleKey:Destroy()
		end
		recheck(p)
	end)

	remConn = Players.PlayerRemoving:Connect(function()
		task.defer(function() recheck() end)
	end)

	UpdateTimerEvent:FireAllClients("Start", waitTime)
	timer = task.delay(waitTime, function()
		if #Players:GetPlayers() == 0 then return end
		proceed(player)
	end)
end

-- 5단계: 으뜸이에게 도착 후 문 열기
local function startStepFive(player)
	local stepFiveTriggered = false
	local connection
	local timer
	local remConn
	local triggeredPlayers = {}

	local function proceed(p)
		if stepFiveTriggered then return end
		UpdateTimerEvent:FireAllClients("Stop")
		stepFiveTriggered = true
		if connection then connection:Disconnect() end
		if remConn then remConn:Disconnect() end
		if timer then pcall(task.cancel, timer) end

		tutotialInformation:FireAllClients(#Players:GetPlayers(), 0, "2층 문 열기")
		arrowEvent:FireAllClients(false, greenPig.Name)

		-- 🔁 전체 인원 대상 대사
		TutorialManager.playDialogForAll(greenPigImageId, {
			"열쇠랑 같은 색깔의 자물쇠를 열 수 있어",
			"보라색 자물쇠가 달린 문을 열어봐"
		})

		startStepSix(p)
	end

	local function recheck(pOpt)
		if stepFiveTriggered then return end
		local count, total = countPresent(triggeredPlayers)
		tutotialInformation:FireAllClients(total, count, "으뜸이 찾아가기")
		if count == total and total > 0 then
			proceed(pOpt or Players:GetPlayers()[1])
		end
	end

	connection = nextDialogEvent.OnServerEvent:Connect(function(p)
		if triggeredPlayers[p] then return end
		triggeredPlayers[p] = true
		recheck(p)
	end)

	remConn = Players.PlayerRemoving:Connect(function()
		task.defer(function() recheck() end)
	end)

	UpdateTimerEvent:FireAllClients("Start", waitTime)
	timer = task.delay(waitTime, function()
		if #Players:GetPlayers() == 0 then return end
		proceed(player)
	end)
end

-- 4단계: 열쇠 획득 후 으뜸이 찾아가기
local function startStepFour(player)
	local stepFourTriggered = false
	local connection
	local timer
	local remConn
	local purpleKeyClone = purpleKey:Clone()
	purpleKeyClone.Parent = workspace
	local keyGiven = {}

	local function proceed(p)
		if stepFourTriggered then return end
		UpdateTimerEvent:FireAllClients("Stop")
		stepFourTriggered = true
		if connection then connection:Disconnect() end
		if remConn then remConn:Disconnect() end
		if timer then pcall(task.cancel, timer) end

		for _, playerInstance in pairs(Players:GetPlayers()) do
			if not keyGiven[playerInstance] then
				local tool = game.ServerScriptService:WaitForChild("PurpleKey"):Clone()
				tool.Parent = playerInstance.Backpack
			end
		end
		if purpleKeyClone and purpleKeyClone.Parent then purpleKeyClone:Destroy() end

		-- 🔁 전체 인원 대상 대사
		TutorialManager.playDialogForAll(amyImageId, {
			"잘했어!",
			"이제 으뜸이를 찾아가봐",
			"화살표 방향을 따라가면 돼!"
		})

		arrowEvent:FireAllClients(true, greenPig.Name)

		local currentPlayers = #Players:GetPlayers()
		tutotialInformation:FireAllClients(currentPlayers, currentPlayers, "열쇠를 지급 받은 인원")
		task.wait(0.1)
		tutotialInformation:FireAllClients(currentPlayers, 0, "으뜸이 찾아가기")
		startStepFive(p)
	end

	local function recheck(pOpt)
		if stepFourTriggered then return end
		local count, total = countPresent(keyGiven)
		tutotialInformation:FireAllClients(total, count, "열쇠를 지급 받은 인원")
		if count == total and total > 0 then
			proceed(pOpt or Players:GetPlayers()[1])
		end
	end

	connection = purpleKeyClone.ProximityPrompt.Triggered:Connect(function(keyP)
		if keyGiven[keyP] then return end
		keyGiven[keyP] = true
		getKeyEvent:FireClient(keyP, purpleKeyClone, purpleKeyClone.ProximityPrompt)
		soundManager.InteractionSound()
		soundManager.GetKeySound()
		local tool = game.ServerScriptService:WaitForChild("PurpleKey"):Clone()
		tool.Parent = keyP.Backpack
		recheck(keyP)
	end)

	remConn = Players.PlayerRemoving:Connect(function()
		task.defer(function() recheck() end)
	end)

	UpdateTimerEvent:FireAllClients("Start", waitTime)
	timer = task.delay(waitTime, function()
		if #Players:GetPlayers() == 0 then return end
		proceed(player)
	end)
end

-- 3단계: 에이미에게 도착 후 열쇠 획득하기
local function startStepThree(player)
	local stepThreeTriggered = false
	local connection
	local timer
	local remConn

	local function proceed(p)
		if stepThreeTriggered then return end
		UpdateTimerEvent:FireAllClients("Stop")
		stepThreeTriggered = true
		if connection then connection:Disconnect() end
		if remConn then remConn:Disconnect() end
		if timer then pcall(task.cancel, timer) end

		tutotialInformation:FireAllClients(#Players:GetPlayers(), 0, "보라색 열쇠 획득하기")
		arrowEvent:FireAllClients(false, amy.Name)
		task.wait(1)
		amy.HumanoidRootPart.Anchored = true

		-- 🔁 전체 인원 대상 대사
		TutorialManager.playDialogForAll(amyImageId, {
			"E키를 눌러서 열쇠를 획득할 수 있어",
			"내 앞에 있는 보라색 열쇠를 주워봐"
		})

		startStepFour(p)
	end

	local triggeredPlayers = {}

	local function recheck(pOpt)
		if stepThreeTriggered then return end
		local count, total = countPresent(triggeredPlayers)
		tutotialInformation:FireAllClients(total, count, "에이미 찾아가기")
		if count == total and total > 0 then
			proceed(pOpt or Players:GetPlayers()[1])
		end
	end

	connection = amyNextDialogEvent.OnServerEvent:Connect(function(p)
		if triggeredPlayers[p] then return end
		triggeredPlayers[p] = true
		recheck(p)
	end)

	remConn = Players.PlayerRemoving:Connect(function()
		task.defer(function() recheck() end)
	end)

	UpdateTimerEvent:FireAllClients("Start", waitTime)
	timer = task.delay(waitTime, function()
		if #Players:GetPlayers() == 0 then return end
		proceed(player)
	end)
end

-- 2단계: 에이미 따라가기
local function startStepTwo(player)
	local stepTwoTriggered = false
	local connection
	local timer
	local remConn

	local function proceed(p)
		if stepTwoTriggered then return end
		UpdateTimerEvent:FireAllClients("Stop")
		stepTwoTriggered = true
		if connection then connection:Disconnect() end
		if remConn then remConn:Disconnect() end
		if timer then pcall(task.cancel, timer) end

		amy:WaitForChild("Pink Pearly TiaraAccessory").Handle.ProximityPrompt.Enabled = false

		-- 🔁 전체 인원 대상 대사
		TutorialManager.playDialogForAll(amyImageId, {
			"우리 집 어때?",
			"이제 열쇠 획득 방법을 알려줄게 나를 따라와"
		})

		amy:SetPrimaryPartCFrame(amySpawn.CFrame)
		greenPig:SetPrimaryPartCFrame(aTarget.CFrame)
		arrowEvent:FireAllClients(true, amy.Name)
		tutotialInformation:FireAllClients(#Players:GetPlayers(), 0, "에이미 찾아가기")
		startStepThree(p)
	end

	local triggeredPlayers = {}

	local function recheck(pOpt)
		if stepTwoTriggered then return end
		local count, total = countPresent(triggeredPlayers)
		tutotialInformation:FireAllClients(total, count, "집 구경후 에이미에게 말 걸기")
		if count == total and total > 0 then
			proceed(pOpt or Players:GetPlayers()[1])
		end
	end

	amy:WaitForChild("Pink Pearly TiaraAccessory").Handle.ProximityPrompt.Enabled = true
	connection = amy:WaitForChild("Pink Pearly TiaraAccessory").Handle.ProximityPrompt.Triggered:Connect(function(p)
		if triggeredPlayers[p] then return end
		triggeredPlayers[p] = true
		soundManager.InteractionSound()
		proximityEnabled:FireClient(p, amy:WaitForChild("Pink Pearly TiaraAccessory").Handle.ProximityPrompt)
		recheck(p)
	end)

	remConn = Players.PlayerRemoving:Connect(function()
		task.defer(function() recheck() end)
	end)

	UpdateTimerEvent:FireAllClients("Start", waitTime)
	timer = task.delay(waitTime, function()
		if #Players:GetPlayers() == 0 then return end
		proceed(player)
	end)
end

-- 1단계 (시작): 집 구경 후 에이미에게 말 걸기
function startTutorial(player)
	if tutorialStarted then return end
	if #Players:GetPlayers() == 0 then return end
	tutorialStarted = true

	local remConn
	local function cleanup()
		if remConn then remConn:Disconnect(); remConn = nil end
	end

	local function pickLead()
		local list = Players:GetPlayers()
		if #list == 0 then return nil end
		if player and table.find(list, player) then return player end
		return list[1]
	end

	-- ✅ 전원 대상 안전 대사 재생
	local function safePlayDialogForAll(imageId, lines)
		if #Players:GetPlayers() == 0 then return false end
		TutorialManager.playDialogForAll(imageId, lines, 60)
		return true
	end

	local function refreshUI()
		local total = #Players:GetPlayers()
		if total == 0 then
			tutorialStarted = false
			cleanup()
			return false
		end
		tutotialInformation:FireAllClients(total, 0, "집 구경 후 에이미에게 말 걸기")
		return true
	end

	if not refreshUI() then return end

	remConn = Players.PlayerRemoving:Connect(function()
		task.defer(function()
			if #Players:GetPlayers() == 0 then
				tutorialStarted = false
				cleanup()
			end
		end)
	end)

	task.spawn(function()
		-- 🔁 환영 대사 (전원)
		if not safePlayDialogForAll("rbxassetid://87253007316755", {
			"안녕 우린 에이미, 으뜸이야!", "우리집에 놀러온 걸 환영해~!"
			}) then return end

		-- 🔁 에이미 대사 (전원)
		if not safePlayDialogForAll(amyImageId, {
			"집 구경을 한 뒤 나에게 말을 걸어줘"
			}) then return end

		local leadNow = pickLead()
		if leadNow then
			task.defer(function()
				startStepTwo(leadNow)
			end)
		else
			tutorialStarted = false
			cleanup()
		end
	end)
end

local function scheduleTutorialStart()
	if tutorialStarted then return end
	startEpoch += 1
	local myEpoch = startEpoch
	if startTimer then pcall(task.cancel, startTimer) end
	startTimer = task.delay(2, function()
		if myEpoch ~= startEpoch then return end
		local list = Players:GetPlayers()
		if #list == 0 then return end
		startTutorial(list[1])
	end)
end

local function onPlayerReady(player)
	if not table.find(playersReady, player) then
		table.insert(playersReady, player)
	end
	if #playersReady == #Players:GetPlayers() and not tutorialStarted then
		startTutorial(Players:GetPlayers()[1])
	end
end

Players.PlayerAdded:Connect(scheduleTutorialStart)
Players.PlayerRemoving:Connect(scheduleTutorialStart)

for _, player in ipairs(Players:GetPlayers()) do
	onPlayerReady(player)
end

imageEvent.OnServerEvent:Connect(function()
	local allPlayers = Players:GetPlayers()
	if #allPlayers > 0 then
		local accessCode = TeleportService:ReserveServer(targetPlaceId)
		TeleportService:TeleportToPrivateServer(targetPlaceId, accessCode, allPlayers)
	end
end)

--TutorialManager.handleDialogDone()