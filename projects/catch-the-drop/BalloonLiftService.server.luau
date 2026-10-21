--------------------------------------------------------------------------------
-- Services & Modules
-- ✅ RunService 제거: Heartbeat → task.wait 루프로 교체
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local AnalyticsService = game:GetService("AnalyticsService")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))
local LootDropService = require(ServerScriptService.Services:WaitForChild("LootDropService"))

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------
local RE_BalloonLift = NetworkFolder:WaitForChild("RE_BalloonLift")
local RE_BalloonLiftFx = NetworkFolder:WaitForChild("RE_BalloonLiftFx")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local CFG = (Constants.PVP and Constants.PVP.BALLOON_LIFT) or {}
local ENABLED = (CFG.ENABLED ~= false)
local COOLDOWN_SEC = tonumber(CFG.COOLDOWN) or 2
local DETECT_RANGE = tonumber(CFG.RANGE) or 25
local CONE_ANGLE_DEG = tonumber(CFG.CONE_ANGLE_DEG) or 70
local MAX_Y_DIFF = tonumber(CFG.MAX_Y_DIFF) or 12
local DURATION_SEC = tonumber(CFG.DURATION) or 2.2
local SERVER_MIN_INTERVAL = tonumber(CFG.SERVER_MIN_INTERVAL) or 0.10

local LIFT_RISE_SPEED = tonumber(CFG.LIFT_RISE_SPEED) or 10
local MAX_RISE_HEIGHT = tonumber(CFG.MAX_RISE_HEIGHT) or 7.5
local LIFT_LINEAR_MAX_FORCE = tonumber(CFG.LIFT_LINEAR_MAX_FORCE) or 45000

local BALLOON_TEMPLATE_NAME = tostring(CFG.BALLOON_TEMPLATE_NAME or "GalaxyBalloon")
local BALLOON_OFFSET = CFG.BALLOON_OFFSET or CFrame.new(0, 0, 8)
local BALLOON_EFFECT_FOLDER_NAME = tostring(CFG.BALLOON_EFFECT_FOLDER_NAME or "BalloonEffect")
local BALLOON_EFFECT_NAME = tostring(CFG.BALLOON_EFFECT_NAME or "Yars")

local BACK_ATTACHMENT_NAME = tostring(CFG.BACK_ATTACHMENT_NAME or "BodyBackAttachment")
local BACK_BALLOON_LOCAL_OFFSET = CFG.BACK_BALLOON_LOCAL_OFFSET or (CFrame.new(0, 0.15, 8) * CFrame.Angles(math.rad(90), 0, 0))
local BACK_STRING_TARGET_LOCAL_OFFSET = CFG.BACK_STRING_TARGET_LOCAL_OFFSET or Vector3.new(0, 0, 0)

local LOCK_LIFTED_VICTIM_XZ = (CFG.LOCK_LIFTED_VICTIM_XZ ~= false)
local LOCK_LIFTED_VICTIM_ROTATION = (CFG.LOCK_LIFTED_VICTIM_ROTATION ~= false)

local STRING_ATTACH_PART_NAME = tostring(CFG.STRING_ATTACH_PART_NAME or "UpperTorso")
local STRING_WIDTH0 = tonumber(CFG.STRING_WIDTH0) or 0.06
local STRING_WIDTH1 = tonumber(CFG.STRING_WIDTH1) or 0.06
local STRING_FACE_CAMERA = (CFG.STRING_FACE_CAMERA == true)
local STRING_COLOR = CFG.STRING_COLOR or Color3.fromRGB(15, 15, 15)
local KEEP_VICTIM_ANGULAR_DAMP = (CFG.KEEP_VICTIM_ANGULAR_DAMP ~= false)

local ALLOW_SELF_TARGET = (CFG.ALLOW_SELF_TARGET == true)
local ALLOW_FRIENDLY_FIRE = (CFG.ALLOW_FRIENDLY_FIRE == true)

local function NormalizeAnimId(id)
	local s = tostring(id or "")
	if s == "" then return "" end
	if s:find("rbxassetid://", 1, true) then return s end
	return "rbxassetid://" .. s
end

local CAST_ANIM_ID = NormalizeAnimId(CFG.CAST_ANIM_ID or "rbxassetid://79413907596272")
local CAST_ANIM_PRIORITY = Enum.AnimationPriority.Action
local CAST_ANIM_FADEIN = tonumber(CFG.CAST_ANIM_FADEIN) or 0.05
local CAST_ANIM_FADEOUT = tonumber(CFG.CAST_ANIM_FADEOUT) or 0.05
local CAST_ANIM_SPEED = tonumber(CFG.CAST_ANIM_SPEED) or 1.0

local VICTIM_LIFT_ANIM_ID = NormalizeAnimId(CFG.VICTIM_LIFT_ANIM_ID or "121566569746115")
local VICTIM_LIFT_ANIM_PRIORITY = Enum.AnimationPriority.Action
local VICTIM_LIFT_ANIM_FADEIN = tonumber(CFG.VICTIM_LIFT_ANIM_FADEIN) or 0.08
local VICTIM_LIFT_ANIM_FADEOUT = tonumber(CFG.VICTIM_LIFT_ANIM_FADEOUT) or 0.08
local VICTIM_LIFT_ANIM_SPEED = tonumber(CFG.VICTIM_LIFT_ANIM_SPEED) or 1.0

local VICTIM_LIFT_DURATION_SEC = tonumber(CFG.VICTIM_LIFT_DURATION_SEC) or 3
local CAST_END_FX_LEAD_TIME = tonumber(CFG.CAST_END_FX_LEAD_TIME) or 0.04
local CAST_ANIM_FALLBACK_DURATION = tonumber(CFG.CAST_ANIM_FALLBACK_DURATION) or 0.45

local CAST_EFFECT_ATTACHMENT_NAME = tostring(CFG.CAST_EFFECT_ATTACHMENT_NAME or "Attachment")
local DEFAULT_CAST_EMIT_COUNT = tonumber(CFG.CAST_EFFECT_EMIT_COUNT) or 12
local CAST_BEAM_ON_TIME = tonumber(CFG.CAST_BEAM_ON_TIME) or 0.08
local CAST_TRAIL_ON_TIME = tonumber(CFG.CAST_TRAIL_ON_TIME) or 0.10

local LIFT_DISABLE_BODY_COLLISIONS = (CFG.LIFT_DISABLE_BODY_COLLISIONS ~= false)
local LIFT_START_UPWARD_VELOCITY = tonumber(CFG.LIFT_START_UPWARD_VELOCITY) or 8
local LAND_RAY_HEIGHT = tonumber(CFG.LAND_RAY_HEIGHT) or 6
local LAND_RAY_DISTANCE = tonumber(CFG.LAND_RAY_DISTANCE) or 60
local LAND_EXTRA_OFFSET = tonumber(CFG.LAND_EXTRA_OFFSET) or 0.15

-- ✅ 모션 루프 주기: Heartbeat(60fps) → 20fps (물리 잠금은 20fps로도 완전히 정확)
local MOTION_UPDATE_INTERVAL = 1 / 20

local lastReqAtByUserId = {}
local activeCastAnimByUserId = {}
local activeLiftByUserId = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function PassThrottle(player)
	local uid = player.UserId
	local now = os.clock()
	local last = lastReqAtByUserId[uid] or 0
	if (now - last) < SERVER_MIN_INTERVAL then return false end
	lastReqAtByUserId[uid] = now
	return true
end

local function GetEquippedTool(player)
	if not player.Character then return nil end
	return player.Character:FindFirstChildOfClass("Tool")
end

local function IsSameTeam(attacker, target)
	if ALLOW_FRIENDLY_FIRE then return false end
	if attacker.Team == nil or target.Team == nil then return false end
	return attacker.Team == target.Team
end

--------------------------------------------------------------------------------
-- Target Validation
--------------------------------------------------------------------------------
local function CanHitTarget(attackerPlayer, targetPlayer, attackerChar, attackerRoot, targetChar, targetRoot)
	if attackerPlayer == targetPlayer and not ALLOW_SELF_TARGET then return false end
	if attackerPlayer:GetAttribute("InSafeZone") == true or targetPlayer:GetAttribute("InSafeZone") == true then return false end
	if IsSameTeam(attackerPlayer, targetPlayer) then return false end

	if SkillUtil.IsTargetAlreadyHit(targetChar) then return false end
	if not SkillUtil.IsValidFrontTarget(attackerRoot, targetRoot, DETECT_RANGE, CONE_ANGLE_DEG, MAX_Y_DIFF) then return false end

	local fromPos = attackerRoot.Position
	local toPos = targetRoot.Position + Vector3.new(0, 2, 0)
	if not SkillUtil.HasLineOfSight(attackerChar, targetChar, fromPos, toPos) then return false end

	return true
end

--------------------------------------------------------------------------------
-- Animation & FX
--------------------------------------------------------------------------------
local function FireCastEndFx(player)
	if player and player.Parent then RE_BalloonLiftFx:FireClient(player, "CastEnd") end
end

local function StopPrevCastAnim(userId)
	local entry = activeCastAnimByUserId[userId]
	if not entry then return end
	entry.Interrupted = true
	if entry.Conn then entry.Conn:Disconnect(); entry.Conn = nil end
	if entry.Track then pcall(function() if entry.Track.IsPlaying then entry.Track:Stop(CAST_ANIM_FADEOUT) end; entry.Track:Destroy() end) end
	activeCastAnimByUserId[userId] = nil
end

local function PlayCastAnim(player, humanoid)
	if CAST_ANIM_ID == "" then return end
	StopPrevCastAnim(player.UserId)
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local anim = Instance.new("Animation")
	anim.AnimationId = CAST_ANIM_ID

	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	anim:Destroy()
	if not ok or not track then return end

	track.Priority = CAST_ANIM_PRIORITY
	track:Play(CAST_ANIM_FADEIN, 1, CAST_ANIM_SPEED)

	local entry = { Track = track, Conn = nil, ReadyForEndFx = false, Interrupted = false }
	activeCastAnimByUserId[player.UserId] = entry

	local predictedDuration = (typeof(track.Length) == "number" and track.Length > 0) and (track.Length / math.max(CAST_ANIM_SPEED, 0.01)) or CAST_ANIM_FALLBACK_DURATION
	task.delay(math.max(predictedDuration - CAST_END_FX_LEAD_TIME, 0.03), function()
		if activeCastAnimByUserId[player.UserId] == entry and not entry.Interrupted then entry.ReadyForEndFx = true end
	end)

	entry.Conn = track.Stopped:Connect(function()
		local current = activeCastAnimByUserId[player.UserId]
		local shouldFireFx = (current == entry) and not entry.Interrupted and entry.ReadyForEndFx
		if entry.Conn then entry.Conn:Disconnect(); entry.Conn = nil end
		pcall(function() track:Destroy() end)
		activeCastAnimByUserId[player.UserId] = nil
		if shouldFireFx then FireCastEndFx(player) end
	end)
end

local function SpawnCastEffect(player)
	local character = player.Character
	if not character then return end

	local tool = GetEquippedTool(player)
	if not tool then return end
	local handle = tool:FindFirstChild("Handle")
	if not handle then return end

	local attachment = handle:FindFirstChild(CAST_EFFECT_ATTACHMENT_NAME) or handle:FindFirstChildWhichIsA("Attachment")
	if not attachment then return end

	for _, descendant in ipairs(attachment:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			local rate = (typeof(descendant:GetAttribute("EmitCount")) == "number") and descendant:GetAttribute("EmitCount") or DEFAULT_CAST_EMIT_COUNT
			descendant:Emit(math.floor(rate))
		elseif descendant:IsA("Beam") then
			descendant.Enabled = true; task.delay(CAST_BEAM_ON_TIME, function() if descendant and descendant.Parent then descendant.Enabled = false end end)
		elseif descendant:IsA("Trail") then
			descendant.Enabled = true; task.delay(CAST_TRAIL_ON_TIME, function() if descendant and descendant.Parent then descendant.Enabled = false end end)
		end
	end
end

--------------------------------------------------------------------------------
-- Lift Motion & Physics
--------------------------------------------------------------------------------
local function PlayVictimLiftAnimation(humanoid)
	if VICTIM_LIFT_ANIM_ID == "" then return nil end
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local anim = Instance.new("Animation")
	anim.AnimationId = VICTIM_LIFT_ANIM_ID
	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	anim:Destroy()
	if ok and track then
		track.Priority = VICTIM_LIFT_ANIM_PRIORITY; track.Looped = false; track:Play(VICTIM_LIFT_ANIM_FADEIN, 1, VICTIM_LIFT_ANIM_SPEED)
		return { Track = track }
	end
	return nil
end

local function StopVictimLiftAnimation(state)
	if state and state.Track then pcall(function() if state.Track.IsPlaying then state.Track:Stop(VICTIM_LIFT_ANIM_FADEOUT) end; state.Track:Destroy() end) end
end

local function SetupBalloonPart(part)
	part.Anchored = true; part.CanCollide = false; part.CanTouch = false; part.CanQuery = false; part.Massless = true; part.CastShadow = false
end

local function EnsurePrimaryPart(model)
	if model.PrimaryPart then return true end
	for _, d in ipairs(model:GetDescendants()) do if d:IsA("BasePart") then model.PrimaryPart = d; return true end end
	return false
end

local function GetBodyBackAttachment(character)
	local ut = character:FindFirstChild("UpperTorso")
	if ut then local att = ut:FindFirstChild(BACK_ATTACHMENT_NAME); if att then return att end end
	local t = character:FindFirstChild("Torso")
	if t then local att = t:FindFirstChild(BACK_ATTACHMENT_NAME); if att then return att end end
	return character:FindFirstChild(BACK_ATTACHMENT_NAME, true)
end

local function AttachVictimBackEffect(character)
	local backAtt = GetBodyBackAttachment(character)
	local effectTemplate = ReplicatedStorage:FindFirstChild("Templates") and ReplicatedStorage.Templates:FindFirstChild(BALLOON_EFFECT_FOLDER_NAME) and ReplicatedStorage.Templates[BALLOON_EFFECT_FOLDER_NAME]:FindFirstChild(BALLOON_EFFECT_NAME)
	if not backAtt or not effectTemplate then return nil end
	local clone = effectTemplate:Clone()
	clone.Name = "BalloonLift_BackEffect"
	clone.Parent = backAtt
	for _, pe in ipairs(clone:GetDescendants()) do if pe:IsA("ParticleEmitter") then pe:Emit(DEFAULT_CAST_EMIT_COUNT) end end
	return clone
end

local function GetBackBalloonWorldCFrame(character, victimRoot)
	local backAtt = GetBodyBackAttachment(character)
	local cf = backAtt and backAtt.WorldCFrame or (character:FindFirstChild("UpperTorso") or victimRoot).CFrame
	return cf * BACK_BALLOON_LOCAL_OFFSET * BALLOON_OFFSET
end

local function SetVisualWorldCFrame(visual, cf)
	if visual:IsA("Model") then visual:PivotTo(cf) elseif visual:IsA("BasePart") then visual.CFrame = cf end
end

local function CreateFallbackBalloonVisual(charName)
	local m = Instance.new("Model"); m.Name = "BalloonLift_Visual_" .. tostring(charName)
	local b = Instance.new("Part"); b.Name = "Balloon"; b.Shape = Enum.PartType.Ball; b.Size = Vector3.new(2.2, 2.6, 2.2); b.Color = Color3.fromRGB(255, 164, 210); SetupBalloonPart(b); b.Parent = m
	local h = Instance.new("Part"); h.Name = "BalloonHolder"; h.Size = Vector3.new(0.2, 0.2, 0.2); h.Transparency = 1; SetupBalloonPart(h); h.Parent = m
	local attH = Instance.new("Attachment"); attH.Name = "StringStart"; attH.Parent = h
	local attB = Instance.new("Attachment"); attB.Name = "StringEnd"; attB.Position = Vector3.new(0, -1.15, 0); attB.Parent = b
	local beam = Instance.new("Beam"); beam.Name = "BalloonString"; beam.Width0 = 0.04; beam.Width1 = 0.04; beam.FaceCamera = true; beam.Attachment0 = attH; beam.Attachment1 = attB; beam.Parent = h
	m.PrimaryPart = b; m.Parent = Workspace
	return m
end

local function AttachBalloonVisual(character, root)
	local templates = ReplicatedStorage:FindFirstChild("Templates")
	local t = templates and templates:FindFirstChild(BALLOON_TEMPLATE_NAME)
	local visual

	if t then
		visual = t:Clone()
		if visual:IsA("Model") and EnsurePrimaryPart(visual) then
			for _, d in ipairs(visual:GetDescendants()) do if d:IsA("BasePart") then SetupBalloonPart(d) end end
			visual.Name = "BalloonLift_Visual_" .. character.Name; visual.Parent = Workspace
		elseif visual:IsA("BasePart") then
			visual.Name = "BalloonLift_Visual_" .. character.Name; SetupBalloonPart(visual); visual.Parent = Workspace
		else
			visual:Destroy(); visual = CreateFallbackBalloonVisual(character.Name)
		end
	else
		visual = CreateFallbackBalloonVisual(character.Name)
	end

	if visual then SetVisualWorldCFrame(visual, GetBackBalloonWorldCFrame(character, root)) end
	return visual
end

local function CleanupLift(victimPlayer)
	local entry = activeLiftByUserId[victimPlayer.UserId]
	if not entry then return end
	activeLiftByUserId[victimPlayer.UserId] = nil

	for _, conn in ipairs(entry.Connections) do if conn then conn:Disconnect() end end
	StopVictimLiftAnimation(entry.VictimAnimTrack)
	for _, inst in ipairs(entry.Instances) do if inst and inst.Parent then inst:Destroy() end end

	local char = entry.Character
	if char and char.Parent then char:SetAttribute("IsBalloonLifted", false) end

	for part, col in pairs(entry.PrevCanCollide) do if part and part.Parent then part.CanCollide = col end end

	local hum = SkillUtil.GetHumanoid(char)
	if hum and victimPlayer.Character == char then
		hum.JumpPower = entry.PrevJumpPower
		hum.JumpHeight = entry.PrevJumpHeight
		hum.AutoRotate = entry.PrevAutoRotate
	end

	-- ✅ WalkSpeed는 직접 복원하지 않고 중앙 속도 계산기로 처리
	-- (영수증/가방 등 다른 스킬 상태가 중첩되어 있어도 올바른 속도 반영됨)
	SkillUtil.UpdateWalkSpeed(char)

	local root = SkillUtil.GetRoot(char)
	if root and victimPlayer.Character == char then pcall(function() root:SetNetworkOwner(victimPlayer) end) end
end

local function ForceLandVictim(victimPlayer)
	local entry = activeLiftByUserId[victimPlayer.UserId]
	if not entry or entry.IsLanding then return end
	entry.IsLanding = true

	local char = entry.Character
	local root = SkillUtil.GetRoot(char)
	if char and root and victimPlayer.Character == char then
		local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Exclude; params.FilterDescendantsInstances = { char }
		local res = Workspace:Raycast(root.Position + Vector3.new(0, LAND_RAY_HEIGHT, 0), Vector3.new(0, -LAND_RAY_DISTANCE, 0), params)
		local targetY = res and (res.Position.Y + (SkillUtil.GetHumanoid(char).HipHeight or 2) + root.Size.Y * 0.5 + LAND_EXTRA_OFFSET) or entry.LandY
		local look = entry.LockedLookVector
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = CFrame.lookAt(Vector3.new(root.Position.X, targetY, root.Position.Z), Vector3.new(root.Position.X, targetY, root.Position.Z) + look, Vector3.new(0, 1, 0))
	end
	CleanupLift(victimPlayer)
end

local function ApplyBalloonLift(attackerPlayer, victimPlayer)
	local victimChar = victimPlayer.Character
	local victimHum = SkillUtil.GetHumanoid(victimChar)
	local victimRoot = SkillUtil.GetRoot(victimChar)

	if not victimRoot or not SkillUtil.IsAlive(victimHum) then return false end
	CleanupLift(victimPlayer)

	local flatLook = victimRoot.CFrame.LookVector
	flatLook = Vector3.new(flatLook.X, 0, flatLook.Z)
	flatLook = (flatLook.Magnitude > 0.001) and flatLook.Unit or Vector3.new(0, 0, -1)

	local entry = {
		Character = victimChar,
		Connections = {}, Instances = {}, PrevCanCollide = {},
		PrevWalkSpeed = victimHum.WalkSpeed, PrevJumpPower = victimHum.JumpPower, PrevJumpHeight = victimHum.JumpHeight, PrevAutoRotate = victimHum.AutoRotate,
		MaxY = victimRoot.Position.Y + MAX_RISE_HEIGHT, LandY = victimRoot.Position.Y,
		LandAt = os.clock() + VICTIM_LIFT_DURATION_SEC, IsLanding = false,
		LockedX = victimRoot.Position.X, LockedZ = victimRoot.Position.Z, LockedLookVector = flatLook,
	}
	activeLiftByUserId[victimPlayer.UserId] = entry

	victimChar:SetAttribute("IsBalloonLifted", true)
	victimChar:SetAttribute("CCImmunityEndTime", workspace:GetServerTimeNow() + VICTIM_LIFT_DURATION_SEC + 0.5)
	pcall(function() victimRoot:SetNetworkOwner(nil) end)

	pcall(function() LootDropService:DropCarriedItem(victimPlayer, attackerPlayer) end)

	victimHum.WalkSpeed = 0; victimHum.JumpPower = 0; victimHum.JumpHeight = 0; victimHum.AutoRotate = false
	if LIFT_DISABLE_BODY_COLLISIONS then
		for _, d in ipairs(victimChar:GetDescendants()) do
			if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
				entry.PrevCanCollide[d] = d.CanCollide; d.CanCollide = false
			end
		end
	end

	entry.VictimAnimTrack = PlayVictimLiftAnimation(victimHum)

	local moveAtt = Instance.new("Attachment"); moveAtt.Name = "BalloonLift_MoveAttachment"; moveAtt.Parent = victimRoot
	local lv = Instance.new("LinearVelocity"); lv.Name = "BalloonLift_LinearVelocity"; lv.Attachment0 = moveAtt; lv.RelativeTo = Enum.ActuatorRelativeTo.World; lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector; lv.VectorVelocity = Vector3.new(0, LIFT_RISE_SPEED, 0)
	pcall(function() lv.MaxForce = LIFT_LINEAR_MAX_FORCE; lv.ForceLimitsEnabled = true end); lv.Parent = victimRoot

	-- ✅ 풍선 비주얼: 서버에서 생성하되, 초기 위치 1회만 설정
	-- 위치 업데이트는 클라이언트가 RE_BalloonLiftFx 신호를 받아 로컬에서 처리
	local visual = AttachBalloonVisual(victimChar, victimRoot)
	local backEffect = AttachVictimBackEffect(victimChar)

	table.insert(entry.Instances, moveAtt); table.insert(entry.Instances, lv)
	if visual then table.insert(entry.Instances, visual) end
	if backEffect then table.insert(entry.Instances, backEffect) end

	victimRoot.AssemblyLinearVelocity = Vector3.new(0, LIFT_START_UPWARD_VELOCITY, 0); victimRoot.AssemblyAngularVelocity = Vector3.zero

	-- ✅ 클라이언트에 풍선 비주얼 시작 신호 전송 (클라이언트가 로컬에서 풍선 위치 추적)
	RE_BalloonLiftFx:FireAllClients("BalloonStart", victimPlayer, VICTIM_LIFT_DURATION_SEC)

	-- ✅ 수정: RunService.Heartbeat → task.wait(1/20) 루프 (3배 복제 감소)
	-- XZ 잠금 + LinearVelocity 조정은 20fps로도 물리적으로 정확함
	-- 풍선 비주얼 위치 업데이트(SetVisualWorldCFrame) 제거 → 클라이언트가 처리
	local motionRunning = true
	local motionConn = { Disconnect = function() motionRunning = false end }

	task.spawn(function()
		while motionRunning do
			task.wait(MOTION_UPDATE_INTERVAL)

			if not motionRunning then break end
			if activeLiftByUserId[victimPlayer.UserId] ~= entry or victimPlayer.Character ~= victimChar then
				motionRunning = false; break
			end

			local curRoot = SkillUtil.GetRoot(victimChar)
			local curHum = SkillUtil.GetHumanoid(victimChar)
			if not curRoot or not SkillUtil.IsAlive(curHum) then
				CleanupLift(victimPlayer); motionRunning = false; break
			end

			if LOCK_LIFTED_VICTIM_XZ or LOCK_LIFTED_VICTIM_ROTATION then
				local fPos = LOCK_LIFTED_VICTIM_XZ and Vector3.new(entry.LockedX, curRoot.Position.Y, entry.LockedZ) or curRoot.Position
				if LOCK_LIFTED_VICTIM_ROTATION then
					curRoot.CFrame = CFrame.lookAt(fPos, fPos + entry.LockedLookVector, Vector3.new(0, 1, 0))
				else
					curRoot.Position = fPos
				end
				curRoot.AssemblyLinearVelocity = Vector3.new(0, math.max(curRoot.AssemblyLinearVelocity.Y, 0), 0)
				curRoot.AssemblyAngularVelocity = Vector3.zero
			end

			if KEEP_VICTIM_ANGULAR_DAMP then
				curRoot.AssemblyAngularVelocity *= 0.55
			end

			if os.clock() >= entry.LandAt then
				ForceLandVictim(victimPlayer); motionRunning = false; break
			end

			local rem = entry.MaxY - curRoot.Position.Y
			lv.VectorVelocity = Vector3.new(0, (rem > 2) and LIFT_RISE_SPEED or ((rem > 0.6) and 4 or ((rem > 0.1) and 0.8 or 0)), 0)

			-- ✅ SetVisualWorldCFrame 제거: 풍선 비주얼 위치 복제 없음
			-- 클라이언트가 IsBalloonLifted attribute와 BalloonStart FX 신호로 로컬 처리
		end
	end)

	table.insert(entry.Connections, motionConn)
	table.insert(entry.Connections, victimHum.Died:Connect(function() CleanupLift(victimPlayer) end))
	table.insert(entry.Connections, victimChar.AncestryChanged:Connect(function(_, p) if p == nil then CleanupLift(victimPlayer) end end))
	task.delay(VICTIM_LIFT_DURATION_SEC + 5, function()
		if activeLiftByUserId[victimPlayer.UserId] == entry then CleanupLift(victimPlayer) end
	end)

	return true
end

--------------------------------------------------------------------------------
-- Core
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Core
--------------------------------------------------------------------------------
RE_BalloonLift.OnServerEvent:Connect(function(player, targetPlayer)
	if not ENABLED or not player or not player.Parent then return end
	if not PassThrottle(player) or player:GetAttribute("InSafeZone") == true then return end

	if not GetEquippedTool(player) then return end
	if SkillUtil.IsTargetAlreadyHit(player.Character) then return end

	local nextTime = player:GetAttribute("BalloonLift_NextCastTime") or 0
	if os.clock() < nextTime then return end

	local attackerChar = player.Character
	local attackerHum = SkillUtil.GetHumanoid(attackerChar)
	local attackerRoot = SkillUtil.GetRoot(attackerChar)

	if not attackerRoot or not SkillUtil.IsAlive(attackerHum) then return end

	local hasValidTarget = (typeof(targetPlayer) == "Instance" and targetPlayer:IsA("Player"))

	-- 타겟이 있을 경우에만 거리/각도/팀킬 등 유효성 검사 진행
	if hasValidTarget then
		local targetChar = targetPlayer.Character
		local targetHum = SkillUtil.GetHumanoid(targetChar)
		local targetRoot = SkillUtil.GetRoot(targetChar)

		if not targetRoot or not SkillUtil.IsAlive(targetHum) then return end
		if not CanHitTarget(player, targetPlayer, attackerChar, attackerRoot, targetChar, targetRoot) then return end
	end

	-- 💡 [핵심] 허공에 썼든 타겟을 맞췄든, 스킬 시전 조건을 모두 통과한 이 시점이 진짜 '스킬 사용' 시점입니다!
	player:SetAttribute("BalloonLift_NextCastTime", os.clock() + COOLDOWN_SEC)

	-- 📊 [Analytics] PvP 스킬 사용 빈도 추적
	pcall(function()
		AnalyticsService:LogCustomEvent(player, "Skill_Used", 1) -- 전체 스킬 사용량 합산용
		AnalyticsService:LogCustomEvent(player, "Skill_Used_BalloonLift") -- 개별 스킬 통계용
		--print(string.format("🎈 [Analytics] 스킬 사용: %s | 스킬명: BalloonLift", player.Name))
	end)

	-- 공통 연출 실행
	PlayCastAnim(player, attackerHum)
	SpawnCastEffect(player)

	-- 타겟이 유효했다면 풍선 띄우기 물리 효과 적용
	if hasValidTarget then
		ApplyBalloonLift(player, targetPlayer)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastReqAtByUserId[player.UserId] = nil
	StopPrevCastAnim(player.UserId)
	CleanupLift(player)
end)