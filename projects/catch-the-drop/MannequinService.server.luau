local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local AnalyticsService = game:GetService("AnalyticsService")

--------------------------------------------------------------------------------
-- Modules & Remotes
--------------------------------------------------------------------------------
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")

local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))

local RE_MannequinSkill = NetworkFolder:FindFirstChild("RE_MannequinSkill")
if not RE_MannequinSkill then
	local remote = Instance.new("RemoteEvent")
	remote.Name = "RE_MannequinSkill"
	remote.Parent = NetworkFolder
	RE_MannequinSkill = remote
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local CFG = (Constants.PVP and Constants.PVP.MANNEQUIN) or {}

local ENABLED = (CFG.ENABLED ~= false)
local SKILL_ID = tostring(CFG.SKILL_ID or "Mannequin")

local COOLDOWN_SEC = tonumber(CFG.COOLDOWN) or 18
local DURATION_SEC = tonumber(CFG.DURATION) or 5
local SERVER_MIN_INTERVAL = tonumber(CFG.SERVER_MIN_INTERVAL) or 0.1
local SPEED_MULTIPLIER = tonumber(CFG.SPEED_MULTIPLIER) or 1.3

local INVINCIBLE_ATTRIBUTE = tostring(CFG.INVINCIBLE_ATTRIBUTE or "IsMannequinInvincible")
local ACTIVE_ATTRIBUTE     = tostring(CFG.ACTIVE_ATTRIBUTE     or "IsMannequinActive")
local ENDTIME_ATTRIBUTE    = tostring(CFG.ENDTIME_ATTRIBUTE    or "MannequinEndTime")
local NEXT_CAST_ATTRIBUTE  = tostring(CFG.NEXT_CAST_ATTRIBUTE  or "MannequinSkill_NextCastTime")

local HIGHLIGHT_FILL_COLOR         = CFG.HIGHLIGHT_FILL_COLOR         or Color3.fromRGB(77, 135, 255)
local HIGHLIGHT_OUTLINE_COLOR      = CFG.HIGHLIGHT_OUTLINE_COLOR      or Color3.fromRGB(255, 255, 255)
local HIGHLIGHT_FILL_TRANSPARENCY  = tonumber(CFG.HIGHLIGHT_FILL_TRANSPARENCY)  or 0.35
local HIGHLIGHT_OUTLINE_TRANSPARENCY = tonumber(CFG.HIGHLIGHT_OUTLINE_TRANSPARENCY) or 0

local REFLECTANCE      = tonumber(CFG.REFLECTANCE)  or 0.05
local USE_FORCE_FIELD  = (CFG.USE_FORCE_FIELD == true)
local CAN_USE_IN_SAFEZONE = (CFG.CAN_USE_IN_SAFEZONE ~= false)

-- 레인보우 설정값은 클라이언트가 읽을 수 있도록 유지 (서버에서는 사용 안 함)
-- RAINBOW_ENABLED, RAINBOW_SPEED 등은 클라이언트(MannequinController)에서 처리

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local lastReqAtByUserId = {}
local activeStates = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function GetNow()
	return Workspace:GetServerTimeNow()
end

local function PassThrottle(player)
	local userId = player.UserId
	local now = os.clock()
	local lastReqAt = lastReqAtByUserId[userId] or 0
	if (now - lastReqAt) < SERVER_MIN_INTERVAL then
		return false
	end
	lastReqAtByUserId[userId] = now
	return true
end

local function GetCharacter(player)
	return player.Character
end

local function CanCast(player)
	local nextCastTime = player:GetAttribute(NEXT_CAST_ATTRIBUTE) or 0
	return os.clock() >= nextCastTime
end

local function SetCooldown(player)
	player:SetAttribute(NEXT_CAST_ATTRIBUTE, os.clock() + COOLDOWN_SEC)
end

local function IsToolDescendant(instance, character)
	if not instance or not character then return false end
	local current = instance
	while current and current ~= character do
		if current:IsA("Tool") then return true end
		current = current.Parent
	end
	return false
end

local function GetCharacterVisualParts(character)
	local parts = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			if descendant.Name ~= "HumanoidRootPart" and not IsToolDescendant(descendant, character) then
				table.insert(parts, descendant)
			end
		end
	end
	return parts
end

local function StorePartState(part)
	return {
		Color       = part.Color,
		Material    = part.Material,
		Reflectance = part.Reflectance,
	}
end

-- ✅ 수정: 레인보우 루프 제거 — 색 복원만 담당 (색 변경은 클라이언트가 처리)
local function RestoreCharacterVisual(state)
	if not state then return end

	if state.Highlight then
		state.Highlight:Destroy()
		state.Highlight = nil
	end

	if state.ForceField then
		state.ForceField:Destroy()
		state.ForceField = nil
	end

	if state.PartStates then
		for part, oldState in pairs(state.PartStates) do
			if part and part.Parent and oldState then
				part.Color       = oldState.Color
				part.Material    = oldState.Material
				part.Reflectance = oldState.Reflectance
			end
		end
	end

	state.PartStates  = nil
	state.VisualParts = nil
end

-- ✅ 수정: StartRainbowLoop 완전 제거 — 서버는 Highlight 생성 및 초기 상태만 설정
local function ApplyCharacterVisual(character, state)
	state.PartStates  = {}
	state.VisualParts = GetCharacterVisualParts(character)

	if USE_FORCE_FIELD then
		local forceField = Instance.new("ForceField")
		forceField.Name    = "MannequinForceField"
		forceField.Visible = false
		forceField.Parent  = character
		state.ForceField   = forceField
	end

	-- Highlight 1회 생성 후 복제 (이후 색 변경은 클라이언트가 로컬에서 처리)
	local highlight = Instance.new("Highlight")
	highlight.Name                = "MannequinHighlight"
	highlight.FillColor           = HIGHLIGHT_FILL_COLOR
	highlight.OutlineColor        = HIGHLIGHT_OUTLINE_COLOR
	highlight.FillTransparency    = HIGHLIGHT_FILL_TRANSPARENCY
	highlight.OutlineTransparency = HIGHLIGHT_OUTLINE_TRANSPARENCY
	highlight.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee             = character
	highlight.Parent              = character
	state.Highlight = highlight

	-- Material / Reflectance 1회 설정 (루프 없음)
	for _, part in ipairs(state.VisualParts) do
		state.PartStates[part] = StorePartState(part)
		part.Material    = Enum.Material.SmoothPlastic
		part.Reflectance = REFLECTANCE
	end

	-- ✅ StartRainbowLoop 호출 제거 → 클라이언트가 IsMannequinActive attribute 감지 후 처리
end

local function ClearConnections(state)
	if not state then return end
	if state.DiedConnection then
		state.DiedConnection:Disconnect()
		state.DiedConnection = nil
	end
	if state.CharacterRemovingConnection then
		state.CharacterRemovingConnection:Disconnect()
		state.CharacterRemovingConnection = nil
	end
end

local function EndMannequin(player, reason)
	local state = activeStates[player]
	if not state then return end

	activeStates[player] = nil
	ClearConnections(state)

	local character = state.Character
	local humanoid  = state.Humanoid

	if character and character.Parent then
		character:SetAttribute(INVINCIBLE_ATTRIBUTE, false)
		character:SetAttribute(ACTIVE_ATTRIBUTE, false)  -- 클라이언트 레인보우 루프도 여기서 중단됨
		character:SetAttribute(ENDTIME_ATTRIBUTE, 0)
	end

	-- ✅ 중앙 속도 계산기 호출
	if character then
		SkillUtil.UpdateWalkSpeed(character)
	end

	RestoreCharacterVisual(state)

	if player and player.Parent then
		RE_MannequinSkill:FireClient(player, "Ended", {
			Reason  = reason or "Unknown",
			SkillId = SKILL_ID,
		})
	end
end

local function IsValidCastState(player)
	local character = GetCharacter(player)
	local humanoid  = SkillUtil.GetHumanoid(character)
	local root      = SkillUtil.GetRoot(character)

	if not character or character ~= player.Character then
		return false, "NoCharacter"
	end
	if not humanoid or not SkillUtil.IsAlive(humanoid) then
		return false, "Dead"
	end
	if not root then
		return false, "NoRoot"
	end
	if SkillUtil.IsTargetAlreadyHit(character) then
		return false, "AlreadyHitState"
	end
	if activeStates[player] then
		return false, "AlreadyActive"
	end
	if (not CAN_USE_IN_SAFEZONE) and player:GetAttribute("InSafeZone") == true then
		return false, "SafeZoneBlocked"
	end
	if not CanCast(player) then
		return false, "Cooldown"
	end
	return true, "OK"
end

-- ✅ 수정: while 루프 폴링 → task.delay 단발 처리 (서버 부하 제거)
local function ScheduleExpire(player, expireAt)
	task.delay(DURATION_SEC, function()
		local state = activeStates[player]
		if not state then return end
		if state.ExpireAt ~= expireAt then return end
		EndMannequin(player, "DurationEnd")
	end)
end

local function ActivateMannequin(player)
	if not ENABLED then return end
	if not player or not player.Parent then return end
	if not PassThrottle(player) then return end

	local allowed, reason = IsValidCastState(player)
	if not allowed then
		RE_MannequinSkill:FireClient(player, "Rejected", {
			Reason  = reason,
			SkillId = SKILL_ID,
		})
		return
	end

	local character = GetCharacter(player)
	local humanoid  = SkillUtil.GetHumanoid(character)
	local root      = SkillUtil.GetRoot(character)

	if not character or not humanoid or not root then return end

	SetCooldown(player)
	
	-- 📊 [Analytics] PvP 스킬 사용 빈도 추적
	pcall(function()
		AnalyticsService:LogCustomEvent(player, "Skill_Used", 1)
		AnalyticsService:LogCustomEvent(player, "Skill_Used_Mannequin")
		--print(string.format("🧍 [Analytics] 스킬 사용: %s | 스킬명: Mannequin", player.Name))
	end)

	local expireAt = GetNow() + DURATION_SEC

	local state = {
		Player            = player,
		Character         = character,
		Humanoid          = humanoid,
		Root              = root,
		ExpireAt          = expireAt,
	}

	activeStates[player] = state

	character:SetAttribute(INVINCIBLE_ATTRIBUTE, true)
	character:SetAttribute(ACTIVE_ATTRIBUTE, true)
	character:SetAttribute(ENDTIME_ATTRIBUTE, expireAt)

	SkillUtil.UpdateWalkSpeed(character)

	ApplyCharacterVisual(character, state)

	state.DiedConnection = humanoid.Died:Connect(function()
		EndMannequin(player, "Died")
	end)

	state.CharacterRemovingConnection = player.CharacterRemoving:Connect(function(removingCharacter)
		if removingCharacter == character then
			EndMannequin(player, "CharacterRemoving")
		end
	end)

	RE_MannequinSkill:FireClient(player, "Activated", {
		SkillId  = SKILL_ID,
		Duration = DURATION_SEC,
		Cooldown = COOLDOWN_SEC,
		ExpireAt = expireAt,
	})

	ScheduleExpire(player, expireAt)
end

--------------------------------------------------------------------------------
-- Remote
--------------------------------------------------------------------------------
RE_MannequinSkill.OnServerEvent:Connect(function(player, action, clientSkillId)
	if action ~= "Activate" then return end
	if clientSkillId ~= nil and tostring(clientSkillId) ~= SKILL_ID then return end
	ActivateMannequin(player)
end)

--------------------------------------------------------------------------------
-- Init / Cleanup
--------------------------------------------------------------------------------
for _, player in ipairs(Players:GetPlayers()) do
	player:SetAttribute(NEXT_CAST_ATTRIBUTE, player:GetAttribute(NEXT_CAST_ATTRIBUTE) or 0)

	if player.Character then
		player.Character:SetAttribute(INVINCIBLE_ATTRIBUTE, false)
		player.Character:SetAttribute(ACTIVE_ATTRIBUTE, false)
		player.Character:SetAttribute(ENDTIME_ATTRIBUTE, 0)
	end

	player.CharacterAdded:Connect(function(character)
		character:SetAttribute(INVINCIBLE_ATTRIBUTE, false)
		character:SetAttribute(ACTIVE_ATTRIBUTE, false)
		character:SetAttribute(ENDTIME_ATTRIBUTE, 0)
	end)
end

Players.PlayerAdded:Connect(function(player)
	player:SetAttribute(NEXT_CAST_ATTRIBUTE, 0)

	player.CharacterAdded:Connect(function(character)
		character:SetAttribute(INVINCIBLE_ATTRIBUTE, false)
		character:SetAttribute(ACTIVE_ATTRIBUTE, false)
		character:SetAttribute(ENDTIME_ATTRIBUTE, 0)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	lastReqAtByUserId[player.UserId] = nil
	EndMannequin(player, "PlayerRemoving")
end)
