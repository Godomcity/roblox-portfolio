-- BalloonLiftController (Tool LocalScript)
-- 역할: 타겟팅 하이라이트 + 툴 발동 → 서버 이벤트 전송
-- 카메라 스웨이 / 스피드라인 FX는 BalloonLiftFxClient (StarterPlayerScripts) 에서 처리
local Tool = script.Parent
local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace      = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local RE_BalloonLift    = NetworkFolder:WaitForChild("RE_BalloonLift")
local RE_BalloonLiftFx  = NetworkFolder:WaitForChild("RE_BalloonLiftFx")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))

local CFG = (Constants.PVP and Constants.PVP.BALLOON_LIFT) or {}
local COOLDOWN_SEC   = tonumber(CFG.COOLDOWN)       or 5
local RANGE          = tonumber(CFG.RANGE)           or 25
local CONE_ANGLE_DEG = tonumber(CFG.CONE_ANGLE_DEG)  or 70
local MAX_Y_DIFF     = tonumber(CFG.MAX_Y_DIFF)       or 12

-- 풍선 비주얼 클라이언트 설정
local BALLOON_TEMPLATE_NAME     = tostring(CFG.BALLOON_TEMPLATE_NAME or "GalaxyBalloon")
local BALLOON_OFFSET            = CFG.BALLOON_OFFSET or CFrame.new(0, 0, 8)
local BACK_ATTACHMENT_NAME      = tostring(CFG.BACK_ATTACHMENT_NAME or "BodyBackAttachment")
local BACK_BALLOON_LOCAL_OFFSET = CFG.BACK_BALLOON_LOCAL_OFFSET or (CFrame.new(0, 0.15, 8) * CFrame.Angles(math.rad(90), 0, 0))
local BALLOON_VISUAL_UPDATE_INTERVAL = 1 / 30

local HIGHLIGHT_UPDATE_INTERVAL = 0.08
local nextUseAt      = 0
local lastHighlightAt = 0
local renderConnection = nil
local currentTarget    = nil

local localBalloonVisuals = {}

--------------------------------------------------------------------------------
-- WeaponHotbarController
--------------------------------------------------------------------------------
local WeaponHotbarController = nil
task.spawn(function()
	pcall(function()
		local ps = LocalPlayer:WaitForChild("PlayerScripts")
		local controllers = ps:WaitForChild("Controllers")
		WeaponHotbarController = require(controllers:WaitForChild("WeaponHotbarController"))
	end)
end)

--------------------------------------------------------------------------------
-- 풍선 비주얼 헬퍼
--------------------------------------------------------------------------------
local function GetBodyBackAttachment(character)
	local ut = character:FindFirstChild("UpperTorso")
	if ut then
		local att = ut:FindFirstChild(BACK_ATTACHMENT_NAME)
		if att then return att end
	end
	local t = character:FindFirstChild("Torso")
	if t then
		local att = t:FindFirstChild(BACK_ATTACHMENT_NAME)
		if att then return att end
	end
	return character:FindFirstChild(BACK_ATTACHMENT_NAME, true)
end

local function SetVisualWorldCFrame(visual, cf)
	if visual:IsA("Model") then visual:PivotTo(cf)
	elseif visual:IsA("BasePart") then visual.CFrame = cf end
end

local function GetBalloonWorldCFrame(character, victimRoot)
	local backAtt = GetBodyBackAttachment(character)
	local cf = backAtt and backAtt.WorldCFrame or (character:FindFirstChild("UpperTorso") or victimRoot).CFrame
	return cf * BACK_BALLOON_LOCAL_OFFSET * BALLOON_OFFSET
end

local function StartBalloonVisualLoop(victimPlayer, durationSec)
	local prev = localBalloonVisuals[victimPlayer]
	if prev then prev.loopRunning = false end

	local state = { loopRunning = true }
	localBalloonVisuals[victimPlayer] = state

	task.spawn(function()
		local elapsed = 0
		while state.loopRunning and elapsed < (durationSec + 1) do
			task.wait(BALLOON_VISUAL_UPDATE_INTERVAL)
			elapsed += BALLOON_VISUAL_UPDATE_INTERVAL
			if not state.loopRunning then break end

			local victimChar = victimPlayer.Character
			if not victimChar then break end
			local victimRoot = SkillUtil.GetRoot(victimChar)
			if not victimRoot then break end

			if victimChar:GetAttribute("IsBalloonLifted") ~= true then
				state.loopRunning = false; break
			end

			local visual = Workspace:FindFirstChild("BalloonLift_Visual_" .. victimChar.Name)
			if visual and visual.Parent then
				SetVisualWorldCFrame(visual, GetBalloonWorldCFrame(victimChar, victimRoot))
			end
		end
		if localBalloonVisuals[victimPlayer] == state then
			localBalloonVisuals[victimPlayer] = nil
		end
	end)
end

local function StopBalloonVisualLoop(victimPlayer)
	local state = localBalloonVisuals[victimPlayer]
	if state then
		state.loopRunning = false
		localBalloonVisuals[victimPlayer] = nil
	end
end

--------------------------------------------------------------------------------
-- 타겟팅 로직
--------------------------------------------------------------------------------
local function GetBestTarget(myChar, myRoot, fromPos)
	local bestTarget = nil
	local minDistance = math.huge

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= LocalPlayer and targetPlayer:GetAttribute("InSafeZone") ~= true then
			local targetChar = targetPlayer.Character
			local targetRoot = SkillUtil.GetRoot(targetChar)
			local targetHum  = SkillUtil.GetHumanoid(targetChar)

			if targetRoot and SkillUtil.IsAlive(targetHum) and not SkillUtil.IsTargetAlreadyHit(targetChar) then
				if SkillUtil.IsValidFrontTarget(myRoot, targetRoot, RANGE, CONE_ANGLE_DEG, MAX_Y_DIFF) then
					local toPos = targetRoot.Position + Vector3.new(0, 2, 0)
					if SkillUtil.HasLineOfSight(myChar, targetChar, fromPos, toPos) then
						local dist = (targetRoot.Position - myRoot.Position).Magnitude
						if dist < minDistance then
							minDistance = dist
							bestTarget = targetPlayer
						end
					end
				end
			end
		end
	end
	return bestTarget
end

local function UpdateHighlights()
	if not LocalPlayer.Character or Tool.Parent ~= LocalPlayer.Character then
		SkillUtil.ClearHighlight()
		currentTarget = nil
		return
	end

	local now = os.clock()
	if (now - lastHighlightAt) < HIGHLIGHT_UPDATE_INTERVAL then return end
	lastHighlightAt = now

	local myChar = LocalPlayer.Character
	local myRoot = SkillUtil.GetRoot(myChar)
	local myHum  = SkillUtil.GetHumanoid(myChar)

	if not myRoot or not SkillUtil.IsAlive(myHum) then
		SkillUtil.ClearHighlight()
		currentTarget = nil
		return
	end

	local fromPos = myRoot.Position + Vector3.new(0, 2, 0)
	currentTarget = GetBestTarget(myChar, myRoot, fromPos)

	if currentTarget then
		SkillUtil.UpdateHighlight(currentTarget.Character, Color3.fromRGB(255, 150, 200))
	else
		SkillUtil.ClearHighlight()
	end
end

--------------------------------------------------------------------------------
-- Tool Activated
--------------------------------------------------------------------------------
Tool.Activated:Connect(function()
	if os.clock() < nextUseAt then return end
	if not LocalPlayer.Character or Tool.Parent ~= LocalPlayer.Character then return end
	if SkillUtil.IsLocalCharacterStunned() then return end

	nextUseAt = os.clock() + COOLDOWN_SEC

	if WeaponHotbarController and WeaponHotbarController.StartCooldown then
		WeaponHotbarController:StartCooldown(Tool.Name, COOLDOWN_SEC)
	end

	RE_BalloonLift:FireServer(currentTarget)
end)

--------------------------------------------------------------------------------
-- 풍선 비주얼 루프 수신 (툴 장착 중인 클라이언트의 비주얼 위치 추적)
--------------------------------------------------------------------------------
RE_BalloonLiftFx.OnClientEvent:Connect(function(action, victimPlayer, durationSec)
	if action == "BalloonStart" then
		if typeof(victimPlayer) == "Instance" and victimPlayer:IsA("Player") then
			StartBalloonVisualLoop(victimPlayer, durationSec or 5)
		end
	elseif action == "BalloonEnd" then
		if typeof(victimPlayer) == "Instance" and victimPlayer:IsA("Player") then
			StopBalloonVisualLoop(victimPlayer)
		end
	end
end)

--------------------------------------------------------------------------------
-- Loop / Cleanup
--------------------------------------------------------------------------------
renderConnection = RunService.RenderStepped:Connect(UpdateHighlights)

Tool.Equipped:Connect(function()
	lastHighlightAt = 0
	UpdateHighlights()
end)

Tool.Unequipped:Connect(function()
	SkillUtil.ClearHighlight()
	currentTarget = nil
end)

Tool.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		if renderConnection then
			renderConnection:Disconnect()
			renderConnection = nil
		end
		SkillUtil.ClearHighlight()
		currentTarget = nil
	end
end)
