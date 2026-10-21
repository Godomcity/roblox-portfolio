-- StarterPlayerScripts/Controllers/BagBlastVFXController.lua (ModuleScript)
local BagBlastVFXController = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")

local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local RE_BagSkillFx = NetworkFolder:WaitForChild("RE_BagSkillFx")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))
local Templates = ReplicatedStorage:WaitForChild("Templates")

local CFG = (Constants.PVP and Constants.PVP.BAG_BLAST) or {}

-- -----------------------------------------------------------------------------
-- [일반 VFX 설정값]
-- -----------------------------------------------------------------------------
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
local AURA_TEMPLATE_NAME = tostring(CFG.AURA_TEMPLATE_NAME or "Aura")
local AURA_LIFETIME = tonumber(CFG.AURA_LIFETIME) or 2.0
local AURA_OFFSET_Y = tonumber(CFG.AURA_OFFSET_Y) or 2.55
local HIT_AURA_NAME = "BagBlast_HitAura"

local TEX_SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_GLOW = "rbxasset://textures/particles/glow_main.dds"

-- -----------------------------------------------------------------------------
-- 💡 [1인칭 피격(Victim) 효과 설정값]
-- -----------------------------------------------------------------------------
--local LocalPlayer = Players.LocalPlayer
--local Camera = workspace.CurrentCamera

--local VICTIM_FOV_STUNNED = 50 -- 💡 (강화됨) 기존 55보다 조금 더 좁혀서 압박감 증가
--local VICTIM_FOV_DEFAULT = 70
--local VICTIM_BAG_TEXTURE_ID = "rbxassetid://102031569943149"
--local VICTIM_TINT_COLOR = Color3.fromRGB(250, 70, 110) 
--local VICTIM_BRIGHTNESS = -0.15
--local VICTIM_CONTRAST = 0.35 -- 💡 [신규] 명암 대비를 올려 어질어질한 느낌 추가
--local VICTIM_BLUR_SIZE = 12  -- 💡 [신규] 앞이 뿌옇게 안 보이게 만드는 블러 수치

----local victimGui = nil
----local victimImage = nil
--local victimColorCorrection = nil
--local victimBlur = nil
--local activeVictimTweens = {}
--local victimTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
--local pulseTweenInfo = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true) -- 무한 반복(울렁거림)

-- -----------------------------------------------------------------------------
-- [1인칭 피격 효과 (Victim VFX) 로직]
-- -----------------------------------------------------------------------------
--local function StopVictimTweens()
--	for _, tw in ipairs(activeVictimTweens) do
--		tw:Cancel()
--	end
--	table.clear(activeVictimTweens)
--end

--local function SetupVictimScreenVFX()
--	if not victimGui then
--		victimGui = Instance.new("ScreenGui")
--		victimGui.Name = "BagBlastVictimVignette"
--		victimGui.IgnoreGuiInset = true
--		victimGui.DisplayOrder = 100
--		victimGui.Enabled = false
--		victimGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

--		victimImage = Instance.new("ImageLabel")
--		victimImage.Size = UDim2.fromScale(1, 1)
--		-- 💡 가방이 울렁거릴 때 여백이 보이지 않도록 앵커 포인트를 중앙으로 맞춤
--		victimImage.AnchorPoint = Vector2.new(0.5, 0.5) 
--		victimImage.Position = UDim2.fromScale(0.5, 0.5)
--		victimImage.BackgroundTransparency = 1
--		victimImage.Image = VICTIM_BAG_TEXTURE_ID
--		victimImage.ImageTransparency = 1
--		victimImage.ScaleType = Enum.ScaleType.Stretch
--		victimImage.Parent = victimGui
--	end

--	if not victimColorCorrection then
--		victimColorCorrection = Instance.new("ColorCorrectionEffect")
--		victimColorCorrection.Name = "BagBlastColorCorrection"
--		victimColorCorrection.Enabled = false
--		victimColorCorrection.Parent = Lighting
--	end

--	if not victimBlur then
--		victimBlur = Instance.new("BlurEffect")
--		victimBlur.Name = "BagBlastBlur"
--		victimBlur.Size = 0
--		victimBlur.Enabled = false
--		victimBlur.Parent = Lighting
--	end
--end

--local function ToggleVictimVFX(isStunned)
--	Camera = workspace.CurrentCamera
--	--SetupVictimScreenVFX()
--	StopVictimTweens()

--	if isStunned then
--		-- 1. GUI 켜기 및 반투명 트윈
--		victimGui.Enabled = true
--		local twGui = TweenService:Create(victimImage, victimTweenInfo, {ImageTransparency = 0.3}) -- 💡 좀 더 짙게(0.3) 가림
--		table.insert(activeVictimTweens, twGui)
--		twGui:Play()

--		-- 💡 [신규] 패닉 상태 연출 (화면이 미세하게 심장박동처럼 울렁거림)
--		victimImage.Size = UDim2.fromScale(1, 1)
--		local twPulse = TweenService:Create(victimImage, pulseTweenInfo, {Size = UDim2.fromScale(1.08, 1.08)})
--		table.insert(activeVictimTweens, twPulse)
--		twPulse:Play()

--		-- 2. 카메라 FOV 좁히기 (줌인)
--		local twFov = TweenService:Create(Camera, victimTweenInfo, {FieldOfView = VICTIM_FOV_STUNNED})
--		table.insert(activeVictimTweens, twFov)
--		twFov:Play()

--		-- 3. 조명(Lighting) 색감, 명도, 대비 왜곡
--		victimColorCorrection.Enabled = true
--		local twCC = TweenService:Create(victimColorCorrection, victimTweenInfo, {
--			Brightness = VICTIM_BRIGHTNESS, 
--			TintColor = VICTIM_TINT_COLOR,
--			Contrast = VICTIM_CONTRAST
--		})
--		table.insert(activeVictimTweens, twCC)
--		twCC:Play()

--		-- 4. 💡 [신규] 블러 효과 켜기 (시야 흐림)
--		victimBlur.Enabled = true
--		local twBlur = TweenService:Create(victimBlur, victimTweenInfo, {Size = VICTIM_BLUR_SIZE})
--		table.insert(activeVictimTweens, twBlur)
--		twBlur:Play()

--	else
--		-- 1. GUI 서서히 끄기
--		local twGui = TweenService:Create(victimImage, victimTweenInfo, {ImageTransparency = 1, Size = UDim2.fromScale(1, 1)})
--		table.insert(activeVictimTweens, twGui)
--		twGui:Play()
--		twGui.Completed:Connect(function()
--			if not LocalPlayer.Character or LocalPlayer.Character:GetAttribute("BagBlastStunned") ~= true then
--				victimGui.Enabled = false
--			end
--		end)

--		-- 2. 카메라 FOV 기본값 복구
--		local twFov = TweenService:Create(Camera, victimTweenInfo, {FieldOfView = VICTIM_FOV_DEFAULT})
--		table.insert(activeVictimTweens, twFov)
--		twFov:Play()

--		-- 3. 조명 색감 복구
--		local twCC = TweenService:Create(victimColorCorrection, victimTweenInfo, {
--			Brightness = 0, 
--			TintColor = Color3.new(1, 1, 1),
--			Contrast = 0
--		})
--		table.insert(activeVictimTweens, twCC)
--		twCC:Play()
--		twCC.Completed:Connect(function()
--			if not LocalPlayer.Character or LocalPlayer.Character:GetAttribute("BagBlastStunned") ~= true then
--				victimColorCorrection.Enabled = false
--			end
--		end)

--		-- 4. 💡 블러 효과 서서히 끄기
--		local twBlur = TweenService:Create(victimBlur, victimTweenInfo, {Size = 0})
--		table.insert(activeVictimTweens, twBlur)
--		twBlur:Play()
--		twBlur.Completed:Connect(function()
--			if not LocalPlayer.Character or LocalPlayer.Character:GetAttribute("BagBlastStunned") ~= true then
--				victimBlur.Enabled = false
--			end
--		end)
--	end
--end

-- 로컬 캐릭터 속성 감지 바인딩
--local function BindLocalCharacter(character)
--	if not character then return end

--	-- 기존 켜진 이펙트 초기화
--	ToggleVictimVFX(false)

--	character:GetAttributeChangedSignal("BagBlastStunned"):Connect(function()
--		local isStunned = character:GetAttribute("BagBlastStunned") == true
--		ToggleVictimVFX(isStunned)
--	end)
--end

-- -----------------------------------------------------------------------------
-- [스킬 투사체 및 환경 VFX 함수 모음]
-- -----------------------------------------------------------------------------
local function GetWandPart(character)
	local tool = character:FindFirstChildOfClass("Tool")
	if tool then
		local handle = tool:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then return handle end
	end
	local rh = character:FindFirstChild("RightHand")
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

local function PlayWandSwingVFX_Client(attackerChar)
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

local function PlayVictimGroundCircleVFX_Client(victimChar)
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

local function PlayVictimMagicBurst_Client(victimChar)
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

-- -----------------------------------------------------------------------------
-- [초기화 & 이벤트 리스너 바인딩]
-- -----------------------------------------------------------------------------
function BagBlastVFXController:Init()
	RE_BagSkillFx.OnClientEvent:Connect(function(action, attackerPlayer, victims)
		if action == "PlayVFX" then
			-- 1. 공격자 지팡이 모션 렌더링
			if attackerPlayer and attackerPlayer.Character then
				PlayWandSwingVFX_Client(attackerPlayer.Character)
			end

			-- 2. 피해자 주변 폭발, 아우라 렌더링
			if victims and type(victims) == "table" then
				for _, victimPlayer in ipairs(victims) do
					if victimPlayer and victimPlayer.Character then
						local vChar = victimPlayer.Character
						PlayVictimGroundCircleVFX_Client(vChar)
						SpawnHitAura(victimPlayer)
						if VFX_IMPACT_ENABLED then
							PlayVictimMagicBurst_Client(vChar)
						end
					end
				end
			end
		end
	end)
end

function BagBlastVFXController:Start()
	-- 자신의 피격 상태 추적
	--if LocalPlayer.Character then
	--	BindLocalCharacter(LocalPlayer.Character)
	--end
	--LocalPlayer.CharacterAdded:Connect(BindLocalCharacter)
end

return BagBlastVFXController