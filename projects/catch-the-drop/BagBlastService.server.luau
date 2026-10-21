--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local AnalyticsService = game:GetService("AnalyticsService")

--------------------------------------------------------------------------------
-- Modules & Remotes (✅ 글로벌 네트워크 폴더 사용)
--------------------------------------------------------------------------------
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))
local LootDropService = require(ServerScriptService.Services:WaitForChild("LootDropService"))

local RE_BagSkill = NetworkFolder:WaitForChild("RE_BagSkill")
local Templates = ReplicatedStorage:WaitForChild("Templates")

--------------------------------------------------------------------------------
-- Config 
--------------------------------------------------------------------------------
local CFG = (Constants.PVP and Constants.PVP.BAG_BLAST) or {}

local ENABLED = (CFG.ENABLED ~= false)
local COOLDOWN_SEC = tonumber(CFG.COOLDOWN) or 5
local DETECT_RANGE = tonumber(CFG.RANGE) or 25
local CONE_ANGLE_DEG = tonumber(CFG.CONE_ANGLE_DEG) or 70
local MAX_Y_DIFF = tonumber(CFG.MAX_Y_DIFF) or 999
local HIT_DURATION = tonumber(CFG.HIT_DURATION) or 4
local SLOW_WALKSPEED = tonumber(CFG.SLOW_WALKSPEED) or 6
local SERVER_MIN_INTERVAL = tonumber(CFG.SERVER_MIN_INTERVAL) or 0.10

local BAG_TEMPLATE_NAME = tostring(CFG.BAG_TEMPLATE_NAME or "GalaxyShoppingBag")
local COVER_HIDE_CHARACTER = (CFG.COVER_HIDE_CHARACTER == true)
local BAG_OFFSET_Y = tonumber(CFG.BAG_OFFSET_Y) or 0
local COVER_FADE_OUT = 0.25

local AURA_TEMPLATE_NAME = tostring(CFG.AURA_TEMPLATE_NAME or "Aura")
local AURA_LIFETIME = tonumber(CFG.AURA_LIFETIME) or 2.0
local AURA_OFFSET_Y = tonumber(CFG.AURA_OFFSET_Y) or 2.55
local HIT_AURA_NAME = "BagBlast_HitAura"

local lastReqAtByUserId = {}
local activeCastAnimByUserId = {}

-- 애니메이션 & VFX
local function NormalizeAnimId(id)
	local s = tostring(id or "")
	if s == "" then return "" end
	if s:find("rbxassetid://", 1, true) then return s end
	return "rbxassetid://" .. s
end

local CAST_ANIM_ID = NormalizeAnimId(CFG.CAST_ANIM_ID or "120642695648036")
local CAST_ANIM_PRIORITY = Enum.AnimationPriority.Action
local CAST_ANIM_FADEIN = tonumber(CFG.CAST_ANIM_FADEIN) or 0.05
local CAST_ANIM_FADEOUT = tonumber(CFG.CAST_ANIM_FADEOUT) or 0.05
local CAST_ANIM_SPEED = tonumber(CFG.CAST_ANIM_SPEED) or 1.0

local VFX_COLOR_PINK = Color3.fromRGB(249, 14, 114)
local VFX_COLOR_HOTPINK = Color3.fromRGB(252, 76, 103)
local VFX_COLOR_ORANGE = Color3.fromRGB(251, 57, 34)
local VFX_COLOR_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0.00, VFX_COLOR_PINK),
	ColorSequenceKeypoint.new(0.55, VFX_COLOR_HOTPINK),
	ColorSequenceKeypoint.new(1.00, VFX_COLOR_ORANGE),
})
local VFX_INTENSITY = math.clamp(tonumber(CFG.VFX_INTENSITY) or 2.0, 0.5, 3.0)
local WAND_VFX_DURATION = tonumber(CFG.WAND_VFX_DURATION) or 0.45
local WAND_VFX_TRAIL_LIFETIME = tonumber(CFG.WAND_VFX_TRAIL_LIFETIME) or 0.22
local WAND_VFX_SPARK_INTERVAL = tonumber(CFG.WAND_VFX_SPARK_INTERVAL) or 0.04
local WAND_VFX_SPARK_PER_TICK = math.clamp(tonumber(CFG.WAND_VFX_SPARK_PER_TICK) or 12, 0, 60)
local WAND_VFX_START_BURST = math.clamp(tonumber(CFG.WAND_VFX_START_BURST) or 40, 0, 220)
local WAND_VFX_TRAIL_WIDTH0 = tonumber(CFG.WAND_VFX_TRAIL_WIDTH0) or 0.22
local WAND_VFX_TRAIL_WIDTH1 = tonumber(CFG.WAND_VFX_TRAIL_WIDTH1) or 0.90
local GROUND_VFX_THICKNESS = tonumber(CFG.GROUND_VFX_THICKNESS) or 0.12
local GROUND_VFX_START_DIA = tonumber(CFG.GROUND_VFX_START_DIA) or 1.2
local GROUND_VFX_END_DIA = tonumber(CFG.GROUND_VFX_END_DIA) or 7.5
local GROUND_VFX_ALPHA0 = tonumber(CFG.GROUND_VFX_ALPHA0) or 0.35
local GROUND_VFX_DURATION = tonumber(CFG.GROUND_VFX_DURATION) or 0.32
local VFX_IMPACT_ENABLED = (CFG.VFX_IMPACT_ENABLED ~= false)
local VICTIM_BURST = math.clamp(tonumber(CFG.VFX_VICTIM_BURST) or 14, 0, 120)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function PassThrottle(player)
	local uid = player.UserId
	local t = os.clock()
	local last = lastReqAtByUserId[uid] or 0
	if (t - last) < SERVER_MIN_INTERVAL then return false end
	lastReqAtByUserId[uid] = t
	return true
end

-- ✅ Tool 의존성 제거: 캐릭터가 들고 있는 무기(Tool)를 직접 찾음
local function GetEquippedTool(player)
	if not player.Character then return nil end
	return player.Character:FindFirstChildOfClass("Tool")
end

local function CanCast(player)
	local nextTime = player:GetAttribute("BagSkill_NextCastTime") or 0
	return os.clock() >= nextTime
end

--------------------------------------------------------------------------------
-- Animation
--------------------------------------------------------------------------------
local function StopPrevCastAnim(userId)
	local entry = activeCastAnimByUserId[userId]
	if not entry then return end
	if entry.Conn then entry.Conn:Disconnect() end
	if entry.Track then pcall(function() if entry.Track.IsPlaying then entry.Track:Stop(CAST_ANIM_FADEOUT) end end) end
	activeCastAnimByUserId[userId] = nil
end

local function PlayCastAnim(player, humanoid)
	if CAST_ANIM_ID == "" then return end
	StopPrevCastAnim(player.UserId)

	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	local anim = Instance.new("Animation")
	anim.AnimationId = CAST_ANIM_ID

	local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
	if not ok or not track then return end

	track.Priority = CAST_ANIM_PRIORITY
	track:Play(CAST_ANIM_FADEIN, 1, CAST_ANIM_SPEED)

	local conn
	conn = track.Stopped:Connect(function()
		if activeCastAnimByUserId[player.UserId] then
			activeCastAnimByUserId[player.UserId].Conn:Disconnect()
			activeCastAnimByUserId[player.UserId] = nil
		end
	end)

	activeCastAnimByUserId[player.UserId] = { Track = track, Conn = conn }
end

--------------------------------------------------------------------------------
-- 타겟 수집
--------------------------------------------------------------------------------
local function GetVictimsInCone(attacker, attackerRoot)
	local victims = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= attacker and plr:GetAttribute("InSafeZone") ~= true then
			local targetChar = plr.Character
			local targetRoot = SkillUtil.GetRoot(targetChar)
			local targetHum = SkillUtil.GetHumanoid(targetChar)

			if targetRoot and SkillUtil.IsAlive(targetHum) and not SkillUtil.IsTargetAlreadyHit(targetChar) then
				if SkillUtil.IsValidFrontTarget(attackerRoot, targetRoot, DETECT_RANGE, CONE_ANGLE_DEG, MAX_Y_DIFF) then
					table.insert(victims, plr)
				end
			end
		end
	end
	return victims
end

--------------------------------------------------------------------------------
-- VFX Functions (Tool 파츠 독립)
--------------------------------------------------------------------------------
local TEX_SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_GLOW = "rbxasset://textures/particles/glow_main.dds"

-- ✅ Tool 의존성 제거
local function GetWandPart(attackerChar)
	local tool = attackerChar:FindFirstChildOfClass("Tool")
	if tool then
		local handle = tool:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then return handle end
	end
	local rh = attackerChar:FindFirstChild("RightHand")
	if rh and rh:IsA("BasePart") then return rh end
	return nil
end

local function PickLongestAxis(part)
	local s = part.Size; local axis = "Y"; local len = s.Y
	if s.X > len then axis = "X"; len = s.X end
	if s.Z > len then axis = "Z"; len = s.Z end
	return axis, len
end
local function AxisVec(axis, v)
	if axis == "X" then return Vector3.new(v, 0, 0)
	elseif axis == "Z" then return Vector3.new(0, 0, v) end
	return Vector3.new(0, v, 0)
end
local function MakeTrail(parentPart)
	local axis, len = PickLongestAxis(parentPart)
	local tipPos = AxisVec(axis, -len * 0.48); local basePos = AxisVec(axis, -len * 0.10)
	local tipAtt = Instance.new("Attachment"); tipAtt.Name = "BB_VFX_Tip"; tipAtt.Position = tipPos; tipAtt.Parent = parentPart
	local baseAtt = Instance.new("Attachment"); baseAtt.Name = "BB_VFX_Base"; baseAtt.Position = basePos; baseAtt.Parent = parentPart
	local wMul = math.clamp(0.85 + 0.45 * VFX_INTENSITY, 0.9, 2.2); local life = math.clamp(WAND_VFX_TRAIL_LIFETIME * (0.85 + 0.25 * VFX_INTENSITY), 0.12, 0.35)
	local trail = Instance.new("Trail"); trail.Name = "BB_VFX_Trail"; trail.Attachment0 = baseAtt; trail.Attachment1 = tipAtt
	trail.Lifetime = life; trail.FaceCamera = true; trail.LightEmission = 1; trail.MinLength = 0.05; trail.Color = VFX_COLOR_SEQ
	trail.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.55, 0.18), NumberSequenceKeypoint.new(1, 1)})
	trail.WidthScale = NumberSequence.new({NumberSequenceKeypoint.new(0, WAND_VFX_TRAIL_WIDTH0 * wMul), NumberSequenceKeypoint.new(0.5, WAND_VFX_TRAIL_WIDTH1 * wMul), NumberSequenceKeypoint.new(1, 0)})
	trail.Enabled = true; trail.Parent = parentPart
	Debris:AddItem(trail, WAND_VFX_DURATION + 0.45); Debris:AddItem(tipAtt, WAND_VFX_DURATION + 0.45); Debris:AddItem(baseAtt, WAND_VFX_DURATION + 0.45)
	return tipAtt
end
local function MakeSparkEmitter(att, isGlow)
	local pe = Instance.new("ParticleEmitter"); pe.Name = isGlow and "BB_VFX_Glow" or "BB_VFX_Spark"; pe.Texture = isGlow and TEX_GLOW or TEX_SPARKLE
	pe.Color = VFX_COLOR_SEQ; pe.LightEmission = 1; pe.Rate = 0
	local speedMul = math.clamp(0.9 + 0.35 * VFX_INTENSITY, 0.9, 2.2)
	pe.Lifetime = NumberRange.new(0.20, 0.55); pe.Speed = NumberRange.new(2.5 * speedMul, 7.5 * speedMul); pe.Rotation = NumberRange.new(0, 360); pe.RotSpeed = NumberRange.new(-320, 320); pe.SpreadAngle = Vector2.new(30, 30); pe.Drag = 2
	if isGlow then
		pe.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 0)}); pe.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(1, 1)})
	else
		pe.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.28), NumberSequenceKeypoint.new(1, 0)}); pe.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.03), NumberSequenceKeypoint.new(1, 1)})
	end
	pe.Parent = att; Debris:AddItem(pe, WAND_VFX_DURATION + 0.8); return pe
end
local function MakeStreakEmitter(att)
	local pe = Instance.new("ParticleEmitter"); pe.Name = "BB_VFX_Streak"; pe.Texture = TEX_GLOW; pe.Color = VFX_COLOR_SEQ; pe.LightEmission = 1; pe.Rate = 0
	local speedMul = math.clamp(1.0 + 0.55 * VFX_INTENSITY, 1.0, 2.8)
	pe.Lifetime = NumberRange.new(0.10, 0.22); pe.Speed = NumberRange.new(10 * speedMul, 18 * speedMul); pe.SpreadAngle = Vector2.new(10, 10); pe.Drag = 5
	pe.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.42), NumberSequenceKeypoint.new(1, 0)}); pe.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(1, 1)})
	pe.Parent = att; Debris:AddItem(pe, WAND_VFX_DURATION + 0.8); return pe
end
local function MakeLightPulse(att)
	local light = Instance.new("PointLight"); light.Name = "BB_VFX_Light"; light.Range = math.floor(14 + 8 * VFX_INTENSITY); light.Brightness = 0; light.Shadows = false; light.Color = VFX_COLOR_HOTPINK; light.Parent = att; Debris:AddItem(light, WAND_VFX_DURATION + 0.8)
	local twIn = TweenService:Create(light, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 3.8 * VFX_INTENSITY })
	local twOut = TweenService:Create(light, TweenInfo.new(math.max(0.10, WAND_VFX_DURATION - 0.06), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0, Range = 0 })
	twIn:Play()
	twIn.Completed:Connect(function() if light and light.Parent then twOut:Play() end end)
end
local function SpawnTipFlashBall(worldPos)
	local p = Instance.new("Part"); p.Name = "BB_VFX_FlashBall"; p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = false; p.Shape = Enum.PartType.Ball; p.Material = Enum.Material.Neon; p.Color = VFX_COLOR_HOTPINK; p.Transparency = 0.15
	local s0 = 0.6 + 0.45 * VFX_INTENSITY; local s1 = 2.4 + 1.6 * VFX_INTENSITY
	p.Size = Vector3.new(s0, s0, s0); p.CFrame = CFrame.new(worldPos); p.Parent = workspace
	TweenService:Create(p, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(s1, s1, s1), Transparency = 1 }):Play()
	Debris:AddItem(p, 0.22)
end
local function PlayWandSwingVFX_Server(attackerChar)
	if not attackerChar then return end
	local wandPart = GetWandPart(attackerChar)
	if not wandPart then return end
	local tipAtt = MakeTrail(wandPart)
	if not tipAtt then return end
	local spark = MakeSparkEmitter(tipAtt, false); local glow = MakeSparkEmitter(tipAtt, true); local streak = MakeStreakEmitter(tipAtt)
	MakeLightPulse(tipAtt)
	local startBurst = math.clamp(math.floor(WAND_VFX_START_BURST * VFX_INTENSITY + 0.5), 0, 260)
	local perTick = math.clamp(math.floor(WAND_VFX_SPARK_PER_TICK * VFX_INTENSITY + 0.5), 0, 80)
	spark:Emit(startBurst); glow:Emit(math.floor(startBurst * 0.55)); streak:Emit(math.floor(startBurst * 0.35))
	task.spawn(function() for _ = 1, 3 do if not tipAtt.Parent then break end; SpawnTipFlashBall(tipAtt.WorldPosition); task.wait(0.05) end end)
	task.spawn(function()
		local t = 0; local interval = math.clamp(WAND_VFX_SPARK_INTERVAL * (1.05 - 0.12 * VFX_INTENSITY), 0.02, 0.08)
		while t < WAND_VFX_DURATION do
			task.wait(interval); t += interval; if not tipAtt.Parent then break end
			spark:Emit(perTick)
			if math.random() < 0.45 then glow:Emit(3 + math.floor(2 * VFX_INTENSITY)) end
			if math.random() < 0.35 then streak:Emit(2 + math.floor(2 * VFX_INTENSITY)) end
		end
	end)
end
local function RaycastGround(excludeChar, originPos)
	local params = RaycastParams.new(); params.FilterType = Enum.RaycastFilterType.Exclude; params.FilterDescendantsInstances = { excludeChar }; params.IgnoreWater = true
	local result = workspace:Raycast(originPos, Vector3.new(0, -16, 0), params)
	if result then return result.Position, result.Normal end
	return nil, nil
end
local function CFrameFromUp(pos, up, forwardHint)
	local upU = (up.Magnitude > 0.001) and up.Unit or Vector3.new(0, 1, 0)
	local f = forwardHint or Vector3.new(0, 0, -1)
	local right = f:Cross(upU)
	if right.Magnitude < 0.01 then right = Vector3.new(1, 0, 0) else right = right.Unit end
	return CFrame.fromMatrix(pos, right, upU)
end
local function PlayVictimGroundCircleVFX_Server(victimChar)
	if not victimChar then return end
	local root = SkillUtil.GetRoot(victimChar)
	if not root then return end
	local castOrigin = root.Position + Vector3.new(0, 3, 0)
	local hitPos, hitNormal = RaycastGround(victimChar, castOrigin)
	local pos = hitPos or (root.Position - Vector3.new(0, 2.5, 0))
	local normal = hitNormal or Vector3.new(0, 1, 0)
	pos += normal.Unit * 0.05
	local disc = Instance.new("Part")
	disc.Name = "BB_VFX_GroundCircle"; disc.Anchored = true; disc.CanCollide = false; disc.CanTouch = false; disc.CanQuery = false; disc.Material = Enum.Material.Neon; disc.Color = VFX_COLOR_HOTPINK; disc.Transparency = GROUND_VFX_ALPHA0; disc.Shape = Enum.PartType.Cylinder; disc.Size = Vector3.new(GROUND_VFX_START_DIA, GROUND_VFX_THICKNESS, GROUND_VFX_START_DIA); disc.CFrame = CFrameFromUp(pos, normal, root.CFrame.LookVector); disc.Parent = workspace
	Debris:AddItem(disc, GROUND_VFX_DURATION + 0.4)
	TweenService:Create(disc, TweenInfo.new(GROUND_VFX_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(GROUND_VFX_END_DIA, GROUND_VFX_THICKNESS, GROUND_VFX_END_DIA), Transparency = 1 }):Play()
	local att = Instance.new("Attachment"); att.Name = "BB_VFX_GroundAtt"; att.Parent = disc; Debris:AddItem(att, GROUND_VFX_DURATION + 0.4)
	local pe = Instance.new("ParticleEmitter"); pe.Name = "BB_VFX_GroundSpark"; pe.Texture = TEX_SPARKLE; pe.Color = VFX_COLOR_SEQ; pe.LightEmission = 1; pe.Rate = 0; pe.Lifetime = NumberRange.new(0.25, 0.55); pe.Speed = NumberRange.new(1.5, 4.5); pe.SpreadAngle = Vector2.new(45, 45); pe.Drag = 2; pe.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(1, 0)}); pe.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.10), NumberSequenceKeypoint.new(1, 1)}); pe.Parent = att; Debris:AddItem(pe, GROUND_VFX_DURATION + 0.4)
	pe:Emit(18)
end
local function PlayVictimMagicBurst_Server(victimChar)
	if not victimChar then return end
	local root = SkillUtil.GetRoot(victimChar)
	if not root then return end
	local att = Instance.new("Attachment"); att.Name = "BB_VFX_VictimAtt"; att.Position = Vector3.new(0, 1.8, 0); att.Parent = root; Debris:AddItem(att, 0.55)
	local spark = MakeSparkEmitter(att, false); local glow = MakeSparkEmitter(att, true); local streak = MakeStreakEmitter(att)
	local burst = math.clamp(math.floor(VICTIM_BURST * (0.9 + 0.35 * VFX_INTENSITY)), 0, 200)
	spark:Emit(burst); glow:Emit(math.floor(burst * 0.45)); streak:Emit(math.floor(burst * 0.25))
end
local function FindHitAuraTemplate()
	local t = Templates:FindFirstChild(AURA_TEMPLATE_NAME)
	if t and (t:IsA("Model") or t:IsA("BasePart")) then return t end
	return nil
end
local function GetFootPart(char)
	local lf = char:FindFirstChild("LeftFoot")
	if lf and lf:IsA("BasePart") then return lf end
	local ll = char:FindFirstChild("Left Leg")
	if ll and ll:IsA("BasePart") then return ll end
	return SkillUtil.GetRoot(char)
end
local function SpawnHitAura(victimPlayer)
	if not victimPlayer or not victimPlayer.Parent then return end
	local char = victimPlayer.Character
	local hum = SkillUtil.GetHumanoid(char)
	if not char or not SkillUtil.IsAlive(hum) then return end
	local template = FindHitAuraTemplate()
	if not template then return end
	local foot = GetFootPart(char)
	if not foot then return end
	local old = char:FindFirstChild(HIT_AURA_NAME)
	if old then old:Destroy() end
	local clone = template:Clone()
	clone.Name = HIT_AURA_NAME
	if clone:IsA("Model") then
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BasePart") then d.CanCollide = false; d.Massless = true end
		end
		clone:PivotTo(foot.CFrame * CFrame.new(0, AURA_OFFSET_Y, 0))
		local wc = Instance.new("WeldConstraint"); wc.Part0 = clone.PrimaryPart; wc.Part1 = foot; wc.Parent = clone.PrimaryPart
		clone.Parent = char
	end
	Debris:AddItem(clone, AURA_LIFETIME)
end

--------------------------------------------------------------------------------
-- Cover 
--------------------------------------------------------------------------------
local function HideCharacterVisuals(character, bagInstance)
	for _, inst in ipairs(character:GetDescendants()) do
		if inst == bagInstance or inst:IsDescendantOf(bagInstance) then continue end
		if inst:IsA("BasePart") then
			if inst:GetAttribute("BB_OldTrans") == nil then inst:SetAttribute("BB_OldTrans", inst.Transparency) end
			if inst:GetAttribute("BB_OldLTM") == nil then inst:SetAttribute("BB_OldLTM", inst.LocalTransparencyModifier) end
			inst.Transparency = 1
			inst.LocalTransparencyModifier = 1
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			if inst:GetAttribute("BB_OldTrans") == nil then inst:SetAttribute("BB_OldTrans", inst.Transparency) end
			inst.Transparency = 1
		end
	end
end

local function RestoreCharacterVisuals(character)
	if not character then return end
	for _, inst in ipairs(character:GetDescendants()) do
		pcall(function()
			if inst:IsA("BasePart") then
				local oldT = inst:GetAttribute("BB_OldTrans")
				if oldT ~= nil then inst.Transparency = oldT; inst:SetAttribute("BB_OldTrans", nil) end
				local oldL = inst:GetAttribute("BB_OldLTM")
				if oldL ~= nil then inst.LocalTransparencyModifier = oldL; inst:SetAttribute("BB_OldLTM", nil) end
			elseif inst:IsA("Decal") or inst:IsA("Texture") then
				local oldT = inst:GetAttribute("BB_OldTrans")
				if oldT ~= nil then inst.Transparency = oldT; inst:SetAttribute("BB_OldTrans", nil) end
			end
		end)
	end
end

local function FadeAndDestroy(inst, fadeTime)
	if not inst or not inst.Parent then return end
	local t = tonumber(fadeTime) or 0.25
	local tweens = {}
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
			table.insert(tweens, TweenService:Create(d, TweenInfo.new(t), { Transparency = 1 }))
		end
	end
	if inst:IsA("BasePart") then table.insert(tweens, TweenService:Create(inst, TweenInfo.new(t), { Transparency = 1 })) end
	for _, tw in ipairs(tweens) do tw:Play() end
	task.delay(t, function() if inst and inst.Parent then inst:Destroy() end end)
end

--------------------------------------------------------------------------------
-- Apply & Cleanup 
--------------------------------------------------------------------------------
local function RemoveBagCover(char)
	if not char or not char.Parent then return end

	char:SetAttribute("BagBlastStunned", false)
	RestoreCharacterVisuals(char)

	local cover = char:FindFirstChild("BagBlast_Cover")
	if cover then
		cover.Name = "BagBlast_Cover_Destroying"
		FadeAndDestroy(cover, COVER_FADE_OUT)
	end

	local effects = char:FindFirstChild("PvpEffects")
	if effects then
		effects:Destroy()
	end

	-- ✅ WalkSpeed는 직접 복원하지 않고 중앙 속도 계산기로 처리
	-- (영수증/풍선 등 다른 스킬 상태가 중첩되어 있어도 올바른 속도 반영됨)
	SkillUtil.UpdateWalkSpeed(char)
end

local function ApplyCoverAndSlow(victimPlayer)
	local char = victimPlayer.Character
	local hum = SkillUtil.GetHumanoid(char)
	local root = SkillUtil.GetRoot(char)
	if not char or not root or not SkillUtil.IsAlive(hum) then return end

	char:SetAttribute("BagBlastStunned", true)
	char:SetAttribute("CCImmunityEndTime", workspace:GetServerTimeNow() + HIT_DURATION + 1.5)

	local effects = char:FindFirstChild("PvpEffects") or Instance.new("Folder")
	effects.Name = "PvpEffects"
	effects.Parent = char

	local cover = char:FindFirstChild("BagBlast_Cover")
	if not cover then
		local t = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild(BAG_TEMPLATE_NAME)
		if t then
			cover = t:Clone()
			cover.Name = "BagBlast_Cover"

			if cover:IsA("Model") then
				if not cover.PrimaryPart then
					for _, d in ipairs(cover:GetDescendants()) do
						if d:IsA("BasePart") then cover.PrimaryPart = d; break end
					end
				end
				cover:PivotTo(root.CFrame * CFrame.new(0, BAG_OFFSET_Y, 0))
			elseif cover:IsA("BasePart") then
				cover.CFrame = root.CFrame * CFrame.new(0, BAG_OFFSET_Y, 0)
			end

			local partsToWeld = {}
			if cover:IsA("BasePart") then table.insert(partsToWeld, cover) end
			for _, d in ipairs(cover:GetDescendants()) do
				if d:IsA("BasePart") then table.insert(partsToWeld, d) end
			end

			for _, d in ipairs(partsToWeld) do
				d.Anchored = false
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
				d.Massless = true

				-- 몸통(Root)에 단단히 용접
				local wc = Instance.new("WeldConstraint")
				wc.Part0 = d
				wc.Part1 = root
				wc.Parent = d
			end

			cover.Parent = char
			if COVER_HIDE_CHARACTER then HideCharacterVisuals(char, cover) end
		end
	end

	-- ✅ [버그수정] 중앙 속도 계산기로 슬로우 적용 (BagBlastStunned=true 상태를 이미 감지함)
	SkillUtil.UpdateWalkSpeed(char)

	local deathConn
	deathConn = hum.Died:Connect(function()
		if deathConn then deathConn:Disconnect() end
		RemoveBagCover(char)
	end)

	task.delay(HIT_DURATION, function()
		if deathConn then deathConn:Disconnect() end
		RemoveBagCover(char)
	end)
end

--------------------------------------------------------------------------------
-- Core 
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Core (Server)
--------------------------------------------------------------------------------
RE_BagSkill.OnServerEvent:Connect(function(player)
	-- 1. 기본 보안 및 스팸(Throttle) 방지
	if player:GetAttribute("InSafeZone") == true then return end
	if not ENABLED then return end
	if not player or not player.Parent then return end
	if not PassThrottle(player) then return end

	-- 2. 장착 중인 무기가 있는지 확인 (비정상적인 스킬 사용 차단)
	if not GetEquippedTool(player) then return end

	-- 3. 스킬 사용 불가 상태 검증 (이미 맞았거나, 쿨타임 중인지 확인)
	if SkillUtil.IsTargetAlreadyHit(player.Character) then return end
	if not CanCast(player) then return end

	-- 4. 쿨타임 적용 (서버 강제)
	player:SetAttribute("BagSkill_NextCastTime", os.clock() + COOLDOWN_SEC)

	-- 📊 [Analytics] PvP 스킬 사용 빈도 추적
	pcall(function()
		-- 이벤트 이름: "Skill_Used", 파라미터 값: "BagBlast" (스킬 고유 이름)
		AnalyticsService:LogCustomEvent(player, "Skill_Used", 1) -- 1은 단순 카운트용
		AnalyticsService:LogCustomEvent(player, "Skill_Used_BagBlast") -- 스킬별 개별 카운트
		--print(string.format("⚔️ [Analytics] 스킬 사용: %s | 스킬명: BagBlast", player.Name))
	end)

	local attackerChar = player.Character
	local attackerHum = SkillUtil.GetHumanoid(attackerChar)
	local attackerRoot = SkillUtil.GetRoot(attackerChar)

	if not attackerRoot or not SkillUtil.IsAlive(attackerHum) then return end

	-- 5. 캐스팅 애니메이션 실행
	PlayCastAnim(player, attackerHum)

	-- 6. 타겟 색출 (핵 방지: 클라이언트의 타겟팅을 믿지 않고 서버가 직접 거리/각도 판정!)
	local victims = GetVictimsInCone(player, attackerRoot)

	-- 💡 7. [핵심 최적화] 무거운 이펙트 연산은 클라이언트로 토스!
	-- 서버 렉의 주범이었던 파티클/트윈 연산을 클라이언트에게 "알아서 그려!" 라고 지시합니다.
	local RE_BagSkillFx = NetworkFolder:FindFirstChild("RE_BagSkillFx")
	if not RE_BagSkillFx then
		-- 만약 RemoteEvent가 없다면 즉석에서 생성
		RE_BagSkillFx = Instance.new("RemoteEvent")
		RE_BagSkillFx.Name = "RE_BagSkillFx"
		RE_BagSkillFx.Parent = NetworkFolder
	end

	-- 모든 유저의 화면에 "누가 스킬을 썼고, 누가 맞았는지" 신호를 보냄
	RE_BagSkillFx:FireAllClients("PlayVFX", player, victims)

	-- 8. 실제 게임플레이(물리/상태이상) 판정 적용
	for _, v in ipairs(victims) do
		-- 아이템 떨구기 (핵 방어를 위해 서버가 강제 수행)
		LootDropService:DropCarriedItem(v, player)

		-- 슬로우 및 가방 씌우기 (물리/속도에 영향을 주므로 서버가 수행)
		ApplyCoverAndSlow(v)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastReqAtByUserId[player.UserId] = nil
	StopPrevCastAnim(player.UserId)
end)