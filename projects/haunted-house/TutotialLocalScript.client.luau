local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local hrp = character:WaitForChild("HumanoidRootPart")

-- 이벤트
local tutorialEvent = ReplicatedStorage:WaitForChild("TutorialEvent")
local changeEvent = ReplicatedStorage:WaitForChild("ChangeValue")
local openDoorEvent = ReplicatedStorage:WaitForChild("OpenDoorEvent")
local arrowEvent = ReplicatedStorage:WaitForChild("ArrowEvent")
local nextDialogEvent = ReplicatedStorage:WaitForChild("nextDialogEvent")
local amyNextDialogEvent = ReplicatedStorage:WaitForChild("AmynextDialogEvent")
local proximityEnabled = ReplicatedStorage:WaitForChild("ProximityEnabled")
local tutotialInformation = ReplicatedStorage:WaitForChild("TutotialInformation")
local getKeyEvent = ReplicatedStorage:WaitForChild("GetKeyEvent")
local UpdateTimerEvent = ReplicatedStorage:WaitForChild("UpdateTimerEvent")
local DialogEvent = ReplicatedStorage:WaitForChild("DialogEvent")
local DialogAckEvent = ReplicatedStorage:WaitForChild("DialogAckEvent")

-- 모듈
local TutorialManager = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TutorialManager"))
local soundManager = require(ReplicatedStorage:WaitForChild("SoundManager"))

-- UI 요소
local frame = script.Parent
local npcImage = frame:WaitForChild("NPCImage")
local dialogText = frame:WaitForChild("DialogText")
local tutorialText = frame:WaitForChild("TutorialText")
local dialogFrame = frame:WaitForChild("DialogFrame")
local timeBackground = frame:WaitForChild("TimeBackGround")
local timerLabel = timeBackground:WaitForChild("TextLabel")

local countdownCoroutine
local StarterGui = game:GetService("StarterGui")
-- 목표 지점
local goal = workspace:WaitForChild("AmySpawn")
local purpleDoor = workspace:WaitForChild("PurpleDisplay")

local isArrow = false

local isamyArrow = false

-- 대사 효과 설정
local AUTO_DELAY = 2
local TYPING_SPEED = 0.04

local function typeText(text)
	dialogText.Text = ""
	for i = 1, #text do
		dialogText.Text = string.sub(text, 1, i)
		soundManager.UIClickSound()
		wait(TYPING_SPEED)
	end
end

local function playDialog(lines)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	npcImage.Visible = true
	dialogText.Visible = true
	dialogFrame.Visible = true

	for _, line in ipairs(lines) do
		typeText(line)
		wait(AUTO_DELAY)
	end

	npcImage.Visible = false
	dialogText.Visible = false
	dialogFrame.Visible = false

	--local doneFlag = player:FindFirstChild("DialogDone")
	--if doneFlag then
	--	doneFlag.Value = true
	--	changeEvent:FireServer(doneFlag)
	--end
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
	
	
	
end

DialogEvent.OnClientEvent:Connect(function(dialogId, npcImageId, lines)
	npcImage.Image = npcImageId
	playDialog(lines)
	DialogAckEvent:FireServer(dialogId)
end)

openDoorEvent.OnClientEvent:Connect(function(ProximityPrompt:ProximityPrompt)
	
	ProximityPrompt:Destroy()		
	local opendoorEffect = ReplicatedStorage:WaitForChild("Effect"):WaitForChild("OpenDoorEffect"):Clone()
	opendoorEffect.Parent = purpleDoor
	
	task.wait(2)
	
	TutorialManager.openDoor()
	purpleDoor:Destroy()
end)

local function StopAmyArrow()

	for i, part:Part in pairs(workspace.AmyArrows:GetChildren()) do

		part.Transparency = 1
	end

end

local function StartamyArrow()
	
	isamyArrow = true
	for i, amyarrow:Part in pairs(workspace.AmyArrows:GetChildren()) do

		amyarrow.Transparency = 0

		task.spawn(function()

			while isamyArrow do
				-- 플레이어와 목표 지점 사이의 거리 계산
				local distance = (hrp.Position - workspace:WaitForChild("AmySpawn").Position).Magnitude

				-- 거리가 10 미만이면 루프 중단 및 이벤트 실행 (요청하신 기능)
				if distance < 10 then
					--StopAmyArrow()
					amyNextDialogEvent:FireServer(player) -- 다음 다이얼로그 이벤트 실행
					isamyArrow = false
					break
				end

				task.wait(0.2) -- 0.2초마다 거리 체크
			end
		end)
	end
end

local function StopArrow()

	for i, part:Part in pairs(workspace.Arrows:GetChildren()) do

		part.Transparency = 1
	end

end

local function StartArrow()
	isArrow = true
	for i, part:Part in pairs(workspace.Arrows:GetChildren()) do
		
		part.Transparency = 0
		
		task.spawn(function()
			
			while isArrow do
				-- 플레이어와 목표 지점 사이의 거리 계산
				local distance = (hrp.Position - workspace:WaitForChild("A_TargetPosition").Position).Magnitude

				-- 거리가 10 미만이면 루프 중단 및 이벤트 실행 (요청하신 기능)
				if distance < 10 then
					StopArrow()
					nextDialogEvent:FireServer(player) -- 다음 다이얼로그 이벤트 실행
					isArrow = false
					break
				end

				task.wait(0.2) -- 0.2초마다 거리 체크
			end
		end)
	end
	
end

-- 4. 이벤트 연결
arrowEvent.OnClientEvent:Connect(function(shouldStart, npcName)
	-- 이벤트에서 true를 받으면 가이드 시작, false를 받으면 중지
	if npcName == "Amy" then
		
		if shouldStart then
			StartamyArrow()
		else
			StopAmyArrow()
		end
		
	else
		
		if shouldStart then
			StartArrow()
		else
			StopArrow()
		end
		
	end
	
end)


-- 튜토리얼 텍스트 업데이트
tutotialInformation.OnClientEvent:Connect(function(totalPlayer, clearCount, text)
	tutorialText.Text = text .. clearCount .. "/" .. totalPlayer
end)

-- ProximityPrompt 비활성화
proximityEnabled.OnClientEvent:Connect(function(proximity)
	proximity.Enabled = false
end)

getKeyEvent.OnClientEvent:Connect(function(clone, ProximityPrompt) 
	
	ProximityPrompt:Destroy()
	
	clone:Destroy()
	
end)

UpdateTimerEvent.OnClientEvent:Connect(function(action, duration)
	-- 기존에 실행되던 카운트다운이 있다면 중지
	if countdownCoroutine then
		coroutine.close(countdownCoroutine)
		countdownCoroutine = nil
	end

	if action == "Start" then
		-- 카운트다운 시작
		timeBackground.Visible = true

		-- 새로운 카운트다운 코루틴 생성 및 실행
		countdownCoroutine = coroutine.create(function()
			for i = duration, 0, -1 do
				timerLabel.Text = "남은 시간:" .. i .."초"
				task.wait(1)
			end
			timeBackground.Visible = false -- 시간이 다 되면 자동으로 숨김
		end)

		coroutine.resume(countdownCoroutine)

	elseif action == "Stop" then
		-- 카운트다운 즉시 중지 및 숨기기
		timeBackground.Visible = false
	end
end)