-- CombatService: 서버 권위 전투 — 쿨다운 → 타겟 선정 → 피해 기록 → 사망 정산(모델당 1회).
-- 제약: 판정 수치는 ReplicatedStorage.Defs.WeaponDefs에서만 읽는다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Defs = ReplicatedStorage:WaitForChild("Defs")
local WeaponDefs = require(Defs:WaitForChild("WeaponDefs"))
local AVDefs = require(Defs:WaitForChild("AVDefs")) -- 스윙 릴레이 반경 등 연출 상수
local MonsterDefs = require(Defs:WaitForChild("MonsterDefs")) -- 피격 넉백 보스 제외 판별
local GameConfig = require(Defs:WaitForChild("GameConfig")) -- HUNT: 보상 자격 기준
local Strings = require(Defs:WaitForChild("Strings"))
local Net = require(ReplicatedStorage:WaitForChild("Net"))

local CombatService = {}

-- 순환 require 방지: Init 시점 resolve
local PlayerService
local DataService
local AnalyticsService -- [2026-07-27 계측 v2] 온보딩 2·3 + 처치 배치

-- 온보딩 관측점(번호 SSOT = AnalyticsService.ONBOARD_NAMES)
local ONBOARD_FIRST_ATTACK = 2
local ONBOARD_FIRST_KILL = 3
-- 매 스윙마다 프로필을 조회하지 않기 위한 세션 캡시(원장은 여전히 프로필이 권위)
local onboardAttackDone = {}

local MONSTER_TAG = "Monster"

local lastAttackAt = {} -- [player] = 마지막 공격 시각(os.clock)
local comboState = {} -- [player] = { index, key }
local damageLog = {} -- [model] = { [userId] = 누적 피해 }
local lastHitLog = {} -- [model] = { [userId] = 마지막 타격 os.clock } — 비활동 판정용
local settled = {} -- [model] = true (사망 정산 1회 보장)
local cleanupConns = {} -- [model] = Destroying 연결
local killedCallbacks = {}
local swingCallbacks = {} -- [2026-07-25 C3] 스윙 훅(fn(player, root)) — 돼지 피격음 등 월드 반응 소비
local damageConfirmedCallbacks = {} -- 서버 확정 평타 명중 훅(fn(player, monsterId, snapshot)) — UseWeapon 퀘스트 소비
-- Sticky grace: 명중 넉백(~6.2)이 유효 사거리(6.0)를 넘어 후속 스윙이 빗나감 — 직전 명중 모델만 STICKY_SEC 동안 연장 사거리 허용(PvE 안전: 몹이 추격).
local STICKY_SEC = 1.2
local STICKY_BONUS = 7
local lastHitInfo = {}
local ATTACK_REQUEST_RATE = 8
local ATTACK_REQUEST_BURST = 12
local attackRequestBuckets = {}
local firstHitHintShown = {}

local function firstHitGuideEnabled()
	local cfg = GameConfig.FIRST_HIT_GUIDE
	return type(cfg) == "table" and cfg.Enabled == true
		and (not RunService:IsStudio() or cfg.StudioPreview == true)
end

local function firstHitGuideActive(player, profile, attackMode)
	if not firstHitGuideEnabled() or (attackMode ~= nil and attackMode ~= "Ground")
		or player:GetAttribute("CombatGuideOn") == false
		or player:GetAttribute("InBossZone") == true
		or player:GetAttribute("W1Q01FirstDamageDone") == true then
		return false
	end
	local cfg = GameConfig.FIRST_HIT_GUIDE
	local quest = profile and profile.QuestChain
	return type(quest) == "table"
		and (tonumber(quest.Index) or 0) == (tonumber(cfg.QuestIndex) or 1)
		and (tonumber(quest.Progress) or 0) <= 0
end

local function showFirstHitMoveCloser(player, profile, attackMode)
	if firstHitHintShown[player] or not firstHitGuideActive(player, profile, attackMode) then
		return
	end
	firstHitHintShown[player] = true
	Net.Event("Notice"):FireClient(player, { text = Strings.getFor(player, "Combat_FirstHit_MoveCloser") })
	AnalyticsService.FirstHitGuideState(player, "MoveCloserShown", tostring(GameConfig.FIRST_HIT_GUIDE.TargetId or "Carrot"))
end

local function allowAttackRequest(player)
	local now = os.clock()
	local state = attackRequestBuckets[player]
	if not state then
		attackRequestBuckets[player] = { tokens = ATTACK_REQUEST_BURST - 1, at = now }
		return true
	end
	local tokens = math.min(ATTACK_REQUEST_BURST, state.tokens + (now - state.at) * ATTACK_REQUEST_RATE)
	state.at = now
	if tokens < 1 then
		state.tokens = tokens
		return false
	end
	state.tokens = tokens - 1
	return true
end

local function clearModel(model)
	damageLog[model] = nil
	lastHitLog[model] = nil
	settled[model] = nil
	local conn = cleanupConns[model]
	if conn then
		conn:Disconnect()
		cleanupConns[model] = nil
	end
end

local function trackModel(model)
	local log = damageLog[model]
	if log then
		return log
	end
	log = {}
	damageLog[model] = log
	cleanupConns[model] = model.Destroying:Connect(function()
		clearModel(model)
	end)
	return log
end

local function noteHit(model, userId)
	local hits = lastHitLog[model]
	if not hits then
		hits = {}
		lastHitLog[model] = hits
	end
	hits[userId] = os.clock()
end

-- 보상 자격 단일 판정: 지분 + 최근 타격. EXP·드랍·퀘스트·도감·일일목표·조각이 같은 결과를 쓴다
-- (구: 6곳이 제각각 판정해 도감·칭호·배지만 게이트가 빠져 있었다).
-- 비활동자는 분모에서 제외하되 기여도 표시(GetContributors)에는 그대로 남긴다.
local function buildSettlement(model)
	local log = damageLog[model] or {}
	local hits = lastHitLog[model] or {}
	local mdef = MonsterDefs[model:GetAttribute("MonsterId")]
	local isBoss = mdef ~= nil and mdef.IsBoss == true
	local cfg = GameConfig.HUNT
	local window = isBoss and cfg.BossActiveSec or cfg.NormalActiveSec
	local minShare = isBoss and cfg.BossShareMin or cfg.NormalShareMin
	local now = os.clock()
	local active, activeTotal = {}, 0
	for userId, dmg in pairs(log) do
		local at = hits[userId]
		if at and (now - at) <= window then
			active[userId] = dmg
			activeTotal += dmg
		end
	end
	local eligible, share, any = {}, {}, false
	for userId, dmg in pairs(active) do
		local s = activeTotal > 0 and (dmg / activeTotal) or 1
		share[userId] = s
		if s >= minShare then
			eligible[userId] = true
			any = true
		end
	end
	if not any and not isBoss and cfg.NormalSafety then
		local topId, topDmg = nil, -1
		for userId, dmg in pairs(active) do
			if dmg > topDmg then
				topId, topDmg = userId, dmg
			end
		end
		if topId then
			eligible[topId] = true
		end
	end
	return { eligible = eligible, share = share, isBoss = isBoss, minShare = minShare }
end

-- 파티 HP 스케일용 최근 타격자 수(2026-08-20 재밸런스 — 존 재실이 아니라 '때린 사람'만 센다).
-- windowSec 내 타격 기록 + 접속 중이면 카운트. 사망·존 이탈도 창 동안 유예(교대 릴레이 완화).
function CombatService.GetRecentAttackerCount(model, windowSec)
	local hits = lastHitLog[model]
	if not hits then
		return 0
	end
	local now = os.clock()
	local n = 0
	for userId, at in pairs(hits) do
		if (now - at) <= windowSec and Players:GetPlayerByUserId(userId) then
			n += 1
		end
	end
	return n
end

local function copyContributors(model)
	local copy = {}
	local log = damageLog[model]
	if log then
		for userId, dmg in pairs(log) do
			copy[userId] = dmg
		end
	end
	return copy
end

-- 장착 무기 옵션(제작 시 1회 확정 롤): 공속/치확/치피 — 구 레코드(옵션 없음)=빈 테이블
local EMPTY_OPTIONS = {}
local function equippedOptions(profile)
	local uid = profile.Inventory.EquippedWeaponUid
	if uid and uid ~= 0 then
		local weapon = profile.Inventory.Weapons[tostring(uid)]
		if weapon and type(weapon.Options) == "table" then
			return weapon.Options
		end
	end
	return EMPTY_OPTIONS
end

-- 장착 무기 전투 프로필 결정: 서버 프로필이 WeaponId/Kind/판정의 단일 권위다.
local function equippedAttackInfo(profile)
	local uid = profile.Inventory.EquippedWeaponUid
	if uid and uid ~= 0 then
		local weapon = profile.Inventory.Weapons[tostring(uid)]
		local weaponId = WeaponDefs.ResolveWeaponId(weapon)
		local weaponKind = WeaponDefs.ResolveKind(weapon)
		local attackKind = weaponKind == "Hammer" and "Blunt" or "Slash"
		local weaponType = WeaponDefs.ResolveWeaponType(weapon)
		local enhance = math.clamp(math.floor(tonumber(weapon and weapon.Enhance) or 0), 0, 10)
		return WeaponDefs.Kinds[weaponKind], WeaponDefs.MotionOf(weaponId), weaponId, attackKind, weaponType, enhance, tostring(uid)
	end
	return WeaponDefs.Kinds.Starter, WeaponDefs.MotionOf("Starter"), "Starter", "Slash", "OneHandSword", 0, "0"
end

local function isAirborne(humanoid)
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Climbing or state == Enum.HumanoidStateType.Swimming
		or state == Enum.HumanoidStateType.Seated or state == Enum.HumanoidStateType.Dead then
		return false
	end
	return humanoid.FloorMaterial == Enum.Material.Air
end

-- 유효 사거리 = range + (모델 HitRadius 어트리뷰트 or TARGET_RADIUS_PAD) + RANGE_EPSILON
-- HitRadius = 스폰 시 모델 수평 크기(Monster/BossService) — 대형 보스 가장자리 타격 허용.
-- 🔴거리는 수평(XZ) 기준 — 3D 중심거리면 키 큰 모델이 타격 불가가 된다(수직 분리는 높이 허용치로 별도 배제).
local VERTICAL_PAD = 6 -- studs added on top of half the model height (jump attacks, slopes)
-- [QA 2026-08-24 Stage2] Big bosses leap: MotherGoblin (halfH 22) rises 18 studs during LeapSlam,
-- so the offset hits 37 while the old limit was halfH+6 = 28 -> the player literally could not
-- damage it mid-jump ("boss takes no damage on its jump attack"). The pad now scales with the
-- model, so small mobs keep the old 6 and tall bosses stay hittable while airborne.
-- [QA 2026-08-24 추가] halfH*0.9 비율만으로는 도약이 높은 보스(Wolf·ForestKeeper)에서 여전히 부족했다
-- (실측: 도약 정점 offset.Y가 허용치를 근소하게 초과 — 밀착 상태에서도 간헐적으로 썰힌다).
-- LeapSlam.RiseHeight를 직접 반영해야 정확하다 — 보스마다 도약 높이가 다르기 때문(16~22 범위).
local function verticalAllowance(halfH, monsterId)
	local base = halfH + math.max(VERTICAL_PAD, halfH * 0.9)
	local def = monsterId and MonsterDefs[monsterId]
	local leap = def and def.LeapSlam
	if leap and type(leap.RiseHeight) == "number" then
		-- standY ≈ halfH(이륙 지점 이상치 폴백과 동일 근사) + 도약 최고높이 + 여유 4
		base = math.max(base, halfH + leap.RiseHeight + 4)
	end
	return base
end
-- 이동 래그 보정: 서버가 보는 클라 캐릭터는 ~3스터드 뒤처져 접근 선타가 빗나감 — 현재 위치 또는 속도 투영 위치 중 하나만 사거리 내면 명중(악용 상한 = WalkSpeed * LAG_COMP_SEC).
local LAG_COMP_SEC = 0.2
-- 전방 원뿔 우선: 단순 최근접은 등 뒤 몹을 잡음 — 원뿔 내 후보를 가까운 순 반환(최대 MULTI_TARGET_MAX), 원뿔이 비면 최근접 1기 폴백(뒤에서 때리는 몹 대응).
local CONE_COS = 0.5 -- cos(60) — left/right 60 degrees
local MULTI_TARGET_MAX = 3
local MULTI_TARGET_FALLOFF = 0.7 -- 2순위부터 피해 배율(1순위 100%)
-- 몬스터 후보 엔트리 캐시(TTL=ENTRY_TTL): 모델 존재·구조(IsA/부모/Humanoid/어트리뷰트 약 7회 조회)만 캐시.
-- 대상 약 101마리 × 공격 빈도만큼 반복되던 비용을 줄인다. 신규 스폰은 최대 ENTRY_TTL만큼 늦게 후보 진입(스폰 연출이 더 길다).
-- 🔴생존·은신 판정(Health·IsDescendantOf·Untargetable)은 캐시 금지 — 항상 실시간 재조회.
local ENTRY_TTL = 0.1
local entryCache = {}
local entryCacheAt = -1

local function monsterCandidates()
	local now = os.clock()
	if now - entryCacheAt < ENTRY_TTL then
		return entryCache
	end
	entryCacheAt = now
	table.clear(entryCache)
	for _, model in ipairs(CollectionService:GetTagged(MONSTER_TAG)) do
		if model:IsA("Model") then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
			if humanoid and root then
				local pad = model:GetAttribute("HitRadius")
				if type(pad) ~= "number" then
					pad = WeaponDefs.TARGET_RADIUS_PAD
				end
				local halfH = model:GetAttribute("HalfHeight")
				if type(halfH) ~= "number" then
					local _, modelSize = model:GetBoundingBox()
					halfH = modelSize.Y * 0.5
					model:SetAttribute("HalfHeight", halfH)
				end
				table.insert(entryCache, { model = model, hum = humanoid, root = root, pad = pad, halfH = halfH })
			end
		end
	end
	return entryCache
end

-- 모바일 표적 힌트는 방향만 보조한다. 피해 대상·사거리·생존 여부는 기존 서버 판정이 최종 결정한다.
local ASSIST_EXTRA_RANGE = 3
local ASSIST_REQUEST_COS = math.cos(math.rad(120))
local function validatedAssistLook(character, root, kindDef, target)
	if typeof(target) ~= "Instance" or not target:IsA("Model")
		or not target:IsDescendantOf(Workspace)
		or not CollectionService:HasTag(target, MONSTER_TAG)
		or target:GetAttribute("Untargetable") == true then
		return nil
	end
	local targetHum = target:FindFirstChildOfClass("Humanoid")
	local targetRoot = target.PrimaryPart or target:FindFirstChild("HumanoidRootPart")
	if not targetHum or targetHum.Health <= 0 or not targetRoot then
		return nil
	end

	local offset = targetRoot.Position - root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude <= 0.05 then
		return nil
	end
	local hitRadius = tonumber(target:GetAttribute("HitRadius")) or WeaponDefs.TARGET_RADIUS_PAD
	local maxHintRange = (tonumber(kindDef.Range) or 0) + hitRadius + ASSIST_EXTRA_RANGE
	if flat.Magnitude > maxHintRange then
		return nil
	end
	local halfH = tonumber(target:GetAttribute("HalfHeight"))
	if not halfH then
		local _, size = target:GetBoundingBox()
		halfH = size.Y * 0.5
		target:SetAttribute("HalfHeight", halfH)
	end
	if math.abs(offset.Y) > verticalAllowance(halfH, target:GetAttribute("MonsterId")) then
		return nil
	end

	-- 클라이언트 회전 복제가 늦어도 측면 표적은 허용하되, 명백한 후방 원격 힌트는 거부한다.
	local rootFlat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	if rootFlat.Magnitude > 0.05 and rootFlat.Unit:Dot(flat.Unit) < ASSIST_REQUEST_COS then
		return nil
	end
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	rayParams.IgnoreWater = true
	local rayOrigin = root.Position + Vector3.new(0, 2, 0)
	local hit = Workspace:Raycast(rayOrigin, targetRoot.Position - rayOrigin, rayParams)
	if hit and not hit.Instance:IsDescendantOf(target) then
		return nil
	end
	return flat.Unit
end

local function findTargets(origin, range, velocity, lookDir, sticky, hitProfile)
	local coneCos = math.clamp(tonumber(hitProfile and hitProfile.ConeCos) or CONE_COS, -1, 1)
	local maxTargets = math.clamp(math.floor(tonumber(hitProfile and hitProfile.MaxTargets) or MULTI_TARGET_MAX), 1, 6)
	-- 랙 보정 속도 클램프: 클라 스푸핑 상한 — FieldBossService.leadTargetPos와 동일 규약(수평 30 stud/s)
	if velocity then
		local flatVel = Vector3.new(velocity.X, 0, velocity.Z)
		if flatVel.Magnitude > 30 then
			velocity = flatVel.Unit * 30
		end
	end
	local lookFlat = nil
	if lookDir then
		local flat = Vector3.new(lookDir.X, 0, lookDir.Z)
		if flat.Magnitude > 0.01 then
			lookFlat = flat.Unit
		end
	end
	local cone = {} -- { model, hum, dist } 원뿔 내 후보 전원
	local best, bestDist, bestHumanoid = nil, math.huge, nil
	for _, e in ipairs(monsterCandidates()) do
		local model, humanoid, root = e.model, e.hum, e.root
		if model:IsDescendantOf(Workspace) then
			-- [2026-07-22] Untargetable: 벽돌대왕 1페 은신 본체 등 타겟 탐색 제외(프록시가 전투 대행)
			if humanoid and humanoid.Health > 0 and root and model:GetAttribute("Untargetable") ~= true then
				local hitRadius = e.pad
				local offset = root.Position - origin
				local dist = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if velocity then
					local projected = origin + Vector3.new(velocity.X, 0, velocity.Z) * LAG_COMP_SEC
					local offP = root.Position - projected
					dist = math.min(dist, Vector3.new(offP.X, 0, offP.Z).Magnitude)
				end
				local halfH = e.halfH
				if type(halfH) ~= "number" then
					local _, modelSize = model:GetBoundingBox()
					halfH = modelSize.Y * 0.5
					model:SetAttribute("HalfHeight", halfH) -- 타 스포너 모델 자가 캐시
				end
				local vertLimit = verticalAllowance(halfH, model:GetAttribute("MonsterId"))
				local allowed = range + hitRadius + WeaponDefs.RANGE_EPSILON
				if sticky and sticky.model == model and os.clock() - sticky.at <= STICKY_SEC then
					allowed += STICKY_BONUS
				end
				if math.abs(offset.Y) <= vertLimit and dist <= allowed then
					local flat = Vector3.new(offset.X, 0, offset.Z)
					-- Point-blank (<1 stud) targets skip the cone check — direction is meaningless there
					local inCone = lookFlat == nil or flat.Magnitude < 1
						or flat.Unit:Dot(lookFlat) >= coneCos
					if inCone then
						table.insert(cone, { model = model, hum = humanoid, dist = dist })
					end
					if dist < bestDist then
						best, bestDist, bestHumanoid = model, dist, humanoid
					end
				end
			end
		end
	end
	if #cone > 0 then
		table.sort(cone, function(a, b)
			return a.dist < b.dist
		end)
		while #cone > maxTargets do
			table.remove(cone)
		end
		return cone
	end
	if best then
		return { { model = best, hum = bestHumanoid, dist = bestDist } }
	end
	return {}
end

local function applyDef(ledgerModel, dmg)
	-- 난이도별 방어력은 스폰 생애에 고정한 Attribute가 원본 Def보다 우선한다.
	local stamped = tonumber(ledgerModel:GetAttribute("Defense"))
	local def = MonsterDefs[ledgerModel:GetAttribute("MonsterId")]
	return math.max(1, math.floor(dmg + 0.5) - (stamped or ((def and def.Def) or 0)))
end

local function resolveDamageTarget(model, humanoid)
	if model:GetAttribute("DamageProxyFor") == nil then
		return model, humanoid
	end
	local ov = model:FindFirstChild("ProxyTarget")
	local host = ov and ov:IsA("ObjectValue") and ov.Value
	if not host or not host:IsA("Model") or not host:IsDescendantOf(Workspace) then
		return nil, nil
	end
	local hostHum = host:FindFirstChildOfClass("Humanoid")
	if not hostHum or hostHum.Health <= 0 then
		return nil, nil
	end
	return host, hostHum
end

local function settleKill(model, lastHitter)
	if settled[model] or model:GetAttribute("DamageProxyFor") ~= nil then
		return
	end
	settled[model] = true
	-- 사망 연출 브로드캐스트 — 일반 몬스터·보스 공통 단일 지점(중복 발화 없음)
	local fxRoot = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	local fxPos = fxRoot and fxRoot.Position or model:GetPivot().Position
	-- 사망 FX는 반경 내 플레이어에게만 전송
	local DEATHFX_DIST = 150
	for _, plr in ipairs(game:GetService("Players"):GetPlayers()) do
		local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		if r and (r.Position - fxPos).Magnitude <= DEATHFX_DIST then
			Net.Event("MonsterDeathFx"):FireClient(plr, fxPos, model:GetAttribute("MonsterId"))
		end
	end
	local settlement = buildSettlement(model)
	local expReward = model:GetAttribute("ExpReward")
	if type(expReward) == "number" and expReward > 0 then
		for userId in pairs(settlement.eligible) do
			local contributor = Players:GetPlayerByUserId(userId)
			if contributor then
				PlayerService.AddExp(contributor, expReward)
			end
		end
	end
	-- 온보딩 3(first_kill) + 처치 배치 — 기여 원장 기준(막타 무관), damageLog는 함수 말미에 비워지므로 그 전에 읽는다.
	-- 🔴처치 건당 발화 금지 — 파밍 속도에서 레이트 상한(120+20×CCU)에 닿는다. 60초 누적 배치.
	-- 오토 여부는 클라 로컬 상태라 서버가 구분 불가 → 몬스터별 MonsterKill로 집계.
	local monsterId = model:GetAttribute("MonsterId")
	for userId in pairs(damageLog[model] or {}) do
		local contributor = Players:GetPlayerByUserId(userId)
		if contributor then
			AnalyticsService.Onboard(contributor, ONBOARD_FIRST_KILL)
			AnalyticsService.FirstRun(contributor, 4) -- [계측 v3] FirstRun first_kill
			if type(monsterId) == "string" and monsterId ~= "" then
				AnalyticsService.Batch(contributor, "MonsterKill", 1, monsterId,
					"Lv - " .. AnalyticsService.LevelBand(tonumber(contributor:GetAttribute("Level")) or 1))
			end
		end
	end
	for _, callback in ipairs(killedCallbacks) do
		-- 콜백마다 사본 전달 (교차 오염 방지) + 에러 격리
		task.spawn(callback, model, copyContributors(model), lastHitter, settlement)
	end
	damageLog[model] = nil -- settled 마커는 Destroying까지 유지
	lastHitLog[model] = nil
end

-- 일반몹 피격 넉백 핸들러 — MonsterService.Init이 ApplyHitKnockback을 주입.
-- 🔴인라인 require(MonsterService) 금지 — Monster↔Combat 순환 경고.
local hitKnockbackHandler = nil
function CombatService.SetHitKnockback(fn)
	hitKnockbackHandler = fn
end

-- 🔴보스 존 밖 안전딜 차단 — FieldBossService.Init이 존 판정을 주입(SetHitKnockback 선례). 존 밖 피해는 무효.
local bossZoneCheck = nil -- fn(bossModel, attackerPos) -> true = 피해 허용
function CombatService.SetBossZoneCheck(fn)
	bossZoneCheck = fn
end

-- 애니메이션 재생속도와 서버 판정 지연을 같은 공식으로 계산한다.
-- 원본 Swing/Hit 시각은 AVDefs.WeaponAttackTimings가 단일 권위다.
local AIR_FIT_MIN_SPEED = 0.8
local AIR_FIT_MAX_SPEED = 2.4
local AIR_FIT_MIN_AIRTIME = 0.12
local AIR_FIT_RAY_DEPTH = 300

local function remainingAirtime(character, root, humanoid)
	if not character or not root or not humanoid or Workspace.Gravity <= 0 then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local hit = Workspace:Raycast(root.Position, Vector3.new(0, -AIR_FIT_RAY_DEPTH, 0), params)
	if not hit then
		return nil
	end
	local feet = humanoid.HipHeight + root.Size.Y * 0.5
	local height = math.max(0, (root.Position.Y - hit.Position.Y) - feet)
	local velocity = root.AssemblyLinearVelocity.Y
	local gravity = Workspace.Gravity
	return (velocity + math.sqrt(velocity * velocity + 2 * gravity * height)) / gravity
end

local function attackPlaybackSpeed(kindDef, motionProfile, combo, attackMode, timing,
		character, root, humanoid, attackSpeedPct, cooldown)
	local motion = kindDef and kindDef.AttackMotion
	local profileSpeeds = motionProfile and motionProfile.PlaybackSpeed
	local haste = math.clamp(tonumber(attackSpeedPct) or 0, 0, 0.5)
	-- 지상 기본 공격은 타입별 무게감 배속을 더한다. 클라이언트 playAttackCombo와 반드시 같은 순서로 계산한다.
	local animationSpeedScale = attackMode == "Ground"
		and (tonumber(kindDef and kindDef.AnimationSpeedScale) or 1) or 1
	local basePlaybackSpeed = tonumber(profileSpeeds and profileSpeeds[combo])
		or tonumber(motion and motion.PlaybackSpeed) or 1
	local speed = math.clamp(basePlaybackSpeed * animationSpeedScale / (1 - haste), 0.6, 2.4)
	if attackMode == "AirAttack" and timing and tonumber(timing.Length) and timing.Length > 0 then
		local airtime = remainingAirtime(character, root, humanoid)
		if airtime then
			speed = math.clamp(timing.Length / math.max(airtime, AIR_FIT_MIN_AIRTIME),
				AIR_FIT_MIN_SPEED, AIR_FIT_MAX_SPEED)
		end
	end
	local hitAt = tonumber(timing and timing.Hit) or 0
	if hitAt > 0 then
		local hitWindow = math.max((tonumber(cooldown) or 0) - WeaponDefs.COOLDOWN_GRACE
			- WeaponDefs.HIT_BEFORE_NEXT_ATTACK_SEC, 0.05)
		speed = math.clamp(math.max(speed, hitAt / hitWindow), 0.6, 2.4)
	end
	return speed
end

local function liveAttackRoot(player, expectedCharacter, expectedWeaponUid, expectedWeaponId, expectedWeaponType)
	if player.Parent ~= Players or player.Character ~= expectedCharacter
		or not expectedCharacter:IsDescendantOf(Workspace) then
		return nil, nil, nil
	end
	local humanoid = expectedCharacter:FindFirstChildOfClass("Humanoid")
	local root = expectedCharacter:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return nil, nil, nil
	end
	local profile = PlayerService.GetProfile(player)
	if not profile then
		return nil, nil, nil
	end
	local _, _, currentWeaponId, _, currentWeaponType, _, currentWeaponUid = equippedAttackInfo(profile)
	if currentWeaponUid ~= expectedWeaponUid or currentWeaponId ~= expectedWeaponId
		or currentWeaponType ~= expectedWeaponType then
		return nil, nil, nil
	end
	return humanoid, root, profile
end

-- comboIdx: 클라가 보낸 콤보 인덱스 — 미사용(치명타 판정·PlayerSwing 릴레이 모두 서버 comboState 기준)
function CombatService._attackAs(player, comboIdx, assistedTarget, requestedMode)
	if not DataService.IsLoaded(player) then
		return -- 프로필 로드 전 busy-wait 스레드 증식 차단
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root then
		return
	end
	if character:GetAttribute("WeaponEvolutionInvulnerable") == true
		or (tonumber(character:GetAttribute("WeaponEvolutionEndsAt")) or 0) > Workspace:GetServerTimeNow() then
		return -- 무기 비행 중 공격 애니·서버 판정 경합 차단
	end
	local profile = PlayerService.GetProfile(player)
	if not profile then
		return
	end
	if not onboardAttackDone[player] then
		onboardAttackDone[player] = true
		AnalyticsService.Onboard(player, ONBOARD_FIRST_ATTACK) -- 첫 입력(60초 이탈 분해용)
		AnalyticsService.FirstRun(player, 3) -- [계측 v3] FirstRun first_attack
	end

	local kindDef, motionProfile, weaponId, attackKind, weaponType, enhance, weaponUid = equippedAttackInfo(profile)
	local combatV2 = WeaponDefs.IsCombatV2Enabled(GameConfig, RunService:IsStudio())
	-- [2026-08-19 밸런스] V2 = 타입 전투 프로필이 레거시 Kind(쿨다운·사거리·치명률)를 대체.
	-- 무기 Atk는 이 프로필 전제로 시뮬 재산 — tools/balance_sim_weapon_types_20260819.js
	local typeCombat = combatV2 and WeaponDefs.TypeCombatOf(weaponType) or nil
	if typeCombat then
		kindDef = typeCombat
	end
	local attackMode = "Ground"
	if combatV2 then
		if isAirborne(humanoid) then
			attackMode = "AirAttack"
		elseif requestedMode == "DashAttack" and character:GetAttribute("DashEvading") == true then
			attackMode = "DashAttack"
		end
	end
	local maxCombo = WeaponDefs.MaxCombo(enhance, combatV2)
	local identity = WeaponDefs.IdentityOf(weaponId)
	local motionHitProfile = motionProfile and motionProfile.HitProfile or nil
	local hitProfile = motionHitProfile
	-- 지상 평타는 타입 판정을 SSOT로 삼되, 명시한 CH1 하이브리드 무기만 기존 Motion 판정을 유지한다.
	-- 대시·공중 및 CombatV2 비활성 경로는 종전 Motion 판정 그대로다.
	if attackMode == "Ground" and typeCombat and typeCombat.HitProfile
		and not (identity and identity.HybridStyle == true) then
		hitProfile = typeCombat.HitProfile
	end
	local normalMonsterControl = attackMode == "Ground" and typeCombat and typeCombat.NormalMonsterControl or nil
	-- 공속 옵션: 스윙 쿨다운 단축(클라 CombatController도 동일 공식 미러 — WeaponAtkSpeed 어트리뷰트)
	local weaponOpts = equippedOptions(profile)
	local atkSpeed = (tonumber(weaponOpts.AtkSpeed) or 0) + (tonumber(player:GetAttribute("AtkSpeedPct")) or 0)
	local cooldown = kindDef.Cooldown * (1 - math.clamp(atkSpeed, 0, 0.5))
	local now = os.clock()
	local last = lastAttackAt[player]
	if last and (now - last) < (cooldown - WeaponDefs.COOLDOWN_GRACE) then
		AnalyticsService.ActionRejected(player, "Attack", "Cooldown")
		return -- 쿨다운 중: 소모 없음
	end
	lastAttackAt[player] = now -- 미명중이어도 쿨다운 소모
	AnalyticsService.AttackAccepted(player)

	local combo = 1
	local comboKey = weaponUid .. ":" .. weaponType .. ":" .. tostring(maxCombo)
	local state = comboState[player]
	if attackMode == "Ground" then
		if last and (now - last) <= cooldown + WeaponDefs.COMBO_LINK_WINDOW and state and state.key == comboKey then
			combo = state.index % maxCombo + 1
		end
		comboState[player] = { index = combo, key = comboKey }
	else
		comboState[player] = nil
	end
	local finisher = attackMode == "Ground" and combo == maxCombo

	PlayerService.NotifyCombat(player)

	local timing = AVDefs.ResolveWeaponAttackTiming(weaponType, attackMode, combo)
	local playbackSpeed = attackPlaybackSpeed(kindDef, motionProfile, combo, attackMode,
		timing, character, root, humanoid, atkSpeed, cooldown)
	local swingDelay = math.max(0, (tonumber(timing.Swing) or 0) / playbackSpeed)
	local hitDelay = math.max(swingDelay, (tonumber(timing.Hit) or timing.Swing or 0) / playbackSpeed)

	-- 원격 스윙음/검기와 서버 스윙 훅도 실제 Swing 마커 시각에 실행한다.
	task.delay(swingDelay, function()
		local _, liveRoot = liveAttackRoot(player, character, weaponUid, weaponId, weaponType)
		if not liveRoot then
			return
		end
		for _, fn in ipairs(swingCallbacks) do
			task.spawn(fn, player, liveRoot)
		end
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player then
				local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
				if otherRoot and (otherRoot.Position - liveRoot.Position).Magnitude <= AVDefs.SWING_RELAY_RADIUS then
					Net.Event("PlayerSwing"):FireClient(other, character, combo, attackMode, maxCombo, weaponType)
				end
			end
		end
	end)

	-- 요청 시각이 아니라 애니메이션 Hit 마커에서 타겟을 다시 검증하고 피해를 확정한다.
	-- 빠른 클릭·홀드·오토 공격 모두 이 단일 서버 타임라인을 공유한다.
	task.delay(hitDelay, function()
		local _, liveRoot, liveProfile = liveAttackRoot(player, character, weaponUid, weaponId, weaponType)
		if not liveRoot or not liveProfile then
			return
		end
		local firstHitGuideWasActive = firstHitGuideActive(player, liveProfile, attackMode)
		local assistedLook = validatedAssistLook(character, liveRoot, kindDef, assistedTarget)
		local guideTargetId = tostring((GameConfig.FIRST_HIT_GUIDE and GameConfig.FIRST_HIT_GUIDE.TargetId) or "Carrot")
		local usedFirstHitTargetAssist = firstHitGuideWasActive and assistedLook ~= nil
			and typeof(assistedTarget) == "Instance" and tostring(assistedTarget:GetAttribute("MonsterId")) == guideTargetId
		local targets = findTargets(liveRoot.Position, kindDef.Range, liveRoot.AssemblyLinearVelocity,
			assistedLook or liveRoot.CFrame.LookVector, lastHitInfo[player], hitProfile)
		if #targets == 0 then
			showFirstHitMoveCloser(player, liveProfile, attackMode)
			AnalyticsService.ActionRejected(player, "Attack", "NoTarget")
			return
		end

		local derived = PlayerService.GetDerived(player)
		if not derived then
			return
		end
		local hitWeaponOpts = equippedOptions(liveProfile)
		local dmg = derived.Atk
		local secondaryFalloff = math.clamp(
			tonumber(hitProfile and hitProfile.SecondaryFalloff) or MULTI_TARGET_FALLOFF, 0, 1)
		local comboMult = attackMode == "AirAttack"
			and (WeaponDefs.AIR_DAMAGE or 1)
			or (attackMode == "DashAttack" and 1
				or ((WeaponDefs.COMBO_DAMAGE and WeaponDefs.COMBO_DAMAGE[combo]) or 1))
		dmg = dmg * comboMult
		local isCrit = false
		if finisher and math.random() < ((kindDef.CritChance or 0)
			+ (tonumber(hitWeaponOpts.CritChance) or 0)) then
			isCrit = true
			dmg = dmg * (WeaponDefs.CritMultiplier(maxCombo)
				+ (tonumber(hitWeaponOpts.CritDamage) or 0))
		end
		lastHitInfo[player] = { model = targets[1].model, at = os.clock() }

		for order, entry in ipairs(targets) do
			local target, targetHumanoid = entry.model, entry.hum
			local ledgerModel, ledgerHum = resolveDamageTarget(target, targetHumanoid)
			if not ledgerModel or not ledgerHum then
				continue
			end
			local ledgerDef = MonsterDefs[ledgerModel:GetAttribute("MonsterId")]
			if ledgerDef and ledgerDef.IsBoss == true and bossZoneCheck
				and not bossZoneCheck(ledgerModel, liveRoot.Position) then
				continue
			end
			local hitDmg = applyDef(ledgerModel, dmg * (order == 1 and 1 or secondaryFalloff))
			local log = trackModel(ledgerModel)
			log[player.UserId] = (log[player.UserId] or 0) + hitDmg
			noteHit(ledgerModel, player.UserId)

			local targetRoot = target.PrimaryPart or target:FindFirstChild("HumanoidRootPart")
			local targetPoint = targetRoot and targetRoot.Position or liveRoot.Position
			local hitPos = targetPoint + Vector3.new(0, 1, 0)
			local impactDelta = targetPoint - liveRoot.Position
			local impactDir = impactDelta.Magnitude > 0.001 and impactDelta.Unit or liveRoot.CFrame.LookVector

			local wasAlive = ledgerHum.Health > 0
			ledgerHum:TakeDamage(hitDmg)
			local analyticsMonsterId = tostring(ledgerModel:GetAttribute("MonsterId") or target:GetAttribute("MonsterId") or "unknown")
			if firstHitGuideWasActive then
				player:SetAttribute("W1Q01FirstDamageDone", true)
				if usedFirstHitTargetAssist then
					AnalyticsService.FirstHitGuideState(player, "TargetAssistDamage", analyticsMonsterId)
				end
				firstHitGuideWasActive = false
			end
			AnalyticsService.DamageConfirmed(player, analyticsMonsterId)
			local damageSnapshot = {
				weaponId = weaponId,
				weaponUid = weaponUid,
				weaponType = weaponType,
				attackMode = attackMode,
				source = "Basic",
			}
			for _, fn in ipairs(damageConfirmedCallbacks) do
				task.spawn(fn, player, analyticsMonsterId, damageSnapshot)
			end
			if ledgerDef and ledgerDef.IsBoss == true then
				AnalyticsService.BossDamaged(player, analyticsMonsterId)
			end
			local remainingHealth = math.max(ledgerHum.Health, 0)
			local killedByHit = wasAlive and remainingHealth <= 0
			Net.Event("MonsterHit"):FireClient(player, {
				pos = hitPos,
				model = target,
				crit = isCrit,
				combo = combo,
				dmg = hitDmg,
				monsterId = target:GetAttribute("MonsterId") or ledgerModel:GetAttribute("MonsterId"),
				source = "Basic",
				impactDir = impactDir,
				attackKind = attackKind,
				weaponId = weaponId,
				weaponType = weaponType,
				attackMode = attackMode,
				maxCombo = maxCombo,
				finisher = finisher,
				kill = killedByHit,
				health = remainingHealth,
				maxHealth = ledgerHum.MaxHealth,
				order = order,
			})
			local targetDef = MonsterDefs[target:GetAttribute("MonsterId")]
			if ledgerHum.Health > 0 and targetDef and targetDef.IsBoss ~= true and hitKnockbackHandler then
				if normalMonsterControl then
					-- 3번째 opts는 스킬 전용 오버라이드라 nil 유지. 타입 보정은 4번째 인자로 분리해 캔슬 면역을 보존한다.
					pcall(hitKnockbackHandler, target, liveRoot.Position, nil, normalMonsterControl)
				else
					pcall(hitKnockbackHandler, target, liveRoot.Position)
				end
			end
			if wasAlive and ledgerHum.Health <= 0 and not settled[ledgerModel] then
				settleKill(ledgerModel, player)
			end
		end
	end)
end

function CombatService.OnKilled(fn)
	table.insert(killedCallbacks, fn)
end

-- [2026-07-25 C3] 검증 통과 스윙 구독 — fn(player, root)
function CombatService.OnSwing(fn)
	table.insert(swingCallbacks, fn)
end

-- 서버가 실제 평타 피해를 확정한 뒤만 발화한다. 클라이언트 입력만으로 진행되지 않는다.
function CombatService.OnDamageConfirmed(fn)
	table.insert(damageConfirmedCallbacks, fn)
end

function CombatService.GetContributors(model)
	return copyContributors(model)
end

-- 원장·정리 연결 초기화 — 다음 피해 시 재추적된다
function CombatService.ClearDamageLog(model)
	clearModel(model)
end

function CombatService._damageAs(player, target, amount, damageOrigin, beforeSettle)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return false
	end
	if not DataService.IsLoaded(player) then
		return false
	end
	local origin = damageOrigin
	if typeof(origin) == "Vector3" then
		if origin.X ~= origin.X or origin.Y ~= origin.Y or origin.Z ~= origin.Z
			or math.abs(origin.X) == math.huge or math.abs(origin.Y) == math.huge or math.abs(origin.Z) == math.huge then
			return false
		end
	else
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not character or not character:IsDescendantOf(Workspace)
			or not humanoid or humanoid.Health <= 0
			or not root or not root:IsA("BasePart") then
			return false
		end
		origin = root.Position
	end
	if typeof(target) ~= "Instance" or not target:IsA("Model")
		or not target:IsDescendantOf(Workspace)
		or not CollectionService:HasTag(target, MONSTER_TAG)
		or target:GetAttribute("Untargetable") == true then
		return false
	end
	if type(amount) ~= "number" or amount <= 0 or amount ~= amount or amount == math.huge then
		return false
	end
	local targetHumanoid = target:FindFirstChildOfClass("Humanoid")
	if not targetHumanoid or targetHumanoid.Health <= 0 then
		return false
	end
	local ledgerModel, ledgerHum = resolveDamageTarget(target, targetHumanoid)
	if not ledgerModel or not ledgerHum
		or not ledgerModel:IsDescendantOf(Workspace)
		or not CollectionService:HasTag(ledgerModel, MONSTER_TAG)
		or not ledgerHum:IsDescendantOf(ledgerModel)
		or ledgerHum.Health <= 0 then
		return false
	end
	local zoneDef = MonsterDefs[ledgerModel:GetAttribute("MonsterId")]
	if zoneDef and zoneDef.IsBoss == true then
		if not bossZoneCheck then
			return false
		end
		local ok, inside = pcall(bossZoneCheck, ledgerModel, origin)
		if not ok or inside ~= true then
			return false
		end
	end
	amount = applyDef(ledgerModel, amount)
	local log = trackModel(ledgerModel)
	log[player.UserId] = (log[player.UserId] or 0) + amount
	noteHit(ledgerModel, player.UserId)
	ledgerHum:TakeDamage(amount)
	local analyticsMonsterId = tostring(ledgerModel:GetAttribute("MonsterId") or "unknown")
	AnalyticsService.DamageConfirmed(player, analyticsMonsterId)
	if zoneDef and zoneDef.IsBoss == true then
		AnalyticsService.BossDamaged(player, analyticsMonsterId)
	end
	local remainingHealth = ledgerHum.Health
	local maxHealth = ledgerHum.MaxHealth
	-- 서버 내부 연출 훅: 오류가 나도 아래 단일 처치 정산 경로는 반드시 실행한다.
	if type(beforeSettle) == "function" then
		local ok, err = pcall(beforeSettle, remainingHealth, amount, maxHealth)
		if not ok then
			warn("[CombatService] beforeSettle callback failed: " .. tostring(err))
		end
	end
	if remainingHealth <= 0 and not settled[ledgerModel] then
		settleKill(ledgerModel, player)
	end
	return remainingHealth, amount, maxHealth
end

function CombatService.Init(services)
	PlayerService = assert(services.PlayerService)
	DataService = require(script.Parent:WaitForChild("DataService"))
	AnalyticsService = require(script.Parent:WaitForChild("AnalyticsService"))
	Net.Event("RequestAttack").OnServerEvent:Connect(function(player, comboIdx, assistedTarget, requestedMode)
		if not allowAttackRequest(player) then
			return
		end
		CombatService._attackAs(player, comboIdx, assistedTarget, requestedMode)
	end)
end

function CombatService.Start()
	Players.PlayerRemoving:Connect(function(player)
		lastAttackAt[player] = nil
		comboState[player] = nil
		lastHitInfo[player] = nil
		onboardAttackDone[player] = nil
		attackRequestBuckets[player] = nil
		firstHitHintShown[player] = nil
		for model, log in pairs(damageLog) do
			log[player.UserId] = nil
			local hits = lastHitLog[model]
			if hits then
				hits[player.UserId] = nil
			end
		end
	end)
end

return CombatService
