-- SkillService: server-authoritative skill casting + unified fragment drops + book binding/leveling.
-- All damage goes through CombatService ledger. Fragment roll is independent from LootService material roll.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Defs = ReplicatedStorage:WaitForChild("Defs")
local SkillDefs = require(Defs:WaitForChild("SkillDefs"))
local MonsterDefs = require(Defs:WaitForChild("MonsterDefs"))
local WeaponDefs = require(Defs:WaitForChild("WeaponDefs"))
local AVDefs = require(Defs:WaitForChild("AVDefs")) -- [2026-08-27] 그립 C0 역산 칼날축(BladeAxisOf) -- [2026-08-05 스킬8종] 검비 ★4 파생조건 판정용
local Strings = require(Defs:WaitForChild("Strings"))
local Net = require(ReplicatedStorage:WaitForChild("Net"))

local SkillService = {}

-- [2026-08-06] 몬스터 처치 시 회복되는 마나(자격 통과자 전원)
local KILL_MP_RESTORE = 4

-- [2026-07-31] 서버가 만드는 스킬 알림은 수신자 로케일 기준으로 조회 — 영어 오버레이(Loc.applyDefsEn)는 클라 전용이라 그냥 두면 영어 모드에서도 한국어로 나간다(TitleService·BadgeService 선례)
local function skillTextFor(player, key)
	return Strings.defsFor(player, "SkillDefs.TEXT." .. key) or SkillDefs.TEXT[key]
end

local function skillNameFor(player, skillId, def)
	return Strings.defsFor(player, "SkillDefs.Skills." .. tostring(skillId) .. ".NameKo") or def.NameKo
end

local PlayerService
local DataService
local CombatService
local LootService
local PurchaseService
local DailyGoalService
local AnalyticsService -- [2026-07-27 M5] SkillCast 60초 배치

local lastCastAt = {} -- [player] = { [skillId] = os.clock }
local castIngress = {}
local castInFlight = {}
local CAST_BURST = 6
local CAST_REFILL_PER_SEC = 4

local function allowCastIngress(player)
	local now = os.clock()
	local state = castIngress[player]
	if not state then
		state = { tokens = CAST_BURST, at = now }
		castIngress[player] = state
	end
	state.tokens = math.min(CAST_BURST, state.tokens + (now - state.at) * CAST_REFILL_PER_SEC)
	state.at = now
	if state.tokens < 1 then
		return false
	end
	state.tokens -= 1
	return true
end

local MONSTER_TAG = "Monster"
local VERTICAL_PAD = 6
-- [2026-07-29 감사 G3] 연출·패킷 상한 = SkillDefs.MaxTargets와 동일한 6(관통 자체는 유지).
-- 열파참 PierceByLevel=999라 밀집 구간에서 1회 시전에 MonsterHit이 무제한 발화한다.
local FX_TARGET_MAX = 6
local FRAG_ID = SkillDefs.FRAG_ID

local autoFillSlots -- 전방 선언: 정의는 assignAs 위지만 grantDefaults가 먼저 호출한다

-- [2026-07-29 감사 D2] 후보 풀 캐시(CombatService.monsterCandidates와 동일 규약) — 캐시하는 건 모델 구조(hum·root·pad)뿐.
-- 🔴생존·은신·소속 판정은 monsterEntries가 매 호출 실시간으로 다시 한다(반환 의미 불변)
local ENTRY_TTL = 0.1
local entryPool = {}
local entryPoolAt = -1

local function refreshEntryPool()
	local now = os.clock()
	if now - entryPoolAt < ENTRY_TTL then
		return
	end
	entryPoolAt = now
	table.clear(entryPool)
	for _, model in ipairs(CollectionService:GetTagged(MONSTER_TAG)) do
		if model:IsA("Model") then
			local hum = model:FindFirstChildOfClass("Humanoid")
			local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
			if hum and root then
				local pad = model:GetAttribute("HitRadius")
				if type(pad) ~= "number" then
					pad = 2
				end
				table.insert(entryPool, { model = model, hum = hum, root = root, pad = pad })
			end
		end
	end
end

local function monsterEntries()
	refreshEntryPool()
	local list = {}
	-- [2026-07-22] Untargetable: 벽돌대왕 1페 은신 본체 제외(CombatService.findTargets와 동일 규약)
	for _, e in ipairs(entryPool) do
		if e.model:IsDescendantOf(Workspace) and e.hum.Health > 0
			and e.model:GetAttribute("Untargetable") ~= true then
			table.insert(list, e)
		end
	end
	return list
end

local function verticalOk(entry, originY)
	local halfH = entry.model:GetAttribute("HalfHeight")
	if type(halfH) ~= "number" then
		local _, size = entry.model:GetBoundingBox()
		halfH = size.Y * 0.5
		entry.model:SetAttribute("HalfHeight", halfH) -- 타 스포너 모델 자가 캐시
	end
	return math.abs(entry.root.Position.Y - originY) <= halfH + VERTICAL_PAD
end

-- 지면 스냅 레이캐스트 공용 파라미터 — 몬스터·플레이어를 빼지 않으면 장판이 머리 위에 얹힌다(2026-08-06)
local function groundRayParams(extra)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local list = {}
	for _, m in ipairs(CollectionService:GetTagged(MONSTER_TAG)) do
		table.insert(list, m)
	end
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl.Character then
			table.insert(list, pl.Character)
		end
	end
	if extra then
		for _, inst in ipairs(extra) do
			table.insert(list, inst)
		end
	end
	rp.FilterDescendantsInstances = list
	return rp
end

local invalidHitDefCallers = {}

local function applyHit(player, atk, def, entry, order, knockFrom, damageOrigin)
	if type(def) ~= "table" or type(def.DamagePct) ~= "number" or type(def.Falloff) ~= "number" then
		local source, line = debug.info(2, "sl")
		local caller = ("%s:%s"):format(tostring(source), tostring(line))
		if not invalidHitDefCallers[caller] then
			invalidHitDefCallers[caller] = true
			warn("[SkillService] applyHit 피해 정의 누락: " .. caller)
		end
		return 0
	end
	if entry.hum.Health <= 0 then
		return 0
	end
	local mult = (order == 1) and 1 or def.Falloff
	local dmg = math.floor(atk * def.DamagePct * mult + 0.5)
	local mdef = MonsterDefs[entry.model:GetAttribute("MonsterId")]
	if dmg <= 0 then
		return 0
	end
	-- _damageAs 내부 콜백은 피해 확정 직후·처치 정산 전에 동기 실행된다.
	local hpOrFalse, dealt = CombatService._damageAs(player, entry.model, dmg, damageOrigin,
		function(confirmedHealth, actualDamage, confirmedMaxHealth)
			dmg = actualDamage or dmg
			local hitOrder = order or 1
			-- 피해는 전 대상에 적용하고 연출만 앞쪽 대상에 제한한다.
			if hitOrder <= FX_TARGET_MAX then
				local pos = entry.root.Position + Vector3.new(0, 1, 0)
				local impactOrigin = typeof(damageOrigin) == "Vector3" and damageOrigin or nil
				if not impactOrigin then
					local character = player.Character
					local playerRoot = character and character:FindFirstChild("HumanoidRootPart")
					impactOrigin = playerRoot and playerRoot.Position or nil
				end
				local impactDelta = impactOrigin and (entry.root.Position - impactOrigin) or Vector3.zero
				local impactDir = impactDelta.Magnitude > 0.001 and impactDelta.Unit or Vector3.new(0, 1, 0)
				Net.Event("MonsterHit"):FireClient(player, {
					pos = pos,
					model = entry.model,
					crit = false,
					dmg = dmg,
					monsterId = entry.model:GetAttribute("MonsterId"),
					source = "Skill",
					impactDir = impactDir,
					attackKind = "Skill",
					finisher = false,
					kill = confirmedHealth <= 0,
					health = math.max(confirmedHealth, 0),
					maxHealth = tonumber(confirmedMaxHealth) or entry.hum.MaxHealth,
					order = hitOrder,
				})
			end
			if knockFrom and confirmedHealth > 0 and entry.hum.Health > 0 and (not mdef or mdef.IsBoss ~= true) then
				pcall(function()
					require(script.Parent.MonsterService).ApplyHitKnockback(entry.model, knockFrom)
				end)
			end
		end)
	if hpOrFalse == false then
		return 0
	end
	dmg = dealt or dmg
	return dmg
end

local function castWaveOnce(player, atk, def, origin, dir, pierce)
	local hits = {}
	for _, entry in ipairs(monsterEntries()) do
		local off = entry.root.Position - origin
		local flat = Vector3.new(off.X, 0, off.Z)
		local along = flat:Dot(dir)
		if along >= 0 and along <= def.Range + entry.pad and verticalOk(entry, origin.Y) then
			local perp = (flat - dir * along).Magnitude
			if perp <= def.Width * 0.5 + entry.pad then
				table.insert(hits, { entry = entry, along = along })
			end
		end
	end
	table.sort(hits, function(a, b)
		return a.along < b.along
	end)
	while #hits > pierce do
		table.remove(hits)
	end
	for order, hit in ipairs(hits) do
		task.delay(math.max(0, hit.along) / def.Speed, function()
			applyHit(player, atk, def, hit.entry, order, origin, origin)
		end)
	end
end

local function castWave(player, atk, def, origin, dir, level)
	local pierce = (def.PierceByLevel and def.PierceByLevel[level]) or def.MaxTargets
	local waves = (def.WavesByLevel and def.WavesByLevel[level]) or 1
	if waves <= 1 then
		castWaveOnce(player, atk, def, origin, dir, pierce)
		return
	end
	local spread = math.rad(12)
	for i = 1, waves do
		local ang = (i - (waves + 1) / 2) * spread
		local c, s = math.cos(ang), math.sin(ang)
		local rdir = Vector3.new(dir.X * c - dir.Z * s, 0, dir.X * s + dir.Z * c)
		rdir = (rdir.Magnitude > 0.01) and rdir.Unit or dir
		castWaveOnce(player, atk, def, origin, rdir, pierce)
	end
end

local function castWhirlwind(player, atk, def, root, level)
	local radius = (def.RadiusByLevel and def.RadiusByLevel[level]) or def.Radius
	local ticks = (def.TicksByLevel and def.TicksByLevel[level]) or def.Ticks
	-- [2026-08-09 사장님 지시] 회전 채널 동안 이동 가속 — 클라 MovementController가 SkillSpeedMul 어트리뷰트를 WalkSpeed에 곱산.
	-- 해제는 별도 task.delay(루프 조기 종료·사망과 무관하게 확정 해제). 쿨(6s) > 채널(2.0~2.8s)이라 중첩 불가.
	player:SetAttribute("SkillSpeedMul", def.SpinSpeedMul or 1.35)
	task.delay(ticks * def.TickSec + 0.1, function()
		if player.Parent then
			player:SetAttribute("SkillSpeedMul", nil)
		end
	end)
	task.spawn(function()
		for i = 1, ticks do
			local character = player.Character
			local hum = character and character:FindFirstChildOfClass("Humanoid")
			if not root.Parent or not hum or hum.Health <= 0 then
				return
			end
			local origin = root.Position
			local hits = {}
			for _, entry in ipairs(monsterEntries()) do
				local off = entry.root.Position - origin
				local dist = Vector3.new(off.X, 0, off.Z).Magnitude
				if dist <= radius + entry.pad and verticalOk(entry, origin.Y) then
					table.insert(hits, { entry = entry, dist = dist })
				end
			end
			table.sort(hits, function(a, b)
				return a.dist < b.dist
			end)
			while #hits > def.MaxTargets do
				table.remove(hits)
			end
			local knockFrom = (i == ticks) and origin or nil
			for order, hit in ipairs(hits) do
				applyHit(player, atk, def, hit.entry, order, knockFrom, origin)
			end
			if i < ticks then
				task.wait(def.TickSec)
			end
		end
	end)
end

-- 끓어당기기: 반경 내 몹을 시전자쪽으로(몹 기준 플레이어 반대편 지점을 넘백원으로) + 경피해
-- [2026-08-09 사장님 지시] 플레이어 위치가 아니라 정면 GatherDist(10) 지점으로 집결 — 황금당근·진흙늪·검비(전방 10)와 연계 콤보용
local function castPull(player, atk, def, root, dir, level)
	local origin = root.Position
	local gather = origin + dir * (def.GatherDist or 10) -- 집결점(범위 스캔은 기존대로 시전자 중심)
	local MonsterService = require(script.Parent.MonsterService)
	-- [2026-07-23] leveling: range/pulled-count grow by level (SkillDefs.RadiusByLevel/PullCountByLevel)
	local radius = (def.RadiusByLevel and def.RadiusByLevel[level]) or def.Radius
	local maxPull = (def.PullCountByLevel and def.PullCountByLevel[level]) or def.MaxTargets
	local hits = {}
	for _, entry in ipairs(monsterEntries()) do
		local off = entry.root.Position - origin
		local dist = Vector3.new(off.X, 0, off.Z).Magnitude
		if dist <= radius + entry.pad and verticalOk(entry, origin.Y) then
			table.insert(hits, { entry = entry, dist = dist })
		end
	end
	table.sort(hits, function(a, b)
		return a.dist < b.dist
	end)
	while #hits > maxPull do
		table.remove(hits)
	end
	-- [2026-07-22] mirror(몸 너머편)을 넉백 원점으로 줘야 플레이어 쪽으로 끌린다(def.PullForce).
	-- [2026-08-03 라이브 QA] 고정 임펄스 아닌 거리 비례 — 몹별 Speed=(거리-StopGap)/StunSec로 전원이 시전자 앞 StopGap에 정렬. StopGap 안쪽은 넉백 생략(오버슈팅 방지).
	local pf = def.PullForce
	for order, hit in ipairs(hits) do
		local mpos = hit.entry.root.Position
		local toGather = Vector3.new(gather.X - mpos.X, 0, gather.Z - mpos.Z).Magnitude -- 집결점 기준 거리(수평)
		local travel = toGather - pf.StopGap
		if travel > 0.5 then
			local mirror = mpos + (mpos - gather) -- 집결점 반대편 = 넘백 원점 → 집결점으로 끌림
			local speed = math.min(travel / pf.StunSec, pf.MaxSpeed)
			pcall(function()
				MonsterService.ApplyHitKnockback(hit.entry.model, mirror,
					{ Speed = speed, UpSpeed = pf.UpSpeed, StunSec = pf.StunSec, Sustain = true, SourcePos = origin })
			end)
		end
		applyHit(player, atk, def, hit.entry, order, nil, origin)
	end
end

-- [2026-08-05 스킬8종 명세 §6-8] 배열 조회 헬퍼 — 길이 초과는 경고+클램프(라이브 경로 assert 금지)
local function arrAt(arr, lv, fallback)
	if type(arr) ~= "table" or #arr == 0 then
		return fallback
	end
	if lv > #arr then
		warn(("[SkillDefs] 배열 길이 초과 lv=%d #arr=%d"):format(lv, #arr))
	end
	return arr[math.clamp(lv, 1, #arr)]
end

-- [2026-08-05 스킬8종] 황금 당근 연출 — 이식 CarrotServer 원본 보존(서버 월드 FX = 전 클라 가시).
-- 판정은 여기 없다 — castGoldenCarrot이 applyHit(_damageAs 원장)으로 별도 수행.
local function carrotRiseFx(origin, radius, riseSec)
	local src = ReplicatedStorage:FindFirstChild("SkillFx_GoldCarrot")
	if not src then
		return
	end
	local TweenService = game:GetService("TweenService")
	local Debris = game:GetService("Debris")
	local RunService = game:GetService("RunService")
	local fxFolder = Instance.new("Folder")
	fxFolder.Name = "SkillFx_GoldenCarrot"
	fxFolder.Parent = Workspace
	-- 지면 스냅: 시전 지점 기준 상대 레이캐스트(절대높이 금지 규약)
	local rp = groundRayParams({ fxFolder })
	local res = Workspace:Raycast(origin + Vector3.new(0, 30, 0), Vector3.new(0, -120, 0), rp)
	local gy = res and res.Position.Y or (origin.Y - 3)
	local c = src:Clone()
	c.Anchored = true; c.CanCollide = false; c.CanQuery = false; c.CanTouch = false; c.CastShadow = false
	c.Size = src.Size * (15 * (radius / 8)) -- 레벨 반경 비례 시각 크기(기본 반경8=원본 15배)
	local rotCF = CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
	local height = c.Size.Y
	local startY = gy - height / 2
	local endY = gy -- 절반 노출(원본 EMERGE_FRACTION 0.5)
	c:PivotTo(CFrame.new(origin.X, startY, origin.Z) * rotCF)
	c.Parent = fxFolder
	-- [2026-08-09 사장님 지시①] 당근 모델 Highlight 제거(육안 과포화) — 더스트·파편 연출은 유지
	local host = Instance.new("Part")
	host.Transparency = 1; host.Size = Vector3.one; host.Anchored = true; host.CanCollide = false
	host.Position = Vector3.new(origin.X, gy + 0.3, origin.Z); host.Parent = fxFolder
	local att = Instance.new("Attachment"); att.Parent = host
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	dust.Color = ColorSequence.new(Color3.fromRGB(150, 120, 80))
	dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	dust.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 11) })
	dust.Lifetime = NumberRange.new(0.5, 0.9); dust.Speed = NumberRange.new(12, 20)
	dust.SpreadAngle = Vector2.new(70, 70); dust.Acceleration = Vector3.new(0, -8, 0)
	dust.Enabled = false; dust.Parent = att
	dust:Emit(26)
	Debris:AddItem(host, 1.1)
	for _ = 1, 14 do
		local piece = Instance.new("Part")
		piece.Size = Vector3.new(math.random(6, 18) / 10, math.random(6, 18) / 10, math.random(6, 18) / 10)
		piece.Color = Color3.fromRGB(115, 88, 55); piece.Material = Enum.Material.Ground
		piece.CanCollide = false; piece.CastShadow = false
		piece.Position = Vector3.new(origin.X + (math.random() - 0.5) * 5, gy + 0.5, origin.Z + (math.random() - 0.5) * 5)
		piece.Parent = fxFolder
		local a = math.random() * math.pi * 2
		piece.AssemblyLinearVelocity = Vector3.new(math.cos(a) * math.random(10, 26), math.random(18, 36), math.sin(a) * math.random(10, 26))
		piece.AssemblyAngularVelocity = Vector3.new(math.random(-12, 12), math.random(-12, 12), math.random(-12, 12))
		Debris:AddItem(piece, 1.5)
	end
	task.spawn(function()
		local t = 0
		while t < riseSec do
			local dt = RunService.Heartbeat:Wait()
			t += dt
			local a = math.min(t / riseSec, 1)
			local ea = 1 - (1 - a) ^ 2
			c:PivotTo(CFrame.new(origin.X, startY + (endY - startY) * ea, origin.Z) * rotCF)
		end
		task.wait(1.2) -- 원본 HOLD
		local t2 = 0
		while t2 < 0.35 do
			local dt = RunService.Heartbeat:Wait()
			t2 += dt
			local a = math.min(t2 / 0.35, 1)
			c:PivotTo(CFrame.new(origin.X, endY + (startY - endY) * a, origin.Z) * rotCF)
		end
		if fxFolder.Parent then
			fxFolder:Destroy()
		end
	end)
end

-- [2026-08-05 스킬8종 §5-1/§6-1] 황금 당근: 전방 CastDist 고정 지점 반경 단발 광역.
-- 🔴시전 좌표 고정(§0-4 함정5) — root 재조회 금지. 판정 시점 = RiseSec(솔아오른 순간).
local function castGoldenCarrot(player, atk, def, root, dir, level)
	local radius = arrAt(def.RadiusByLevel, level, def.Radius)
	local castDist = arrAt(def.CastDistByLevel, level, def.CastDist)
	local falloff = arrAt(def.FalloffByLevel, level, def.Falloff)
	local attackerOrigin = root.Position
	local origin = attackerOrigin + dir * castDist
	carrotRiseFx(origin, radius, def.RiseSec or 0.5)
	-- FalloffByLevel은 applyHit이 def.Falloff를 읽으므로 오버레이 def로 전달(원본 def 불변)
	local edef = setmetatable({ Falloff = falloff }, { __index = def })
	task.delay(def.RiseSec or 0.5, function()
		local hits = {}
		for _, entry in ipairs(monsterEntries()) do
			local off = entry.root.Position - origin
			local dist = Vector3.new(off.X, 0, off.Z).Magnitude
			if dist <= radius + entry.pad and verticalOk(entry, origin.Y) then
				table.insert(hits, { entry = entry, dist = dist })
			end
		end
		table.sort(hits, function(a, b)
			return a.dist < b.dist
		end)
		while #hits > def.MaxTargets do
			table.remove(hits)
		end
		if #hits == 0 then
			-- [명세 §10-1/§11] 타격 0 관측(hit_count=0 알람용) — 60초 배치
			AnalyticsService.Batch(player, "SkillCastHit0", 1, "GoldenCarrot")
		end
		for order, hit in ipairs(hits) do
			applyHit(player, atk, edef, hit.entry, order, origin, attackerOrigin)
		end
	end)
end

-- [2026-08-05 스킬8종] 볏짚 굴리기 연출 — 이식 StrawRollServer 원본 보존(서버 월드 FX·지형추종 굴림).
-- 판정은 castStrawRoll이 경로 스냅샷+도달시간 applyHit으로 별도 수행(castWaveOnce 규약).
local function strawRollFx(casterChar, origin, dir, range, speed, appearSec)
	local src = ReplicatedStorage:FindFirstChild("SkillFx_Straw01")
	if not src then
		return
	end
	local TweenService = game:GetService("TweenService")
	local Debris = game:GetService("Debris")
	local RunService = game:GetService("RunService")
	local fxFolder = Instance.new("Folder")
	fxFolder.Name = "SkillFx_StrawRoll"
	fxFolder.Parent = Workspace
	local refY = origin.Y
	local strawRp = groundRayParams({ casterChar, fxFolder })
	local function floorY(x, z)
		local res = Workspace:Raycast(Vector3.new(x, refY + 60, z), Vector3.new(0, -300, 0), strawRp)
		local gy = res and res.Position.Y or (refY - 3)
		return math.clamp(gy, refY - 8, refY + 8) -- 절벽·구덩이에서 볏짚이 멀리 떨어지지 않게 시전 높이 기준 클램프
	end
	local up = Vector3.new(0, 1, 0)
	local rightVec = Vector3.new(-dir.Z, 0, dir.X)
	local fullSize = src.Size
	local c = src:Clone()
	c.Anchored = true; c.CanCollide = false; c.CanQuery = false; c.CanTouch = false; c.CastShadow = true
	c.Size = fullSize
	c.Parent = fxFolder
	local function setCF(dist, theta)
		local px, pz = origin.X + dir.X * dist, origin.Z + dir.Z * dist
		local gy = floorY(px, pz)
		local radius = c.Size.Z / 2
		c.CFrame = CFrame.fromMatrix(Vector3.new(px, gy + radius, pz), rightVec, up) * CFrame.Angles(theta, 0, 0)
	end
	local hl = Instance.new("Highlight")
	hl.FillColor = Color3.fromRGB(255, 225, 120); hl.FillTransparency = 0.35
	hl.OutlineColor = Color3.fromRGB(255, 245, 200); hl.OutlineTransparency = 0.1
	hl.Parent = c
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 225, 120); light.Brightness = 6; light.Range = 24; light.Parent = c
	local rollAtt = Instance.new("Attachment"); rollAtt.Parent = c; rollAtt.Position = Vector3.new(0, -fullSize.Z / 2, 0)
	local rollDust = Instance.new("ParticleEmitter")
	rollDust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	rollDust.Color = ColorSequence.new(Color3.fromRGB(210, 190, 120))
	rollDust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
	rollDust.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 8) })
	rollDust.Lifetime = NumberRange.new(0.3, 0.6); rollDust.Rate = 40
	rollDust.Speed = NumberRange.new(4, 10); rollDust.SpreadAngle = Vector2.new(40, 40)
	rollDust.Acceleration = Vector3.new(0, -5, 0); rollDust.Enabled = false; rollDust.Parent = rollAtt
	task.spawn(function()
		-- Phase 1: 빛나며 팝업(원본 APPEAR 0.25)
		local t = 0
		while t < appearSec do
			local dt = RunService.Heartbeat:Wait()
			t += dt
			local a = math.min(t / appearSec, 1)
			c.Size = fullSize * (0.4 + 0.6 * a)
			setCF(0, 0)
		end
		c.Size = fullSize
		hl.FillTransparency = 0.6
		rollDust.Enabled = true
		-- Phase 2: 굴러감(지형추종 · 굴림각 = 거리/반지름)
		local dist = 0
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			dist = math.min(dist + speed * dt, range)
			local radius = c.Size.Z / 2
			setCF(dist, -dist / radius)
			if dist >= range then
				conn:Disconnect()
				rollDust.Enabled = false
				light.Enabled = false
				TweenService:Create(hl, TweenInfo.new(0.35), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
				local t2 = 0
				local fade
				fade = RunService.Heartbeat:Connect(function(d2)
					t2 += d2
					c.Transparency = math.min(t2 / 0.35, 1)
					if t2 >= 0.35 then
						fade:Disconnect()
						if fxFolder.Parent then
							fxFolder:Destroy()
						end
					end
				end)
			end
		end)
	end)
	Debris:AddItem(fxFolder, appearSec + range / speed + 2)
end

-- [2026-08-05 스킬8종 §5-1/§6-1] 볏짚 굴리기: SpawnOffset 지점부터 경로 관통(대상당 1히트·MaxTargets 6).
-- 🔴경로 스냅샷 + 도달 시간차 타격 = castWaveOnce 규약(재조회 없음)
local function castStrawRoll(player, atk, def, root, dir, level)
	local range = arrAt(def.RangeByLevel, level, def.Range)
	local width = arrAt(def.WidthByLevel, level, def.Width)
	local speed = arrAt(def.SpeedByLevel, level, def.Speed)
	local appearSec = def.AppearSec or 0.25
	local attackerOrigin = root.Position
	local origin = attackerOrigin + dir * (def.SpawnOffset or 8)
	strawRollFx(player.Character, origin, dir, range, speed, appearSec)
	local hits = {}
	for _, entry in ipairs(monsterEntries()) do
		local off = entry.root.Position - origin
		local flat = Vector3.new(off.X, 0, off.Z)
		local along = flat:Dot(dir)
		if along >= -entry.pad and along <= range + entry.pad and verticalOk(entry, origin.Y) then
			local perp = (flat - dir * along).Magnitude
			if perp <= width * 0.5 + entry.pad then
				table.insert(hits, { entry = entry, along = math.max(along, 0) })
			end
		end
	end
	table.sort(hits, function(a, b)
		return a.along < b.along
	end)
	while #hits > def.MaxTargets do
		table.remove(hits)
	end
	if #hits == 0 then
		AnalyticsService.Batch(player, "SkillCastHit0", 1, "StrawRoll") -- [명세 §10-1/§11] 타격 0 관측
	end
	for order, hit in ipairs(hits) do
		local contactPos = origin + dir * hit.along
		task.delay(appearSec + hit.along / speed, function()
			applyHit(player, atk, def, hit.entry, order, contactPos, attackerOrigin)
		end)
	end
end

-- [2026-08-05 스킬8종] 진황 늮 연출 — 이식 MudPoolServer 원본 보존(성장→유지→페이드, SkillFx_MudAsset).
local function mudPoolFx(casterChar, origin, radius, growSec, holdSec)
	local src = ReplicatedStorage:FindFirstChild("SkillFx_MudAsset")
	if not src then
		return
	end
	local Debris = game:GetService("Debris")
	local RunService = game:GetService("RunService")
	local fxFolder = Instance.new("Folder")
	fxFolder.Name = "SkillFx_MudPool"
	fxFolder.Parent = Workspace
	local rp = groundRayParams({ casterChar, fxFolder })
	local res = Workspace:Raycast(origin + Vector3.new(0, 30, 0), Vector3.new(0, -120, 0), rp)
	local gy = res and res.Position.Y or (origin.Y - 3)
	local baseSize = src.Size
	local targetScale = (radius * 2) / math.max(baseSize.X, 0.1) -- 메시 폭을 판정 지름에 일치
	local yaw = math.rad(math.random(0, 360))
	local c = src:Clone()
	c.Anchored = true; c.CanCollide = false; c.CanQuery = false; c.CanTouch = false; c.CastShadow = false
	local function place(scale)
		c.Size = baseSize * scale
		c.CFrame = CFrame.new(origin.X, gy + c.Size.Y / 2, origin.Z) * CFrame.Angles(0, yaw, 0)
	end
	place(targetScale * 0.2)
	c.Parent = fxFolder
	-- 첨벙 스플랫(원본 splat 보존)
	local host = Instance.new("Part")
	host.Transparency = 1; host.Size = Vector3.one; host.Anchored = true; host.CanCollide = false
	host.Position = Vector3.new(origin.X, gy + 0.5, origin.Z); host.Parent = fxFolder
	local att = Instance.new("Attachment"); att.Parent = host
	local p = Instance.new("ParticleEmitter")
	p.Texture = "rbxasset://textures/particles/smoke_main.dds"
	p.Color = ColorSequence.new(src.Color)
	p.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 6) })
	p.Lifetime = NumberRange.new(0.4, 0.8); p.Speed = NumberRange.new(8, 16)
	p.SpreadAngle = Vector2.new(60, 60); p.Acceleration = Vector3.new(0, -14, 0)
	p.Enabled = false; p.Parent = att
	p:Emit(24)
	Debris:AddItem(host, 1)
	task.spawn(function()
		local t = 0
		while t < growSec do
			local dt = RunService.Heartbeat:Wait()
			t += dt
			local a = math.min(t / growSec, 1)
			local ea = 1 - (1 - a) ^ 2
			place(targetScale * (0.2 + 0.8 * ea))
		end
		place(targetScale)
		task.wait(holdSec)
		-- 페이드(파티클 먼저 소등)
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("ParticleEmitter") then
				d.Enabled = false
			end
		end
		local ft = 0
		while ft < 0.6 do
			local dt = RunService.Heartbeat:Wait()
			ft += dt
			c.Transparency = math.min(ft / 0.6, 1)
		end
		if fxFolder.Parent then
			fxFolder:Destroy()
		end
	end)
	Debris:AddItem(fxFolder, growSec + holdSec + 1.5)
end

local function castMudPool(player, atk, def, root, dir, level)
	local radius = arrAt(def.RadiusByLevel, level, def.Radius)
	local ticks = arrAt(def.TicksByLevel, level, def.Ticks)
	local growSec = def.GrowSec or 0.5
	local tickSec = def.TickSec or 1.0
	local attackerOrigin = root.Position
	local origin = attackerOrigin + dir * (def.CastDist or 0)
	mudPoolFx(player.Character, origin, radius, growSec, ticks * tickSec)
	task.spawn(function()
		local anyHit = false
		for i = 1, ticks do
			task.wait(i == 1 and growSec or tickSec)
			local hits = {}
			for _, entry in ipairs(monsterEntries()) do
				local off = entry.root.Position - origin
				local dist = Vector3.new(off.X, 0, off.Z).Magnitude
				if dist <= radius + entry.pad and verticalOk(entry, origin.Y) then
					table.insert(hits, { entry = entry, dist = dist })
				end
			end
			table.sort(hits, function(a, b)
				return a.dist < b.dist
			end)
			while #hits > def.MaxTargets do
				table.remove(hits)
			end
			if #hits > 0 then
				anyHit = true
			end
			for order, hit in ipairs(hits) do
				applyHit(player, atk, def, hit.entry, order, nil, attackerOrigin)
			end
		end
		if not anyHit then
			AnalyticsService.Batch(player, "SkillCastHit0", 1, "MudPool")
		end
	end)
end

-- [2026-08-05 스킬8종] 씨앗 흡수 연출 — 이식 SeedDrainServer 원본 보존(씨앗버스트+빔+새숭+흡수오브+회복반짝임).
-- 단발 명세(구 4초 채널→0.4s 후 1회)에 맞춰 압축 — 요소는 전부 유지.
local SEED_ABSORB_SOUND = "rbxassetid://139366885078517"
local function seedDrainFx(player, targets, hitDelay, ticks, tickSec)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local Debris = game:GetService("Debris")
	local TweenService = game:GetService("TweenService")
	local fxFolder = Instance.new("Folder")
	fxFolder.Name = "SkillFx_SeedDrain"
	fxFolder.Parent = Workspace
	-- 씨앗 버스트(시전자)
	local host = Instance.new("Part")
	host.Transparency = 1; host.Size = Vector3.one; host.Anchored = true; host.CanCollide = false
	host.Position = hrp.Position; host.Parent = fxFolder
	local hatt = Instance.new("Attachment"); hatt.Parent = host
	local burst = Instance.new("ParticleEmitter")
	burst.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	burst.Color = ColorSequence.new(Color3.fromRGB(180, 140, 80), Color3.fromRGB(120, 200, 90))
	burst.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	burst.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 0.2) })
	burst.Lifetime = NumberRange.new(0.5, 0.9); burst.Speed = NumberRange.new(20, 34)
	burst.SpreadAngle = Vector2.new(180, 180); burst.Acceleration = Vector3.new(0, -20, 0)
	burst.Enabled = false; burst.Parent = hatt
	burst:Emit(60)
	Debris:AddItem(host, 1)
	-- 회복 반짝임(시전자 부착)
	local pAtt = Instance.new("Attachment"); pAtt.Parent = hrp
	local heal = Instance.new("ParticleEmitter")
	heal.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	heal.Color = ColorSequence.new(Color3.fromRGB(150, 255, 140))
	heal.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	heal.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0.1) })
	heal.Lifetime = NumberRange.new(0.4, 0.7); heal.Rate = 0
	heal.Speed = NumberRange.new(2, 5); heal.SpreadAngle = Vector2.new(180, 180)
	heal.Acceleration = Vector3.new(0, 6, 0); heal.Parent = pAtt
	-- 대상별: 새숭 빌보드 + 빔 + 하이라이트
	for _, t in ipairs(targets) do
		local head = t.head
		local a0 = Instance.new("Attachment"); a0.Parent = head
		local bb = Instance.new("BillboardGui")
		bb.Name = "FlowerMark"; bb.Adornee = head; bb.AlwaysOnTop = true
		bb.Size = UDim2.fromOffset(44, 44); bb.StudsOffset = Vector3.new(0, head.Size.Y / 2 + 1.2, 0)
		local tl = Instance.new("TextLabel")
		tl.BackgroundTransparency = 1; tl.AnchorPoint = Vector2.new(0.5, 1)
		tl.Position = UDim2.new(0.5, 0, 1, 0); tl.Size = UDim2.fromScale(0, 0)
		tl.Text = "🌿"; tl.TextScaled = true; tl.Font = Enum.Font.GothamBold; tl.TextColor3 = Color3.new(1, 1, 1)
		tl.Parent = bb
		bb.Parent = fxFolder
		TweenService:Create(tl, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) }):Play()
		local beam = Instance.new("Beam")
		beam.Attachment0 = pAtt; beam.Attachment1 = a0
		beam.Color = ColorSequence.new(Color3.fromRGB(120, 210, 85), Color3.fromRGB(185, 255, 150))
		beam.LightEmission = 0.8; beam.FaceCamera = true
		beam.Width0 = 0.6; beam.Width1 = 0.18; beam.Segments = 26
		beam.CurveSize0 = 5; beam.CurveSize1 = -5
		beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(1, 0.45) })
		beam.Parent = a0
		local hl = Instance.new("Highlight")
		hl.FillColor = Color3.fromRGB(130, 255, 120); hl.FillTransparency = 0.55
		hl.OutlineColor = Color3.fromRGB(190, 255, 150); hl.OutlineTransparency = 0
		hl.Adornee = t.model; hl.Parent = fxFolder
	end
	-- [2026-08-09 지시③] 틱마다 흡수 오브가 대상→시전자로 날아오고 회복 반짝임 — 채널형 '피를 빨아들이는' 연출(사운드는 첫 틱만)
	task.spawn(function()
		for i = 1, (ticks or 1) do
			task.wait(i == 1 and hitDelay or (tickSec or 0.3))
			if not fxFolder.Parent then
				return
			end
			if i == 1 and #targets > 0 then
				local sp = Instance.new("Part")
				sp.Anchored = true; sp.CanCollide = false; sp.Transparency = 1; sp.Size = Vector3.one
				sp.Position = hrp.Position; sp.Parent = fxFolder
				local s = Instance.new("Sound")
				s.SoundId = SEED_ABSORB_SOUND; s.Volume = 1
				s.RollOffMaxDistance = 140; s.RollOffMinDistance = 10; s.Parent = sp
				s:Play()
				Debris:AddItem(sp, 3)
			end
			if #targets > 0 then
				heal:Emit(10)
			end
			for _, t in ipairs(targets) do
				if t.head.Parent then
					local orb = Instance.new("Part")
					orb.Shape = Enum.PartType.Ball; orb.Size = Vector3.new(0.8, 0.8, 0.8)
					orb.Material = Enum.Material.Neon; orb.Color = Color3.fromRGB(150, 255, 140)
					orb.Anchored = true; orb.CanCollide = false; orb.CastShadow = false
					orb.CFrame = CFrame.new(t.head.Position); orb.Parent = fxFolder
					local l = Instance.new("PointLight"); l.Color = Color3.fromRGB(150, 255, 140); l.Brightness = 4; l.Range = 8; l.Parent = orb
					TweenService:Create(orb, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
						{ CFrame = CFrame.new(hrp.Position), Size = Vector3.new(0.2, 0.2, 0.2) }):Play()
					Debris:AddItem(orb, 0.55)
				end
			end
		end
	end)
	-- 정리(빔·새숭·하이라이트) — 채널 종료 후
	task.delay(hitDelay + math.max(0, (ticks or 1) - 1) * (tickSec or 0.3) + 0.8, function()
		if pAtt.Parent then
			pAtt:Destroy()
		end
		if fxFolder.Parent then
			fxFolder:Destroy()
		end
	end)
end

-- [2026-08-05 스킬8종 §5-1/§6-4] 씨앗 흡수 — [2026-08-09 사장님 지시③] 단발 → 0.3초 채널 도트(첫 틱 0.4s 후 6틱).
-- 틱마다 실피해×DrainPct 회복, 누계 상한 = MaxHp×DrainCapPct(캐스트당). 대상 = 시전 순간 스냅샷(빔 부착 대상과 일치). 🔴MP 회수 금지(§5-3).
local function castSeedDrain(player, atk, def, root, _dir, level)
	local radius = arrAt(def.RadiusByLevel, level, def.Radius)
	local drainPct = arrAt(def.DrainPctByLevel, level, def.DrainPct)
	local capPct = arrAt(def.DrainCapPctByLevel, level, def.DrainCapPct)
	local ticks = def.Ticks or 6
	local tickSec = def.TickSec or 0.3
	local hitDelay = def.HitDelaySec or 0.4
	local origin = root.Position
	local hits = {}
	for _, entry in ipairs(monsterEntries()) do
		local off = entry.root.Position - origin
		local dist = Vector3.new(off.X, 0, off.Z).Magnitude
		if dist <= radius + entry.pad and verticalOk(entry, origin.Y) then
			table.insert(hits, { entry = entry, dist = dist })
		end
	end
	table.sort(hits, function(a, b)
		return a.dist < b.dist
	end)
	while #hits > def.MaxTargets do
		table.remove(hits)
	end
	if #hits == 0 then
		AnalyticsService.Batch(player, "SkillCastHit0", 1, "SeedDrain") -- [명세 §10-1/§11]
	end
	local targets = {}
	for _, hit in ipairs(hits) do
		local m = hit.entry.model
		local head = m:FindFirstChild("Head") or hit.entry.root
		table.insert(targets, { head = head, model = m })
	end
	seedDrainFx(player, targets, hitDelay, ticks, tickSec)
	task.spawn(function()
		local healed = 0
		for i = 1, ticks do
			task.wait(i == 1 and hitDelay or tickSec)
			local total = 0
			for order, hit in ipairs(hits) do
				total += applyHit(player, atk, def, hit.entry, order, nil, origin) or 0 -- 죽은 대상은 0 반환(재타겟 없음)
			end
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 and total > 0 then
				local cap = hum.MaxHealth * capPct
				local healAmt = math.min(total * drainPct, math.max(0, cap - healed))
				if healAmt > 0 then
					healed += healAmt
					hum.Health = math.min(hum.MaxHealth, hum.Health + healAmt)
				end
			end
		end
	end)
end

-- [2026-08-05 스킬8종] 바위 갑옷 — [2026-08-09 사장님 지시④] 흡수 실드(사실상 무적) → 받는 피해 감소(ReducePct).
-- 플레이어 피해의 중앙 관문이 없어(몹이 hum:TakeDamage 직행) HealthChanged 환급 방식 유지 — 감소분만 환급.
-- ⚠한 방에 현재 HP를 넘는 치명타는 환급 전 사망 — 구 실드와 동일한 알려진 한계.
local activeShields = {} -- [player] = { reduce, lastHealth, busy, conn, diedConn }

local function clearShield(player)
	local st = activeShields[player]
	if not st then
		return
	end
	activeShields[player] = nil
	if st.conn then
		st.conn:Disconnect()
	end
	if st.diedConn then
		st.diedConn:Disconnect()
	end
end
SkillService._clearShield = clearShield

-- 이식 RockArmorServer 원본 보존: 충격파 링+흙먼지+캐릭터 하이라이트 펄스+포인트라이트.
-- 굤도는 클라 렌더(SkillController.renderRockPieces — SkillFx 릴레이 경유).
local function rockArmorFx(char, duration)
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local TweenService = game:GetService("TweenService")
	local Debris = game:GetService("Debris")
	local RunService = game:GetService("RunService")
	local fxFolder = Instance.new("Folder")
	fxFolder.Name = "SkillFx_RockArmor"
	fxFolder.Parent = Workspace
	-- [2026-08-12] 동일 결함 3번째 지점 — 몬스터가 시전자에 겹쳐 서면 충격링·먼지가 공중에 뜼다
	local rp = groundRayParams({ fxFolder, char })
	local res = Workspace:Raycast(hrp.Position + Vector3.new(0, 10, 0), Vector3.new(0, -60, 0), rp)
	local gy = res and res.Position.Y or (hrp.Position.Y - 3)
	local pos = Vector3.new(hrp.Position.X, gy, hrp.Position.Z)
	local wave = Instance.new("Part")
	wave.Shape = Enum.PartType.Cylinder; wave.Anchored = true; wave.CanCollide = false; wave.CanQuery = false; wave.CastShadow = false
	wave.Material = Enum.Material.SmoothPlastic; wave.Color = Color3.fromRGB(120, 85, 50); wave.Transparency = 0.25
	wave.Size = Vector3.new(0.12, 3, 3)
	wave.CFrame = CFrame.new(pos + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	wave.Parent = fxFolder
	TweenService:Create(wave, TweenInfo.new(0.55), { Size = Vector3.new(0.12, 30, 30), Transparency = 1 }):Play()
	Debris:AddItem(wave, 0.6)
	local host = Instance.new("Part")
	host.Transparency = 1; host.Size = Vector3.one; host.Anchored = true; host.CanCollide = false
	host.Position = pos + Vector3.new(0, 0.3, 0); host.Parent = fxFolder
	local att = Instance.new("Attachment"); att.Parent = host
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
	dust.Color = ColorSequence.new(Color3.fromRGB(150, 115, 80))
	dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	dust.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 12) })
	dust.Lifetime = NumberRange.new(0.5, 0.9); dust.Speed = NumberRange.new(10, 18)
	dust.SpreadAngle = Vector2.new(75, 75); dust.Acceleration = Vector3.new(0, -8, 0)
	dust.Enabled = false; dust.Parent = att
	dust:Emit(24)
	Debris:AddItem(host, 1.1)
	local hl = Instance.new("Highlight")
	hl.FillColor = Color3.fromRGB(150, 55, 40); hl.FillTransparency = 1
	hl.OutlineColor = Color3.fromRGB(150, 55, 40); hl.OutlineTransparency = 1
	hl.Adornee = char; hl.Parent = fxFolder
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 140, 80); light.Brightness = 0; light.Range = 6; light.Shadows = true; light.Parent = hrp
	Debris:AddItem(light, duration + 1.2)
	task.spawn(function()
		local APPEAR, FADE = 0.5, 0.6
		local elapsed = 0
		while elapsed < duration + FADE do
			local dt = RunService.Heartbeat:Wait()
			if not (char.Parent and hrp.Parent) then
				break
			end
			elapsed += dt
			local vis
			if elapsed < APPEAR then
				vis = elapsed / APPEAR
			elseif elapsed < duration then
				vis = 1
			else
				vis = math.max(0, 1 - (elapsed - duration) / FADE)
			end
			hl.FillTransparency = 1 - vis * (1 - 0.55)
			hl.OutlineTransparency = 1 - vis * (1 - 0.1)
			light.Brightness = vis * 3
		end
		if fxFolder.Parent then
			fxFolder:Destroy()
		end
	end)
end

-- [2026-08-05 스킬8종 §5-1/§6-4] 바위 갑옷: [2026-08-09 지시④] 받는 피해 ReducePct만큼 감소(무적 아님), 지속·쿨 레벨 변동.
-- 총량 풀 없음 — 지속시간이 유일한 상한. 중첩 불가(쿨>지속이라 정상 경로 도달 불가 — 방어적 clearShield)
local function castRockArmor(player, atk, def, root, _dir, level)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end
	local duration = arrAt(def.DurationByLevel, level, def.Duration or 8)
	local reduce = arrAt(def.ReducePctByLevel, level, 0.4)
	clearShield(player)
	rockArmorFx(char, duration)
	local st = { reduce = reduce, busy = false, lastHealth = hum.Health }
	activeShields[player] = st
	st.diedConn = hum.Died:Connect(function()
		clearShield(player)
	end)
	st.conn = hum.HealthChanged:Connect(function(h)
		if st.busy then
			return
		end
		if h < st.lastHealth then
			local taken = st.lastHealth - h
			local refund = taken * st.reduce -- 감소분만 되돌려준다(나머지는 실피해)
			st.busy = true
			hum.Health = math.min(hum.MaxHealth, h + refund)
			st.busy = false
			st.lastHealth = hum.Health
			return
		end
		st.lastHealth = h
	end)
	task.delay(duration, function()
		if activeShields[player] == st then
			clearShield(player)
		end
	end)
end

-- [2026-08-05 스킬8종 §5-1/§6-1] 돌진베기: 서버 구동 대시(이식 DashSlashServer 이동 규약 보존) + 경로 판정.
-- 슬래시 파티클(SkillFx_DashSlashPart)은 HRP 웰드로 동행, 잔상·FOV 펀치는 클라(playCastFx).
-- 무적 프레임 없음(명세) — 대시 중에도 피격된다.
local function castDashSlash(player, atk, def, root, dir, level)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end
	local dashDist = arrAt(def.DashDistByLevel, level, def.DashDist)
	local width = arrAt(def.WidthByLevel, level, def.Width)
	local maxTargets = math.min(arrAt(def.MaxTargetsByLevel, level, def.MaxTargets or 4), 6) -- 이중 방어(§6-8)
	local dashSec = def.DashSec or 0.25
	local speed = dashDist / dashSec
	local origin = root.Position
	-- 경로 판정 스냅샷(도달 시간차 타격 — castWaveOnce 규약)
	local hits = {}
	for _, entry in ipairs(monsterEntries()) do
		local off = entry.root.Position - origin
		local flat = Vector3.new(off.X, 0, off.Z)
		local along = flat:Dot(dir)
		if along >= -entry.pad and along <= dashDist + entry.pad and verticalOk(entry, origin.Y) then
			local perp = (flat - dir * along).Magnitude
			if perp <= width * 0.5 + entry.pad then
				table.insert(hits, { entry = entry, along = math.max(along, 0) })
			end
		end
	end
	table.sort(hits, function(a, b)
		return a.along < b.along
	end)
	while #hits > maxTargets do
		table.remove(hits)
	end
	if #hits == 0 then
		AnalyticsService.Batch(player, "SkillCastHit0", 1, "DashSlash") -- [명세 §10-1/§11]
	end
	for order, hit in ipairs(hits) do
		local contactPos = origin + dir * hit.along
		task.delay(hit.along / speed, function()
			applyHit(player, atk, def, hit.entry, order, contactPos, origin)
		end)
	end
	-- 서버 구동 대시(원본 이동 규약: WalkSpeed 0·AutoRotate off·수평 속도 주입·종료 시 복원)
	local RunService = game:GetService("RunService")
	local TweenService = game:GetService("TweenService")
	local Debris = game:GetService("Debris")
	local fxFolder = Instance.new("Folder")
	fxFolder.Name = "SkillFx_DashSlash"
	fxFolder.Parent = Workspace
	local slashFX
	local tpl = ReplicatedStorage:FindFirstChild("DashSlashPart")
	if tpl then
		slashFX = tpl:Clone()
		slashFX.Anchored = false; slashFX.CanCollide = false; slashFX.CanQuery = false; slashFX.CanTouch = false
		slashFX.Massless = true; slashFX.Transparency = 1
		slashFX.CFrame = root.CFrame * CFrame.new(0, 0.5, -3)
		slashFX.Parent = fxFolder
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = slashFX; weld.Part1 = root; weld.Parent = slashFX
		for _, e in ipairs(slashFX:GetDescendants()) do
			if e:IsA("ParticleEmitter") then
				e.Enabled = true
			end
		end
	end
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(198, 34, 37); light.Range = 5; light.Brightness = 6; light.Parent = root
	local origWalk = hum.WalkSpeed
	local origAuto = hum.AutoRotate
	hum.WalkSpeed = 0
	hum.AutoRotate = false
	-- [2026-08-10] 실이동속도는 클라 MovementController가 기본×SpeedMul(AGI)×SkillSpeedMul로 로컬 계산 — 서버가 보는
	-- hum.WalkSpeed(origWalk)에는 그 배율이 없다. origWalk만 복원하면 낡은 기본값이 클라로 복제되어 대시 후 감속이 굳음.
	-- SkillSpeedMul 0→nil 전이(회오리 규약)로 클라 applyWalkSpeed 재계산을 강제해 올바른 속도로 복귀시킨다.
	player:SetAttribute("SkillSpeedMul", 0)
	-- [2026-08-05 판정검증] 구 속도 주입은 클라 소유 물리와 싸워 실이동이 ~80%(17.5/22)에 그치는 것을 실측.
	-- 대시 동안 서버 소유로 전환 + CFrame 스텝(회전·낙하 보존)으로 실이동=DashDist 정확히.
	-- 벽 판정: 수평 레이캐스트(RespectCanCollide)로 가파른 면(normal.Y<0.5)만 정지 — 완만한 경사는 통과.
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	local dashRp = groundRayParams({ char, fxFolder }) -- 몬스터 몸에 대쉬가 가로막히지 않게 제외
	dashRp.RespectCanCollide = true
	local function endDashControl()
		hum.WalkSpeed = origWalk
		hum.AutoRotate = origAuto
		player:SetAttribute("SkillSpeedMul", nil) -- 변경 이벤트로 클라가 base×SpeedMul 재적용(굳은 감속 해제)
		pcall(function()
			root:SetNetworkOwnershipAuto() -- 자동 복원(시전자 클라로 복귀)
		end)
	end
	-- 스텝 기준 = 실제 진행거리(시작점 대비 전방 투영) — 소유권 전환 직후 클라 복제에 덮인 프레임을 다음 프레임이 보상.
	-- 종료 시 잔여분은 장애물 재확인 후 최종 스냅 — 실이동=DashDist 보장. 시간 상한은 dashSec×1.6(보상 여유).
	local dashStart = root.Position
	local function progressOf()
		return (root.Position - dashStart):Dot(dir)
	end
	local t = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		t += dt
		if not root.Parent or hum.Health <= 0 then
			conn:Disconnect()
			endDashControl()
			return
		end
		local travelled = math.max(progressOf(), 0)
		local step = math.min(speed * dt, dashDist - travelled)
		local blocked = false
		if step > 0 then
			local res = Workspace:Raycast(root.Position, dir * (step + 1.5), dashRp)
			if res and res.Normal.Y < 0.5 then
				step = math.max(0, (res.Position - root.Position).Magnitude - 1.5)
				blocked = true
			end
		end
		if step > 0 then
			root.CFrame = CFrame.new(root.Position + dir * step) * root.CFrame.Rotation
			travelled += step
		end
		if (not blocked) and travelled < dashDist - 0.05 and t >= dashSec then
			-- 보상 시간 내 미달분 최종 스냅(장애물 재확인)
			if t >= dashSec * 1.6 then
				local remain = dashDist - travelled
				local res2 = Workspace:Raycast(root.Position, dir * (remain + 1.5), dashRp)
				if not (res2 and res2.Normal.Y < 0.5) then
					root.CFrame = CFrame.new(root.Position + dir * remain) * root.CFrame.Rotation
					travelled = dashDist
				end
			end
		end
		if (t >= dashSec and travelled >= dashDist - 0.05) or t >= dashSec * 1.6 or travelled >= dashDist - 0.01 or (blocked and step <= 0) then
			conn:Disconnect()
			root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
			endDashControl()
			if slashFX then
				for _, e in ipairs(slashFX:GetDescendants()) do
					if e:IsA("ParticleEmitter") then
						e.Enabled = false
					end
				end
			end
			TweenService:Create(light, TweenInfo.new(0.35), { Brightness = 0 }):Play()
			Debris:AddItem(light, 0.4)
			task.delay(1.4, function()
				if fxFolder.Parent then
					fxFolder:Destroy()
				end
			end)
		end
	end)
end

-- [2026-08-05 스킬8종] 장착검 연출 공용 헬퍼 — [[project-skill-port-zxv]] 규약:
-- ★블레이드축=핸들로컬 8꼭짓점 전개 최장축(중심 휴리스틱 금지) · ★월드 판정은 worldYSpan(GetBoundingBox=피벗기준 함정)
local function rotBetween(a, b)
	local d = math.clamp(a:Dot(b), -1, 1)
	if d > 0.99999 then
		return CFrame.identity
	elseif d < -0.99999 then
		local perp = math.abs(a.X) < 0.9 and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
		return CFrame.fromAxisAngle(a:Cross(perp).Unit, math.pi)
	end
	return CFrame.fromAxisAngle(a:Cross(b).Unit, math.acos(d))
end

local function cloneEquippedBlade(char)
	local equipped = char and char:FindFirstChild("EquippedWeapon")
	if not equipped then
		return nil
	end
	local m = equipped:Clone()
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true; d.CanCollide = false; d.CanQuery = false; d.CanTouch = false; d.Massless = true
		end
	end
	-- 용접 프레임은 CraftService.getWeaponHandle과 같은 순서(그립 C0와 같은 기준이어야 한다).
	local handle = m:FindFirstChild("Handle") or m:FindFirstChild("Part")
		or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
	if not handle then
		m:Destroy()
		return nil
	end
	m.PrimaryPart = handle
	-- [2026-08-27] 베이크된 PivotOffset 제거. PivotTo는 '피벗' 기준이라 오프셋이 남으면
	-- 파트 프레임이 그만큼 어긋나 칼날을 아래로 돌려도 빗간다(청자검 실측 90°X → 수직도 50%).
	-- LootService.makeDropVisual이 같은 이유로 이미 지우고 있다.
	handle.PivotOffset = CFrame.new()
	local INF = math.huge
	local mnX, mnY, mnZ, mxX, mxY, mxZ = INF, INF, INF, -INF, -INF, -INF
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") then
			local h = d.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local lp = handle.CFrame:PointToObjectSpace(d.CFrame:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz)))
						mnX = math.min(mnX, lp.X); mxX = math.max(mxX, lp.X)
						mnY = math.min(mnY, lp.Y); mxY = math.max(mxY, lp.Y)
						mnZ = math.min(mnZ, lp.Z); mxZ = math.max(mxZ, lp.Z)
					end
				end
			end
		end
	end
	local ex, ey, ez = mxX - mnX, mxY - mnY, mxZ - mnZ
	local blade, tipProj, backProj
	-- [2026-08-27] 1순위 = 그립 C0 역산. 아래 바운딩박스 추정은 그립 정보가 없는 무기용 폴백이다.
	-- 덩어리진 신형 메시는 1·2위 길이가 거의 같아(청자검 비율 1.04) 축이 무작위로 바뀌고,
	-- 그 결과 난하검이 누워서 꿂힌다. 그립 C0는 정답을 이미 가지고 있다.
	local skinId
	do
		local wid = m:GetAttribute("WeaponId")
		local w = wid and WeaponDefs.Weapons and WeaponDefs.Weapons[wid]
		skinId = w and (w.SkinId or w.NameKo) or nil
	end
	local gripBlade = AVDefs.BladeAxisOf(m, skinId)
	if gripBlade then
		blade = gripBlade
		-- 끝까지 거리는 8꼭지점을 칼날축에 투영해 구한다(꿂힘 깊이·트레일 길이용).
		local mnP, mxP = math.huge, -math.huge
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") then
				local h = d.Size / 2
				for sx = -1, 1, 2 do
					for sy = -1, 1, 2 do
						for sz = -1, 1, 2 do
							local p = handle.CFrame:PointToObjectSpace(d.CFrame:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))):Dot(blade)
							if p < mnP then mnP = p end
							if p > mxP then mxP = p end
						end
					end
				end
			end
		end
		tipProj = mxP
		backProj = -mnP
	elseif ex >= ey and ex >= ez then
		local sign = (mxX + mnX) >= 0 and 1 or -1
		blade = Vector3.new(sign, 0, 0)
		tipProj = sign > 0 and mxX or -mnX
		backProj = sign > 0 and -mnX or mxX
	elseif ey >= ez then
		local sign = (mxY + mnY) >= 0 and 1 or -1
		blade = Vector3.new(0, sign, 0)
		tipProj = sign > 0 and mxY or -mnY
		backProj = sign > 0 and -mnY or mxY
	else
		local sign = (mxZ + mnZ) >= 0 and 1 or -1
		blade = Vector3.new(0, 0, sign)
		tipProj = sign > 0 and mxZ or -mnZ
		backProj = sign > 0 and -mnZ or mxZ
	end
	return m, blade, tipProj, backProj
end

local function worldYSpanModel(model)
	local mn, mx = math.huge, -math.huge
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local h = d.Size / 2
			for sx = -1, 1, 2 do
				for sy = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local y = d.CFrame:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz)).Y
						mn = math.min(mn, y); mx = math.max(mx, y)
					end
				end
			end
		end
	end
	return mn, mx
end

-- [2026-08-05 스킬8종] 내리찍기 연출 — 이식 GiantSlamServer 보존(장착검 거대화 솔아오름→전도→폭발),
-- 단 전체 타임라인을 WindupSec에 압축(선딜 단축=성장축 — 판정과 착지 동기화)
-- 🔧거대화된 검의 세로 길이(스터드). 무기 종류와 무관하게 이 길이로 정규화된다.
--   솟아오르는 거리·착지 폭발 위치가 여기서 파생되므로 이 값만 바꾸면 전부 따라온다.
local SLAM_TARGET_LEN = 20
local function giantSlamFx(char, origin, dir, windup)
	local TweenService = game:GetService("TweenService")
	local Debris = game:GetService("Debris")
	local RunService = game:GetService("RunService")
	local fxFolder = Instance.new("Folder")
	fxFolder.Name = "SkillFx_GiantSlam"
	fxFolder.Parent = Workspace
	-- [2026-08-12] 지면 스냅 = 공용 groundRayParams. 몬스터를 빼지 않으면
	--   레이가 몬스터 몸통에 맞아 거대검이 몬스터 등 위에 서서 내리찍는다.
	-- 🔴extra는 ipairs 순회다 — nil이 앞에 오면 뒤가 통째로 무시되므로 fxFolder를 먼저 넣는다.
	local rp = groundRayParams({ fxFolder, char })
	local fxBase = origin + dir * 4.5
	local res = Workspace:Raycast(fxBase + Vector3.new(0, 30, 0), Vector3.new(0, -120, 0), rp)
	local basePoint = Vector3.new(fxBase.X, res and res.Position.Y or (origin.Y - 3), fxBase.Z)
	local sword, STAND
	local m, blade = cloneEquippedBlade(char)
	if m then
		sword = m
		STAND = rotBetween(blade, Vector3.new(0, 1, 0))
	else
		sword = Instance.new("Model")
		local b = Instance.new("Part")
		b.Size = Vector3.new(1.7, 14, 0.5); b.Material = Enum.Material.Neon; b.Color = Color3.fromRGB(150, 230, 255)
		b.Anchored = true; b.CanCollide = false; b.CanQuery = false; b.CanTouch = false; b.CastShadow = false
		b.CFrame = CFrame.new(0, 7, 0)
		b.Parent = sword
		sword.PrimaryPart = b
		STAND = CFrame.identity
	end
	sword.Parent = fxFolder
	local faceRot = CFrame.lookAt(basePoint, basePoint + dir).Rotation
	local rightAxis = faceRot.RightVector
	sword:PivotTo(CFrame.new(0, -500, 0) * STAND)
	local mn0, mx0 = worldYSpanModel(sword)
	local curLen = mx0 - mn0
	if curLen > 0.1 then
		local cur = 1
		pcall(function()
			cur = sword:GetScale()
		end)
		pcall(function()
			sword:ScaleTo(cur * (SLAM_TARGET_LEN / curLen))
		end)
	end
	sword:PivotTo(CFrame.new(basePoint) * faceRot * STAND)
	local mnY, mxY = worldYSpanModel(sword)
	local standPivot = CFrame.new(0, basePoint.Y - mnY, 0) * (CFrame.new(basePoint) * faceRot * STAND)
	local reach = mxY - mnY
	local function toppleCF(angle)
		local Rw = CFrame.fromAxisAngle(rightAxis, -angle)
		return CFrame.new(basePoint) * Rw * CFrame.new(-basePoint) * standPivot
	end
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(150, 230, 255); glow.Range = 18; glow.Brightness = 0; glow.Parent = sword.PrimaryPart
	local riseSec = windup * 0.45
	local pauseSec = windup * 0.1
	local fallSec = windup * 0.45
	TweenService:Create(glow, TweenInfo.new(riseSec), { Brightness = 4 }):Play()
	task.spawn(function()
		-- 솔아오름
		local t = 0
		while t < riseSec do
			local dt = RunService.Heartbeat:Wait()
			t += dt
			local a = math.min(t / riseSec, 1)
			local ea = 1 - (1 - a) ^ 3
			sword:PivotTo(CFrame.new(0, -reach * (1 - ea), 0) * standPivot)
		end
		sword:PivotTo(standPivot)
		task.wait(pauseSec)
		-- 전도
		local t2 = 0
		while t2 < fallSec do
			local dt = RunService.Heartbeat:Wait()
			t2 += dt
			local a = math.min(t2 / fallSec, 1)
			sword:PivotTo(toppleCF(a * a * (math.pi / 2)))
		end
		-- 착지 폭발(원본 groundBurst 축약)
		local tip = basePoint + dir * (reach * 0.62)
		local flash = Instance.new("Part")
		flash.Shape = Enum.PartType.Ball; flash.Size = Vector3.new(4, 4, 4)
		flash.Material = Enum.Material.Neon; flash.Color = Color3.fromRGB(240, 250, 255); flash.Transparency = 0.05
		flash.Anchored = true; flash.CanCollide = false; flash.CanQuery = false; flash.CastShadow = false
		flash.Position = tip + Vector3.new(0, 2, 0); flash.Parent = fxFolder
		TweenService:Create(flash, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(24, 24, 24), Transparency = 1 }):Play()
		Debris:AddItem(flash, 0.4)
		local ring = Instance.new("Part")
		ring.Shape = Enum.PartType.Cylinder; ring.Size = Vector3.new(0.5, 4, 4)
		ring.Material = Enum.Material.Neon; ring.Color = Color3.fromRGB(150, 230, 255); ring.Transparency = 0.12
		ring.Anchored = true; ring.CanCollide = false; ring.CanQuery = false; ring.CastShadow = false
		ring.CFrame = CFrame.new(tip + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = fxFolder
		TweenService:Create(ring, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Size = Vector3.new(0.5, 48, 48), Transparency = 1 }):Play()
		Debris:AddItem(ring, 0.6)
		for _ = 1, 8 do
			local c = Instance.new("Part")
			c.Size = Vector3.new(math.random(16, 40) / 10, math.random(16, 40) / 10, math.random(16, 40) / 10)
			c.Color = Color3.fromRGB(150, 152, 162); c.Material = Enum.Material.Slate
			c.CanCollide = false; c.CastShadow = false; c.CanQuery = false -- [2026-08-12] 파편이 다음 시전의 지면 레이를 막지 않게
			c.Position = tip + Vector3.new((math.random() - 0.5) * 3, 1, (math.random() - 0.5) * 3)
			c.Parent = fxFolder
			local a = math.random() * math.pi * 2
			c.AssemblyLinearVelocity = Vector3.new(math.cos(a) * math.random(10, 22), math.random(20, 34), math.sin(a) * math.random(10, 22))
			c.AssemblyAngularVelocity = Vector3.new(math.random(-12, 12), math.random(-12, 12), math.random(-12, 12))
			Debris:AddItem(c, 1.2)
		end
		task.wait(0.8)
		TweenService:Create(glow, TweenInfo.new(0.3), { Brightness = 0 }):Play()
		for _, d in ipairs(sword:GetDescendants()) do
			if d:IsA("BasePart") then
				TweenService:Create(d, TweenInfo.new(0.35), { Transparency = 1 }):Play()
			end
		end
		task.wait(0.4)
		if fxFolder.Parent then
			fxFolder:Destroy()
		end
	end)
end

-- [2026-08-05 스킬8종 §5-1/§6-1] 내리찍기: 자기 발밑 반경 단발(선딜 WindupSec 후)·넅백 없음·Falloff 0.6·칩 0.07
local function castGiantSlam(player, atk, def, root, dir, level)
	-- [2026-08-06 사장님 지시] 원형 → 직선 판정. 검이 앞으로 쓰러지는 연출과 판정을 일치시킨다.
	-- 규약은 열파참(castWaveOnce)과 동일 — 전방 성분 along, 진행축 이탈 perp.
	local range = arrAt(def.RangeByLevel, level, def.Range)
	local halfW = arrAt(def.WidthByLevel, level, def.Width) * 0.5
	local windup = arrAt(def.WindupByLevel, level, def.WindupSec)
	local maxTargets = math.min(arrAt(def.MaxTargetsByLevel, level, def.MaxTargets or 4), 6)
	local origin = root.Position -- 시전 좌표 고정
	giantSlamFx(player.Character, origin, dir, windup)
	task.delay(windup, function()
		local hits = {}
		for _, entry in ipairs(monsterEntries()) do
			local off = entry.root.Position - origin
			local flat = Vector3.new(off.X, 0, off.Z)
			local along = flat:Dot(dir) -- 전방 성분(뒤쪽은 음수라 자동 제외)
			if along >= 0 and along <= range + entry.pad and verticalOk(entry, origin.Y) then
				local perp = (flat - dir * along).Magnitude -- 진행축에서 좌우로 벗어난 거리
				if perp <= halfW + entry.pad then
					table.insert(hits, { entry = entry, along = along })
				end
			end
		end
		table.sort(hits, function(a, b)
			return a.along < b.along -- 가까운 순 = 첫 대상이 감쇠 없이 맞는다
		end)
		while #hits > maxTargets do
			table.remove(hits)
		end
		if #hits == 0 then
			AnalyticsService.Batch(player, "SkillCastHit0", 1, "GiantSlam") -- [명세 §10-1/§11]
		end
		for order, hit in ipairs(hits) do
			applyHit(player, atk, def, hit.entry, order, nil, origin) -- 넉백 없음(명세)
		end
	end)
end

-- [2026-08-05 스킬8종] 검비 연출 — 이식 RapierRainServer 보존(장착검 낙하·수직 꽂힘·70% 노출·충격링),
-- 타임라인을 틱 모델(FirstTickDelay+TickSec)에 동기화: 검 i 착지 = 틱 i 판정 시점
-- 🔧낙하 검 크기 배율(1.0 = 무기 원본 크기). 내리찍기의 SLAM_TARGET_LEN과 짝이 되는 조절 손잡이.
--   검비는 검이 여러 자루 쏟아지므로 절대 길이가 아니라 배율로 잡는다
--   (무기 27종의 원본 길이 차이를 그대로 살려야 무기 교체가 체감된다).
local RAIN_SCALE = 2.0
local function rapierRainFx(char, origin, radius, ticks, firstDelay, tickSec)
	local TweenService = game:GetService("TweenService")
	local Debris = game:GetService("Debris")
	local RunService = game:GetService("RunService")
	local fxFolder = Instance.new("Folder")
	fxFolder.Name = "SkillFx_RapierRain"
	fxFolder.Parent = Workspace
	local dropTemplate, dropAngles, stickOffset
	local m, blade, tipProj = cloneEquippedBlade(char)
	local function applyRainScale(model)
		if RAIN_SCALE == 1 then
			return
		end
		pcall(function()
			model:ScaleTo(model:GetScale() * RAIN_SCALE)
		end)
	end
	if m then
		dropTemplate = m
		dropAngles = rotBetween(blade, Vector3.new(0, -1, 0))
		applyRainScale(dropTemplate)
		-- 꽂힘 깊이도 같은 배율로 — 안 하면 커진 검이 땅에 파묻힌다
		stickOffset = math.max(tipProj * RAIN_SCALE * 0.7, 1.5)
	else
		local tpl = ReplicatedStorage:FindFirstChild("RapierRainTemplate")
		if not tpl then
			return
		end
		dropTemplate = tpl:Clone()
		dropAngles = CFrame.Angles(math.rad(-90), 0, 0)
		applyRainScale(dropTemplate)
		stickOffset = 2.6 * RAIN_SCALE
	end
	-- [2026-08-12] 지면 스냅 = 공용 groundRayParams. 몬스터 미제외 시 난하검이 머리 위에 꽂힌다
	--   (endY = gy + 꽂힘 보정이라 오염된 gy 위에 보정까지 더해져 더 크게 뜼다).
	-- 🔴rp 생성은 반드시 틱 루프 밖인 이 자리 유지 — 안으로 옮기면 검 자루 수만큼 태그 순회가 반복된다.
	local rp = groundRayParams({ fxFolder, char })
	local APPEAR = 0.15
	local FALL = 0.15
	-- 🔧낙하 거리(스터드). 검 크기와 무관하게 항상 이만큼 떨어진다.
	--   RAIN_SCALE을 키웠을 때 더 높은 데서 떨어뜨리고 싶으면 이 값을 올린다.
	local DROP_H = 17
	local STICK = 0.8
	for i = 1, ticks do
		local landAt = firstDelay + (i - 1) * tickSec
		task.delay(math.max(landAt - APPEAR - FALL, 0), function()
			local ang = math.random() * math.pi * 2
			local r = math.sqrt(math.random()) * radius
			local lx, lz = origin.X + math.cos(ang) * r, origin.Z + math.sin(ang) * r
			local res = Workspace:Raycast(Vector3.new(lx, origin.Y + 60, lz), Vector3.new(0, -300, 0), rp)
			local gy = res and res.Position.Y or (origin.Y - 3)
			local rap = dropTemplate:Clone()
			local yaw = math.random() * math.pi * 2
			local function place(y)
				rap:PivotTo(CFrame.new(lx, y, lz) * CFrame.Angles(0, yaw, 0) * dropAngles)
			end
			local endY = gy + stickOffset
			-- 🔴시작 높이는 '지면 + DROP_H'가 아니라 '착지점 + DROP_H'다.
			--   지면 기준으로 잡으면 검을 키울수록 꽂힘 깊이(stickOffset)만큼 낙하 거리가
			--   깎여, 결국 하늘에서 안 떨어지고 바닥에서 튀어나오듯 보인다.
			local startY = endY + DROP_H
			place(startY)
			local origT = {}
			for _, d in ipairs(rap:GetDescendants()) do
				if d:IsA("BasePart") then
					origT[d] = d.Transparency
					d.Transparency = 1
				end
			end
			rap.Parent = fxFolder
			for d, tr in pairs(origT) do
				TweenService:Create(d, TweenInfo.new(APPEAR), { Transparency = tr }):Play()
			end
			task.delay(APPEAR, function()
				local t = 0
				local conn
				conn = RunService.Heartbeat:Connect(function(dt)
					t += dt
					local a = math.min(t / FALL, 1)
					place(startY + (endY - startY) * a * a)
					if a >= 1 then
						conn:Disconnect()
						-- 착지 링
						local ring = Instance.new("Part")
						ring.Shape = Enum.PartType.Cylinder; ring.Size = Vector3.new(0.2, 2, 2)
						ring.Material = Enum.Material.Neon; ring.Color = Color3.fromRGB(150, 230, 255); ring.Transparency = 0.3
						ring.Anchored = true; ring.CanCollide = false; ring.CanQuery = false; ring.CanTouch = false; ring.CastShadow = false
						ring.CFrame = CFrame.new(Vector3.new(lx, gy + 0.1, lz)) * CFrame.Angles(0, 0, math.rad(90))
						ring.Parent = fxFolder
						TweenService:Create(ring, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.2, radius * 1.4, radius * 1.4), Transparency = 1 }):Play()
						Debris:AddItem(ring, 0.5)
						task.delay(STICK, function()
							for _, d in ipairs(rap:GetDescendants()) do
								if d:IsA("BasePart") then
									TweenService:Create(d, TweenInfo.new(0.3), { Transparency = 1 }):Play()
								end
							end
							Debris:AddItem(rap, 0.4)
						end)
					end
				end)
			end)
		end)
	end
	task.delay(firstDelay + (ticks - 1) * tickSec + STICK + 1.2, function()
		if dropTemplate then
			dropTemplate:Destroy()
		end
		if fxFolder.Parent then
			fxFolder:Destroy()
		end
	end)
end

local function castRapierRain(player, atk, def, root, dir, level)
	local radius = arrAt(def.RadiusByLevel, level, def.Radius)
	local castDist = arrAt(def.CastDistByLevel, level, def.CastDist)
	local ticks = arrAt(def.TicksByLevel, level, def.Ticks)
	local firstDelay = def.FirstTickDelay or 0.3
	local tickSec = def.TickSec or 0.45
	local attackerOrigin = root.Position
	local origin = attackerOrigin + dir * castDist
	rapierRainFx(player.Character, origin, radius, ticks, firstDelay, tickSec)
	task.spawn(function()
		local anyHit = false
		for i = 1, ticks do
			task.wait(i == 1 and firstDelay or tickSec)
			local hits = {}
			for _, entry in ipairs(monsterEntries()) do
				local off = entry.root.Position - origin
				local dist = Vector3.new(off.X, 0, off.Z).Magnitude
				if dist <= radius + entry.pad and verticalOk(entry, origin.Y) then
					table.insert(hits, { entry = entry, dist = dist })
				end
			end
			table.sort(hits, function(a, b)
				return a.dist < b.dist
			end)
			-- 피해는 범위 내 전 대상에 적용하며 연출 제한은 applyHit에서 처리한다.
			if #hits > 0 then
				anyHit = true
			end
			for order, hit in ipairs(hits) do
				applyHit(player, atk, def, hit.entry, order, nil, attackerOrigin)
			end
		end
		if not anyHit then
			AnalyticsService.Batch(player, "SkillCastHit0", 1, "RapierRain")
		end
	end)
end

-- [2026-08-05 명세 §10-1] 스킬 명부 — 스킬 1개=핸들러 1개. if 분기 하드코딩 금지(무음 실패 방지).
-- 시그니처 통일: fn(player, atk, def, root, dir, level)
local CASTERS = {
	SwordWave = function(player, atk, def, root, dir, level)
		castWave(player, atk, def, root.Position, dir, level)
	end,
	Whirlwind = function(player, atk, def, root, _dir, level)
		castWhirlwind(player, atk, def, root, level)
	end,
	Pull = function(player, atk, def, root, dir, level)
		castPull(player, atk, def, root, dir, level) -- [2026-08-09] 전방 집결점용 dir 전달
	end,
	GoldenCarrot = castGoldenCarrot,
	StrawRoll = castStrawRoll,
	MudPool = castMudPool,
	SeedDrain = castSeedDrain,
	RockArmor = castRockArmor,
	DashSlash = castDashSlash,
	GiantSlam = castGiantSlam,
	RapierRain = castRapierRain,
}
SkillService._casters = CASTERS -- SkillDefsValidator(Studio 전용)가 명부 누락 검사에 사용

-- 시전 시작 시 서버 프로필에서 무기·공명을 1회 스냅샷한다. 지연 판정 중 재장착해도 결과는 바뀌지 않는다.
local function resolveCastAffinity(profile, skillId)
	local inv = profile and profile.Inventory
	local uid = inv and inv.EquippedWeaponUid
	local weapon = uid and uid ~= 0 and inv.Weapons and inv.Weapons[tostring(uid)] or nil
	local weaponId = WeaponDefs.ResolveWeaponId(weapon)
	local affinity, affinityKey = WeaponDefs.SkillAffinityOf(weaponId, skillId)
	return weaponId, affinity, affinityKey
end

-- Studio 전용 스킬 테스트: 슬롯·보유·쿨다운·마나 무시 즉시 시전(SkillTest 패널 전용 — 라이브 경로 없음)
local function testCastAs(player, skillId)
	local def = SkillDefs.Skills[skillId]
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not def or not root then
		return
	end
	local level = 1
	local profile = nil
	if DataService.IsLoaded(player) then
		profile = DataService.GetProfile(player)
		local skills = profile and profile.Skills
		local lv = skills and type(skills.Levels) == "table" and skills.Levels[skillId]
		if type(lv) == "number" then
			level = lv
		end
	end
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	local dir = (flat.Magnitude > 0.01) and flat.Unit or Vector3.new(0, 0, -1)
	local weaponId, affinity, affinityKey = resolveCastAffinity(profile, skillId)
	local derived = PlayerService.GetDerived(player)
	local atk = ((derived and derived.Atk) or 10)
		* (SkillDefs.LEVEL_MULT[level] or 1)
		* (affinity and affinity.DamageMul or 1)
	local caster = CASTERS[skillId]
	if caster then
		caster(player, atk, def, root, dir, level)
	end
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			Net.Event("SkillFx"):FireClient(other, character, skillId, dir, level)
		end
	end
end

local function slotCap(player)
	-- [2026-07-29 감사 E5] 슬롯 캡은 공표 어트리뷰트로 읽는다(PurchaseService.ApplyAttributes가 입장 시 세팅).
	-- GetSkillSlotCap→HasPass 경로는 yield해서 쿨다운 기록보다 앞에 창이 열린다 — 동시 캐스트로 쿨 우회 가능.
	local cap = tonumber(player:GetAttribute("SkillSlotCap"))
	if cap then
		return cap
	end
	return PurchaseService.GetSkillSlotCap(player) -- 아직 미공표(입장 직후) — 기존 경로 폴백
end

local function castAs(player, slotIndex, aimDir)
	if type(slotIndex) ~= "number" or slotIndex > slotCap(player) then
		return { ok = false, reason = "locked" }
	end
	if not DataService.IsLoaded(player) then
		return { ok = false, reason = "loading" }
	end
	local profile = DataService.GetProfile(player)
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not profile or not hum or hum.Health <= 0 or not root then
		return { ok = false, reason = "dead" }
	end
	local skills = profile.Skills
	local skillId = skills and skills.Slots and skills.Slots[slotIndex]
	local def = skillId and SkillDefs.Skills[skillId]
	if not def or not (skills.Owned and skills.Owned[skillId]) then
		return { ok = false, reason = "unowned" }
	end
	local weaponId, affinity, affinityKey = resolveCastAffinity(profile, skillId)
	-- [2026-08-05 스킬8종] CooldownByLevel 런타임 지원(바위 갑옷 §6-4) — 레벨을 쿨 판정 전에 조회
	local level = (type(skills.Levels) == "table" and skills.Levels[skillId]) or 1
	local cooldown = arrAt(def.CooldownByLevel, level, def.Cooldown)
	local now = os.clock()
	local mine = lastCastAt[player]
	if not mine then
		mine = {}
		lastCastAt[player] = mine
	end
	local last = mine[skillId]
	if last and (now - last) < (cooldown - SkillDefs.CAST_GRACE) then
		return {
			ok = false,
			reason = "cooldown",
			cooldownEndsAt = Workspace:GetServerTimeNow() + (cooldown - (now - last)),
		}
	end
	-- 마나 게이트: 쿨 통과 후·기록 전(부족 시 쿨 미소모)
	if def.MpCost and def.MpCost > 0 and not PlayerService.SpendMp(player, def.MpCost) then
		return { ok = false, reason = "mp" }
	end
	mine[skillId] = now
	PlayerService.NotifyCombat(player)
	DailyGoalService.Report(player, "Skill", 1)
	-- [2026-07-27 M5] 스킬 사용량 — 쿨 5s × CCU 50이면 건당 발화가 레이트 상한에 근접해 60초 누적한다
	AnalyticsService.Batch(player, "SkillCast", 1, skillId)

	-- 자동 사용은 클라가 aimDir를 함께 보낸다(캐릭터 회전 복제를 기다리면 한 박자 늦음). 수동은 aimDir 없이 캐릭터 정면 — 원래도 캐릭터를 돌려 얻던 자유도라 새 권한 아님.
	local dir
	if typeof(aimDir) == "Vector3" then
		local flat = Vector3.new(aimDir.X, 0, aimDir.Z)
		local m = flat.Magnitude
		if m > 0.01 and m < 1e6 then -- NaN/inf는 두 비교 모두 실패해 걸러진다
			dir = flat.Unit
		end
	end
	if not dir then
		local look = root.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		dir = (flat.Magnitude > 0.01) and flat.Unit or Vector3.new(0, 0, -1)
	end
	local atk = PlayerService.GetDerived(player).Atk
		* (SkillDefs.LEVEL_MULT[level] or 1)
		* (affinity and affinity.DamageMul or 1)

	local caster = CASTERS[skillId]
	if caster then
		caster(player, atk, def, root, dir, level)
	else
		-- [명세 §10-1] 무음 실패 방지 — 등재됐는데 명부가 비면 즉시 경고(마나·쿨은 이미 소모된 상태)
		warn("[SkillService] 미등록 스킬 캐스터: " .. tostring(skillId))
	end

	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if otherRoot and (otherRoot.Position - root.Position).Magnitude <= SkillDefs.FX_RELAY_RADIUS then
				Net.Event("SkillFx"):FireClient(other, character, skillId, dir, level) -- [2026-08-05] level 추가(바위갑옷 지속 등 원격 연출용)
			end
		end
	end

	return {
		ok = true,
		cooldownEndsAt = Workspace:GetServerTimeNow() + cooldown,
		weaponId = weaponId,
		affinityFxKey = affinityKey,
	}
end

-- Unified fragment roll: first kill 100%, then Pct + soft/hard pity. LCK multiplicative (cap).
-- Drop count is differential per monster (SkillDefs.FragDropCount).
local function rollFragments(model, contributors, settlement)
	local monsterId = model:GetAttribute("MonsterId")
	local dropCount = monsterId and SkillDefs.FragDropCount[monsterId]
	if not dropCount then
		return
	end
	local cfg = SkillDefs.FRAG_DROP
	local mdef = MonsterDefs[monsterId]
	local isBoss = mdef ~= nil and mdef.IsBoss == true
	local fxRoot = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	local dropPos = fxRoot and fxRoot.Position or model:GetPivot().Position
	local eligible = settlement and settlement.eligible
	for userId in pairs(eligible or contributors) do
		local player = Players:GetPlayerByUserId(userId)
		if player and DataService.IsLoaded(player) then
			local profile = DataService.GetProfile(player)
			local skills = profile and profile.Skills
			if skills and type(skills.Pity) == "table" and type(skills.FirstFrag) == "table" then
				if isBoss and SkillDefs.FRAG_BOSS_GUARANTEED then
					-- [2026-08-05 명세 §6-6] 보스 = Pct/피티 우회 확정 지급(리스폰 60s+TTK 대비 빈손 방지).
					-- 필드 피티 카운터는 건드리지 않는다(초보 체감 빈도 불변 원칙).
					local count = dropCount
					local firstKey = "BossKill_" .. monsterId
					if not skills.FirstFrag[firstKey] then
						skills.FirstFrag[firstKey] = true -- 보스별 최초 처치 원장(콜백 순서 무관 — Codex 경합 회피)
						count = dropCount * (SkillDefs.FRAG_BOSS_FIRSTKILL_MUL or 1)
					end
					LootService.SpawnDrop(player, FRAG_ID, count, dropPos)
					DataService.MarkDirty(player, "SkillFrag")
				else
					local drop = false
					if not skills.FirstFrag[FRAG_ID] then
						skills.FirstFrag[FRAG_ID] = true
						drop = true
					else
						local pity = skills.Pity[FRAG_ID] or 0
						if pity >= cfg.PityHard - 1 then
							drop = true
						else
							local chance = cfg.Pct + math.max(0, pity - (cfg.PitySoftStart - 1)) * cfg.PitySoftStep
							local lck = (profile.Profile and profile.Profile.Stats and profile.Profile.Stats.LCK) or 0
							chance = math.min(chance * math.min(1 + 0.01 * lck, cfg.LckMulCap), cfg.MaxChance)
							-- [2026-08-05 명세 §6-6] 레벨 격차 감쇠(필드 전용) — chance에만 곱(피티·첫킬 불가침)
							local mLv = mdef and tonumber(mdef.Level)
							local pLv = tonumber(player:GetAttribute("Level"))
							if mLv and pLv and type(SkillDefs.FRAG_LEVEL_GAP) == "table" then
								local gap = pLv - mLv
								for _, band in ipairs(SkillDefs.FRAG_LEVEL_GAP) do
									if gap <= band.MaxGap then
										chance = chance * band.Mul
										break
									end
								end
							end
							drop = math.random() < chance
						end
					end
					if drop then
						skills.Pity[FRAG_ID] = 0
						LootService.SpawnDrop(player, FRAG_ID, dropCount, dropPos)
					else
						skills.Pity[FRAG_ID] = (skills.Pity[FRAG_ID] or 0) + 1
					end
					DataService.MarkDirty(player, "SkillFrag")
				end
			end
		end
	end
end

-- [2026-07-21 W1Q06S] 제본 성공 훅 — QuestChainService가 Skill 타입 퀘 진행에 구독(LootService.OnFragmentGranted 패턴)
local boundCallbacks = {}
function SkillService.OnBound(fn)
	table.insert(boundCallbacks, fn)
end

local function skillLevelCost(skillId, level)
	local tbl = SkillDefs.LEVEL_COST[skillId]
	return tbl and tbl[level]
end

-- Fired via LootService.OnFragmentGranted subscription after fragments enter Inventory.SkillFragments.
-- previousCount/newCount는 실제 지급 구간에서 캡처한다. defer 뒤 현재 총량을 다시 읽어
-- 연속 지급 둘 다 같은 임계값을 통과했다고 오판하는 중복 토스트를 방지한다.
function SkillService.OnFragmentGranted(player, fragId, amount, previousCount, newCount)
	if fragId ~= FRAG_ID or not DataService.IsLoaded(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	local skills = profile and profile.Skills
	if not skills then
		return
	end
	local frags = profile.Inventory.SkillFragments or {}
	local storedCount = tonumber(frags[FRAG_ID]) or 0
	local count = tonumber(newCount) or storedCount
	local prev = tonumber(previousCount)
	if prev == nil then
		-- 디버그·구 호출자 호환 폴백. 정상 지급 경로는 항상 고정 구간을 전달한다.
		prev = count - (tonumber(amount) or 1)
	end
	for _, skillId in ipairs(SkillDefs.Order) do
		local def = SkillDefs.Skills[skillId]
		local owned = skills.Owned and skills.Owned[skillId]
		if not owned and def.BindCost then
			if count >= def.BindCost and prev < def.BindCost then
				Net.Event("Notice"):FireClient(player, { text = skillTextFor(player, "CanBind"):format(skillNameFor(player, skillId, def)) })
			end
		elseif owned then
			local level = (type(skills.Levels) == "table" and skills.Levels[skillId]) or 1
			local cost = level < SkillDefs.LEVEL_MAX and skillLevelCost(skillId, level + 1) or nil
			if cost and count >= cost and prev < cost then
				Net.Event("Notice"):FireClient(player, { text = skillTextFor(player, "CanLevelUp"):format(skillNameFor(player, skillId, def)) })
			end
		end
	end
end

local function bindAs(player, skillId)
	if not DataService.IsLoaded(player) then
		return { ok = false, reason = "loading" }
	end
	local profile = DataService.GetProfile(player)
	local skills = profile and profile.Skills
	local def = skillId and SkillDefs.Skills[skillId]
	if not def or not skills or type(skills.Owned) ~= "table" then
		return { ok = false, reason = "bad" }
	end
	if skills.Owned[skillId] then
		return { ok = false, reason = "owned" }
	end
	local cost = def.BindCost
	if not cost then
		return { ok = false, reason = "bad" }
	end
	local frags = profile.Inventory.SkillFragments or {}
	if (frags[FRAG_ID] or 0) < cost then
		return { ok = false, reason = "frags" }
	end
	frags[FRAG_ID] -= cost
	skills.Owned[skillId] = true
	if type(skills.Levels) ~= "table" then
		skills.Levels = {}
	end
	skills.Levels[skillId] = 1
	for i = 1, slotCap(player) do
		if skills.Slots[i] == nil or skills.Slots[i] == "" then
			skills.Slots[i] = skillId
			break
		end
	end
	DataService.MarkDirty(player, "SkillBind")
	PlayerService.SyncState(player, { "Skills", "Inventory" })
	Net.Event("Notice"):FireClient(player, { text = skillTextFor(player, "BindDone"):format(skillNameFor(player, skillId, def)) })
	-- [2026-07-21 W1Q06S] 제본 훅 발화(상태 확정 후) — 구독자 예외가 제본을 막지 않게 task.spawn+pcall
	for _, fn in ipairs(boundCallbacks) do
		task.spawn(function()
			pcall(fn, player, skillId)
		end)
	end
	return { ok = true }
end

local function levelUpAs(player, skillId)
	if not DataService.IsLoaded(player) then
		return { ok = false, reason = "loading" }
	end
	local profile = DataService.GetProfile(player)
	local skills = profile and profile.Skills
	local def = skillId and SkillDefs.Skills[skillId]
	if not def or not skills or not (skills.Owned and skills.Owned[skillId]) then
		return { ok = false, reason = "unowned" }
	end
	if type(skills.Levels) ~= "table" then
		skills.Levels = {}
	end
	local level = skills.Levels[skillId] or 1
	if level >= SkillDefs.LEVEL_MAX then
		return { ok = false, reason = "max" }
	end
	local cost = skillLevelCost(skillId, level + 1)
	local frags = profile.Inventory.SkillFragments or {}
	if not cost or (frags[FRAG_ID] or 0) < cost then
		return { ok = false, reason = "frags" }
	end
	frags[FRAG_ID] -= cost
	level += 1
	skills.Levels[skillId] = level
	DataService.MarkDirty(player, "SkillLevel")
	PlayerService.SyncState(player, { "Skills", "Inventory" })
	AnalyticsService.Batch(player, "SkillLevelUp", 1, skillId, "Lv - " .. level) -- [명세 §11] 레벨 분포 관측
	-- [2026-07-29 8차 QA] 토스트 수치 = 타격당 위력 %(스킬북 카드와 동일 단위).
	-- 공식 SSOT = applyHit(Atk × LEVEL_MULT × DamagePct) — LEVEL_MULT 상대 증가율(+10%)로 쓰면 카드의 200%→220%와 어긋난다.
	local function powerPct(lv)
		return math.floor(def.DamagePct * (SkillDefs.LEVEL_MULT[lv] or 1) * 100 + 0.5)
	end
	local function tickOf(lv)
		return (type(def.TicksByLevel) == "table" and def.TicksByLevel[lv]) or def.Ticks
	end
	local text = skillTextFor(player, "LevelBonus"):format(skillNameFor(player, skillId, def), level, powerPct(level - 1), powerPct(level))
	local prevTicks, curTicks = tickOf(level - 1), tickOf(level)
	if curTicks and prevTicks ~= curTicks then -- 타격 횟수까지 늘은 레벨에만 병기(회오리 Lv3·4·5)
		text = text .. " " .. skillTextFor(player, "TickSuffix"):format(curTicks)
	end
	Net.Event("Notice"):FireClient(player, { text = text })
	return { ok = true, level = level }
end

-- [2026-08-05 명세 §2] 보스 처치 스킬 해금 — SkillDefs.Skills[*].Unlock = { Boss, Pct, RampStartTry, RampStepPct, CeilTry }
local UNLOCKS_BY_BOSS = {} -- [monsterId] = { skillId, ... }
for _, unlockSkillId in ipairs(SkillDefs.Order) do
	local u = SkillDefs.Skills[unlockSkillId] and SkillDefs.Skills[unlockSkillId].Unlock
	if u and u.Boss then
		local list = UNLOCKS_BY_BOSS[u.Boss]
		if not list then
			list = {}
			UNLOCKS_BY_BOSS[u.Boss] = list
		end
		table.insert(list, unlockSkillId)
	end
end

-- 습득 확정 공통 경로(보스 드랍·소급·성장조건 공용). Owned/Levels는 이 시점에 생성(§8-2).
local function grantSkill(player, profile, skillId, source)
	local skills = profile.Skills
	if type(skills) ~= "table" or type(skills.Owned) ~= "table" then
		return false
	end
	if skills.Owned[skillId] then
		return false
	end
	skills.Owned[skillId] = true
	if type(skills.Levels) ~= "table" then
		skills.Levels = {}
	end
	skills.Levels[skillId] = 1
	autoFillSlots(player, profile) -- 빈 슬롯 자동 장착(§2-7)
	DataService.MarkDirty(player, "SkillGrant")
	PlayerService.SyncState(player, { "Skills" })
	local def = SkillDefs.Skills[skillId]
	Net.Event("Notice"):FireClient(player, { text = skillTextFor(player, "BindDone"):format(skillNameFor(player, skillId, def)) })
	-- [명세 §2-7] 획득 모달+강제 1회 시전 트리거(클라 SkillController) — 소급(retro)은 모달만(강제 시전 생략 §2-5)
	Net.Event("SkillAcquired"):FireClient(player, skillId, tostring(source))
	-- [명세 §11] skill_acquired — source: boss/derive/retro
	AnalyticsService.Batch(player, "SkillAcquired", 1, skillId, "Src - " .. tostring(source))
	return true
end
SkillService._grantSkill = grantSkill

-- P(n) 확률 모델(§2-3): n<RampStart→기본 / 이후 +Step×(n-시작+1) / n≥Ceil→확정
local function unlockChance(u, tryN)
	if u.CeilTry and tryN >= u.CeilTry then
		return 1
	end
	local chance = u.Pct
	if u.RampStartTry and u.RampStartTry > 0 and tryN >= u.RampStartTry then
		chance += (u.RampStepPct or 0) * (tryN - u.RampStartTry + 1)
	end
	return math.min(chance, 1)
end
SkillService._unlockChance = unlockChance -- 몸테카를로 검증(§10-4) 공용

-- 판정·카운터 모두 기여도 자격(settlement.eligible) 통과자 한정(§2-3 — 막타 치고 빠지기 악용 차단)
local function rollSkillUnlocks(model, settlement)
	local monsterId = model:GetAttribute("MonsterId")
	local list = monsterId and UNLOCKS_BY_BOSS[monsterId]
	if not list then
		return
	end
	local eligible = settlement and settlement.eligible
	if not eligible then
		return
	end
	for userId in pairs(eligible) do
		local player = Players:GetPlayerByUserId(userId)
		if player and DataService.IsLoaded(player) then
			local profile = DataService.GetProfile(player)
			local skills = profile and profile.Skills
			if skills and type(skills.Owned) == "table" then
				for _, skillId in ipairs(list) do
					if not skills.Owned[skillId] then
						local u = SkillDefs.Skills[skillId].Unlock
						if type(skills.BossTry) ~= "table" then
							skills.BossTry = {}
						end
						local tryN = (skills.BossTry[skillId] or 0) + 1
						skills.BossTry[skillId] = tryN
						DataService.MarkDirty(player, "SkillBossTry")
						AnalyticsService.Batch(player, "SkillBossTry", 1, skillId)
						if math.random() < unlockChance(u, tryN) then
							grantSkill(player, profile, skillId, "boss")
						end
					end
				end
			end
		end
	end
end

-- [2026-08-05 명세 §2-5] 성장조건형 상태검사 — 내리찍기(강화+3)·검비(★4 무기).
-- 🔴이벤트 훅 금지: "최초 도달"은 재현 불가 — 강화 시도/무기 획득 시점마다 현재 인벤토리 상태를 검사해 지급.
-- (로그인 자동 지급 아님 — "새로 획득" 원칙 유지)
local function checkDerivedSkills(player)
	if not DataService.IsLoaded(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	local skills = profile and profile.Skills
	if not skills or type(skills.Owned) ~= "table" then
		return
	end
	local weapons = profile.Inventory and profile.Inventory.Weapons or {}
	if not skills.Owned.GiantSlam then
		for _, rec in pairs(weapons) do
			if (tonumber(rec.Enhance) or 0) >= 3 then
				grantSkill(player, profile, "GiantSlam", "derive")
				break
			end
		end
	end
	if not skills.Owned.RapierRain then
		for _, rec in pairs(weapons) do
			local wdef = rec.WeaponId and WeaponDefs.Weapons and WeaponDefs.Weapons[rec.WeaponId]
			if wdef and (tonumber(wdef.Star) or 1) >= 4 then
				grantSkill(player, profile, "RapierRain", "derive")
				break
			end
		end
	end
end
SkillService._checkDerivedSkills = checkDerivedSkills

-- [명세 §8-3] 소급 지급 — 황금 당근 전용. 🔴순서: 플래그 → 저장 → 지급(TOCTOU — 지급 후 크래시 시 중복 지급 방지)
local function retroGrants(player, profile)
	local skills = profile.Skills
	if type(skills) ~= "table" then
		return
	end
	if type(skills.RetroDone) ~= "table" then
		skills.RetroDone = {}
	end
	if skills.RetroDone.GoldenCarrot then
		return
	end
	local kills = profile.Codex and profile.Codex.Kills
	if not (type(kills) == "table" and (kills.CarrotBoss or 0) > 0) then
		return -- 처치 이력 없음 — 처치 훅 경로로 획득
	end
	if skills.Owned and skills.Owned.GoldenCarrot then
		skills.RetroDone.GoldenCarrot = true -- 이미 보유(처치 훅 선행) — 플래그만 기록
		DataService.MarkDirty(player, "SkillRetro")
		return
	end
	skills.RetroDone.GoldenCarrot = true
	DataService.MarkDirty(player, "SkillRetro")
	pcall(DataService.ForceSave, player, "SkillRetro") -- 플래그 저장 확인 후 지급(§8-3 순서)
	grantSkill(player, profile, "GoldenCarrot", "retro")
end

SkillService._retroGrants = retroGrants -- [2026-08-05] DebugService 소급 재실행 검증 창구(모의 스토어 비영속 — 재접속 시나리오 대체)

local function grantDefaults(player, profile)
	local skills = profile.Skills
	if type(skills) ~= "table" or type(skills.Owned) ~= "table" or type(skills.Slots) ~= "table" then
		return
	end
	local changed = false
	for _, id in ipairs(SkillDefs.STARTER_SKILLS) do
		if not skills.Owned[id] then
			skills.Owned[id] = true
			changed = true
		end
	end
	if skills.Slots[1] == nil or skills.Slots[1] == "" then
		skills.Slots[1] = SkillDefs.STARTER_SKILLS[1] or ""
		changed = true
	end
	-- 끓어당기기: 슬롯3(T) 자동 장착(스타터)
	-- [2026-07-23] default: active skills pack front (slot1=E, slot2=R), slot3(T)=locked until bind
	if (skills.Slots[2] == nil or skills.Slots[2] == "") and skills.Slots[3] == "Pull" then
		skills.Slots[2] = "Pull" -- migration: old default(slot3) -> slot2
		skills.Slots[3] = ""
		changed = true
	end
	local second = SkillDefs.STARTER_SKILLS[2]
	if second and skills.Owned[second] and (skills.Slots[2] == nil or skills.Slots[2] == "")
		and skills.Slots[1] ~= second and skills.Slots[3] ~= second then
		skills.Slots[2] = second
		changed = true
	end
	if changed then
		DataService.MarkDirty(player, "SkillsGrant")
		PlayerService.SyncState(player, { "Skills" })
	end
	autoFillSlots(player, profile) -- [2026-07-27] 구매 후 재접속 경로도 커버(입장 시점 cap 기준)
	retroGrants(player, profile) -- [2026-08-05 명세 §8-3] 황금 당근 소급(1회성)
end

-- [2026-07-27] 슬롯 해금 즉시 사용 가능하게: 해금된 범위(slotCap) 안의 빈 슬롯을 보유 스킬로 자동으로 채운다.
-- 보유 스킬이 빈 슬롯 수보다 적으면 그만큼만 채운다(없는 스킬을 발명하지 않는다).
function autoFillSlots(player, profile)
	if not profile then
		if not DataService.IsLoaded(player) then
			return false
		end
		profile = DataService.GetProfile(player)
	end
	local skills = profile and profile.Skills
	if not skills or type(skills.Slots) ~= "table" or type(skills.Owned) ~= "table" then
		return false
	end
	local assigned = {}
	for i = 1, 3 do
		local id = skills.Slots[i]
		if type(id) == "string" and id ~= "" then
			assigned[id] = true
		end
	end
	local changed = false
	for i = 1, slotCap(player) do
		local cur = skills.Slots[i]
		if cur == nil or cur == "" then
			for _, id in ipairs(SkillDefs.Order) do
				if skills.Owned[id] and not assigned[id] then
					skills.Slots[i] = id
					assigned[id] = true
					changed = true
					break
				end
			end
		end
	end
	if changed then
		DataService.MarkDirty(player, "SkillSlotAutoFill")
		PlayerService.SyncState(player, { "Skills" })
	end
	return changed
end

SkillService.AutoFillSlots = autoFillSlots

-- [2026-07-23] quickslot assign/swap from skill book (owned skills only)
local function assignAs(player, skillId, slotIndex)
	if type(slotIndex) ~= "number" or slotIndex % 1 ~= 0 or slotIndex < 1 or slotIndex > 3 then
		return { ok = false, reason = "bad" }
	end
	if slotIndex > slotCap(player) then
		return { ok = false, reason = "locked" }
	end
	if not DataService.IsLoaded(player) then
		return { ok = false, reason = "loading" }
	end
	local profile = DataService.GetProfile(player)
	local skills = profile and profile.Skills
	if not skills or type(skills.Slots) ~= "table" or not SkillDefs.Skills[skillId] then
		return { ok = false, reason = "bad" }
	end
	if not (skills.Owned and skills.Owned[skillId]) then
		return { ok = false, reason = "unowned" }
	end
	local fromIndex = nil
	for i = 1, 3 do
		if skills.Slots[i] == skillId then
			fromIndex = i
		end
	end
	if fromIndex == slotIndex then
		return { ok = true }
	end
	local displaced = skills.Slots[slotIndex]
	skills.Slots[slotIndex] = skillId
	if fromIndex then
		skills.Slots[fromIndex] = displaced or "" -- swap(밀려난 스킬은 원래 자리로) / 빈 칸이면 해제
	end
	DataService.MarkDirty(player, "SkillAssign")
	PlayerService.SyncState(player, { "Skills" })
	-- [2026-07-27] 들어오는 스킬이 원래 슬롯에 없었으면(fromIndex=nil) 밀려난 스킬은 돌아갈 자리가 없어 그대로 해제된다.
	-- 화면에 표시가 없어 "스킬이 사라졌나?" 하는 오해가 있었다(사장님 QA) — 보유는 그대로란 점을 토스트로 알린다.
	if not fromIndex and type(displaced) == "string" and displaced ~= "" then
		local ddef = SkillDefs.Skills[displaced]
		if ddef then
			Net.Event("Notice"):FireClient(player, { text = skillTextFor(player, "SlotUnassigned"):format(skillNameFor(player, displaced, ddef)) })
		end
	end
	return { ok = true }
end

SkillService._castAs = castAs
SkillService._assignAs = assignAs
SkillService._levelUpAs = levelUpAs
SkillService._bindAs = bindAs

function SkillService.Init()
	PlayerService = require(script.Parent:WaitForChild("PlayerService"))
	DataService = require(script.Parent:WaitForChild("DataService"))
	CombatService = require(script.Parent:WaitForChild("CombatService"))
	LootService = require(script.Parent:WaitForChild("LootService"))
	PurchaseService = require(script.Parent:WaitForChild("PurchaseService"))
	DailyGoalService = require(script.Parent:WaitForChild("DailyGoalService"))
	AnalyticsService = require(script.Parent:WaitForChild("AnalyticsService"))
	-- [2026-07-21] 조각 획득 통지 구독 — LootService 측 인라인 require 폐지(순환 경고 해소)
	LootService.OnFragmentGranted(SkillService.OnFragmentGranted)
	DataService.OnLoaded(grantDefaults)
	-- [2026-08-05 명세 §2-5] 성장조건형 상태검사 훅 — 강화 완료·제작 완료 시점마다 재검사(기존 유저도 행동 1회로 획득)
	local CraftService = require(script.Parent:WaitForChild("CraftService"))
	CraftService.OnEnhanced(function(enhPlayer)
		checkDerivedSkills(enhPlayer)
	end)
	CraftService.OnCrafted(function(craftPlayer)
		checkDerivedSkills(craftPlayer)
	end)
	CombatService.OnKilled(function(model, contributors, _lastHitter, settlement)
		-- [2026-08-06 사장님 지시] 처치 시 마나 회복 — 초반 마나 고갈 완화.
		-- 초반 몹은 자주 죽어 효과가 크고, 후반 몹은 오래 버텨 상대적으로 미미하다(자동 초반 편중).
		-- 자격은 다른 보상과 동일 기준(settlement.eligible) — 막타만 치고 빠지는 악용 차단.
		for userId in pairs((settlement and settlement.eligible) or contributors or {}) do
			local p = Players:GetPlayerByUserId(userId)
			if p then
				PlayerService.AddMp(p, KILL_MP_RESTORE)
			end
		end
		rollFragments(model, contributors, settlement)
		rollSkillUnlocks(model, settlement) -- [2026-08-05 명세 §2] 보스 처치 스킬 해금(자격 통과자 한정)
	end)
	Net.Function("SkillCast").OnServerInvoke = function(player, slotIndex, aimDir)
		if not allowCastIngress(player) then
			return { ok = false, reason = "rate" }
		end
		if slotIndex ~= 1 and slotIndex ~= 2 and slotIndex ~= 3 then
			return { ok = false, reason = "bad" }
		end
		local active = castInFlight[player] or 0
		if active >= 3 then
			return { ok = false, reason = "busy" }
		end
		castInFlight[player] = active + 1
		local ok, result = pcall(castAs, player, slotIndex, aimDir)
		local remaining = math.max(0, (castInFlight[player] or 1) - 1)
		castInFlight[player] = remaining > 0 and remaining or nil
		if not ok then
			warn("[SkillService] SkillCast 실패 | " .. tostring(result))
			return { ok = false, reason = "server" }
		end
		return result
	end
	Net.Function("SkillManage").OnServerInvoke = function(player, action, skillId, slotIndex)
		if type(skillId) ~= "string" then
			return { ok = false, reason = "bad" }
		end
		if action == "levelup" then
			return levelUpAs(player, skillId)
		elseif action == "bind" then
			return bindAs(player, skillId)
		elseif action == "assign" then
			return assignAs(player, skillId, slotIndex)
		end
		return { ok = false, reason = "bad" }
	end
end

function SkillService.Start()
	if RunService:IsStudio() then
		local testEvent = ReplicatedStorage:FindFirstChild("StudioSkillTest")
		if not testEvent then
			testEvent = Instance.new("RemoteEvent")
			testEvent.Name = "StudioSkillTest"
			testEvent.Parent = ReplicatedStorage
		end
		testEvent.OnServerEvent:Connect(function(player, skillId)
			if type(skillId) == "string" then
				testCastAs(player, skillId)
			end
		end)
	end
	-- [2026-07-27] 슬롯 추가 구매 즉시 반응: PurchaseService.ApplyAttributes가 SkillSlotCap을 올리는 순간
	-- 빈 슬롯을 자동으로 채운다. 어트리뷰트 구독이라 PurchaseService에 역의존을 만들지 않는다.
	local function hookSlotCap(player)
		player:GetAttributeChangedSignal("SkillSlotCap"):Connect(function()
			autoFillSlots(player)
		end)
	end
	Players.PlayerAdded:Connect(hookSlotCap)
	for _, player in ipairs(Players:GetPlayers()) do
		hookSlotCap(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastCastAt[player] = nil
		castIngress[player] = nil
		castInFlight[player] = nil
		clearShield(player)
	end)
end

return SkillService
