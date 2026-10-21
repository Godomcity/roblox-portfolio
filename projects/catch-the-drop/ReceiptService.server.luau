local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local AnalyticsService = game:GetService("AnalyticsService")

--------------------------------------------------------------------------------
-- Modules & Remotes
--------------------------------------------------------------------------------
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local EffectFolder = ReplicatedStorage:WaitForChild("Templates"):WaitForChild("Effect")

local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))
local LootDropService = require(ServerScriptService.Services:WaitForChild("LootDropService"))

local RE_ReceiptSkill = NetworkFolder:WaitForChild("RE_ReceiptSkill")

-- 클라이언트 화면 이펙트용 Remote (없으면 자동 생성)
local RE_ReceiptClientEffect = NetworkFolder:FindFirstChild("RE_ReceiptClientEffect")
if not RE_ReceiptClientEffect then
	RE_ReceiptClientEffect = Instance.new("RemoteEvent")
	RE_ReceiptClientEffect.Name = "RE_ReceiptClientEffect"
	RE_ReceiptClientEffect.Parent = NetworkFolder
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local CFG = (Constants.PVP and Constants.PVP.RECEIPT) or {}

local ENABLED = (CFG.ENABLED ~= false)
local COOLDOWN_SEC = tonumber(CFG.COOLDOWN) or 0.2
local SERVER_MIN_INTERVAL = tonumber(CFG.SERVER_MIN_INTERVAL) or 0.10

local DETECT_RANGE = tonumber(CFG.RAYCAST_RANGE) or tonumber(CFG.RANGE) or 14
local MAX_Y_DIFF = tonumber(CFG.MAX_Y_DIFF) or 20

local HITBOX_WIDTH = tonumber(CFG.HITBOX_WIDTH) or 5
local HITBOX_HEIGHT = tonumber(CFG.HITBOX_HEIGHT) or 5

local HIT_IMMUNITY = tonumber(CFG.HIT_IMMUNITY) or 0.8
local EFFECT_LIFETIME = tonumber(CFG.EFFECT_LIFETIME) or 5

-- 5초 슬로우 (0.2x)
local SLOW_DURATION = tonumber(CFG.SLOW_DURATION) or 5.0
local SLOW_MULTIPLIER = tonumber(CFG.SLOW_MULTIPLIER) or 0.2

local EFFECT_TEMPLATE_NAME = tostring(CFG.EFFECT_TEMPLATE_NAME or "HitReceiptEffect")
local SKILL_ID = tostring(CFG.SKILL_ID or "ReceiptBeam")
local ALLOW_NON_PLAYER_TARGETS = (CFG.ALLOW_NON_PLAYER_TARGETS == true)

-- 서버 빔 연출
local SERVER_BEAM_VISUAL_RANGE = tonumber(CFG.BEAM_VISUAL_RANGE) or 10
local BEAM_HOLD_TIME = tonumber(CFG.BEAM_HOLD_TIME) or 0.2
local START_MOVE_TIME = tonumber(CFG.START_MOVE_TIME) or 0.12
local BEAM_SPREAD_ANGLE = tonumber(CFG.BEAM_SPREAD_ANGLE) or 18
local MAX_TARGETS_PER_CAST = tonumber(CFG.MAX_TARGETS_PER_CAST) or 3

local RUNTIME_ATTACHMENT_CFRAME = CFG.RUNTIME_ATTACHMENT_CFRAME
	or (CFrame.new(1.53, 1.1, -3.27) * CFrame.Angles(0, 0, math.rad(-90)))

-- 클라이언트 이펙트 지속 시간 (서버의 SLOW_DURATION과 동기화)
local CLIENT_EFFECT_DURATION = SLOW_DURATION

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local lastReqAtByUserId = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
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

local function GetEquippedTool(player)
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChildOfClass("Tool")
end

local function CanCast(player)
	local nextCastTime = player:GetAttribute("ReceiptSkill_NextCastTime") or 0
	return os.clock() >= nextCastTime
end

local function SetCooldown(player)
	player:SetAttribute("ReceiptSkill_NextCastTime", os.clock() + COOLDOWN_SEC)
end

local function FindEffectTemplate()
	local template = EffectFolder:FindFirstChild(EFFECT_TEMPLATE_NAME)
	if not template then
		warn("[ReceiptService] Templates/Effect 안에 이펙트 템플릿이 없습니다:", EFFECT_TEMPLATE_NAME)
		return nil
	end

	return template
end

--------------------------------------------------------------------------------
-- Tool 원본 Beam 강제 비활성
--------------------------------------------------------------------------------
local function DisableToolTemplateBeam(tool)
	if not tool or not tool:IsA("Tool") then
		return
	end

	local handle = tool:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		return
	end

	local attachment = handle:FindFirstChild("Attachment1")
	if not attachment or not attachment:IsA("Attachment") then
		return
	end

	local beam = attachment:FindFirstChild("Beam0")
	if not beam or not beam:IsA("Beam") then
		return
	end

	beam.Enabled = false
	beam.Attachment0 = nil
	beam.Attachment1 = nil
end

local function BindCharacterBeamCleanup(character)
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") then
			DisableToolTemplateBeam(child)
		end
	end

	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			DisableToolTemplateBeam(child)
		end
	end)
end

--------------------------------------------------------------------------------
-- 서버 빔 연출
--------------------------------------------------------------------------------
local function GetFlatForward(rootPart)
	local look = rootPart.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)

	if flat.Magnitude <= 0.001 then
		return Vector3.new(0, 0, -1)
	end

	return flat.Unit
end

local function PlayServerBeamVisual(attackerCharacter, equippedTool)
	local attackerRoot = SkillUtil.GetRoot(attackerCharacter)
	if not attackerRoot then
		return
	end

	local handle = SkillUtil.GetToolHandle(equippedTool)
	if not handle then
		return
	end

	local attachment1 = handle:FindFirstChild("Attachment1")
	if not attachment1 or not attachment1:IsA("Attachment") then
		return
	end

	local beamTemplate = attachment1:FindFirstChild("Beam0")
	if not beamTemplate or not beamTemplate:IsA("Beam") then
		return
	end

	beamTemplate.Enabled = false
	beamTemplate.Attachment0 = nil
	beamTemplate.Attachment1 = nil

	local previewAttachment = Instance.new("Attachment")
	previewAttachment.Name = "ReceiptServerBeamPreview"
	previewAttachment.CFrame = RUNTIME_ATTACHMENT_CFRAME
	previewAttachment.Parent = attackerRoot

	local startWorldPosition = previewAttachment.WorldPosition
	previewAttachment:Destroy()

	local flatForward = GetFlatForward(attackerRoot)
	local upVector = Vector3.yAxis
	local spreadAngle = math.rad(BEAM_SPREAD_ANGLE)
	local angleOffsets = {0, -spreadAngle, spreadAngle}

	for _, angleOffset in ipairs(angleOffsets) do
		local rotatedForward = CFrame.fromAxisAngle(upVector, angleOffset):VectorToWorldSpace(flatForward)
		if rotatedForward.Magnitude > 0.001 then
			rotatedForward = rotatedForward.Unit
		else
			rotatedForward = flatForward
		end

		local endWorldPosition = startWorldPosition + (rotatedForward * SERVER_BEAM_VISUAL_RANGE)
		local endLocalPosition = attackerRoot.CFrame:PointToObjectSpace(endWorldPosition)

		local startAttachment = Instance.new("Attachment")
		startAttachment.Name = "ReceiptServerBeamStart"
		startAttachment.CFrame = RUNTIME_ATTACHMENT_CFRAME
		startAttachment.Parent = attackerRoot

		local endAttachment = Instance.new("Attachment")
		endAttachment.Name = "ReceiptServerBeamEnd"
		endAttachment.CFrame = RUNTIME_ATTACHMENT_CFRAME
		endAttachment.Parent = attackerRoot

		endAttachment.Position = endLocalPosition

		local beam = beamTemplate:Clone()
		beam.Name = "ReceiptServerBeam"
		beam.Enabled = false
		beam.Attachment0 = startAttachment
		beam.Attachment1 = endAttachment
		beam.Parent = attackerRoot

		beam.TextureSpeed = -5
		beam.Enabled = true

		task.delay(BEAM_HOLD_TIME, function()
			if not beam.Parent or not startAttachment.Parent then
				return
			end

			local tween = TweenService:Create(
				startAttachment,
				TweenInfo.new(START_MOVE_TIME, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
				{ Position = endLocalPosition }
			)
			tween:Play()
		end)

		local cleanupDelay = BEAM_HOLD_TIME + START_MOVE_TIME + 0.05
		Debris:AddItem(beam, cleanupDelay)
		Debris:AddItem(startAttachment, cleanupDelay)
		Debris:AddItem(endAttachment, cleanupDelay)
	end
end

--------------------------------------------------------------------------------
-- Effect (Attachment 기반)
--------------------------------------------------------------------------------
local function AttachHitReceiptEffect(targetCharacter)
	local targetRoot = SkillUtil.GetRoot(targetCharacter)
	if not targetRoot then
		return
	end

	local oldEffect = targetRoot:FindFirstChild("HitReceiptEffect_Runtime")
	if oldEffect then
		oldEffect:Destroy()
	end

	local template = FindEffectTemplate()
	if not template then
		return
	end

	if not template:IsA("Attachment") then
		warn("[ReceiptService] HitReceiptEffect 템플릿은 Attachment 여야 합니다.")
		return
	end

	local effect = template:Clone()
	effect.Name = "HitReceiptEffect_Runtime"
	effect.Parent = targetRoot

	for _, descendant in ipairs(effect:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			local emitCount = descendant:GetAttribute("EmitCount")
			if typeof(emitCount) == "number" and emitCount > 0 then
				descendant:Emit(emitCount)
			end
		end
	end

	Debris:AddItem(effect, EFFECT_LIFETIME)
end

--------------------------------------------------------------------------------
-- Slow
--------------------------------------------------------------------------------
local function ApplyReceiptSlow(targetCharacter)
	local humanoid = SkillUtil.GetHumanoid(targetCharacter)
	if not SkillUtil.IsAlive(humanoid) then
		return
	end

	local effectsFolder = targetCharacter:FindFirstChild("PvpEffects")
	if not effectsFolder then
		local newFolder = Instance.new("Folder")
		newFolder.Name = "PvpEffects"
		newFolder.Parent = targetCharacter
		effectsFolder = newFolder
	end

	local tokenValue = effectsFolder:FindFirstChild("ReceiptSlow_Token")
	if not tokenValue then
		local newToken = Instance.new("IntValue")
		newToken.Name = "ReceiptSlow_Token"
		newToken.Parent = effectsFolder
		tokenValue = newToken
	end

	tokenValue.Value += 1
	local myToken = tokenValue.Value

	SkillUtil.UpdateWalkSpeed(targetCharacter)

	task.delay(SLOW_DURATION, function()
		if not targetCharacter or not targetCharacter.Parent then
			return
		end

		local currentEffects = targetCharacter:FindFirstChild("PvpEffects")
		if not currentEffects then
			return
		end

		local currentToken = currentEffects:FindFirstChild("ReceiptSlow_Token")
		if not currentToken or currentToken.Value ~= myToken then
			return
		end

		currentToken:Destroy()

		if #currentEffects:GetChildren() == 0 then
			currentEffects:Destroy()
		end

		SkillUtil.UpdateWalkSpeed(targetCharacter)
	end)
end

--------------------------------------------------------------------------------
-- Immunity
--------------------------------------------------------------------------------
local function ApplyHitImmunity(targetCharacter)
	if not targetCharacter then
		return
	end

	local immunityEndTime = Workspace:GetServerTimeNow() + HIT_IMMUNITY
	targetCharacter:SetAttribute("CCImmunityEndTime", immunityEndTime)
end

--------------------------------------------------------------------------------
-- Hit Apply
--------------------------------------------------------------------------------
local function ApplyReceiptHit(attackerPlayer, targetCharacter)
	if not targetCharacter then
		return
	end

	local targetHumanoid = SkillUtil.GetHumanoid(targetCharacter)
	if not SkillUtil.IsAlive(targetHumanoid) then
		return
	end

	ApplyHitImmunity(targetCharacter)
	AttachHitReceiptEffect(targetCharacter)
	ApplyReceiptSlow(targetCharacter)

	-- 피격 플레이어에게 클라이언트 화면 이펙트 전송
	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	if targetPlayer then
		RE_ReceiptClientEffect:FireClient(targetPlayer, CLIENT_EFFECT_DURATION)
		LootDropService:DropCarriedItem(targetPlayer, attackerPlayer)
	end
end

--------------------------------------------------------------------------------
-- Core
--------------------------------------------------------------------------------
RE_ReceiptSkill.OnServerEvent:Connect(function(player, clientSkillId)
	if not ENABLED then
		return
	end

	if not player or not player.Parent then
		return
	end

	if player:GetAttribute("InSafeZone") == true then
		return
	end

	if clientSkillId ~= nil and tostring(clientSkillId) ~= SKILL_ID then
		return
	end

	if not PassThrottle(player) then
		return
	end

	local equippedTool = GetEquippedTool(player)
	if not equippedTool then
		return
	end

	DisableToolTemplateBeam(equippedTool)

	local attackerCharacter = player.Character
	local attackerHumanoid = SkillUtil.GetHumanoid(attackerCharacter)
	local attackerRoot = SkillUtil.GetRoot(attackerCharacter)

	if not attackerRoot or not SkillUtil.IsAlive(attackerHumanoid) then
		return
	end

	if SkillUtil.IsTargetAlreadyHit(attackerCharacter) then
		return
	end

	if not CanCast(player) then
		return
	end

	SetCooldown(player)

	pcall(function()
		AnalyticsService:LogCustomEvent(player, "Skill_Used", 1)
		AnalyticsService:LogCustomEvent(player, "Skill_Used_Receipt")
	end)

	PlayServerBeamVisual(attackerCharacter, equippedTool)

	local spreadAngle = math.rad(BEAM_SPREAD_ANGLE)
	local targetCharacters = SkillUtil.ResolveSpreadBoxCharacterTargets(
		attackerCharacter,
		equippedTool,
		DETECT_RANGE,
		HITBOX_WIDTH,
		HITBOX_HEIGHT,
		MAX_Y_DIFF,
		ALLOW_NON_PLAYER_TARGETS,
		{0, -spreadAngle, spreadAngle}
	)

	if #targetCharacters == 0 then
		return
	end

	local appliedCount = 0

	for _, targetCharacter in ipairs(targetCharacters) do
		if appliedCount >= MAX_TARGETS_PER_CAST then
			break
		end

		ApplyReceiptHit(player, targetCharacter)
		appliedCount += 1
	end
end)

--------------------------------------------------------------------------------
-- Init / Cleanup
--------------------------------------------------------------------------------
for _, player in ipairs(Players:GetPlayers()) do
	if player.Character then
		BindCharacterBeamCleanup(player.Character)
	end

	player.CharacterAdded:Connect(function(character)
		BindCharacterBeamCleanup(character)
	end)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		BindCharacterBeamCleanup(character)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	lastReqAtByUserId[player.UserId] = nil
end)
