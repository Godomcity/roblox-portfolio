--------------------------------------------------------------------------------
-- Services & Modules
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local AnalyticsService = game:GetService("AnalyticsService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))
local LootDropService = require(ServerScriptService.Services:WaitForChild("LootDropService"))

--------------------------------------------------------------------------------
-- Folders / Remotes (✅ 글로벌 네트워크 폴더 사용)
--------------------------------------------------------------------------------
local TemplatesFolder = ReplicatedStorage:WaitForChild("Templates")
local EffectFolder = TemplatesFolder:WaitForChild("Effect")
local UsePaparazziEffectTemplate = EffectFolder:WaitForChild("UsePaparazziEffect")
local HitPaparazziEffectTemplate = EffectFolder:WaitForChild("HitPaparazziEffect")

local RE_Paparazzi = NetworkFolder:WaitForChild("RE_Paparazzi")
local RE_PaparazziFx = NetworkFolder:WaitForChild("RE_PaparazziFx")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local CFG = (Constants.PVP and Constants.PVP.PAPARAZZI) or {}
local ENABLED               = (CFG.ENABLED ~= false)
local COOLDOWN_SEC          = tonumber(CFG.COOLDOWN_SEC)          or 1.25
local RANGE                 = tonumber(CFG.RANGE)                 or 10
local CONE_ANGLE_DEG        = tonumber(CFG.CONE_ANGLE_DEG)        or 80
local MAX_Y_DIFF            = tonumber(CFG.MAX_Y_DIFF)            or 12
local TARGET_FRONT_DOT      = tonumber(CFG.TARGET_FRONT_DOT)      or 0.2
local TARGET_BACK_DOT       = tonumber(CFG.TARGET_BACK_DOT)       or -0.15
local REQUIRE_LINE_OF_SIGHT = (CFG.REQUIRE_LINE_OF_SIGHT ~= false)
local STUN_DURATION         = tonumber(CFG.STUN_DURATION)         or 2
local HIT_EFFECT_LIFETIME   = tonumber(CFG.HIT_EFFECT_LIFETIME)   or 2
local BLUR_SIZE             = tonumber(CFG.BLUR_SIZE)             or 22
local BLUR_FADE_IN          = tonumber(CFG.BLUR_FADE_IN)          or 0.05
local BLUR_HOLD             = tonumber(CFG.BLUR_HOLD)             or 1.5
local BLUR_FADE_OUT         = tonumber(CFG.BLUR_FADE_OUT)         or 0.28
local CONE_FLASH_Y_OFFSET   = tonumber(CFG.CONE_FLASH_Y_OFFSET)   or -2.6

local VICTIM_ANIMATION_ID = tostring(CFG.VICTIM_ANIMATION_ID or "84301472571660")
if not string.find(VICTIM_ANIMATION_ID, "rbxassetid://", 1, true) then
	VICTIM_ANIMATION_ID = "rbxassetid://" .. VICTIM_ANIMATION_ID
end

local FLASH_HOLD, FLASH_FADE, FLASH_STEPS, FLASH_SLICES = 0.06, 0.12, 6, 10

local cooldownByUserId = {}
local stunStateByCharacter = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
-- ✅ Tool 의존성 제거: 캐릭터가 들고 있는 무기(Tool)를 직접 찾음
local function GetEquippedTool(player)
	if not player.Character then return nil end
	return player.Character:FindFirstChildOfClass("Tool")
end

--------------------------------------------------------------------------------
-- Effect Helpers 
--------------------------------------------------------------------------------
local function emitEffectDescendants(rootInstance)
	for _, descendant in ipairs(rootInstance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
			descendant:Emit(type(descendant:GetAttribute("EmitCount")) == "number" and descendant:GetAttribute("EmitCount") or 20)
		elseif descendant:IsA("Trail") or descendant:IsA("Beam") then
			descendant.Enabled = true
		elseif descendant:IsA("Sound") then
			descendant:Play()
		end
	end
end

local function playHitEffect(victimCharacter)
	local upperTorso = victimCharacter:FindFirstChild("UpperTorso")
	local att = upperTorso and upperTorso:FindFirstChild("BodyBackAttachment")
	if not att then return end
	local clone = HitPaparazziEffectTemplate:Clone()
	clone.Parent = att
	emitEffectDescendants(clone); Debris:AddItem(clone, HIT_EFFECT_LIFETIME)
end

local function playVictimAnimation(victimCharacter)
	local humanoid = SkillUtil.GetHumanoid(victimCharacter)
	if not humanoid then return nil end

	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local animation = Instance.new("Animation"); animation.AnimationId = VICTIM_ANIMATION_ID
	local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
	animation:Destroy()

	if not ok or not track then
		humanoid.Sit = true
		return "Sit"
	end

	track.Priority = Enum.AnimationPriority.Action; track.Looped = true; track:Play(0.1, 1, 1)
	task.delay(0.15, function() pcall(function() if track.IsPlaying then track:AdjustSpeed(0) end end) end)
	return track
end

local function playVictimBlur(victimPlayer)
	RE_PaparazziFx:FireClient(victimPlayer, "VictimBlur", { Size = BLUR_SIZE, FadeIn = BLUR_FADE_IN, Hold = BLUR_HOLD, FadeOut = BLUR_FADE_OUT })
end

local function playConeFlashWithEffect(attackerPlayer, attackerCharacter)
	local root = SkillUtil.GetRoot(attackerCharacter)
	if not root then return end
	local flatLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	if flatLook.Magnitude <= 0.001 then return end

	local baseAngle = math.atan2(flatLook.Z, flatLook.X); local halfAngle = math.rad(CONE_ANGLE_DEG * 0.5)
	local center = root.Position + Vector3.new(0, CONE_FLASH_Y_OFFSET, 0)
	local folder = Instance.new("Folder"); folder.Name = "Paparazzi_Flash"; folder.Parent = Workspace

	local effectClone = nil
	-- ✅ Tool 의존성 제거: 장착 중인 Tool의 Handle을 찾아 이펙트 부착
	local tool = GetEquippedTool(attackerPlayer)
	local handle = tool and tool:FindFirstChild("Handle")
	local att = handle and (handle:FindFirstChild("Attachment") or handle:FindFirstChildWhichIsA("Attachment"))
	if att then
		effectClone = UsePaparazziEffectTemplate:Clone(); effectClone.Parent = att; emitEffectDescendants(effectClone)
	end

	local parts = {}
	for i = 0, FLASH_SLICES - 1 do
		local aMid = baseAngle - halfAngle + (halfAngle * 2 * (((i / FLASH_SLICES) + ((i + 1) / FLASH_SLICES)) / 2))
		local p = Instance.new("Part"); p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false; p.CastShadow = false; p.Material = Enum.Material.Neon; p.BrickColor = BrickColor.new("White"); p.Size = Vector3.new(RANGE * (halfAngle * 2 / FLASH_SLICES) * 1.15, 0.15, RANGE); p.CFrame = CFrame.new(center + Vector3.new(math.cos(aMid), 0, math.sin(aMid)) * (RANGE * 0.5)) * CFrame.Angles(0, -(aMid - math.pi / 2), 0); p.Parent = folder
		table.insert(parts, p)
	end

	local centerPart = Instance.new("Part"); centerPart.Anchored = true; centerPart.CanCollide = false; centerPart.CanTouch = false; centerPart.CanQuery = false; centerPart.CastShadow = false; centerPart.Shape = Enum.PartType.Ball; centerPart.Material = Enum.Material.Neon; centerPart.BrickColor = BrickColor.new("White"); centerPart.Size = Vector3.new(1.5, 1.5, 1.5); centerPart.CFrame = CFrame.new(center); centerPart.Parent = folder; table.insert(parts, centerPart)
	local light = Instance.new("PointLight"); light.Color = Color3.fromRGB(255, 250, 230); light.Range = RANGE * 2; light.Brightness = 12; light.Shadows = false; light.Parent = centerPart

	task.spawn(function()
		task.wait(FLASH_HOLD)
		for i = 1, FLASH_STEPS do
			local alpha = i / FLASH_STEPS
			task.wait(FLASH_FADE / FLASH_STEPS)
			for _, p in ipairs(parts) do if p.Parent then p.Transparency = alpha end end
			if light.Parent then light.Brightness = 12 * (1 - alpha) end
		end
		if effectClone then effectClone:Destroy() end
		if folder then folder:Destroy() end
	end)
end

--------------------------------------------------------------------------------
-- Stun (✅ 무적시간 + 애니메이션 버그 수정 완벽 포함)
--------------------------------------------------------------------------------
local function releaseStun(character)
	local state = stunStateByCharacter[character]
	if not state then return end
	if state.DeathConn then state.DeathConn:Disconnect(); state.DeathConn = nil end

	if state.AnimTrack then
		pcall(function()
			if typeof(state.AnimTrack) == "Instance" and state.AnimTrack:IsA("AnimationTrack") then
				state.AnimTrack:AdjustSpeed(1) 
				state.AnimTrack:Stop(0.1)      
				state.AnimTrack:Destroy()
			end
		end)
	end

	if character.Parent then character:SetAttribute("PaparazziStunned", false) end
	if state.Humanoid.Parent then
		state.Humanoid.AutoRotate = state.AutoRotate
		if state.UseJumpPower then state.Humanoid.JumpPower = state.JumpPower else state.Humanoid.JumpHeight = state.JumpHeight end
		if state.WasSitting and state.Humanoid.Sit then state.Humanoid.Sit = false end
	end

	-- ✅ 중앙 속도 계산기 호출
	SkillUtil.UpdateWalkSpeed(character)

	if state.Root.Parent then
		state.Root.Anchored = state.WasAnchored; state.Root.AssemblyLinearVelocity = Vector3.zero; state.Root.AssemblyAngularVelocity = Vector3.zero
	end
	stunStateByCharacter[character] = nil
end

local function applyStun(character, duration, animTrackOrSit)
	local humanoid = SkillUtil.GetHumanoid(character)
	local root = SkillUtil.GetRoot(character)
	if not humanoid or not root then return end

	local state = stunStateByCharacter[character]
	if not state then
		state = {
			Token = 0, Humanoid = humanoid, Root = root, AutoRotate = humanoid.AutoRotate,
			UseJumpPower = humanoid.UseJumpPower, JumpPower = humanoid.JumpPower, JumpHeight = humanoid.JumpHeight, WasAnchored = root.Anchored,
			AnimTrack = (typeof(animTrackOrSit) == "Instance" and animTrackOrSit:IsA("AnimationTrack")) and animTrackOrSit or nil,
			WasSitting = (animTrackOrSit == "Sit")
		}
		stunStateByCharacter[character] = state

		character:SetAttribute("PaparazziStunned", true)
		character:SetAttribute("CCImmunityEndTime", workspace:GetServerTimeNow() + duration + 0.5)

		humanoid.AutoRotate = false
		-- ✅ 중앙 속도 계산기 호출
		SkillUtil.UpdateWalkSpeed(character)

		if humanoid.UseJumpPower then humanoid.JumpPower = 0 else humanoid.JumpHeight = 0 end
		root.AssemblyLinearVelocity = Vector3.zero; root.AssemblyAngularVelocity = Vector3.zero; root.Anchored = true

		state.DeathConn = humanoid.Died:Connect(function() releaseStun(character) end)
	end

	state.Token += 1
	local currentToken = state.Token

	task.spawn(function()
		task.wait(duration)
		if stunStateByCharacter[character] and stunStateByCharacter[character].Token == currentToken then releaseStun(character) end
	end)
end

--------------------------------------------------------------------------------
-- Target Validation
--------------------------------------------------------------------------------
local function collectValidFrontTargets(attackerPlayer, attackerCharacter, attackerRoot)
	local targets = {}
	local fromPosition = attackerRoot.Position + Vector3.new(0, 2, 0)

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= attackerPlayer and otherPlayer:GetAttribute("InSafeZone") ~= true then
			local victimCharacter = otherPlayer.Character
			local victimHumanoid  = SkillUtil.GetHumanoid(victimCharacter)
			local victimRoot      = SkillUtil.GetRoot(victimCharacter)

			if victimRoot and SkillUtil.IsAlive(victimHumanoid) and not SkillUtil.IsTargetAlreadyHit(victimCharacter) then
				if SkillUtil.IsValidFrontTarget(attackerRoot, victimRoot, RANGE, CONE_ANGLE_DEG, MAX_Y_DIFF, TARGET_FRONT_DOT, TARGET_BACK_DOT) then
					local toPosition = victimRoot.Position + Vector3.new(0, 2, 0)
					if not REQUIRE_LINE_OF_SIGHT or SkillUtil.HasLineOfSight(attackerCharacter, victimCharacter, fromPosition, toPosition) then
						table.insert(targets, otherPlayer)
					end
				end
			end
		end
	end
	return targets
end

--------------------------------------------------------------------------------
-- Use
--------------------------------------------------------------------------------
local function handleUseRequest(attackerPlayer)
	if not ENABLED or not attackerPlayer or not attackerPlayer.Parent or attackerPlayer:GetAttribute("InSafeZone") == true then return end

	-- ✅ Tool 의존성 제거: 무기를 들고 있는지 검사
	if not GetEquippedTool(attackerPlayer) then return end

	local attackerCharacter = attackerPlayer.Character
	local attackerHumanoid  = SkillUtil.GetHumanoid(attackerCharacter)
	local attackerRoot      = SkillUtil.GetRoot(attackerCharacter)

	if not attackerRoot or not SkillUtil.IsAlive(attackerHumanoid) then return end
	if SkillUtil.IsTargetAlreadyHit(attackerCharacter) then return end

	local now = os.clock()
	if now < (cooldownByUserId[attackerPlayer.UserId] or 0) then return end
	cooldownByUserId[attackerPlayer.UserId] = now + COOLDOWN_SEC

	-- 📊 [Analytics] PvP 스킬 사용 빈도 추적
	pcall(function()
		AnalyticsService:LogCustomEvent(attackerPlayer, "Skill_Used", 1)
		AnalyticsService:LogCustomEvent(attackerPlayer, "Skill_Used_Paparazzi")
		--print(string.format("📸 [Analytics] 스킬 사용: %s | 스킬명: Paparazzi", attackerPlayer.Name))
	end)

	playConeFlashWithEffect(attackerPlayer, attackerCharacter)

	local targets = collectValidFrontTargets(attackerPlayer, attackerCharacter, attackerRoot)
	for _, victimPlayer in ipairs(targets) do
		local victimCharacter = victimPlayer.Character
		if victimCharacter and not SkillUtil.IsTargetAlreadyHit(victimCharacter) then
			local animTrackOrSit = playVictimAnimation(victimCharacter)
			applyStun(victimCharacter, STUN_DURATION, animTrackOrSit)

			playVictimBlur(victimPlayer)
			playHitEffect(victimCharacter)
			LootDropService:DropCarriedItem(victimPlayer, attackerPlayer)
		end
	end
end

--------------------------------------------------------------------------------
-- Remote & Cleanup
--------------------------------------------------------------------------------
RE_Paparazzi.OnServerEvent:Connect(function(player, action)
	if action == "Use" then handleUseRequest(player) end
end)

Players.PlayerRemoving:Connect(function(player)
	cooldownByUserId[player.UserId] = nil
	if player.Character then releaseStun(player.Character) end
end)