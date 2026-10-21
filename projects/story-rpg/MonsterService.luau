-- MonsterService — 일반 몬스터 스폰·AI·리스폰(IsBoss 마커 무시 — 보스는 BossService 몫).
-- 제약: 튜닝 수치는 ReplicatedStorage.Defs.MonsterDefs에서만 읽는다.
-- 제약: AI는 Scheduler 단일 틱("MonsterAI")으로만 — 몬스터별 루프·코루틴 금지(성능 원칙).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Defs = ReplicatedStorage:WaitForChild("Defs")
local MonsterDefs = require(Defs:WaitForChild("MonsterDefs"))
local WeaponDefs = require(Defs:WaitForChild("WeaponDefs")) -- HIT_RADIUS_MIN(타겟 판정 하한)
local AVDefs = require(Defs:WaitForChild("AVDefs")) -- 몬스터 이동/사망 애니 id
local Net = require(ReplicatedStorage:WaitForChild("Net"))
local PlayerDamageService = require(script.Parent:WaitForChild("PlayerDamageService"))
-- [2026-08-20 Z1 이식] 게시 애니가 없는 몹(도깨비 숲 3종)용 절차 애니 재생기
local MonsterProcAnim = require(script.Parent:WaitForChild("MonsterProcAnim"))
local AI = MonsterDefs.AI

local MonsterService = {}

-- 순환 require 방지: Init 시점 resolve
local Scheduler
local CombatService

local MARKER_TAG = "SpawnMarker"
local MONSTER_TAG = "Monster"

local monstersFolder -- Workspace._Runtime.Monsters
local active = {} -- [model] = { Def, Marker, SpawnPos, State, Humanoid, Root, TargetRoot, TargetHum, LastAtkAt }
local adopted = {} -- [marker] = true (스폰 체인 가동 중 — 중복 스폰 방지)

-- 성능: 미사용 Humanoid 상태 비활성 (Dead·Running·Freefall·Landed·GettingUp은 유지)
local DISABLED_STATES = {
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.PlatformStanding,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.StrafingNoPhysics,
	Enum.HumanoidStateType.Jumping,
}

local function ensureFolder(parent, name)
	local folder = parent:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = parent
	end
	return folder
end

-- 임시 모델 보정(StoneMonster): 루트에서 벌어진 파트를 루트 주변 원형으로 모아 재용접.
-- 기존 조인트는 이동 파트를 원위치로 되돌리므로 해당 조인트만 제거 (교체 예정 임시 모델 — 기능 우선)
local function compactLooseParts(model, root)
	local movedSet, moved = {}, 0
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part ~= root and (part.Position - root.Position).Magnitude > AI.CompactDetectDist then
			part.CFrame = root.CFrame * CFrame.new(
				math.cos(moved * AI.CompactAngleStep) * AI.CompactPlaceRadius, 0,
				math.sin(moved * AI.CompactAngleStep) * AI.CompactPlaceRadius)
			movedSet[part] = true
			moved += 1
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end
	end
	if moved == 0 then
		return
	end
	for _, joint in ipairs(model:GetDescendants()) do
		if joint:IsA("JointInstance") and (movedSet[joint.Part0] or movedSet[joint.Part1]) then
			joint:Destroy()
		end
	end
end

-- 생존 플레이어 스냅샷은 50ms TTL로 공유 — 몬스터별로 만들면 틱당 GetPlayers 95회 + 인스턴스 조회 190×N회.
-- 🔴TTL 방식이라 aiTick 밖 호출부(반격 어그 등)도 무수정으로 공유된다. 50ms 지연 = 16 stud/s 기준 0.8스터드(타겟팅 무해).
local SNAPSHOT_TTL = 0.05
local aliveSnapshot = {}
local aliveSnapshotAt = -1

local function ensureAliveSnapshot()
	local now = os.clock()
	if now - aliveSnapshotAt < SNAPSHOT_TTL then
		return
	end
	aliveSnapshotAt = now
	table.clear(aliveSnapshot)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root then
			table.insert(aliveSnapshot, { Root = root, Hum = humanoid, Pos = root.Position })
		end
	end
end

local function nearestAlivePlayer(origin, maxDist)
	ensureAliveSnapshot()
	local bestRoot, bestHum, bestDist = nil, nil, maxDist
	for _, e in ipairs(aliveSnapshot) do
		local dist = (e.Pos - origin).Magnitude
		if dist <= bestDist then
			bestRoot, bestHum, bestDist = e.Root, e.Hum, dist
		end
	end
	return bestRoot, bestHum
end

-- AVDefs.Sounds[key]를 몬스터 루트에 3D 재생(서버 생성 — 전 클라 자동 복제).
-- 미등록 키/빈 Id는 무음 no-op — 몬스터별 키 규칙: <MonsterId>Aggro/<MonsterId>DashWindup/<MonsterId>SlamWindup/<MonsterId>SlamHit
local function playMobSound(root, key)
	local def = AVDefs.Sounds[key]
	if not (def and def.Id and def.Id ~= "" and root and root.Parent) then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "MobSfx_" .. key
	sound.SoundId = def.Id
	sound.Volume = def.Volume or 0.5
	sound.PlaybackSpeed = def.PlaybackSpeed or 1
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMaxDistance = def.RollOffMaxDistance or 45
	sound.Parent = root
	sound:Play()
	Debris:AddItem(sound, 8)
end

-- 어그로 울음 중첩 방지: 팩 동시 어그로 시 몬스터 종류별 전역 쿨다운(1마리만 울음)
local AGGRO_SOUND_CD = 2
local lastAggroSoundAt = {}

local spawnAt -- 전방 선언 (retire와 상호 참조)

-- 같은 플레이어를 여러 몬스터가 동시에 덮치는 슬러그페스트를 막는다.
-- 공격 슬롯은 윈드업 시작부터 패턴 종료까지 점유하며, 시작 시점도 짧게 엇갈리게 한다.
local attackGroups = setmetatable({}, { __mode = "k" }) -- [targetHumanoid] = { Count, NextAt }

local function releaseAttackSlot(st)
	local targetHum = st.AttackSlotHum
	st.AttackSlotHum = nil
	if not targetHum then
		return
	end
	local group = attackGroups[targetHum]
	if group then
		group.Count = math.max(0, (group.Count or 0) - 1)
		if group.Count == 0 then
			-- 한 패턴이 끝난 직후 다음 몬스터가 바로 덮치지 않도록 짧은 회피·포션 사용 창을 보장한다.
			group.NextAt = math.max(group.NextAt or 0, os.clock() + math.max(0, tonumber(AI.AttackGroupRecoverySec) or 0.65))
		end
	end
end

local function tryBeginAttack(st, targetRoot, targetHum)
	if st.AttackBusy or st.AttackSlotHum
		or not (targetRoot and targetRoot.Parent and targetHum and targetHum.Health > 0) then
		return false
	end
	local now = os.clock()
	local group = attackGroups[targetHum]
	if not group then
		group = { Count = 0, NextAt = 0 }
		attackGroups[targetHum] = group
	end
	local slots = math.max(1, math.floor(tonumber(AI.AttackSlotsPerTarget) or 2))
	if group.Count >= slots or now < (group.NextAt or 0) then
		return false
	end
	group.Count += 1
	group.NextAt = now + math.max(0, tonumber(AI.AttackGroupGapSec) or 0.35)
	st.AttackSlotHum = targetHum
	st.TargetRoot, st.TargetHum = targetRoot, targetHum
	st.AttackBusy = true
	return true
end

-- 사망·유실 공통 정리: 시체 제거 + 같은 마커 재스폰 예약 (task.delay 단발 — 상시 루프 아님)
local function retire(model)
	local st = active[model]
	if not st then
		return
	end
	releaseAttackSlot(st)
	active[model] = nil
	-- 시체 고정: 쓰러진 직후(사망 애니 정착 여유) 충돌 오프 + 앵커 — 밀림/걷어차임 방지
	task.delay(0.35, function()
		if not model.Parent then
			return
		end
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.Anchored = true
			end
		end
	end)
	local marker = st.Marker
	local respawnSec = st.Def.RespawnSec
	task.delay(AI.CorpseDespawnSec, function()
		if model.Parent then
			model:Destroy()
		end
	end)
	task.delay(respawnSec, function()
		if marker.Parent then
			spawnAt(marker)
		else
			adopted[marker] = nil
		end
	end)
end

-- 공격 소품 이름 매칭: 문자열 하나 또는 배열 모두 허용.
-- 술독 정령처럼 소품이 2파트(Alcohol_in/Alcohol_out)인 몹이 있어 배열을 받는다.
local function propNameMatches(names, partName)
	if type(names) == "table" then
		for _, n in ipairs(names) do
			if n == partName then
				return true
			end
		end
		return false
	end
	return names == partName
end

spawnAt = function(marker)
	local monsterId = marker:GetAttribute("MonsterId")
	local def = MonsterDefs[monsterId]
	-- 스폰 비활성 몹 — 마커는 남겨두되 스폰 안 함
	-- [2026-08-20] SpawnDisabled = map-marker spawn ban (summon-only defs). Boss summons pass via the Summoned flag.
	-- Without this exception SpawnSummon silently returns nil (its caller is inside pcall, so nothing is logged).
	if not def or (def.SpawnDisabled and not marker:GetAttribute("Summoned")) then
		return
	end
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local monsters = assets and assets:FindFirstChild("Monsters")
	local template = monsters and monsters:FindFirstChild(def.ModelName)
	if not template then
		warn(("[MonsterService] 모델 없음: %s"):format(tostring(def.ModelName)))
		return
	end

	local model = template:Clone()
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		warn(("[MonsterService] 루트/휴머노이드 없음: %s"):format(def.ModelName))
		model:Destroy()
		return
	end

	if def.CompactParts then
		compactLooseParts(model, root) -- StoneMonster 전용 임시 보정 — 정상 리그는 상부 파트(머리 등)가 오인 이동되므로 금지
	end
	if def.ModelScale ~= 1 then
		model:ScaleTo(def.ModelScale)
	end
	-- 공격 때만 꺼내는 소품(도깨비 북채 등)은 스폰 직후 숨기고 원 투명도를 보존한다.
	if def.AttackPropHidden and def.AttackPropName then
		for _, inst in ipairs(model:GetDescendants()) do
			if inst:IsA("BasePart") and propNameMatches(def.AttackPropName, inst.Name) then
				inst:SetAttribute("_AttackPropBaseTransparency", inst.Transparency)
				inst.Transparency = 1
			end
		end
	end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end

	humanoid.MaxHealth = def.Hp
	humanoid.Health = def.Hp
	humanoid.WalkSpeed = def.WalkSpeed
	-- [2026-08-20] FlyHeight: 비행 몹(도깨비불·박쥐)은 HipHeight로 띄운다.
	-- Humanoid가 그 높이를 스스로 유지하므로 Running 상태·MoveTo·판정이 전부 그대로 살아 있다
	-- (BodyPosition류로 띄우면 Humanoid 이동이 깨진다). 실측: 발끝-지면 = HipHeight 그대로.
	-- ★상한 주의 — 전투 수직 허용치는 HalfHeight + VERTICAL_PAD(6)라, 그보다 높이 띄우면 플레이어가 못 때린다.
	humanoid.HipHeight = (def.HipOffset or 0) + (def.FlyHeight or 0) -- R6 힙공식 부양/파묻힘 보정
	-- MeshPart 루트는 쿡된 충돌 헐이 크기박스 밖으로 돌출해 몬스터를 공중에 얹어놓는다
	-- (HipHeight가 무력화되고 낙하도 안 함). 루트 충돌만 끔고 몸통 파트로 접지시킨다.
	if def.RootNoCollide then
		root.CanCollide = false
	end
	humanoid.RequiresNeck = false -- 커스텀 릭에 Neck 조인트 없음 — 스폰 즉사 방지
	humanoid.BreakJointsOnDeath = false -- 사망 시 파트 흩어짐 방지 (시체는 일괄 제거)
	for _, state in ipairs(DISABLED_STATES) do
		humanoid:SetStateEnabled(state, false)
	end

	local extents = model:GetExtentsSize() -- ScaleTo 이후 크기 기준
	-- 마커 절대 Y 대신 레이캐스트 지면 기준 — 맵 레벨링으로 마커가 떠도 공중 스폰(낙하 등장) 방지.
	-- 실패 시 마커 위치 폴백(기존 동작). 시작점 +2는 오버행(절벽·캐노피) 오인 방지.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	-- _Markers 폴더 통째로 제외(체크포인트 등 투명 로직 파트를 지면으로 오인 방지)
	local exclude = { monstersFolder, marker }
	local markersFolder = Workspace:FindFirstChild("_Markers")
	if markersFolder then
		table.insert(exclude, markersFolder)
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(exclude, plr.Character)
		end
	end
	rayParams.FilterDescendantsInstances = exclude
	-- 마커 기준 랜덤 링 산개: 리스폰마다 다른 지점(밀집 해소). 지면 레이캐스트도 산개 지점 기준
	-- 마커별 오버라이드: ScatterRadius 어트리뷰트(숫자) — 0 = 산개 없이 마커 정위치, N = 최대 반경 N
	local scatter = AI.SpawnScatter
	local sAngle = math.random() * math.pi * 2
	local sRadius = scatter and (scatter.Min + math.random() * (scatter.Max - scatter.Min)) or 0
	local scatterOverride = marker:GetAttribute("ScatterRadius")
	if type(scatterOverride) == "number" then
		sRadius = scatterOverride > 0 and (math.random() * scatterOverride) or 0
	end
	local sx = marker.Position.X + math.cos(sAngle) * sRadius
	local sz = marker.Position.Z + math.sin(sAngle) * sRadius
	local groundHit = Workspace:Raycast(Vector3.new(sx, marker.Position.Y + 2, sz), Vector3.new(0, -300, 0), rayParams)
	local baseY = groundHit and groundHit.Position.Y or marker.Position.Y
	local spawnPos = Vector3.new(sx, baseY + extents.Y / 2 + AI.SpawnHeightPad, sz)
	-- [2026-08-20] World=2 목은 스폰 마커의 LookVector 방향으로 세운다(보스와 같은 규약 — 조정 지점 = 마커 회전 하나).
	-- 챕턴1 목은 마커 회전이 임의라 건드리면 전부 엉뚜 방향을 보게 된다 — World 게이트로 격리.
	local spawnLook = marker.CFrame.LookVector * Vector3.new(1, 0, 1)
	if def.World == 2 and spawnLook.Magnitude > 0.05 then
		model:PivotTo(CFrame.lookAt(spawnPos, spawnPos + spawnLook.Unit))
	else
		model:PivotTo(CFrame.new(spawnPos))
	end
	model:SetAttribute("MonsterId", monsterId)
	model:SetAttribute("ExpReward", def.Exp)
	-- CombatService 타겟 판정 히트 반경: 모델 수평 크기 기반 — 대형 모델 가장자리 타격 허용
	model:SetAttribute("HitRadius", math.max(WeaponDefs.HIT_RADIUS_MIN, (extents.X + extents.Z) / 4))
	model:SetAttribute("HalfHeight", extents.Y / 2) -- 수직 판정 캐시 — Combat/SkillService 공용 규약
	CollectionService:AddTag(model, MONSTER_TAG)
	model.Parent = monstersFolder
	pcall(function()
		root:SetNetworkOwner(nil) -- 서버 권위 이동 고정
	end)
	model.Destroying:Connect(function()
		retire(model) -- 외부 제거 대비 안전망 (retire는 멱등)
	end)

	active[model] = {
		Model = model,
		Def = def,
		Marker = marker,
		SpawnPos = spawnPos,
		State = "Idle",
		Humanoid = humanoid,
		Root = root,
		TargetRoot = nil,
		TargetHum = nil,
		LastAtkAt = 0,
	}
	return model -- [2026-08-20] 소환 경로(SpawnSummon)가 생성 모델을 받아야 한다(기존 호출자는 반환값 미사용)
end

local function adoptMarker(marker)
	if adopted[marker] then
		return
	end
	local def = MonsterDefs[marker:GetAttribute("MonsterId")]
	if not def or def.IsBoss then
		return
	end
	adopted[marker] = true
	-- [2026-09-07] SpawnCount 어트리뷰트(숫자, 기본 1·상한 12): 모커 하나에서 N마리 팩 스폰.
	-- 개체별 st.Marker가 같은 모커를 가리켜 retire→리스폰도 개체 단위로 돈다(모커 복제 방식과 동치).
	-- ★같이 ScatterRadius도 줘야 한다 — 0이면 N마리가 한 점에 겝쳐 스폰된다.
	local count = tonumber(marker:GetAttribute("SpawnCount")) or 1
	count = math.clamp(math.floor(count), 1, 12)
	for _ = 1, count do
		spawnAt(marker)
	end
end

-- 태그 "Monster" 모델 공용 애니메이션 부착 — MonsterService/BossService 스폰 공통(보스 포함)
-- walk = AVDefs.MonsterAnims[id].Run (Movement 우선순위, 실제 이동 속도로 Play/Stop)
-- dead = AVDefs.MonsterAnims[id].Dead (Action4, 사망 시 1회 재생 — 시체는 CorpseDespawnSec 후 제거)
local animatedModels = setmetatable({}, { __mode = "k" }) -- [model] = true (중복 부착 방지)

local function attachMonsterAnimations(model)
	if animatedModels[model] then
		return
	end
	local monsterId = model:GetAttribute("MonsterId")
	local animDef = monsterId and AVDefs.MonsterAnims[monsterId]
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	-- [2026-08-20 Z1 이식] 절차 애니 부착(클립 미등록이면 no-op).
	-- ★animDef를 넘기므로 키프레임이 있는 슬롯(Run/Dead)은 절차 쪽이 알아서 비켜준다 = 기존 몹 무영향.
	MonsterProcAnim.Attach(model, humanoid, monsterId, animDef)
	if not animDef then
		return -- 키프레임 애니 없음 — 위 절차 애니가 대신한다
	end
	animatedModels[model] = true
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- [2026-08-27 사장님] Idle 슬롯(옵트인) — Core 우선순위로 상시 재생해 둔다.
	-- Movement(Run)·Action(공격·패턴)이 더 높은 우선순위라 움직이거나 때릴 땐 자연히 가려진다.
	-- animDef.Idle이 없는 목은 종전 그대로(무영향).
	if animDef.Idle and animDef.Idle ~= "" then
		local idleAnim = Instance.new("Animation")
		idleAnim.Name = "MonsterIdle"
		idleAnim.AnimationId = animDef.Idle
		local okIdle, idleTrack = pcall(animator.LoadAnimation, animator, idleAnim)
		if okIdle and idleTrack then
			idleTrack.Priority = Enum.AnimationPriority.Core
			idleTrack.Looped = true
			idleTrack:Play(0.2)
			humanoid.Died:Connect(function()
				if idleTrack.IsPlaying then
					idleTrack:Stop(0.15) -- 사망 연출(Dead 트랙) 위로 숨쉬 올라오지 않게
				end
			end)
		end
	end

	local runAnimId = animDef.Run
	local walkAnimId = nil
	if monsterId == "Wolf" then
		local saves = model:FindFirstChild("AnimSaves")
		local difficultyFolder = saves and saves:FindFirstChild("DifficultyAnimations")
		local runSlot = difficultyFolder and difficultyFolder:FindFirstChild("RunOverride")
		local walkSlot = difficultyFolder and difficultyFolder:FindFirstChild("WalkOverride")
		if runSlot and runSlot:IsA("Animation") and runSlot.AnimationId ~= "" then
			runAnimId = runSlot.AnimationId
		end
		if walkSlot and walkSlot:IsA("Animation") and walkSlot.AnimationId ~= "" then
			walkAnimId = walkSlot.AnimationId
		end
	end
	local function loadMovementTrack(name, animationId)
		if not animationId or animationId == "" then return nil end
		local animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = animationId
		local ok, track = pcall(animator.LoadAnimation, animator, animation)
		if not ok or not track then return nil end
		track.Priority = Enum.AnimationPriority.Movement
		track.Looped = true
		return track
	end
	local runTrack = loadMovementTrack("MonsterRun", runAnimId)
	local walkTrack = loadMovementTrack("MonsterWalk", walkAnimId)
	local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	local activeMovementTrack = nil
	local function stopMovementTracks(keep)
		if runTrack and runTrack ~= keep and runTrack.IsPlaying then runTrack:Stop(0.15) end
		if walkTrack and walkTrack ~= keep and walkTrack.IsPlaying then walkTrack:Stop(0.15) end
		activeMovementTrack = keep
	end
	local function bindWolfFootsteps(track)
		if monsterId ~= "Wolf" or not track then return end
		track:GetMarkerReachedSignal("FootStep"):Connect(function(param)
			if activeMovementTrack == track and track.IsPlaying
				and model:GetAttribute("WolfLocomotionMode") ~= "Stop"
				and humanoid.Health > 0 and root and root.Parent then
				playMobSound(root, "WolfFootstep")
				model:SetAttribute("LastWolfFootStepAt", os.clock())
				model:SetAttribute("LastWolfFootStepSide", param ~= "" and param or nil)
			end
		end)
	end
	bindWolfFootsteps(runTrack)
	bindWolfFootsteps(walkTrack)
	if runTrack or walkTrack then
		-- Humanoid.Running은 추격을, WolfLocomotionMode=Walk는 CFrame 기반 무타깃 복귀를 담당한다.
		local baseWalk = math.max(1, (MonsterDefs[monsterId] and MonsterDefs[monsterId].WalkSpeed) or 12)
		local lastSpeed = 0
		local function updateMovement(speed)
			lastSpeed = tonumber(speed) or lastSpeed
			if humanoid.Health <= 0 then
				stopMovementTracks(nil)
				return
			end
			local forced = monsterId == "Wolf" and model:GetAttribute("WolfLocomotionMode") or nil
			local selected = nil
			local displaySpeed = lastSpeed
			if forced == "Walk" then
				selected = walkTrack or runTrack
				displaySpeed = baseWalk * 0.52
			elseif forced == "Run" then
				selected = runTrack or walkTrack
				displaySpeed = baseWalk
			elseif forced ~= "Stop" and lastSpeed > AVDefs.RUN_ANIM_MIN_SPEED then
				if walkTrack and runTrack and lastSpeed < baseWalk * 0.72 then
					selected = walkTrack
				else
					selected = runTrack or walkTrack
				end
			end
			stopMovementTracks(selected)
			if selected then
				if not selected.IsPlaying then selected:Play(0.1) end
				local referenceSpeed = selected == walkTrack and baseWalk * 0.52 or baseWalk
				local maxPlaybackSpeed = monsterId == "Wolf" and 1.8 or 1.5
				selected:AdjustSpeed(math.clamp(displaySpeed / math.max(1, referenceSpeed), 0.4, maxPlaybackSpeed))
			end
		end
		humanoid.Running:Connect(updateMovement)
		if monsterId == "Wolf" then
			model:GetAttributeChangedSignal("WolfLocomotionMode"):Connect(function()
				updateMovement(lastSpeed)
			end)
		end
	end
	if animDef.Dead and animDef.Dead ~= "" then
		humanoid.Died:Connect(function()
			stopMovementTracks(nil)
			local deadAnim = Instance.new("Animation")
			deadAnim.Name = "MonsterDead"
			deadAnim.AnimationId = animDef.Dead
			local ok, track = pcall(animator.LoadAnimation, animator, deadAnim)
			if ok and track then
				track.Priority = Enum.AnimationPriority.Action4
				track.Looped = false
				track:Play(0) -- 재생 후 시체 유지 — 제거는 retire의 CorpseDespawnSec 몫
			end
		end)
	end
end

-- 공격 실애니: AVDefs.MonsterAnims[id].Attack 정의 시 재생(트랙은 st에 캐시 — 모델 수명과 동일).
-- 반환 nil = 미정의/로드 실패 — 호출측이 기존 절차 모션 유지(예: Straw 돌진)
local function playAttackAnim(st)
	local monsterId = st.Model and st.Model:GetAttribute("MonsterId")
	local animDef = monsterId and AVDefs.MonsterAnims[monsterId]
	local animId = animDef and animDef.Attack
	if not animId or animId == "" then
		-- 절차 공격 클립 폴백(미등록이면 no-op) — nil 반환은 유지해 호출측 루트 모션·판정 타이밍 불변
		if st.Model then
			MonsterProcAnim.Play(st.Model, "Attack")
		end
		return nil
	end
	local track = st.AttackTrack
	if not track then
		local animator = st.Humanoid and st.Humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			return nil
		end
		local anim = Instance.new("Animation")
		anim.Name = "MonsterAttack"
		anim.AnimationId = animId
		local ok, loaded = pcall(animator.LoadAnimation, animator, anim)
		if not ok or not loaded then
			return nil
		end
		loaded.Priority = Enum.AnimationPriority.Action
		loaded.Looped = false
		st.AttackTrack = loaded
		track = loaded
	end
	track:Play(0.05)
	return track
end

-- 공격 패턴 규약: 판정 = XZ 오리엔티드 박스(높이 관대 — 위치 이탈로 회피), 예고 = 지면 인디케이터 채움 = 회피 타이밍.
-- 시퀀스는 공격 1회 한정 단발 코루틴(상시 루프 금지) — 진행 중 aiTick은 st.AttackBusy로 개입하지 않는다.
local function monsterGroundY(pos)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.IgnoreWater = true
	-- _Markers 제외 필수: 투명 체크포인트/포털 파트가 지면으로 오인되면 텔레그래프가 공중(머리 위)에 그려짐
	local exclude = { monstersFolder }
	local markers = Workspace:FindFirstChild("_Markers")
	if markers then
		exclude[#exclude + 1] = markers
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			exclude[#exclude + 1] = p.Character
		end
	end
	rp.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(Vector3.new(pos.X, pos.Y + 50, pos.Z), Vector3.new(0, -500, 0), rp)
	return hit and hit.Position.Y or (pos.Y - 2)
end

-- 시야 판정: 몹 루트 → 타겟 사이에 지형·구조물이 있으면 false.
-- 벽 통과 몹(신전 수호령)이 "이동은 통과하되 공격은 시야가 필요"를 지키게 하는 게이트.
-- 제외 목록은 monsterGroundY와 동일 규약(몹 폴더·_Markers·캠릭터).
local function hasLineOfSight(root, targetRoot)
	if not (root and targetRoot) then
		return true
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.IgnoreWater = true
	local exclude = { monstersFolder }
	local markers = Workspace:FindFirstChild("_Markers")
	if markers then
		exclude[#exclude + 1] = markers
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			exclude[#exclude + 1] = p.Character
		end
	end
	rp.FilterDescendantsInstances = exclude
	return Workspace:Raycast(root.Position, targetRoot.Position - root.Position, rp) == nil
end

local function pointInBox(boxCf, size, pos)
	local lp = boxCf:PointToObjectSpace(pos)
	return math.abs(lp.X) <= size.X / 2 and math.abs(lp.Z) <= size.Z / 2
end

local function showBoxTelegraph(boxCf, size, windup, color)
	color = color or Color3.fromRGB(255, 70, 60)
	local groundY = boxCf.Position.Y - size.Y / 2
	local flatCf = CFrame.new(boxCf.Position.X, groundY + 0.1, boxCf.Position.Z) * (boxCf - boxCf.Position)
	local function makeFlat(sx, sz, transparency, yoff)
		local box = Instance.new("Part")
		box.Name = "AttackTelegraph"
		box.Material = Enum.Material.Neon
		box.Color = color
		box.Transparency = transparency
		box.Anchored = true
		box.CanCollide = false
		box.CanQuery = false
		box.CanTouch = false
		box.CastShadow = false
		box.Size = Vector3.new(sx, 0.2, sz)
		box.CFrame = flatCf * CFrame.new(0, yoff or 0, 0)
		box.Parent = monstersFolder
		return box
	end
	local outline = makeFlat(size.X, size.Z, 0.5)
	local fill = makeFlat(size.X, math.min(size.Z, 0.6), 0.2, 0.03)
	pcall(function()
		TweenService:Create(fill, TweenInfo.new(windup, Enum.EasingStyle.Linear), {
			Size = Vector3.new(size.X, 0.2, size.Z),
		}):Play()
	end)
	Debris:AddItem(outline, windup + 0.25)
	Debris:AddItem(fill, windup + 0.25)
end

-- 패턴 공용 연출 헬퍼: 파티클 버스트·지면 확장 링(서버 생성 — 전 클라 자동 복제)
local function spawnBurst(pos, color, count, speed, size)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.CFrame = CFrame.new(pos)
	holder.Parent = monstersFolder
	local att = Instance.new("Attachment")
	att.Parent = holder
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(color)
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(0.3, 0.6)
	pe.Speed = NumberRange.new(speed * 0.55, speed)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Acceleration = Vector3.new(0, -42, 0)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-180, 180)
	pe.Rate = 0
	pe.Parent = att
	pe:Emit(count)
	Debris:AddItem(holder, 1.3)
end

local function spawnGroundRing(pos, radius, color, lifeSec)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = color
	ring.Transparency = 0.35
	ring.Size = Vector3.new(0.3, radius * 0.7, radius * 0.7)
	ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = monstersFolder
	pcall(function()
		TweenService:Create(ring, TweenInfo.new(lifeSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.3, radius * 2, radius * 2),
			Transparency = 1,
		}):Play()
	end)
	Debris:AddItem(ring, lifeSec + 0.15)
end

-- 클래식 링 메시를 쓰는 실제 도넛 파동. 실린더 원판과 달리 중앙이 비어 초음파/북 충격파가 읽힌다.
local DONUT_RING_MESH_ID = "rbxassetid://3270017"

local function makeDonutRing(name, color, parent, transparency)
	local part = Instance.new("Part")
	part.Name = name or "DonutRing"
	part.Size = Vector3.new(1, 1, 1)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency or 0.2
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = DONUT_RING_MESH_ID
	mesh.Scale = Vector3.new(1, 1, 1)
	mesh.Parent = part
	part.Parent = parent or monstersFolder
	return part, mesh
end

local function placeDonutRing(part, mesh, pos, normal, diameter, thickness)
	if normal then
		local n = normal.Magnitude > 0.01 and normal.Unit or Vector3.new(0, 0, 1)
		part.CFrame = CFrame.lookAt(pos, pos + n)
	else
		part.CFrame = CFrame.new(pos) * CFrame.Angles(math.rad(90), 0, 0)
	end
	mesh.Scale = Vector3.new(diameter, diameter, thickness or math.max(diameter * 0.16, 0.6))
end

local function spawnDonutRing(pos, radius, color, lifeSec, startRatio)
	local part, mesh = makeDonutRing("GroundDonutRing", color, monstersFolder, 0.18)
	local endDia = radius * 2
	local startDia = endDia * (startRatio or 0.28)
	placeDonutRing(part, mesh, pos, nil, startDia, math.max(startDia * 0.16, 0.5))
	pcall(function()
		TweenService:Create(mesh, TweenInfo.new(lifeSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = Vector3.new(endDia, endDia, math.max(endDia * 0.16, 0.8)),
		}):Play()
		TweenService:Create(part, TweenInfo.new(lifeSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Transparency = 1,
		}):Play()
	end)
	Debris:AddItem(part, lifeSec + 0.15)
	return part
end

-- Shared pattern epilogue: a windup cancelled by a player hit retries after AI.CancelRetrySec
-- instead of burning the full AtkInterval (prevents an endless cancel loop).
-- [2026-08-20 Z2 패턴 이식] 독 포자 장판(버섯정령). 근접(Slam)·원거리(Throw) 양쪽에서 호출한다.
-- ★원거리 전용으로 두면 실전에서 한 번도 안 나온다 — 몹이 AttackRange까지 접근해 근접만 쓰기 때문(챕터2 실측).
-- ⚠몹당 장판 1개만 유지: 공격 주기 < 장판 지속이라 겹치면 같은 자리에서 틱이 중복 적용된다.
local function spawnPoisonZone(st, centerPos)
	local def = st.Def
	local pz = def and def.PoisonZone
	if not pz then
		return
	end
	if st.PoisonZonePart and st.PoisonZonePart.Parent then
		st.PoisonZonePart:Destroy()
	end
	local zr = pz.Radius or 7
	-- ★지면 스냅: centerPos는 몹 루트(몸통 중앙)라 그대로 쓰면 허리 높이에 뜬 원판이 된다
	local gy = monsterGroundY(centerPos)
	local zone = Instance.new("Part")
	zone.Name = "PoisonZone"
	zone.Shape = Enum.PartType.Cylinder
	zone.Size = Vector3.new(0.25, zr * 2, zr * 2)
	zone.CFrame = CFrame.new(centerPos.X, gy + 0.12, centerPos.Z) * CFrame.Angles(0, 0, math.rad(90))
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanQuery = false
	zone.CanTouch = false
	zone.CastShadow = false
	zone.Material = Enum.Material.SmoothPlastic
	zone.Color = pz.Color or Color3.fromRGB(130, 200, 85)
	zone.Transparency = 0.5
	zone.Parent = monstersFolder
	st.PoisonZonePart = zone
	-- 포자 안개: 중앙 Attachment 1개에 몰지 않고 원판 전체에 골든앵글로 분산한다.
	-- 입자 크기도 반경 비례 대형 안개에서 작은 독 포자로 바꿔 장판 가장자리까지 고르게 읽히게 한다.
	local mistHolder = Instance.new("Part")
	mistHolder.Name = "SporeMistHolder"
	mistHolder.Size = Vector3.new(0.2, 0.2, 0.2)
	mistHolder.CFrame = CFrame.new(centerPos.X, gy + 0.16, centerPos.Z)
	mistHolder.Anchored = true
	mistHolder.CanCollide = false
	mistHolder.CanQuery = false
	mistHolder.CanTouch = false
	mistHolder.Transparency = 1
	mistHolder.Parent = zone
	local mistEmitters = {}
	local mistCount = 10
	for i = 1, mistCount do
		local u = (i - 0.35) / mistCount
		local ang = i * 2.399963229728653 -- golden angle
		local rad = zr * math.sqrt(u) * 0.84
		local att = Instance.new("Attachment")
		att.Position = Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
		att.Parent = mistHolder
		local mist = Instance.new("ParticleEmitter")
		mist.Name = "SporeMist"
		mist.Color = ColorSequence.new(pz.Color or Color3.fromRGB(130, 200, 85), Color3.fromRGB(78, 145, 58))
		mist.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.28),
			NumberSequenceKeypoint.new(0.45, 0.78),
			NumberSequenceKeypoint.new(1, 0.22),
		})
		mist.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.18, 0.28),
			NumberSequenceKeypoint.new(0.72, 0.52),
			NumberSequenceKeypoint.new(1, 1),
		})
		mist.Lifetime = NumberRange.new(0.9, 1.55)
		mist.Rate = 3.4
		mist.Speed = NumberRange.new(0.35, 0.9)
		mist.EmissionDirection = Enum.NormalId.Top
		mist.SpreadAngle = Vector2.new(28, 28)
		mist.Acceleration = Vector3.new(0, 2.2, 0)
		mist.Rotation = NumberRange.new(0, 360)
		mist.RotSpeed = NumberRange.new(-45, 45)
		mist.LightEmission = 0.12
		mist.LightInfluence = 0.65
		mist.Parent = att
		mist:Emit(3)
		mistEmitters[#mistEmitters + 1] = mist
	end
	local bubbleColor = pz.BubbleColor or Color3.fromRGB(120, 195, 75)
	task.spawn(function()
		local endAt = os.clock() + (pz.Duration or 4.5)
		while os.clock() < endAt and zone.Parent do
			-- 독 방울: 파티클이 배경에 묻혀도 이건 읽힌다. sqrt(random)은 원 안에 고르게 뿌리기 위한 것
			for _ = 1, 4 do
				local bang = math.random() * math.pi * 2
				local brad = zr * math.sqrt(math.random()) * 0.85
				local bub = Instance.new("Part")
				bub.Name = "SporeBubble"
				bub.Shape = Enum.PartType.Ball
				bub.Size = Vector3.new(0.22, 0.22, 0.22)
				bub.Anchored = true
				bub.CanCollide = false
				bub.CanQuery = false
				bub.CanTouch = false
				bub.CastShadow = false
				bub.Material = Enum.Material.SmoothPlastic
				bub.Color = bubbleColor
				bub.Transparency = 0.25
				bub.CFrame = CFrame.new(centerPos.X + math.cos(bang) * brad, gy + 0.3, centerPos.Z + math.sin(bang) * brad)
				bub.Parent = monstersFolder
				pcall(function()
					TweenService:Create(bub, TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Size = Vector3.new(0.9, 0.9, 0.9),
						Transparency = 1,
						CFrame = bub.CFrame + Vector3.new(0, 1.5, 0),
					}):Play()
				end)
				Debris:AddItem(bub, 0.95)
			end
			for _, p in ipairs(Players:GetPlayers()) do
				local c = p.Character
				local pr2 = c and c:FindFirstChild("HumanoidRootPart")
				local ph2 = c and c:FindFirstChildOfClass("Humanoid")
				if pr2 and ph2 and ph2.Health > 0
					and Vector3.new(pr2.Position.X - centerPos.X, 0, pr2.Position.Z - centerPos.Z).Magnitude <= zr then
					PlayerDamageService.Apply(ph2, pz.TickDamage or 7)
				end
			end
			task.wait(pz.TickSec or 1.0)
		end
		if zone.Parent then
			for _, mist in ipairs(mistEmitters) do
				mist.Enabled = false
			end
			pcall(function()
				TweenService:Create(zone, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { Transparency = 1 }):Play()
			end)
			Debris:AddItem(zone, 2.6)
		end
	end)
end

local function finishAttack(st)
	releaseAttackSlot(st)
	local now = os.clock()
	if st.Cancelled then
		st.Cancelled = nil
		local interval = (st.Def and st.Def.AtkInterval) or 1
		st.LastAtkAt = now - math.max(0, interval - (AI.CancelRetrySec or 0.5))
	else
		st.LastAtkAt = now
	end
	st.AttackBusy = nil
	st.KbInterrupt = nil
	-- [2026-09-07] 패턴 중 root.Anchored true→false를 거치면 네트워크 소유권이 Auto로 풀려 근접 플레이어 클라이언트로 넘어갈 수 있다
	-- (실측: 북 도깨비 rootOwner=플레이어 → 서버 MoveTo 무시 → 후퇴·추격 불능 고착, WalkToPoint는 있는데 MoveDirection 0).
	-- 공격 종료마다 서버 소유권을 다시 고정한다(spawnAt의 SetNetworkOwner(nil) 규약 재확인).
	if st.Root and st.Root.Parent and not st.Root.Anchored then
		pcall(function()
			st.Root:SetNetworkOwner(nil)
		end)
	end
	-- 공격 중 피격은 폴링하지 않고 최신 1회만 보관한다. 앵커 해제 직후 다음 스케줄에
	-- 적용해 긴 투척/다단 돌진에서도 반응이 유실되지 않고 연타 코루틴도 쌓이지 않는다.
	local pending = st.PendingHitKnockback
	st.PendingHitKnockback = nil
	if pending then
		task.defer(function()
			if active[st.Model] == st and st.Root and st.Root.Parent then
				MonsterService.ApplyHitKnockback(st.Model, pending.AttackerPos, pending.Opts, pending.Control)
			end
		end)
	end
end

-- armSwingFx 전방 선언 — performDash/Slam이 이 함수보다 먼저 정의되므로 업밸류 캡처용(실제 할당은 findJoint 뒤).
local armSwingFx

local function findModelPart(model, name)
	if not (model and name) then
		return nil
	end
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") and inst.Name == name then
			return inst
		end
	end
	return nil
end

-- 이름이 같은 파트가 여럿이거나 이름 목록이 오면 **전부** 처리한다.
-- 종전에는 첫 파트만 바꿔 술독 정령처럼 2파트짜리 소품은 한 쪽이 느냄없이 남았다.
local function setNamedPropVisible(st, names, visible)
	local model = st and st.Model
	if not (model and names) then
		return nil
	end
	local last
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") and propNameMatches(names, inst.Name) then
			local base = inst:GetAttribute("_AttackPropBaseTransparency")
			if type(base) ~= "number" then
				base = inst.Transparency
				inst:SetAttribute("_AttackPropBaseTransparency", base)
			end
			inst.Transparency = visible and base or 1
			last = inst
		end
	end
	return last
end

local function setAttackPropVisible(st, visible)
	local def = st and st.Def
	if def and def.AttackPropName then
		return setNamedPropVisible(st, def.AttackPropName, visible)
	end
	return nil
end

-- 짚단 돌진: 윈드업(뒤로 감김+떨림 코일) → 경로 박스 돌진(도약 아크) → 박스 내 타겟 1회 타격.
-- 돌진 이동은 루트 앵커+CFrame(원본 리그 분리/막힘/텔레포트 수정 방식). 종료 시 앵커 복원 보장.
local function performDash(st)
	st.KbInterrupt = nil -- 윈드업 피격 캔슬 플래그 초기화
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot, tHum = st.TargetRoot, st.TargetHum
	pcall(function()
		-- [2026-08-20 Z2 패턴 이식] 다단 돌진: DashCount회 반복(박쥐 "여러 번 들이받는다").
		-- 미지정이면 1 = 종전과 완전히 동일. 회차마다 재조준하므로 옆으로 피하면 다음 타가 빗나간다.
		local count = def.DashCount or 1
		for shot = 1, count do
		if hum.Health <= 0 or not root.Parent then
			break
		end
		local origin = root.Position
		local dirV = tRoot and tRoot.Parent and (tRoot.Position - origin) * Vector3.new(1, 0, 1)
		if not dirV or dirV.Magnitude < 0.5 then
			return
		end
		local dir = dirV.Unit
		local windup = (def.DashWindups and def.DashWindups[shot]) or def.DashWindup or 0.65
		local width = def.DashWidth or 4.5
		local length = math.clamp(dirV.Magnitude + 4, 6, (def.DashRange or 12) + 4)
		local gy = monsterGroundY(origin)
		local center = Vector3.new(origin.X, gy + AI.HitBoxHeight / 2, origin.Z) + dir * (length / 2)
		local boxCf = CFrame.lookAt(center, center + dir)
		local boxSize = Vector3.new(width, AI.HitBoxHeight, length)
		showBoxTelegraph(boxCf, boxSize, windup)
		playMobSound(root, (st.Model and st.Model:GetAttribute("MonsterId") or "") .. "DashWindup")
		hum.AutoRotate = false
		root.Anchored = true
		-- [2026-08-20 Z1 이식] ★performDash는 원래 playAttackAnim을 호출하지 않아 Dash 몹은 공격 클립이 안 돌았다.
		-- 박쥐가 날개를 채며 들이받으려면 여기서 재생해야 한다(키프레임 없으면 절차 클립으로 폴백).
		-- 전용 돌진 클립이 있으면 그걸 쓰고(긴 윈드업에 맞춤), 없으면 공용 Attack 클립 폴백
		if not MonsterProcAnim.Play(st.Model, "Charge") then
			playAttackAnim(st)
		end
		task.spawn(armSwingFx, st, windup + 0.35, "tackle") -- 박치기 전용 팔(오버헤드 슬램 팔과 구분)
		local base = origin
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return -- 윈드업 중 피격 = 패턴 캔슬(넉백 스태거 체감)
			end
			local a = (os.clock() - t0) / windup
			root.CFrame = CFrame.lookAt(base, base + dir)
				* CFrame.Angles(math.rad(8 + 24 * a), 0, math.rad(3 * math.sin(a * 42)))
			task.wait()
		end
		-- [2026-08-24] 돌진 속도·아크를 def에서 열었다 — 수호석처럼 "천천히 돌진"하는 몹을 만들기 위함.
		-- 미지정이면 종전과 완전히 동일(0.3초 · 도약 아크 1.6).
		local dashTime = def.DashTime or 0.3
		local hop = def.DashHop or 1.6 -- 0 = 도약 없이 지면을 밀고 나간다(돌덩이는 뛰지 않는다)
		local hitDone = false
		local hitDepth = math.max(3.5, math.min(length, (tonumber(st.Model:GetAttribute("HitRadius")) or width * 0.5) * 2))
		local previousHitPos = base
		local t1 = os.clock()
		while true do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			local a = math.min((os.clock() - t1) / dashTime, 1)
			local cx = base.X + dir.X * (length * a)
			local cz = base.Z + dir.Z * (length * a)
			local cy = base.Y + math.sin(a * math.pi) * hop -- 도약 포물선 아크(hop=0이면 평면 밀기)
			root.CFrame = CFrame.lookAt(Vector3.new(cx, cy, cz), Vector3.new(cx + dir.X, cy, cz + dir.Z))
				* CFrame.Angles(math.rad(-34 + 20 * a), 0, math.rad(12 * math.sin(a * math.pi)))
			local currentHitPos = Vector3.new(cx, base.Y, cz)
			local stepDist = (currentHitPos - previousHitPos).Magnitude
			local hitCenter = previousHitPos:Lerp(currentHitPos, 0.5)
			local movingHitCf = CFrame.lookAt(
				Vector3.new(hitCenter.X, gy + AI.HitBoxHeight / 2, hitCenter.Z),
				Vector3.new(hitCenter.X, gy + AI.HitBoxHeight / 2, hitCenter.Z) + dir
			)
			local movingHitSize = Vector3.new(width, AI.HitBoxHeight, stepDist + hitDepth)
			if not hitDone and tRoot and tRoot.Parent and tHum and tHum.Health > 0
				and pointInBox(movingHitCf, movingHitSize, tRoot.Position) then
				hitDone = true
				local dashHit = PlayerDamageService.Apply(tHum, math.floor(def.Atk * (def.DashDamageMul or 1) + 0.5))
				if dashHit and def.DashKnockback then
					-- 무거운 돌진은 밀어낸다 — 미지정 몹은 종전대로 낛백 없음
					local pl = Players:GetPlayerFromCharacter(tHum.Parent)
					if pl then
						MonsterService.KnockbackPlayer(pl, Vector3.new(base.X, tRoot.Position.Y, base.Z),
							def.DashKnockback.Force or 30, def.DashKnockback.Lift or 10)
					end
				end
			end
			previousHitPos = currentHitPos
			if a >= 1 then
				break
			end
			task.wait()
		end
		local pos = root.Position
		root.CFrame = CFrame.lookAt(Vector3.new(pos.X, base.Y, pos.Z), Vector3.new(pos.X + dir.X, base.Y, pos.Z + dir.Z))
		if shot < count then
			root.Anchored = false -- 회차 사이에는 물리 복귀(연속 앵커는 접지가 밀린다)
			local gapEnd = os.clock() + (def.DashGap or 0.25)
			while os.clock() < gapEnd do
				if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
					return
				end
				task.wait()
			end
			root.Anchored = true
		end
		end
	end)
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 벽돌 슬램: 무겁게 들어올리는 윈드업 → 내리찍기 → 몸 중심 사각 광역(박스 내 전 생존 플레이어).
local function performSlam(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	setAttackPropVisible(st, true)
	pcall(function()
		local windup = def.SlamWindup or 0.55
		local radius = def.SlamRadius or 9
		-- [2026-08-20 Z2 패턴 이식] 타겟 조준(SlamFaceTarget): Slam은 제자리 공격이라 이동이 없고,
		-- Humanoid 자동 회전은 "이동 방향"으로만 걸리므로 직전에 걷던 방향 그대로 굳은 채 때린다(실측 79도 어긋남).
		-- 몸에 붙은 부위(항아리 속·뚜껑)가 엉뚱한 곳을 보게 되므로, 윈드업 직전에 한 번 타겟 쪽으로 돌린다.
		-- ★반드시 center/baseYaw를 읽기 전에 돌려야 한다 — 뒤에서 돌리면 판정 박스와 모션 기준이 어긋난다.
		if def.SlamFaceTarget then
			local tR = st.TargetRoot
			if tR and tR.Parent then
				local toT = (tR.Position - root.Position) * Vector3.new(1, 0, 1)
				if toT.Magnitude > 0.5 then
					root.CFrame = CFrame.lookAt(root.Position, root.Position + toT.Unit)
				end
			end
		end
		local center = root.Position
		local gy = monsterGroundY(center)
		local boxCf, boxSize
		-- [2026-09-07] SlamStyle="Fist"(수호석 돌주먹 내려찍기): Wing과 같은 전방 박스 판정이지만 런지(전진) 없이 제자리. 폭/길이는 SlamWidth/SlamReach.
		if def.SlamStyle == "Wing" or def.SlamStyle == "Fist" then
			-- 날개 후려치기(박쥐): 몸 중심 정사각 광역 대신 전방 지향 박스.
			-- 폭=양 날개 스팬, 깊이=날개가 닿는 거리. 뒤로 돌아가면 빠져나갈 수 있어 회피 여지가 생긴다
			-- (제자리 광역은 붙어 있으면 무조건 맞는 구조였다). pointInBox는 CFrame 기반이라 회전 박스를 그대로 지원.
			local lv = root.CFrame.LookVector * Vector3.new(1, 0, 1)
			local ld = lv.Magnitude > 0.1 and lv.Unit or Vector3.new(0, 0, 1)
			local reach = def.SlamReach or def.WingReach or 8
			local c = center + ld * (reach * 0.5)
			local cy = monsterGroundY(c) + AI.HitBoxHeight / 2
			boxCf = CFrame.lookAt(Vector3.new(c.X, cy, c.Z), Vector3.new(c.X + ld.X, cy, c.Z + ld.Z))
			boxSize = Vector3.new(def.SlamWidth or def.WingWidth or 11, AI.HitBoxHeight, reach)
		else
			boxCf = CFrame.new(center.X, gy + AI.HitBoxHeight / 2, center.Z)
			boxSize = Vector3.new(radius * 2, AI.HitBoxHeight, radius * 2)
		end
		showBoxTelegraph(boxCf, boxSize, windup)
		local slamMid = st.Model and st.Model:GetAttribute("MonsterId") or ""
		playMobSound(root, slamMid .. "SlamWindup")
		-- 실공격 애니(AVDefs Attack) 있으면 재생하고 절차 루트 모션(들어올리기/내리찍기)은 생략 — 판정/타이밍 불변
		local attackTrack = playAttackAnim(st)
		-- SlamStyle="Shove"(몸통 밀치기): 들어올리기 대신 뒤로 재었다 몸통 런지 + 전방 푸시 팔
		local shove = def.SlamStyle == "Shove"
		-- Wing = 날개 후려치기. 들어올리기(2.2스터드)는 박쥐에 과해 위아래로 통통 튀어 보였다
		-- → 살짝 떠올라 앞으로 훅 미는 이동형으로 전환(Shove와 같은 경로, 수치만 다름)
		local wing = def.SlamStyle == "Wing"
		local lunge = shove or wing
		local lungeBack = wing and 0.8 or 1.2   -- 윈드업에 뒤로 재는 거리
		local lungeFwd = wing and 2.6 or 3.7    -- 타격에 전진하는 거리
		local lungeRise = wing and 0.5 or 0     -- 날개는 살짝 부상(밀치기는 지면 유지)
		local lungePitch = wing and -14 or 20   -- 날개=뒤로 젖힘(음수), 밀치기=앞으로 숙임
		local lungeSwing = wing and 30 or 38    -- 타격 시 되돌리는 각
		local lookV = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		local lookDir = lookV.Magnitude > 0.1 and lookV.Unit or Vector3.new(0, 0, 1)
		-- 밀치기 런지가 수평 고정 Y로 움직이면 경사면에서 파묻힘/부유 — 지면 추종 Y
		local shoveStandY = 0
		local function shoveGroundY(pos)
			local gy2 = monsterGroundY(pos)
			return gy2 + shoveStandY
		end
		if lunge then
			shoveStandY = root.Position.Y - monsterGroundY(root.Position)
			if shoveStandY < 0.5 or shoveStandY > 12 then
				shoveStandY = (def.HipOffset or 0) + (def.FlyHeight or 0) + root.Size.Y * 0.5 -- 이상치 폴백
			end
		end
		task.spawn(armSwingFx, st, (def.SlamWindup or 0.55) + 0.3, shove and "push" or "overhead")
		local base = center
		local _, baseYaw = root.CFrame:ToOrientation()
		root.Anchored = true
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return -- 윈드업 중 피격 = 패턴 캔슬
			end
			if not attackTrack then
				local a = (os.clock() - t0) / windup
				if lunge then
					-- 밀치기 차징: 뒤로 물러나며 젖힘(들어올리기 없음) — Y는 지면 추종
					local p = base - lookDir * (lungeBack * a)
					root.CFrame = CFrame.new(Vector3.new(p.X, shoveGroundY(p) + lungeRise * a, p.Z))
						* CFrame.Angles(0, baseYaw, 0) * CFrame.Angles(math.rad(lungePitch * a), 0, 0)
				else
					root.CFrame = CFrame.new(base.X, base.Y + a * 2.2, base.Z)
						* CFrame.Angles(0, baseYaw, 0) * CFrame.Angles(math.rad(18 * a), 0, 0)
				end
			end
			task.wait()
		end
		local slamT = 0.16
		local t1 = os.clock()
		while os.clock() - t1 < slamT do
			if not root.Parent then
				return
			end
			if not attackTrack then
				local a = math.min((os.clock() - t1) / slamT, 1)
				if lunge then
					-- 밀치기 타격: 몸통 전방 런지(뒤로 재었던 1.2 + 전진 2.5) — Y는 지면 추종
					local p = base + lookDir * (-lungeBack + lungeFwd * a)
					root.CFrame = CFrame.new(Vector3.new(p.X, shoveGroundY(p) + lungeRise * (1 - a), p.Z))
						* CFrame.Angles(0, baseYaw, 0) * CFrame.Angles(math.rad(lungePitch - lungeSwing * a), 0, 0)
				else
					root.CFrame = CFrame.new(base.X, base.Y + 2.2 * (1 - a), base.Z)
						* CFrame.Angles(0, baseYaw, 0) * CFrame.Angles(math.rad(18 - 42 * a), 0, 0)
				end
			end
			task.wait()
		end
		if not attackTrack then
			root.CFrame = CFrame.new(base) * CFrame.Angles(0, baseYaw, 0)
		end
		-- [2026-08-20 Z2 패턴 이식] 다단 타격(드럼롤): SlamHits회 반복. 미지정이면 1 = 종전 단타와 완전히 동일하다.
		-- 같은 자리를 겹쳐 때리므로 회당 피해는 나눠 갖는다(총량은 def의 SlamDamageMul로 맞춘다).
		local hits = math.max(1, def.SlamHits or 1)
		local hitGap = def.SlamHitGap or 0.18
		for hi = 1, hits do
		if hi > 1 then
			task.wait(hitGap)
			if not (root.Parent and hum.Health > 0) then
				break
			end
		end
		-- 충격파 링(도깨비 북): 두드린 순간 지면에 파동이 퍼진다.
		-- 판정과 같은 시점·같은 반경이라 "북소리가 닿는 범위"가 눈으로 읽힌다(기존 spawnGroundRing 재사용).
		if def.SlamShockRing then
			local ringCol = def.SlamShockColor and Color3.fromRGB(def.SlamShockColor[1], def.SlamShockColor[2], def.SlamShockColor[3])
				or Color3.fromRGB(255, 205, 130)
			local ringScale = (hi == hits) and 1 or (0.58 + 0.12 * hi)
			spawnDonutRing(Vector3.new(center.X, gy + 0.15, center.Z), radius * ringScale, ringCol, 0.42, 0.16)
			if hi == hits then
				-- 마지막 타에만 안쪽 도넛 파동을 한 겹 더 얹어 북소리 마무리를 강조
				task.delay(0.12, function()
					spawnDonutRing(Vector3.new(center.X, gy + 0.15, center.Z), radius * 0.72, ringCol, 0.38, 0.18)
				end)
			end
		end
		-- 날개 궤적: 후려친 자리에 얇은 호를 남겨 "날개를 썼다"를 눈에 보이게 한다.
		-- 조인트 모션만으로는 0.16초 타격이 순식간에 지나가 잘 안 읽혔다.
		-- 판정 박스와 같은 CFrame을 쓰므로 맞는 범위와 보이는 범위가 일치한다.
		if wing then
			local sweepColor = def.ThrowColor and Color3.fromRGB(def.ThrowColor[1], def.ThrowColor[2], def.ThrowColor[3])
				or Color3.fromRGB(180, 225, 255)
			for i = 1, 3 do
				local arc = Instance.new("Part")
				arc.Name = "WingSweep"
				arc.Anchored = true
				arc.CanCollide = false
				arc.CanQuery = false
				arc.CanTouch = false
				arc.CastShadow = false
				arc.Material = Enum.Material.Neon
				arc.Color = sweepColor
				arc.Transparency = 0.35 + (i - 1) * 0.12
				-- 안쪽에서 바깥으로 세 겹 — 스윕이 훑고 지나간 잔상
				local w = boxSize.X * (0.5 + i * 0.18)
				local d2 = boxSize.Z * (0.34 + i * 0.1)
				arc.Size = Vector3.new(w, 0.3, d2)
				arc.CFrame = boxCf * CFrame.new(0, -AI.HitBoxHeight / 2 + 1.6 + i * 0.5, 0)
					* CFrame.Angles(0, 0, math.rad(-16 + i * 12))
				arc.Parent = monstersFolder
				pcall(function()
					TweenService:Create(arc, TweenInfo.new(0.22 + i * 0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Size = Vector3.new(w * 1.25, 0.3, d2 * 1.15),
						Transparency = 1,
					}):Play()
				end)
				Debris:AddItem(arc, 0.45)
			end
		end
		if def.SlamImpactColor then
			local c = Color3.fromRGB(def.SlamImpactColor[1], def.SlamImpactColor[2], def.SlamImpactColor[3])
			spawnBurst(Vector3.new(center.X, gy + 0.35, center.Z), c, 14, 11, 0.38)
			spawnDonutRing(Vector3.new(center.X, gy + 0.18, center.Z), radius * 0.85, c, 0.32, 0.18)
		end
		playMobSound(root, slamMid .. "SlamHit") -- 내리찍기 임팩트(판정 직전 = 타격감 동기화)
		for _, p in ipairs(Players:GetPlayers()) do
			local c = p.Character
			local pr = c and c:FindFirstChild("HumanoidRootPart")
			local ph = c and c:FindFirstChildOfClass("Humanoid")
			if pr and ph and ph.Health > 0 and pointInBox(boxCf, boxSize, pr.Position) then
				local damaged = PlayerDamageService.Apply(ph, math.floor(def.Atk * (def.SlamDamageMul or 1) + 0.5))
				if damaged and def.PlayerKnockback then
					MonsterService.KnockbackPlayer(p, boxCf.Position, def.PlayerKnockback.Force, def.PlayerKnockback.Lift)
				end
			end
		end
		end
		if def.PoisonOnSlam ~= false then
			spawnPoisonZone(st, center) -- 근접 살포(명시적으로 끈 몬스터는 점프 공격과 독 투척을 분리)
		end
	end)
	if def.AttackPropHidden then
		setAttackPropVisible(st, false)
	end
	if root.Parent then
		root.Anchored = false
	end
	finishAttack(st)
end

-- 상태 머신: Idle → Chase → Attack, 리쉬 이탈 시 Return (귀환 중 어그로 무시)
-- 조인트 조회(이름=Motor6D명 또는 Part1명) — 절차 패턴 애니용
local function findJoint(model, name)
	if not model then
		return nil
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") and (d.Name == name or (d.Part1 and d.Part1.Name == name)) then
			return d
		end
	end
	return nil
end

-- 절차 팔 스윙: 근접 패턴(돌진/슬램/회전)에 팔 타격 모션 부여(공격 키프레임 애니 없는 몹용).
-- 실 Attack 애니가 있는 몹(Mud/늑대)은 애니가 조인트를 구동하므로 생략. RightArm/LeftArm Motor6D 없으면 no-op. C0 복원 보장.
armSwingFx = function(st, dur, kind)
	local id = st.Model and st.Model:GetAttribute("MonsterId")
	local animDef = id and AVDefs.MonsterAnims[id]
	if animDef and animDef.Attack and animDef.Attack ~= "" then
		return
	end
	if MonsterProcAnim.Has(id, "Attack") then
		return -- 절차 공격 클립이 조인트를 구동 중 — 팔 스윙과 이중 구동 금지
	end
	-- 짚단 리그(조인트명 "Right Arm" 공백형) 지원
	local rArm = findJoint(st.Model, "RightArm") or findJoint(st.Model, "Right Arm")
	local lArm = findJoint(st.Model, "LeftArm") or findJoint(st.Model, "Left Arm")
	if not rArm and not lArm then
		return
	end
	local rC0 = rArm and rArm.C0
	local lC0 = lArm and lArm.C0
	local t0 = os.clock()
	while os.clock() - t0 < dur do
		if not (st.Model and st.Model.Parent) then
			break
		end
		local a = (os.clock() - t0) / dur
		local swing = a < 0.45 and (a / 0.45) or (1 - (a - 0.45) / 0.55) -- 0→치켜들기→0내려침
		if kind == "spin" then
			if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(0, 0, math.rad(75 * swing)) end
			if lArm and lC0 then lArm.C0 = lC0 * CFrame.Angles(0, 0, math.rad(-75 * swing)) end
		elseif kind == "tackle" then
			-- 박치기(Dash): 양팔을 뒤로 젖혀 들이받는 자세(오버헤드 슬램 팔과 구분)
			if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(math.rad(55 * swing), 0, math.rad(-14 * swing)) end
			if lArm and lC0 then lArm.C0 = lC0 * CFrame.Angles(math.rad(55 * swing), 0, math.rad(14 * swing)) end
		elseif kind == "push" then
			-- 몸통 밀치기(Shove 슬램): 양팔 전방 푸시
			if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(math.rad(-85 * swing), 0, 0) end
			if lArm and lC0 then lArm.C0 = lC0 * CFrame.Angles(math.rad(-85 * swing), 0, 0) end
		else
			if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(math.rad(-110 * swing), 0, 0) end
			if lArm and lC0 then lArm.C0 = lC0 * CFrame.Angles(math.rad(-110 * swing), 0, 0) end
		end
		task.wait()
	end
	if rArm and rC0 and rArm.Parent then rArm.C0 = rC0 end
	if lArm and lC0 and lArm.Parent then lArm.C0 = lC0 end
end

-- 흙덩이 투척 페이싱: 종류별 전역 최소 간격(팩 동시투척 방지)
local THROW_GLOBAL_CD = 1.2
local lastThrowGlobalAt = {}

-- 회전 후려치기: 밀착 시 제자리 360° 몸통 회전 광역.
-- performDash와 거리 분담(붙으면 휘두르고 떨어지면 돌진) — SpinRadius 정의 몹만 aiTick이 디스패치.
local function performSpin(st)
	local def, hum, root = st.Def, st.Humanoid, st.Root
	-- Straw 리그 조인트(RootJoint/Head) 원C0 캡처 — pcall 밖 복원 보장
	local rootJoint = findJoint(st.Model, "RootJoint") or findJoint(st.Model, "Torso") -- 당근이 리그(RootJoint 없음 — Torso 직결) 코일 지원
	local headJoint = findJoint(st.Model, "Head")
	local rootC0 = rootJoint and rootJoint.C0
	local headC0 = headJoint and headJoint.C0
	pcall(function()
		local windup = def.SpinWindup or 0.5
		local radius = def.SpinRadius or 7
		local center = root.Position
		local gy = monsterGroundY(center)
		local boxCf = CFrame.new(center.X, gy + AI.HitBoxHeight / 2, center.Z)
		local boxSize = Vector3.new(radius * 2, AI.HitBoxHeight, radius * 2)
		showBoxTelegraph(boxCf, boxSize, windup, Color3.fromRGB(255, 150, 40)) -- 주황 = 돌진(빨강)과 구분
		local spinMid = st.Model and st.Model:GetAttribute("MonsterId") or ""
		playMobSound(root, spinMid .. "SpinWindup") -- 미등록 키는 무음 no-op
		local attackTrack = playAttackAnim(st)
		task.spawn(armSwingFx, st, (def.SpinWindup or 0.5) + 0.7, "spin")
		local base = center
		local _, baseYaw = root.CFrame:ToOrientation()
		hum.AutoRotate = false
		root.Anchored = true
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			if not attackTrack then
				local a = (os.clock() - t0) / windup
				root.CFrame = CFrame.new(base) * CFrame.Angles(0, baseYaw - math.rad(55 * a), 0)
					* CFrame.Angles(0, 0, math.rad(3 * math.sin(a * 40)))
				if rootJoint then
					rootJoint.C0 = CFrame.new(0, -0.35 * a, 0) * CFrame.Angles(math.rad(-10 * a), 0, math.rad(14 * a)) * rootC0
				end
				if headJoint then
					headJoint.C0 = CFrame.Angles(math.rad(12 * a), math.rad(-18 * a), 0) * headC0
				end
			end
			task.wait()
		end
		-- 회오리 연출: 지면 바람 링(판정 반경) + 짚 파편 버스트
		spawnGroundRing(Vector3.new(base.X, gy + 0.4, base.Z), radius, Color3.fromRGB(255, 222, 140), 0.38)
		spawnBurst(base + Vector3.new(0, 1.6, 0), Color3.fromRGB(236, 208, 108), 16, 26, 0.7)
		local spinT = 0.28
		local t1 = os.clock()
		while os.clock() - t1 < spinT do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			if not attackTrack then
				local a = math.min((os.clock() - t1) / spinT, 1)
				local pop = math.sin(a * math.pi)
				root.CFrame = CFrame.new(base) * CFrame.Angles(0, baseYaw - math.rad(55) + math.rad(415 * a), 0)
					* CFrame.Angles(math.rad(6 * pop), 0, 0)
				if rootJoint then
					rootJoint.C0 = CFrame.new(0, 0.5 * pop, 0) * CFrame.Angles(math.rad(8 * pop), 0, math.rad(-18 * pop)) * rootC0
				end
				if headJoint then
					headJoint.C0 = CFrame.Angles(math.rad(-8 * pop), 0, 0) * headC0
				end
			end
			task.wait()
		end
		if not attackTrack then
			root.CFrame = CFrame.new(base) * CFrame.Angles(0, baseYaw, 0)
		end
		playMobSound(root, spinMid .. "SpinHit")
		for _, p in ipairs(Players:GetPlayers()) do
			local c = p.Character
			local pr = c and c:FindFirstChild("HumanoidRootPart")
			local ph = c and c:FindFirstChildOfClass("Humanoid")
			if pr and ph and ph.Health > 0 and pointInBox(boxCf, boxSize, pr.Position) then
				PlayerDamageService.Apply(ph, math.floor(def.Atk * (def.SpinDamageMul or 1) + 0.5))
			end
		end
	end)
	if rootJoint and rootJoint.Parent then
		rootJoint.C0 = rootC0 -- 조인트 원상 복원(조기 중단 포함)
	end
	if headJoint and headJoint.Parent then
		headJoint.C0 = headC0
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 순간이동 베기(춤추는 도깨비): 탈 환영만 남기고 사라졌다 타겟 등 뒤에 나타나 벤다.
-- 노션 "몬스터 외형 참고" — 춤추는 도깨비 특징 "춤을 추며 순간이동하듯 이동한다".
-- 회피 설계: 순간이동 자체는 못 피해도 등장 뒤 베기 전조(BlinkWindup)는 피할 수 있다 — 즉사 기습 금지.
-- ★파트 투명화는 pcall 밖에서 반드시 복원한다(조기 return 시 투명 고착 = 안 보이는 몹).
local function performBlink(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local model = st.Model
	local hidden = {}
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local rgb = def.BlinkColor or { 168, 120, 235 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local vanish = def.BlinkVanishSec or 0.3
		local windup = def.BlinkWindup or 0.45
		local width = def.BlinkWidth or 5
		local length = def.BlinkLength or 7
		local behind = def.BlinkBehind or 4.5
		local mid = (model and model:GetAttribute("MonsterId")) or ""
		-- 모드: "Away" = 거리를 벌리는 점멸(도깨비불 마법사 — 베기 없음) · 기본 = 등 뒤 기습(춤추는 도깨비)
		local awayMode = def.BlinkMode == "Away"

		hum.AutoRotate = false
		root.Anchored = true

		-- ① 사라짐: 몸 파트 투명화 + 잔상 버스트
		local from = root.Position
		spawnBurst(from + Vector3.new(0, 1.5, 0), color, 18, 22, 0.7)
		playMobSound(root, mid .. "BlinkOut")
		-- 이탈 폭발(Away 전용): 사라진 자리에 청염이 남아 터진다 — 무작정 밀착의 대가.
		-- 전조 길이 = 사라짐 시간 전체라 붙어 있던 플레이어에게 빠질 시간을 준다.
		local departCf, departSize
		if awayMode and def.BlinkDepartRadius then
			local dgy = monsterGroundY(from)
			local r = def.BlinkDepartRadius
			departCf = CFrame.new(from.X, dgy + AI.HitBoxHeight / 2, from.Z)
			departSize = Vector3.new(r * 2, AI.HitBoxHeight, r * 2)
			showBoxTelegraph(departCf, departSize, vanish, color)
		end
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d ~= root then
				hidden[d] = d.Transparency
				d.Transparency = 1
			end
		end
		local t0 = os.clock()
		while os.clock() - t0 < vanish do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			task.wait()
		end

		-- ② 등장 지점 = 타겟 등 뒤. 지면 스냅 + 출발 지점의 루트 힙 높이 보존(파묻힘·부양 방지)
		if not (tRoot and tRoot.Parent) then
			return
		end
		local look = tRoot.CFrame.LookVector * Vector3.new(1, 0, 1)
		look = look.Magnitude > 0.05 and look.Unit or Vector3.new(0, 0, 1)
		local want
		if awayMode then
			-- 타겟 기준 정반대편으로 물러난다. 재등장 거리는 반드시 투척 사거리(ThrowMinRange~ThrowRange) 안쪽으로 잡을 것 —
			-- 밖으로 나가면 물러났다가 다시 걸어오는 왕복만 생긴다.
			local backV = (from - tRoot.Position) * Vector3.new(1, 0, 1)
			local backDir = backV.Magnitude > 0.05 and backV.Unit or -look
			want = tRoot.Position + backDir * (def.BlinkAwayDist or 16)
		else
			want = tRoot.Position - look * behind
		end
		-- ★힙 높이는 반드시 클램프: 넘어지거나 밀려 떠 있는 상태에서 그대로 쓰면
		-- 순간이동이 그 고도를 보존해 계속 공중에 나타난다(실측: Y 442 지면에서 487까지 누적).
		local hip = math.clamp(from.Y - monsterGroundY(from), 0.5, root.Size.Y)
		local gy = monsterGroundY(Vector3.new(want.X, from.Y, want.Z))
		local appear = Vector3.new(want.X, gy + hip, want.Z)
		local dirV = (tRoot.Position - appear) * Vector3.new(1, 0, 1)
		local dir = dirV.Magnitude > 0.05 and dirV.Unit or look
		root.CFrame = CFrame.lookAt(appear, appear + dir)

		-- ③ 등장 + 베기 전조(등장 링 → 전방 박스). 예고 박스 = 판정 박스 동일
		for d, tr in pairs(hidden) do
			if d.Parent then
				d.Transparency = tr
			end
		end
		table.clear(hidden)
		spawnBurst(appear + Vector3.new(0, 1.5, 0), color, 18, 22, 0.7)
		spawnGroundRing(Vector3.new(appear.X, gy + 0.4, appear.Z), width * 0.6, color, 0.35)
		playMobSound(root, mid .. "BlinkIn")
		-- 이탈 폭발 판정: 사라짐 전조 박스를 그대로 쓴다(예고=판정)
		if departCf then
			spawnBurst(Vector3.new(from.X, from.Y + 1.2, from.Z), color, 22, 26, 0.8)
			spawnGroundRing(Vector3.new(from.X, monsterGroundY(from) + 0.35, from.Z), def.BlinkDepartRadius, color, 0.35)
			playMobSound(root, mid .. "BlinkDepart")
			for _, p in ipairs(Players:GetPlayers()) do
				local pc = p.Character
				local ppr = pc and pc:FindFirstChild("HumanoidRootPart")
				local ph = pc and pc:FindFirstChildOfClass("Humanoid")
				if ppr and ph and ph.Health > 0 and pointInBox(departCf, departSize, ppr.Position) then
					PlayerDamageService.Apply(ph, math.floor(def.Atk * (def.BlinkDepartDamageMul or 0.9) + 0.5))
				end
			end
		end
		if awayMode then
			-- 후퇴형은 베기가 없다 — 타겟을 바라본 채 자세만 고치고 경직으로 넘어간다.
			root.CFrame = CFrame.lookAt(appear, appear + dir)
			playAttackAnim(st)
		else
			local center = Vector3.new(appear.X, gy + AI.HitBoxHeight / 2, appear.Z) + dir * (length / 2)
			local boxCf = CFrame.lookAt(center, center + dir)
			local boxSize = Vector3.new(width, AI.HitBoxHeight, length)
			showBoxTelegraph(boxCf, boxSize, windup, color)
			playAttackAnim(st)
			task.spawn(armSwingFx, st, windup + 0.3, "spin") -- 춤사위 팔

			local t1 = os.clock()
			while os.clock() - t1 < windup do
				if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
					return
				end
				local a = (os.clock() - t1) / windup
				root.CFrame = CFrame.lookAt(appear, appear + dir) * CFrame.Angles(0, math.rad(-50 * a), 0)
				task.wait()
			end

			-- ④ 베기
			root.CFrame = CFrame.lookAt(appear, appear + dir) * CFrame.Angles(0, math.rad(60), 0)
			spawnBurst(center + Vector3.new(0, 1.2, 0), color, 12, 18, 0.5)
			playMobSound(root, mid .. "BlinkHit")
			for _, p in ipairs(Players:GetPlayers()) do
				local pc = p.Character
				local pr = pc and pc:FindFirstChild("HumanoidRootPart")
				local ph = pc and pc:FindFirstChildOfClass("Humanoid")
				if pr and ph and ph.Health > 0 and pointInBox(boxCf, boxSize, pr.Position) then
					PlayerDamageService.Apply(ph, math.floor(def.Atk * (def.BlinkDamageMul or 1) + 0.5))
				end
			end
		end

		-- ⑤ 경직: 순간이동 직후 공격 불가(명세 0.6초). 앵커를 먼저 풀어 반격 창을 준다.
		if root.Parent then
			root.Anchored = false
		end
		local rec = def.BlinkRecoverSec or 0.6
		local t2 = os.clock()
		while os.clock() - t2 < rec do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			task.wait()
		end
	end)
	for d, tr in pairs(hidden) do
		if d.Parent then
			d.Transparency = tr
		end
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 탈 환영 연무(춤추는 도깨비 부 패턴): 몸을 축으로 균등 간격 부채 N장을 동시에 친다.
-- 노션 환영검 계열 연출("가면 환영이 떠다니며 보랏빛 안개").
-- ★Spin과의 결정적 차이 = 원 전체가 아니라 부채 N장이라 **사이 틈에 서면 안전**하다.
--   "밖으로 벗어나는" 패턴이 아니라 "틈을 읽는" 패턴 — 순간이동으로 등 뒤를 잡힌 직후와 궁합이 맞는다.
-- 전조 박스 좌표를 그대로 판정에 쓴다(예고=판정). 윈드업 중 몸은 돌지만 부채는 고정.
local function performMaskDance(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local cfg = def.MaskDance or {}
	pcall(function()
		if not root.Parent then
			return
		end
		local fans = math.max(2, cfg.Fans or 3)
		local width = cfg.Width or 5
		local length = cfg.Length or 9
		local windup = cfg.Windup or 0.6
		local rgb = def.BlinkColor or { 168, 120, 235 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local mid = (st.Model and st.Model:GetAttribute("MonsterId")) or ""
		local base = root.Position
		local gy = monsterGroundY(base)
		-- ★부채 기준은 몹의 현재 facing이 아니라 **타겟 방향**이어야 한다.
		-- Blink 마무리의 60° 비틀기가 남아 있으면 몹이 최대 44° 틀어진 채 시전해
		-- 거리 4.5에서 측면 이탈이 3.1 > 허용 2.5 → 부채 3장이 전부 빗나갔다(실측 피해 0회).
		-- 1번 부채를 타겟에 정렬해야 "제자리에 있으면 맞고 틈으로 비키면 산다"는 설계가 성립한다.
		local tRoot = st.TargetRoot
		local aimV = (tRoot and tRoot.Parent) and ((tRoot.Position - base) * Vector3.new(1, 0, 1)) or nil
		if aimV and aimV.Magnitude > 0.05 then
			root.CFrame = CFrame.lookAt(base, base + aimV.Unit)
		end
		local _, baseYaw = root.CFrame:ToOrientation()
		local boxes = {}
		for i = 1, fans do
			local yaw = baseYaw + (i - 1) * (math.pi * 2 / fans)
			local dir = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
			local center = Vector3.new(base.X, gy + AI.HitBoxHeight / 2, base.Z) + dir * (length / 2)
			local cf = CFrame.lookAt(center, center + dir)
			local size = Vector3.new(width, AI.HitBoxHeight, length)
			boxes[i] = { Cf = cf, Size = size }
			showBoxTelegraph(cf, size, windup, color)
		end
		playMobSound(root, mid .. "MaskDanceWindup")
		playAttackAnim(st)
		hum.AutoRotate = false
		root.Anchored = true
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			local a = (os.clock() - t0) / windup
			root.CFrame = CFrame.new(base) * CFrame.Angles(0, baseYaw + math.rad(320 * a), 0)
			task.wait()
		end
		root.CFrame = CFrame.new(base) * CFrame.Angles(0, baseYaw, 0)
		spawnBurst(base + Vector3.new(0, 1.4, 0), color, 20, 24, 0.7)
		for _, b in ipairs(boxes) do
			spawnGroundRing(Vector3.new(b.Cf.Position.X, gy + 0.35, b.Cf.Position.Z), width * 0.5, color, 0.3)
		end
		playMobSound(root, mid .. "MaskDanceHit")
		for _, p in ipairs(Players:GetPlayers()) do
			local pc = p.Character
			local ppr = pc and pc:FindFirstChild("HumanoidRootPart")
			local ph = pc and pc:FindFirstChildOfClass("Humanoid")
			if ppr and ph and ph.Health > 0 then
				for _, b in ipairs(boxes) do
					if pointInBox(b.Cf, b.Size, ppr.Position) then
						PlayerDamageService.Apply(ph, math.floor(def.Atk * (cfg.DamageMul or 0.7) + 0.5))
						break -- 부채 겹침 지점 중복 타격 방지
					end
				end
			end
		end
	end)
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 북 점프 충격파(북 도깨비 주 패턴): 북을 딛고 크게 뛰어올랐다 착지 지점에 원형 충격파.
-- 노션 "북으로 점프를 뛰며 이동 · 도깨비가 북 위에서 점프하면 충격파 발생".
-- ★착지 지점을 도약 **전에** 전조로 깔고 뛰다(예고=판정) — 공중에 떠 있는 동안
--   원 밖으로 걸어 나가면 산다. 도약 거리는 MaxDist로 클램프해 맵 밖 착지를 막는다.
local function performDrumStomp(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local cfg = def.DrumStomp or {}
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local radius = cfg.Radius or 9
		local windup = cfg.Windup or 0.9
		local airT = cfg.AirTime or 0.75
		local rise = cfg.RiseHeight or 9
		local mid = (st.Model and st.Model:GetAttribute("MonsterId")) or ""
		local rgb = cfg.Color or { 255, 205, 130 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])

		local base = root.Position
		local toV = (tRoot.Position - base) * Vector3.new(1, 0, 1)
		local maxD = cfg.MaxDist or 16
		local landXZ = (toV.Magnitude > maxD) and (base + toV.Unit * maxD) or (base + toV)
		local gy = monsterGroundY(landXZ)
		local landPos = Vector3.new(landXZ.X, gy, landXZ.Z)
		local boxCf = CFrame.new(landPos.X, gy + AI.HitBoxHeight / 2, landPos.Z)
		local boxSize = Vector3.new(radius * 2, AI.HitBoxHeight, radius * 2)
		showBoxTelegraph(boxCf, boxSize, windup + airT, color)
		playMobSound(root, mid .. "StompWindup")
		-- 전용 클립이 있으면 그걸 쓰고(도약 길이에 맞춤), 없으면 공용 Attack 클립 폴백
		if not MonsterProcAnim.Play(st.Model, "DrumStomp") then
			playAttackAnim(st)
		end
		hum.AutoRotate = false
		root.Anchored = true

		-- ① 웅크림
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end

		-- ② 도약 아크. 루트 힙 높이는 클램프해 공중 고착을 막는다(Blink와 동일 규약).
		local hip = math.clamp(base.Y - monsterGroundY(base), 0.5, root.Size.Y)
		local startPos = base
		local endPos = Vector3.new(landPos.X, gy + hip, landPos.Z)
		local faceV = (endPos - startPos) * Vector3.new(1, 0, 1)
		local t1 = os.clock()
		while true do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			local a = math.min((os.clock() - t1) / airT, 1)
			local p = startPos:Lerp(endPos, a) + Vector3.new(0, math.sin(a * math.pi) * rise, 0)
			if faceV.Magnitude > 0.05 then
				root.CFrame = CFrame.lookAt(p, p + faceV.Unit)
			else
				root.CFrame = CFrame.new(p)
			end
			if a >= 1 then
				break
			end
			task.wait()
		end

		-- ③ 착지 충격파
		spawnGroundRing(Vector3.new(landPos.X, gy + 0.35, landPos.Z), radius, color, 0.45)
		spawnBurst(Vector3.new(landPos.X, gy + 1.0, landPos.Z), color, 22, 30, 0.8)
		playMobSound(root, mid .. "StompHit")
		for _, p in ipairs(Players:GetPlayers()) do
			local pc = p.Character
			local ppr = pc and pc:FindFirstChild("HumanoidRootPart")
			local ph = pc and pc:FindFirstChildOfClass("Humanoid")
			if ppr and ph and ph.Health > 0 and pointInBox(boxCf, boxSize, ppr.Position) then
				local damaged = PlayerDamageService.Apply(ph, math.floor(def.Atk * (cfg.DamageMul or 1.2) + 0.5))
				if damaged and cfg.Knockback then
					MonsterService.KnockbackPlayer(p, Vector3.new(landPos.X, ppr.Position.Y, landPos.Z),
						cfg.Knockback.Force or 26, cfg.Knockback.Lift or 9)
				end
			end
		end
	end)
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 장승 솟구침(신전 수호령 부 패턴): 타겟 발밑 지면에서 석상 기둥이 솟아올라 들이받는다.
-- 사장님 지시(2026-08-24): 벽 통과 유령 연출은 폐기하고 "아래에서 장승이 나와서 때리는" 패턴으로 교체.
-- 프롭은 몸체 메시(ShineGuardianPillar)를 복제해 쓴다 — 별도 에셋 없이 같은 석상이 솟는다.
-- 솟을 자리는 시전 시점 타겟 위치로 고정 — 전조(지면 링) 보고 걸어 나가면 산다.
local function performPillarRise(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local cfg = def.PillarRise or {}
	local pillar
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local radius = cfg.Radius or 6
		local windup = cfg.Windup or 0.9
		local riseT = cfg.RiseSec or 0.22
		local holdT = cfg.HoldSec or 0.6
		local scale = cfg.Scale or 0.8
		local mid = (st.Model and st.Model:GetAttribute("MonsterId")) or ""
		local rgb = cfg.Color or { 180, 200, 255 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])

		local spot = tRoot.Position
		local gy = monsterGroundY(spot)
		local boxCf = CFrame.new(spot.X, gy + AI.HitBoxHeight / 2, spot.Z)
		local boxSize = Vector3.new(radius * 2, AI.HitBoxHeight, radius * 2)
		showBoxTelegraph(boxCf, boxSize, windup, color)
		spawnGroundRing(Vector3.new(spot.X, gy + 0.3, spot.Z), radius, color, windup)
		playMobSound(root, mid .. "PillarWindup")
		if not MonsterProcAnim.Play(st.Model, "PillarRise") then
			playAttackAnim(st)
		end
		hum.AutoRotate = false
		root.Anchored = true
		local faceV = (spot - root.Position) * Vector3.new(1, 0, 1)
		if faceV.Magnitude > 0.05 then
			local here = root.Position
			root.CFrame = CFrame.lookAt(here, here + faceV.Unit)
		end

		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end

		local tpl = findModelPart(st.Model, cfg.PartName or "ShineGuardianPillar")
		if tpl then
			pillar = tpl:Clone()
			for _, c in ipairs(pillar:GetChildren()) do
				-- 장식(재질·데칼)만 남기고 조인트·어태치먼트는 때어낸다(복제본은 순수 프롭)
				if not (c:IsA("SurfaceAppearance") or c:IsA("Decal") or c:IsA("Texture")) then
					c:Destroy()
				end
			end
			pillar.Name = "GuardianPillarProp"
			pillar.Size = tpl.Size * scale
			pillar.Anchored = true
			pillar.CanCollide = false
			pillar.CanQuery = false
			pillar.CanTouch = false
			pillar.CastShadow = false
			pillar.Parent = monstersFolder
		end
		local pillarH = (pillar and pillar.Size.Y) or 12
		local topY = gy + pillarH / 2
		local botY = gy - pillarH / 2 - 1
		if pillar then
			pillar.CFrame = CFrame.new(spot.X, botY, spot.Z)
		end
		spawnBurst(Vector3.new(spot.X, gy + 0.8, spot.Z), color, 20, 26, 0.75)
		spawnGroundRing(Vector3.new(spot.X, gy + 0.35, spot.Z), radius, color, 0.4)
		playMobSound(root, mid .. "PillarHit")

		-- ① 솟구침
		local t1 = os.clock()
		while true do
			if not root.Parent then
				break
			end
			local a = math.min((os.clock() - t1) / riseT, 1)
			if pillar and pillar.Parent then
				pillar.CFrame = CFrame.new(spot.X, botY + (topY - botY) * a, spot.Z)
			end
			if a >= 1 then
				break
			end
			task.wait()
		end

		-- ② 판정(전조 박스 그대로) + 위로 띄우는 낛백
		for _, p in ipairs(Players:GetPlayers()) do
			local pc = p.Character
			local ppr = pc and pc:FindFirstChild("HumanoidRootPart")
			local ph = pc and pc:FindFirstChildOfClass("Humanoid")
			if ppr and ph and ph.Health > 0 and pointInBox(boxCf, boxSize, ppr.Position) then
				local damaged = PlayerDamageService.Apply(ph, math.floor(def.Atk * (cfg.DamageMul or 1) + 0.5))
				if damaged and cfg.Knockback then
					MonsterService.KnockbackPlayer(p, Vector3.new(spot.X, ppr.Position.Y, spot.Z),
						cfg.Knockback.Force or 14, cfg.Knockback.Lift or 22)
				end
			end
		end

		-- ③ 유지 후 다시 가라앉으며 소멸
		local t2 = os.clock()
		while os.clock() - t2 < holdT do
			if not root.Parent then
				break
			end
			task.wait()
		end
		if pillar and pillar.Parent then
			pcall(function()
				TweenService:Create(pillar, TweenInfo.new(0.35, Enum.EasingStyle.Quad), {
					CFrame = CFrame.new(spot.X, botY, spot.Z),
					Transparency = 1,
				}):Play()
			end)
			Debris:AddItem(pillar, 0.5)
			pillar = nil
		end
	end)
	if pillar and pillar.Parent then
		pillar:Destroy() -- 조기 중단 시 프롭 잔류 방지
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 흙덩이 투척: 중거리 견제 — 발사 결정 시점 타겟 지점 고정 예고(회피 기회)
-- → 포물선 투사체 → 착탄 광역. 판정은 예고 지점 박스(투사체 접촉 아님 — 위치 이탈 회피 설계).
local function performMudThrow(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local heldPropName = def.ThrowHeldPropName or (def.AttackPropHidden and def.AttackPropName)
	if heldPropName then
		setNamedPropVisible(st, heldPropName, true)
	end
	-- SoilMob 리그 조인트(RightArm/Torso) 원C0 캡처 — 전용 던지기 모션
	local armJoint = findJoint(st.Model, "RightArm") or findJoint(st.Model, "Right Arm")
	local torsoJoint = findJoint(st.Model, "Torso")
	local armC0 = armJoint and armJoint.C0
	local torsoC0 = torsoJoint and torsoJoint.C0
	pcall(function()
		if not (tRoot and tRoot.Parent) then
			return
		end
		local windup = def.ThrowWindup or 0.8
		local relT = 0.12
		local flightT = def.ThrowFlightSec or 0.45
		local radius = def.ThrowRadius or 5
		local targetPos = tRoot.Position
		local gy = monsterGroundY(targetPos)
		local landPos = Vector3.new(targetPos.X, gy, targetPos.Z)
		local boxCf = CFrame.new(landPos.X, gy + AI.HitBoxHeight / 2, landPos.Z)
		local boxSize = Vector3.new(radius * 2, AI.HitBoxHeight, radius * 2)
		local teleTbl = def.ThrowTelegraphColor
		local teleColor = (type(teleTbl) == "table" and #teleTbl >= 3)
			and Color3.fromRGB(teleTbl[1], teleTbl[2], teleTbl[3]) or Color3.fromRGB(150, 95, 45)
		showBoxTelegraph(boxCf, boxSize, windup + relT + flightT, teleColor)
		local throwMid = st.Model and st.Model:GetAttribute("MonsterId") or ""
		playMobSound(root, throwMid .. "ThrowWindup")
		-- [2026-08-24] 투척은 원래 공격 애니를 안 돌렸다 — 발사가 주 패턴인 몹(마법사)은 주문 동작이 필요.
		-- 클립 미등록 몹은 no-op이라 기존 몹 동작은 불변.
		playAttackAnim(st)
		local base = root.Position
		local faceV = (landPos - base) * Vector3.new(1, 0, 1)
		local faceDir = faceV.Magnitude > 0.05 and faceV.Unit or root.CFrame.LookVector
		hum.AutoRotate = false
		root.Anchored = true
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			local a = (os.clock() - t0) / windup
			root.CFrame = CFrame.lookAt(base, base + faceDir) * CFrame.Angles(math.rad(16 * a), 0, 0)
			if armJoint then
				armJoint.C0 = armC0 * CFrame.Angles(math.rad(-150 * a), 0, math.rad(14 * a))
			end
			if torsoJoint then
				torsoJoint.C0 = CFrame.Angles(0, math.rad(-24 * a), 0) * torsoC0
			end
			task.wait()
		end
		local tr = os.clock()
		while os.clock() - tr < relT do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			local a = math.min((os.clock() - tr) / relT, 1)
			root.CFrame = CFrame.lookAt(base, base + faceDir) * CFrame.Angles(math.rad(16 - 26 * a), 0, 0)
			if armJoint then
				armJoint.C0 = armC0 * CFrame.Angles(math.rad(-150 + 215 * a), 0, math.rad(14 * (1 - a)))
			end
			if torsoJoint then
				torsoJoint.C0 = CFrame.Angles(0, math.rad(-24 + 34 * a), 0) * torsoC0
			end
			task.wait()
		end
		local bsize = 2.6 * (def.ModelScale or 1)
		-- 투사체 비주얼 def 주도: ThrowVisual(Assets.Drops 메시명) 지정 몹은 제 재질을 던짐 — 미지정은 진흙 볼 폴백
		-- [2026-08-20 Z1/Z2 이식] 투사체 크기 상한: bsize는 ModelScale 비례라 작은 몹(박쥐 2.948)은
		-- 제 몸보다 큰 구슬을 던지게 된다 — 실측 반높이(HalfHeight)로 억누른다(속성 없으면 무동작).
		local halfH = st.Model and st.Model:GetAttribute("HalfHeight")
		if type(halfH) == "number" and halfH > 0 then
			bsize = math.clamp(bsize, 2.0, halfH * 1.1)
		end
		local tintTbl = def.ThrowColor
		local tint = (type(tintTbl) == "table" and #tintTbl >= 3) and Color3.fromRGB(tintTbl[1], tintTbl[2], tintTbl[3]) or nil
		local isWave = def.ThrowStyle == "Wave"
		-- 투사체 비주얼 def 주도:
		--   ThrowStyle="Flame" → 네온 화염구(도깨비불 계열 — 색은 ThrowColor)
		--   ThrowStyle="Wave"  → 진행방향 음파 원판(박쥐 초음파·북소리 파동) — 텔블링 없이 맥동 + 잔향 링
		--   ThrowStyle="Liquid" → 반투명 액체 방울(술독 정령 술 뿜기)
		--   ThrowVisual(Assets.Drops 메시명) → 제 재질을 던짐 · 전부 미지정 → 진흙 볼 폴백
		local ball
		local assets = ReplicatedStorage:FindFirstChild("Assets")
		local dropsFolder = assets and assets:FindFirstChild("Drops")
		local throwTemplate = def.ThrowVisual and dropsFolder and dropsFolder:FindFirstChild(def.ThrowVisual)
		if not (throwTemplate and throwTemplate:IsA("BasePart")) and def.ThrowVisual then
			throwTemplate = findModelPart(st.Model, def.ThrowVisual) -- 손에 든 방망이/북채 메시 재사용
		end
		if def.ThrowStyle == "Flame" then
			local flame = tint or Color3.fromRGB(90, 170, 255)
			ball = Instance.new("Part")
			ball.Name = "FlameThrowBall"
			ball.Shape = Enum.PartType.Ball
			ball.Size = Vector3.new(bsize * 0.8, bsize * 0.8, bsize * 0.8)
			ball.Color = flame
			ball.Material = Enum.Material.Neon
			local light = Instance.new("PointLight")
			light.Color = flame
			light.Range = 14
			light.Brightness = 3
			light.Parent = ball
			-- 불꽃 파티클은 Assets.Effect.Fire 재사용(설정 유지 · 색만 ThrowColor로). 발사 순간 Emit 버스트 병행 = 모바일 누락 방지
			local effects = assets and assets:FindFirstChild("Effect")
			local fireTpl = effects and effects:FindFirstChild("Fire")
			if fireTpl and fireTpl:IsA("ParticleEmitter") then
				local fx = fireTpl:Clone()
				-- 원본 Fire는 연기형 스프라이트라 파랑을 입혀도 흰 수증기처럼 보인다 — 툴 화염 스프라이트로 교체.
				fx.Texture = "rbxassetid://13764992917"
				fx.Color = ColorSequence.new(flame:Lerp(Color3.new(1, 1, 1), 0.35), flame:Lerp(Color3.new(0, 0, 0), 0.25))
				fx.LightEmission = 0.6
				fx.Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, bsize * 0.55),
					NumberSequenceKeypoint.new(0.7, bsize * 0.35),
					NumberSequenceKeypoint.new(1, 0),
				})
				fx.Parent = ball
				fx:Emit(14)
			end
		elseif def.ThrowStyle == "Wave" then
			local wave = tint or Color3.fromRGB(180, 225, 255)
			ball = Instance.new("Part")
			ball.Name = "SonicThrowWave"
			ball.Size = Vector3.new(0.2, 0.2, 0.2) -- 이동 기준점; 실제 보이는 형상은 아래 도넛 링 1~3개
			ball.Color = wave
			ball.Material = Enum.Material.Neon
			ball.Transparency = 1
			local light = Instance.new("PointLight")
			light.Color = wave
			light.Range = 12
			light.Brightness = 1.6
			light.Parent = ball
		elseif def.ThrowStyle == "Liquid" then
			local liq = tint or Color3.fromRGB(120, 210, 190)
			ball = Instance.new("Part")
			ball.Name = "LiquidThrowBall"
			ball.Shape = Enum.PartType.Ball
			ball.Size = Vector3.new(bsize * 0.85, bsize * 0.85, bsize * 0.85)
			ball.Color = liq
			ball.Material = Enum.Material.Glass
			ball.Transparency = 0.25
			ball.Reflectance = 0.15
		elseif throwTemplate and throwTemplate:IsA("BasePart") then
			ball = throwTemplate:Clone()
			ball.Name = "MobThrowProj"
			local ms = math.max(ball.Size.X, ball.Size.Y, ball.Size.Z)
			if ms > 0.01 then
				ball.Size = ball.Size * (bsize / ms)
			end
			ball.Transparency = 0
		else
			ball = Instance.new("Part")
			ball.Name = "MudThrowBall"
			ball.Shape = Enum.PartType.Ball
			ball.Size = Vector3.new(bsize, bsize, bsize)
			ball.Color = Color3.fromRGB(110, 76, 46)
			ball.Material = Enum.Material.Mud
		end
		ball.Anchored = true
		ball.CanCollide = false
		ball.CanQuery = false
		ball.CanTouch = false
		local startPos = base + Vector3.new(0, 2, 0) + faceDir * 1.5
		ball.CFrame = CFrame.new(startPos)
		-- 음파는 도넛 형상 자체가 잔상을 만들므로 리본 트레일을 생략한다.
		if not isWave then
			local trailTop = Instance.new("Attachment")
			trailTop.Position = Vector3.new(0, bsize * 0.35, 0)
			trailTop.Parent = ball
			local trailBot = Instance.new("Attachment")
			trailBot.Position = Vector3.new(0, -bsize * 0.35, 0)
			trailBot.Parent = ball
			local trail = Instance.new("Trail")
			trail.Attachment0 = trailTop
			trail.Attachment1 = trailBot
			trail.Color = tint and ColorSequence.new(tint, tint:Lerp(Color3.new(0, 0, 0), 0.4))
				or ColorSequence.new(Color3.fromRGB(158, 110, 62), Color3.fromRGB(92, 63, 38))
			trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
			trail.Lifetime = 0.35
			trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.3) })
			trail.LightEmission = (def.ThrowStyle == "Flame") and 1 or 0.15
			trail.Parent = ball
		end
		ball.Parent = monstersFolder
		if heldPropName and def.ThrowHideHeldProp then
			setNamedPropVisible(st, heldPropName, false)
		end
		Debris:AddItem(ball, flightT + 1)
		-- 발사 순간 손끝 흙 튐
		spawnBurst(startPos, tint or Color3.fromRGB(140, 98, 58), 10, 12, 0.55)
		local landCenter = landPos + Vector3.new(0, bsize * 0.35, 0)
		local arc = def.ThrowArcHeight or 7
		-- 음파: 중앙이 빈 클래식 링 메시를 1~3개 겹쳐 발사한다.
		-- 박쥐는 WaveRingCount=3이며 각 링의 위상·크기를 달리해 작아졌다 커지는 파동으로 보인다.
		local waveDia = bsize * 1.5
		local waveDir = (landCenter - startPos)
		waveDir = waveDir.Magnitude > 0.01 and waveDir.Unit or faceDir
		local waveRings = {}
		if isWave then
			local count = math.clamp(math.floor(def.WaveRingCount or 1), 1, 3)
			for i = 1, count do
				local ringPart, ringMesh = makeDonutRing("SonicWaveRing" .. i, tint or Color3.fromRGB(180, 225, 255), ball, 0.16 + (i - 1) * 0.07)
				-- [2026-08-27 사장님] "도넋 하나만 나간다" — 실제로는 3개였으나 간격이 0.42스터드뿐이라
				-- 지름 8.3/10.3/12.4의 동심원이 겹대서 두꺼운 링 하나로 보였다.
				-- → 진행 방향으로 2.6스터드씩 띄워 "줄지어 나가는" 형태로 만든다.
				-- 앞선 링이 크고 뒤로 갈수록 작다(퍼져 나가는 파동 느낌).
				-- Phase를 1/3씩 어깋게 해 세 링이 동시에 같은 크기가 되지 않게 한다
				-- (어느 순간에도 하나는 작고 하나는 커져 있음 = "작아졌다 커지는" 움직임).
				waveRings[i] = {
					Part = ringPart,
					Mesh = ringMesh,
					BaseScale = 1.00 - (i - 1) * 0.14,
					Phase = (i - 1) * (math.pi * 2 / 3),
					Offset = (i - 1) * 2.6,
				}
			end
		end
		local t1 = os.clock()
		while true do
			if not ball.Parent then
				break
			end
			if st.KbInterrupt then
				return
			end
			local a = math.min((os.clock() - t1) / flightT, 1)
			local fpos = startPos:Lerp(landCenter, a) + Vector3.new(0, math.sin(a * math.pi) * arc, 0)
			if isWave then
				ball.CFrame = CFrame.lookAt(fpos, fpos + waveDir)
				for _, ring in ipairs(waveRings) do
					-- 맥동 폭 0.20 → 0.35: 수축·팽창이 눈에 보이는 크기까지 키운다.
					local pulse = 1 + 0.35 * math.sin(a * math.pi * 4 - ring.Phase)
					local diameter = waveDia * ring.BaseScale * pulse
					local ringPos = fpos - waveDir * ring.Offset
					placeDonutRing(ring.Part, ring.Mesh, ringPos, waveDir, diameter, math.max(diameter * 0.14, 0.55))
				end
			else
				ball.CFrame = CFrame.new(fpos) * CFrame.Angles(a * 9, a * 5, 0)
			end
			if armJoint then
				armJoint.C0 = armC0 * CFrame.Angles(math.rad(65 * (1 - a)), 0, 0)
			end
			if torsoJoint then
				torsoJoint.C0 = CFrame.Angles(0, math.rad(10 * (1 - a)), 0) * torsoC0
			end
			if a >= 1 then
				break
			end
			task.wait()
		end
		ball:Destroy()
		-- 착탄: 흙 폭발 버스트 + 지면 확장 링(예고 반경과 동일)
		spawnBurst(landCenter, tint or Color3.fromRGB(120, 84, 50), 22, 20, 0.8)
		spawnGroundRing(Vector3.new(landPos.X, gy + 0.35, landPos.Z), radius, tint or Color3.fromRGB(150, 100, 55), 0.4)
		if root.Parent then
			root.CFrame = CFrame.lookAt(base, base + faceDir)
		end
		playMobSound(root, throwMid .. "ThrowHit")
		if def.ThrowImpactDamage ~= false then
			for _, p in ipairs(Players:GetPlayers()) do
				local c = p.Character
				local pr = c and c:FindFirstChild("HumanoidRootPart")
				local ph = c and c:FindFirstChildOfClass("Humanoid")
				if pr and ph and ph.Health > 0 and pointInBox(boxCf, boxSize, pr.Position) then
					PlayerDamageService.Apply(ph, math.floor(def.Atk * (def.ThrowDamageMul or 1) + 0.5))
				end
			end
		end
		spawnPoisonZone(st, landPos) -- 원거리 살포: 착탄 지점
	end)
	if armJoint and armJoint.Parent then
		armJoint.C0 = armC0
	end
	if torsoJoint and torsoJoint.Parent then
		torsoJoint.C0 = torsoC0
	end
	if heldPropName then
		local showAfter = not (def.AttackPropHidden and heldPropName == def.AttackPropName)
		setNamedPropVisible(st, heldPropName, showAfter)
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 아기 도깨비 울음 감속. 다른 이동 효과가 값을 바꾸면 정확히 자신이 설정한 값일 때만 복원한다.
local crySlowState = setmetatable({}, { __mode = "k" })

local function applyCrySlow(player, hum, ratio, sec)
	if not (hum and hum.Parent and hum.Health > 0) then
		return
	end
	local st = crySlowState[hum]
	if not st then
		st = { Orig = hum.WalkSpeed, Token = 0 }
		crySlowState[hum] = st
	end
	st.Token += 1
	local token = st.Token
	local applied = math.min(hum.WalkSpeed, math.max(4, st.Orig * ratio))
	hum.WalkSpeed = applied
	st.Applied = hum.WalkSpeed
	Net.Event("PlayerCc"):FireClient(player, { kind = "slow", sec = sec })
	task.delay(sec, function()
		local cur = crySlowState[hum]
		if cur ~= st or cur.Token ~= token then
			return
		end
		crySlowState[hum] = nil
		if hum.Parent and hum.Health > 0 and hum.WalkSpeed == cur.Applied then
			hum.WalkSpeed = cur.Orig
		end
	end)
end

local function performCry(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local cfg = def.Cry
	pcall(function()
		if not (cfg and root.Parent and hum.Health > 0) then
			return
		end
		local radius = cfg.Radius or 10
		local windup = cfg.Windup or 0.7
		local gy = monsterGroundY(root.Position)
		local center = Vector3.new(root.Position.X, gy + 0.16, root.Position.Z)
		local color = cfg.Color or Color3.fromRGB(190, 225, 255)
		hum:MoveTo(root.Position)
		hum.AutoRotate = false
		root.Anchored = true
		MonsterProcAnim.Play(st.Model, "Cry")
		playMobSound(root, (st.Model:GetAttribute("MonsterId") or "") .. "Cry")
		-- 윈드업과 함께 첫 도넛이 최대 반경에 닿고, 판정 순간 두 겹의 잔향이 뒤따른다.
		spawnDonutRing(center, radius, color, windup, 0.08)
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end
		spawnBurst(center + Vector3.new(0, 1.4, 0), color, 16, 10, 0.38)
		task.delay(0.05, function()
			spawnDonutRing(center, radius * 0.82, color, 0.38, 0.12)
		end)
		task.delay(0.13, function()
			spawnDonutRing(center, radius * 0.64, color, 0.34, 0.14)
		end)
		local dmg = math.floor(def.Atk * (cfg.DamageMul or 0.25) + 0.5)
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local pr = character and character:FindFirstChild("HumanoidRootPart")
			local ph = character and character:FindFirstChildOfClass("Humanoid")
			if pr and ph and ph.Health > 0
				and Vector3.new(pr.Position.X - center.X, 0, pr.Position.Z - center.Z).Magnitude <= radius then
				local damaged = PlayerDamageService.Apply(ph, dmg)
				if damaged then
					applyCrySlow(player, ph, cfg.SlowRatio or 0.55, cfg.SlowSec or 1.8)
				end
			end
		end
	end)
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 술 뿜기(술독 정령 주 패턴): 항아리를 타겟 쪽으로 기울여 주둥이(Alcohol_in/out)에서 부채꼴로 술을 뿜는다.
-- [2026-09-07] 노션 수치 명세 v1.3 "술 뿜기 — 부채꼴 + 슬로우 30%×2s". 종전 Throw"Liquid"(포물선 투사체 + 착탄 웅덩이)는
-- '던지기'라 "뿜는다"는 외형과 어긋나 교체. 투사체·웅덩이 없음 — 전조 부채꼴 = 판정 부채꼴(예고=판정).
-- ★사거리·쿨·윈드업은 투척 공용 필드(ThrowRange/ThrowMinRange/ThrowCooldown/ThrowWindup)를 그대로 읽는다:
--   RangedPriority 후퇴·throwReady·밀착 고착 해제가 전부 그 필드로 돌아가므로 디스패치는 def.Spray 유무로만 갈린다.
-- 판정 = 수평 각도(cos) + 거리 + 몹 지면 기준 높이 대역. 감속은 applyCrySlow 재사용(자기가 놓은 값일 때만 복원).
local function performSpray(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local cfg = def.Spray or {}
	local propName = def.AttackPropHidden and def.AttackPropName
	if propName then
		setNamedPropVisible(st, propName, true)
	end
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local windup = def.ThrowWindup or cfg.Windup or 0.9
		local sprayT = cfg.Duration or 0.5
		local length = cfg.Length or def.ThrowRange or 14
		local angle = math.rad(math.clamp(cfg.AngleDeg or 70, 20, 180))
		local half = angle / 2
		local rgb = cfg.Color or def.ThrowColor or { 240, 228, 200 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local mid = (st.Model and st.Model:GetAttribute("MonsterId")) or ""
		local base = root.Position
		local gy = monsterGroundY(base)
		local aimV = (tRoot.Position - base) * Vector3.new(1, 0, 1)
		local lookFlat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		local aimDir = aimV.Magnitude > 0.05 and aimV.Unit or (lookFlat.Magnitude > 0.05 and lookFlat.Unit or Vector3.new(0, 0, -1))
		hum.AutoRotate = false
		root.Anchored = true
		root.CFrame = CFrame.lookAt(base, base + aimDir)
		-- 전조: 부채꼴을 쐐기 박스 N개로 근사(각 박스 = 그 각도 구간의 중심선 방향, 폭 = 구간 호 폭의 3/4).
		local segs = math.clamp(math.floor(cfg.TelegraphSegments or 3), 1, 6)
		local segAngle = angle / segs
		local segWidth = math.max(2, length * math.tan(segAngle / 2) * 2 * 0.75)
		for i = 1, segs do
			local a = -half + segAngle * (i - 0.5)
			local dir = CFrame.fromAxisAngle(Vector3.yAxis, a):VectorToWorldSpace(aimDir)
			local center = Vector3.new(base.X, gy + AI.HitBoxHeight / 2, base.Z) + dir * (length / 2)
			showBoxTelegraph(CFrame.lookAt(center, center + dir), Vector3.new(segWidth, AI.HitBoxHeight, length), windup, color)
		end
		playMobSound(root, mid .. "SprayWindup")
		-- 전용 클립(Spray: 젖힘 → 기울여 뿜기)이 있으면 그걸, 없으면 공용 Attack 폴백
		if not MonsterProcAnim.Play(st.Model, "Spray") then
			playAttackAnim(st)
		end
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end
		-- 뿜기 연출: 주둥이 위치에 파티클 원뿔(SpreadAngle = 부채 반각). Enabled 대신 Emit 버스트(모바일 누락 방지 규약).
		local mouth = base + Vector3.new(0, 2.2, 0) + aimDir * 1.6
		local emitterPart = Instance.new("Part")
		emitterPart.Name = "SprayEmitter"
		emitterPart.Anchored = true
		emitterPart.CanCollide = false
		emitterPart.CanQuery = false
		emitterPart.CanTouch = false
		emitterPart.Transparency = 1
		emitterPart.Size = Vector3.new(0.2, 0.2, 0.2)
		emitterPart.CFrame = CFrame.lookAt(mouth, mouth + aimDir)
		local pe = Instance.new("ParticleEmitter")
		pe.EmissionDirection = Enum.NormalId.Front
		-- 실측(9/7): 막걸리색 작은 입자는 밝은 나무 바닥에 묻혀 안 보였다 — 앞반은 진한 술빛(얼베볃)·마무리는 흘 거품, 입자 1.6까지.
		local deep = color:Lerp(Color3.fromRGB(196, 150, 70), 0.45)
		pe.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, deep), ColorSequenceKeypoint.new(0.55, color), ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)) })
		pe.LightEmission = 0.15
		pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.0), NumberSequenceKeypoint.new(0.5, 1.6), NumberSequenceKeypoint.new(1, 0.4) })
		pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.6, 0.25), NumberSequenceKeypoint.new(1, 1) })
		local travel = math.max(0.45, sprayT + 0.35)
		pe.Lifetime = NumberRange.new(travel * 0.8, travel)
		pe.Speed = NumberRange.new(length / travel * 0.85, length / travel * 1.1)
		pe.SpreadAngle = Vector2.new(math.deg(half) * 0.9, 9)
		pe.Acceleration = Vector3.new(0, -10, 0)
		pe.Rate = 0
		pe.Parent = emitterPart
		emitterPart.Parent = monstersFolder
		Debris:AddItem(emitterPart, sprayT + travel + 0.5)
		spawnBurst(mouth, color, 10, 8, 0.5)
		playMobSound(root, mid .. "SprayHit")
		-- 판정: 부채꼴(수평 각도 + 거리) 안 + 몹 지면 기준 히트박스 높이 대역 안. 전조 종료 순간 1회(MaskDance와 동일 규약).
		local cosHalf = math.cos(half)
		local dmg = math.floor(def.Atk * (cfg.DamageMul or 1) + 0.5)
		for _, p in ipairs(Players:GetPlayers()) do
			local c = p.Character
			local pr = c and c:FindFirstChild("HumanoidRootPart")
			local ph = c and c:FindFirstChildOfClass("Humanoid")
			if pr and ph and ph.Health > 0 then
				local v = (pr.Position - base) * Vector3.new(1, 0, 1)
				local d = v.Magnitude
				local dy = pr.Position.Y - gy
				local inCone = d <= length and (d < 1.5 or v.Unit:Dot(aimDir) >= cosHalf)
				if inCone and dy >= -2 and dy <= AI.HitBoxHeight + 2 then
					local damaged = PlayerDamageService.Apply(ph, dmg)
					if damaged and cfg.Slow then
						applyCrySlow(p, ph, cfg.Slow, cfg.SlowSec or 2)
					end
				end
			end
		end
		-- 뿜는 동안 버스트를 4회로 나눠 쏘고(연속 분사 느낌), 끝에 바닥 튐 링
		local t1 = os.clock()
		local emitted = 0
		while os.clock() - t1 < sprayT do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			local due = math.floor((os.clock() - t1) / sprayT * 4 + 1)
			while emitted < due and emitted < 4 do
				pe:Emit(28)
				emitted += 1
			end
			task.wait()
		end
		spawnGroundRing(Vector3.new(base.X, gy + 0.35, base.Z) + aimDir * (length * 0.6), segWidth * 0.6, color, 0.55)
	end)
	if propName then
		setNamedPropVisible(st, propName, false)
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 가면 부매랑(춤추는 도깨비 주 패턴): 쓴 거대 탈(Head)을 던져 직선으로 날렸다 되돌려 받는다.
-- [2026-09-07] 노션 수치 명세 v1.3 "가면 던지기 — 원거리" + 가드레일 #11(일반몹 순간이동 금지) → 종전 Blink 폐기.
-- 전조 = 직선 박스(폭 Width·길이 Range) = 뱄행 경로. 날아가는 동안 본체 Head는 투명(가면을 벗어 던진 얼굴).
-- 판정은 매 프레임 가면 중심과 플레이어 수평 거리 — 왕복 중 플레이어 1명당 1회만(서 있어도 2배 안 맞음).
-- 사거리·쿨·최소거리는 투척 공용 필드(ThrowRange/ThrowMinRange/ThrowCooldown)로 돈다(Spray와 같은 규약).
-- ★본체 Head 투명도 복원은 pcall 밖(조기 return 시 얼굴 없는 몹 고착 방지 — Blink 투명 고착 선례).
local function performMaskThrow(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local cfg = def.MaskThrow or {}
	local model = st.Model
	local head = model and model:FindFirstChild(cfg.PartName or "Head")
	local headTransp = head and head.Transparency
	local mask
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local windup = cfg.Windup or def.ThrowWindup or 0.5
		local range = cfg.Range or def.ThrowRange or 16
		local width = cfg.Width or 3.5
		local outT = cfg.OutSec or 0.45
		local backT = cfg.BackSec or 0.5
		local rgb = cfg.Color or { 168, 120, 235 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local mid = (model and model:GetAttribute("MonsterId")) or ""
		local base = root.Position
		local gy = monsterGroundY(base)
		local aimV = (tRoot.Position - base) * Vector3.new(1, 0, 1)
		local lookFlat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		local dir = aimV.Magnitude > 0.05 and aimV.Unit or (lookFlat.Magnitude > 0.05 and lookFlat.Unit or Vector3.new(0, 0, -1))
		hum.AutoRotate = false
		root.Anchored = true
		root.CFrame = CFrame.lookAt(base, base + dir)
		-- 전조: 직선 경로 박스(예고 = 판정 경로)
		local center = Vector3.new(base.X, gy + AI.HitBoxHeight / 2, base.Z) + dir * (range / 2)
		showBoxTelegraph(CFrame.lookAt(center, center + dir), Vector3.new(width, AI.HitBoxHeight, range), windup, color)
		playMobSound(root, mid .. "MaskThrowWindup")
		if not MonsterProcAnim.Play(model, "MaskThrow") then
			playAttackAnim(st)
		end
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end
		-- 가면 투사체 = 본체 Head 복제(별도 에셋 불필요 — 장승 PillarRise와 같은 수법). 본체 Head는 뱄행 동안 투명.
		local startPos = (head and head.Position) or (base + Vector3.new(0, 2, 0))
		if head then
			mask = head:Clone()
			for _, c in ipairs(mask:GetChildren()) do
				if not (c:IsA("SurfaceAppearance") or c:IsA("Decal") or c:IsA("Texture")) then
					c:Destroy()
				end
			end
			head.Transparency = 1
		else
			mask = Instance.new("Part")
			mask.Shape = Enum.PartType.Cylinder
			mask.Size = Vector3.new(0.4, 2.4, 2.4)
			mask.Color = color
		end
		mask.Name = "MaskBoomerang"
		mask.Anchored = true
		mask.CanCollide = false
		mask.CanQuery = false
		mask.CanTouch = false
		mask.Transparency = 0
		mask.CFrame = CFrame.new(startPos)
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 1.0, 0)
		a0.Parent = mask
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -1.0, 0)
		a1.Parent = mask
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Color = ColorSequence.new(color, color:Lerp(Color3.new(1, 1, 1), 0.6))
		trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		trail.Lifetime = 0.3
		trail.LightEmission = 0.5
		trail.Parent = mask
		mask.Parent = monstersFolder
		Debris:AddItem(mask, outT + backT + 1.5)
		spawnBurst(startPos, color, 10, 12, 0.5)
		playMobSound(root, mid .. "MaskThrowHit")
		local farPos = startPos + dir * range
		local hit = {}
		local dmg = math.floor(def.Atk * (cfg.DamageMul or 0.7) + 0.5)
		local function judge(pos)
			for _, p in ipairs(Players:GetPlayers()) do
				local c = p.Character
				local pr = c and c:FindFirstChild("HumanoidRootPart")
				local ph = c and c:FindFirstChildOfClass("Humanoid")
				if pr and ph and ph.Health > 0 and not hit[p] then
					local d = ((pr.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
					if d <= width / 2 + 1.6 and math.abs(pr.Position.Y - pos.Y) <= 4.5 then
						hit[p] = true
						PlayerDamageService.Apply(ph, dmg)
					end
				end
			end
		end
		-- ① 나감: 직선 + 살짝 떠오르는 아크, 가면은 수직축 고속 회전(부매랑)
		local t1 = os.clock()
		while true do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			local a = math.min((os.clock() - t1) / outT, 1)
			local pos = startPos:Lerp(farPos, a) + Vector3.new(0, math.sin(a * math.pi) * 1.2, 0)
			mask.CFrame = CFrame.lookAt(pos, pos + dir) * CFrame.Angles(0, a * math.pi * 6, 0)
			judge(pos)
			if a >= 1 then
				break
			end
			task.wait()
		end
		spawnGroundRing(Vector3.new(farPos.X, gy + 0.35, farPos.Z), width * 0.8, color, 0.3)
		-- ② 돌아옴: 본체 Head 자리로 복귀(본체는 앵커 상태라 자리 고정)
		local t2 = os.clock()
		while true do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			local a = math.min((os.clock() - t2) / backT, 1)
			local endPos = (head and head.Position) or startPos
			local pos = farPos:Lerp(endPos, a) + Vector3.new(0, math.sin(a * math.pi) * 1.2, 0)
			mask.CFrame = CFrame.lookAt(pos, pos - dir) * CFrame.Angles(0, a * math.pi * 6, 0)
			judge(pos)
			if a >= 1 then
				break
			end
			task.wait()
		end
		spawnBurst((head and head.Position) or startPos, color, 8, 10, 0.45)
	end)
	if mask and mask.Parent then
		mask:Destroy()
	end
	if head and head.Parent and headTransp then
		head.Transparency = headTransp -- pcall 밖 복원(조기 return 시 얼굴 없는 몹 방지)
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 탈춤 발구름 충격파(춤추는 도깨비 주 패턴): 제자리에서 발을 굴러 보랏받 링이 바닥을 타고 밖으로 퍼진다.
-- [2026-09-07 2차] 가면 부매랑(뱄리가 날아가는 연출)이 어색하다는 사장님 판단 → 본체는 그대로 두고 바닥 링으로 교체.
-- 판정 = 확산 중인 링 띠(BandWidth)가 플레이어를 지나가는 순간 1회. 바닥에서 JumpClear 이상 떠 있으면 링이 발밑을 지나간다(점프 회피).
-- 사거리·쿨·최소거리는 투척 공용 필드(ThrowRange/ThrowMinRange/ThrowCooldown/ThrowWindup)로 돈다(Spray·MaskThrow와 같은 규약).
local function performStompWave(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	-- [2026-09-07] FlameRing(도깨비불 마법사 부 패턴 · 밀착 청염 링)도 이 함수를 공유한다 — 확산 링 판정이 똑같다.
	local cfg = def.StompWave or def.FlameRing or {}
	local model = st.Model
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local windup = cfg.Windup or def.ThrowWindup or 0.7
		local radius = cfg.Radius or def.ThrowRange or 14
		local expandT = cfg.ExpandTime or 0.6
		local band = cfg.BandWidth or 3.5
		local jumpClear = cfg.JumpClear or 5
		local rgb = cfg.Color or { 168, 120, 235 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local mid = (model and model:GetAttribute("MonsterId")) or ""
		local base = root.Position
		local gy = monsterGroundY(base)
		local center = Vector3.new(base.X, gy + 0.16, base.Z)
		local aimV = (tRoot.Position - base) * Vector3.new(1, 0, 1)
		if aimV.Magnitude > 0.05 then
			root.CFrame = CFrame.lookAt(base, base + aimV.Unit)
		end
		hum.AutoRotate = false
		root.Anchored = true
		-- 전조: 바닥 원(최대 반경 = 링이 닿는 거리) + 윈드업 동안 채워지는 도넛 프리뷰(Cry와 같은 수법)
		-- ★사각 박스 전조(showBoxTelegraph 반경×2)는 금지 — 28×28 분홍판이 화벙을 뒤덮었다(실측). 원형 패턴은 도넛 프리뷰만.
		spawnDonutRing(center, radius, color, windup, 0.08)
		task.delay(windup * 0.5, function()
			if root.Parent then
				spawnDonutRing(center, radius, color, windup * 0.5, 0.08)
			end
		end)
		playMobSound(root, mid .. "StompWaveWindup")
		if not MonsterProcAnim.Play(model, cfg.AnimKey or "StompWave") then
			playAttackAnim(st)
		end
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end
		-- 발구름: 버스트 + 실제 충격파 링(확산 시간 = 판정 시간) + 잔향 링 한 겜
		-- [2026-09-07] Waves(기본 1)·WaveGap: 북 도깨비 "리듬 3연 충격파" — 장단에 맞첰 링을 N번 연달아 퍼뜨린다. 링번마다 피해 1회(점프로 개별 회피).
		local waves = math.clamp(math.floor(cfg.Waves or 1), 1, 5)
		local gap = cfg.WaveGap or 0.5
		local dmg = math.floor(def.Atk * (cfg.DamageMul or 0.7) + 0.5)
		for w = 1, waves do
			if w > 1 then
				local tg = os.clock()
				while os.clock() - tg < gap do
					if hum.Health <= 0 or not root.Parent then
						return
					end
					task.wait()
				end
			end
		spawnBurst(base + Vector3.new(0, 0.6, 0), color, 18, 14, 0.55)
		spawnDonutRing(center, radius, color, expandT, 0.04)
		task.delay(0.08, function()
			spawnDonutRing(center, radius * 0.9, color, expandT * 0.95, 0.04)
		end)
		playMobSound(root, mid .. "StompWaveHit")
		local hit = {}
		local t1 = os.clock()
		local prevR = 0
		while true do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			local a = math.min((os.clock() - t1) / expandT, 1)
			local r = radius * a
			-- 프레임 간 링이 건너받 구간 [prevR, r] + 띠 절반 — 빠른 확산에서 플레이어를 건너뛰지 않게 구간으로 판정
			local lo, hi = prevR - band / 2, r + band / 2
			for _, p in ipairs(Players:GetPlayers()) do
				local c = p.Character
				local pr = c and c:FindFirstChild("HumanoidRootPart")
				local ph = c and c:FindFirstChildOfClass("Humanoid")
				if pr and ph and ph.Health > 0 and not hit[p] then
					local d = ((pr.Position - base) * Vector3.new(1, 0, 1)).Magnitude
					local footY = pr.Position.Y - (ph.HipHeight + pr.Size.Y / 2)
					if d >= lo and d <= hi and d <= radius and (footY - gy) < jumpClear then
						hit[p] = true
						PlayerDamageService.Apply(ph, dmg)
					end
				end
			end
			prevR = r
			if a >= 1 then
				break
			end
			task.wait()
		end
		end -- for w (waves)
	end)
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 탈 환영 3연 던지기(춤추는 도깨비 주 패턴): 본체 탈은 그대로 두고, 보랏받 반투명 탈 환영 N개를 중앙·±SpreadDeg로 펼쳐 직선으로 날린다.
-- [2026-09-07 3차] 사장님 선택(가면 부매랑=뱄리 날아가서 X · 발구름 링 X). 무기 '환영검 — 가면 환영이 떠다니며 보랏받 안개' 콘셉과 직결.
-- 환영 = 본체 Head 복제(텍스처 제거·보라 네온·반투명) — 본체 Head는 그대로(투명 안 함). 전조 = 직선 박스 N개 = 경로(사이 틈이 안전).
-- 판정 = 매 프레임 환영 중심과 플레이어 수평 거리, 한 발리(volley)에 플레이어 1명당 1회(원점 근처 겹침 구간 3중 피격 방지).
-- 사거리·쿨·윈드업·최소거리는 투척 공용 필드(ThrowRange/ThrowMinRange/ThrowWindup/ThrowCooldown)로 돈다.
local function performPhantomMasks(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	-- [2026-09-07] ShardVolley(수호석 수정 파편 틅기기)도 이 함수를 공유한다: cfg.Visual="Crystal"이면 Head 복제 대신 수정 조각 파트를 만든다.
	local cfg = def.PhantomMask or def.ShardVolley or {}
	local isCrystal = cfg.Visual == "Crystal"
	local model = st.Model
	local phantoms = {}
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local windup = cfg.Windup or def.ThrowWindup or 0.6
		local range = cfg.Range or def.ThrowRange or 16
		local width = cfg.Width or 3
		local count = math.clamp(math.floor(cfg.Count or 3), 1, 5)
		local spread = math.rad(cfg.SpreadDeg or 15)
		local flightT = cfg.FlightSec or 0.5
		local rgb = cfg.Color or { 168, 120, 235 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local mid = (model and model:GetAttribute("MonsterId")) or ""
		local base = root.Position
		local gy = monsterGroundY(base)
		local aimV = (tRoot.Position - base) * Vector3.new(1, 0, 1)
		local lookFlat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		local aimDir = aimV.Magnitude > 0.05 and aimV.Unit or (lookFlat.Magnitude > 0.05 and lookFlat.Unit or Vector3.new(0, 0, -1))
		hum.AutoRotate = false
		root.Anchored = true
		root.CFrame = CFrame.lookAt(base, base + aimDir)
		-- 방향 N개: 중앙 기준 좌우 대칭(홀수는 중앙 포함, 짝수는 ±spread/2부터)
		local dirs = {}
		for i = 1, count do
			local k = i - (count + 1) / 2
			dirs[i] = CFrame.fromAxisAngle(Vector3.yAxis, k * spread):VectorToWorldSpace(aimDir)
		end
		for _, d in ipairs(dirs) do
			local center = Vector3.new(base.X, gy + AI.HitBoxHeight / 2, base.Z) + d * (range / 2)
			showBoxTelegraph(CFrame.lookAt(center, center + d), Vector3.new(width, AI.HitBoxHeight, range), windup, color)
		end
		playMobSound(root, mid .. "PhantomMaskWindup")
		if not MonsterProcAnim.Play(model, cfg.AnimKey or "PhantomMask") then
			playAttackAnim(st)
		end
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end
		-- 환영 생성: Head 복제(있으면) / 없으면 원판 폴백. 본체 Head는 손대지 않는다.
		local head = (not isCrystal) and model and model:FindFirstChild(cfg.PartName or "Head") or nil
		local startPos = (head and head.Position) or (base + Vector3.new(0, cfg.LaunchHeight or 2, 0))
		for i, d in ipairs(dirs) do
			local ph
			if head then
				ph = head:Clone()
				for _, c in ipairs(ph:GetChildren()) do
					c:Destroy() -- 조인트·어태치물트·텍스처 자식 전부 제거(네온 실루엣만 남김)
				end
				if ph:IsA("MeshPart") then
					ph.TextureID = ""
				end
			else
				-- 수정 조각: 길재 로 바탕(Y가 장축) — 뱄행 중 장축을 진행방향에 맞추고 자전시켜 반짝이게 한다
				ph = Instance.new("Part")
				ph.Size = isCrystal and Vector3.new(0.8, 2.6, 0.8) or Vector3.new(0.4, 2.4, 2.4)
				if not isCrystal then
					ph.Shape = Enum.PartType.Cylinder
				end
			end
			ph.Name = cfg.ProjName or "PhantomMask"
			ph.Anchored = true
			ph.CanCollide = false
			ph.CanQuery = false
			ph.CanTouch = false
			ph.CastShadow = false
			ph.Material = Enum.Material.Neon
			ph.Color = color
			ph.Transparency = cfg.Transparency or 0.4
			ph.CFrame = CFrame.lookAt(startPos, startPos + d)
			local light = Instance.new("PointLight")
			light.Color = color
			light.Range = 9
			light.Brightness = 1.5
			light.Parent = ph
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0.9, 0)
			a0.Parent = ph
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, -0.9, 0)
			a1.Parent = ph
			local trail = Instance.new("Trail")
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Color = ColorSequence.new(color, color:Lerp(Color3.new(1, 1, 1), 0.6))
			trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
			trail.Lifetime = 0.35
			trail.LightEmission = 0.6
			trail.Parent = ph
			ph.Parent = monstersFolder
			Debris:AddItem(ph, flightT + 1.0)
			phantoms[i] = ph
		end
		spawnBurst(startPos, color, 12, 12, 0.55)
		playMobSound(root, mid .. "PhantomMaskHit")
		local hit = {}
		local dmg = math.floor(def.Atk * (cfg.DamageMul or 0.7) + 0.5)
		local t1 = os.clock()
		while true do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			local a = math.min((os.clock() - t1) / flightT, 1)
			for i, d in ipairs(dirs) do
				local ph = phantoms[i]
				if ph and ph.Parent then
					local pos = startPos + d * (range * a) + Vector3.new(0, math.sin(a * math.pi) * 0.8, 0)
					-- 수직축 회전 = 날아가는 탈이 빙글 도는 느낌. 반투명은 멀어질수록 조금 더 트이게.
					if isCrystal then
						ph.CFrame = CFrame.lookAt(pos, pos + d) * CFrame.Angles(math.rad(90), 0, 0) * CFrame.Angles(0, a * math.pi * 6, 0)
					else
						ph.CFrame = CFrame.lookAt(pos, pos + d) * CFrame.Angles(0, a * math.pi * 4, 0)
					end
					ph.Transparency = (cfg.Transparency or 0.4) + 0.35 * a
					for _, p in ipairs(Players:GetPlayers()) do
						local c = p.Character
						local pr = c and c:FindFirstChild("HumanoidRootPart")
						local phum = c and c:FindFirstChildOfClass("Humanoid")
						if pr and phum and phum.Health > 0 and not hit[p] then
							local dd = ((pr.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
							if dd <= width / 2 + 1.6 and math.abs(pr.Position.Y - pos.Y) <= 4.5 then
								hit[p] = true
								PlayerDamageService.Apply(phum, dmg)
								spawnBurst(pos, color, 8, 10, 0.45)
							end
						end
					end
				end
			end
			if a >= 1 then
				break
			end
			task.wait()
		end
		for _, d in ipairs(dirs) do
			local endPos = startPos + d * range
			spawnGroundRing(Vector3.new(endPos.X, gy + 0.35, endPos.Z), width * 0.7, color, 0.3)
		end
	end)
	for _, ph in ipairs(phantoms) do
		if ph.Parent then
			ph:Destroy()
		end
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 상모 휩쓸기(북 도깨비 주 패턴): 상모 띠가 반경 Radius까지 길게 늘어나 머리 위에서 SpinDeg만큼 빨리 돌며 부채꼴 판정이 회전한다.
-- [2026-09-07 4차] 사장님 제안 "상투(상모) 돌리기" — 모델에 모자 띠(Ribbon 메시)가 이미 머리를 감고 있어 사물놀이 상모돌리기와 1:1.
-- 회피 두 가지: ①반경 InnerSafe 안(북 바로 옆)은 띠가 머리 위로 지나가 안전 → "달려들어 붙기" ②Radius 밖으로 물러나기. 점프는 안 통한다.
-- 판정 = 프레임 간 회전 구간 [prevAng, ang] + 띠 폭 각도 허용 — 빠른 회전(600°/s)에서 플레이어를 건너뛰지 않게 구간으로 본다. 1회/인.
-- 연출 = Head에서 나가는 Beam 띠(카메라 향) + 바닥 쉘이 네온 쉐지(띠 그림자 = 판정 위치) + 상모 회전은 절차 클립(RibbonSweep)이 담당(C0 이중구동 금지).
-- 사거리·쿨·윈드업·최소거리는 투척 공용 필드(ThrowRange/ThrowMinRange/ThrowWindup/ThrowCooldown)로 돈다.
local function performRibbonSweep(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local cfg = def.RibbonSweep or {}
	local model = st.Model
	local props = {}
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local windup = cfg.Windup or def.ThrowWindup or 0.7
		local radius = cfg.Radius or def.ThrowRange or 12
		local inner = math.min(cfg.InnerSafe or 4, radius - 2)
		local width = cfg.Width or 3.5
		local spin = math.rad(cfg.SpinDeg or 720)
		local dur = cfg.Duration or 1.4
		local rgb = cfg.Color or { 240, 244, 255 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local mid = (model and model:GetAttribute("MonsterId")) or ""
		local base = root.Position
		local gy = monsterGroundY(base)
		local center = Vector3.new(base.X, gy + 0.16, base.Z)
		local aimV = (tRoot.Position - base) * Vector3.new(1, 0, 1)
		local lookFlat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		local aimDir = aimV.Magnitude > 0.05 and aimV.Unit or (lookFlat.Magnitude > 0.05 and lookFlat.Unit or Vector3.new(0, 0, -1))
		hum.AutoRotate = false
		root.Anchored = true
		root.CFrame = CFrame.lookAt(base, base + aimDir)
		local startAng = math.atan2(aimDir.Z, aimDir.X)
		local segLen = radius - inner
		-- 전조: 바깥 가장자리 링 + 안전 반경 링(동시에 링 2개 = 띠 구간) + 회전 시작 부채 박스 1장
		spawnDonutRing(center, radius, color, windup + dur, 0.97)
		spawnDonutRing(center, inner, color, windup + dur, 0.97)
		local segCenter = Vector3.new(base.X, gy + AI.HitBoxHeight / 2, base.Z) + aimDir * (inner + segLen / 2)
		showBoxTelegraph(CFrame.lookAt(segCenter, segCenter + aimDir), Vector3.new(width, AI.HitBoxHeight, segLen), windup, color)
		playMobSound(root, mid .. "RibbonSweepWindup")
		if not MonsterProcAnim.Play(model, "RibbonSweep") then
			playAttackAnim(st)
		end
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end
		-- 연출 파트: 띠 끝(tip) + Head→tip Beam + 바닥 쉘이 쉐지
		local head = model and model:FindFirstChild("Head")
		local headPos = head and head.Position or (base + Vector3.new(0, 2.5, 0))
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, (head and head.Size.Y / 2 or 1), 0)
		a0.Parent = head or root
		local tip = Instance.new("Part")
		tip.Name = "RibbonTip"
		tip.Size = Vector3.new(0.2, 0.2, 0.2)
		tip.Transparency = 1
		tip.Anchored = true
		tip.CanCollide = false
		tip.CanQuery = false
		tip.CanTouch = false
		local a1 = Instance.new("Attachment")
		a1.Parent = tip
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Width0 = 1.4
		beam.Width1 = 0.45
		beam.Color = ColorSequence.new(color)
		beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 0.45) })
		beam.LightEmission = 0.4
		beam.Segments = 12
		beam.CurveSize0 = 2.5
		beam.CurveSize1 = -2.5
		beam.FaceCamera = true
		beam.Parent = tip
		tip.Parent = monstersFolder
		local wedge = Instance.new("Part")
		wedge.Name = "RibbonSweepWedge"
		wedge.Size = Vector3.new(width, 0.2, segLen)
		wedge.Material = Enum.Material.Neon
		wedge.Color = color
		wedge.Transparency = 0.35
		wedge.Anchored = true
		wedge.CanCollide = false
		wedge.CanQuery = false
		wedge.CanTouch = false
		wedge.CastShadow = false
		wedge.Parent = monstersFolder
		props = { tip, wedge, a0 }
		Debris:AddItem(tip, dur + 1)
		Debris:AddItem(wedge, dur + 1)
		Debris:AddItem(a0, dur + 1)
		playMobSound(root, mid .. "RibbonSweepHit")
		spawnBurst(headPos, color, 10, 10, 0.5)
		local hit = {}
		local dmg = math.floor(def.Atk * (cfg.DamageMul or 0.9) + 0.5)
		local TAU = math.pi * 2
		local t1 = os.clock()
		local prevAng = startAng
		while true do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			local a = math.min((os.clock() - t1) / dur, 1)
			local ang = startAng + spin * a
			local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
			local hp = head and head.Position or headPos
			tip.CFrame = CFrame.new(hp + dir * radius + Vector3.new(0, -1.2, 0))
			local wc = Vector3.new(base.X, gy + 0.3, base.Z) + dir * (inner + segLen / 2)
			wedge.CFrame = CFrame.lookAt(wc, wc + dir)
			local swept = ang - prevAng
			for _, p in ipairs(Players:GetPlayers()) do
				local c = p.Character
				local pr = c and c:FindFirstChild("HumanoidRootPart")
				local ph = c and c:FindFirstChildOfClass("Humanoid")
				if pr and ph and ph.Health > 0 and not hit[p] then
					local v = (pr.Position - base) * Vector3.new(1, 0, 1)
					local d = v.Magnitude
					if d >= inner and d <= radius + 1.2 and math.abs(pr.Position.Y - gy) <= AI.HitBoxHeight + 2 then
						local pAng = math.atan2(v.Z, v.X)
						local delta = (pAng - prevAng) % TAU
						local tol = math.atan2(width / 2 + 1.2, math.max(d, 1))
						if delta <= swept + tol or delta >= TAU - tol then
							hit[p] = true
							PlayerDamageService.Apply(ph, dmg)
							spawnBurst(pr.Position, color, 8, 10, 0.45)
						end
					end
				end
			end
			prevAng = ang
			if a >= 1 then
				break
			end
			task.wait()
		end
		spawnGroundRing(center + Vector3.new(0, 0.2, 0), radius, color, 0.4)
	end)
	for _, inst in ipairs(props) do
		if inst.Parent then
			inst:Destroy()
		end
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 도깨비불 구슬 사출(도깨비불 마법사 주 패턴): 몸 주위를 도는 구슬 2개가 실제로 떨어져 타겟으로 날아갔다 돌아온다.
-- [2026-09-07] 종전 Throw"Flame"(몸과 무관한 화염구) + Blink"Away"(순간이동 = 가드레일 #11 위반) → 모델의 Wisp_G 구슬을 그대로 무기로 쓴다.
-- 구슬은 Count개가 Interval 간격으로 시차 발사된다(두 번 피해야 함) · 각각 직선으로 나갔다 본체로 복귀.
-- 본체 구슬(Wisp_G 하위 파트)는 비행 중 투명 — 복원은 pcall 밖(조기 return 시 구슬 사라짐 고착 방지).
-- 판정 = 매 프레임 구슬 중심과 수평 거리, 구슬별로 플레이어 1명당 1회(왕복 중복 없음).
-- 사거리·쿨·윈드업·최소거리는 투척 공용 필드(ThrowRange/ThrowMinRange/ThrowWindup/ThrowCooldown).
local function performOrbLaunch(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local cfg = def.OrbLaunch or {}
	local model = st.Model
	local hidden, orbs = {}, {}
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local windup = cfg.Windup or def.ThrowWindup or 0.75
		local range = cfg.Range or def.ThrowRange or 18
		local width = cfg.Width or 3.5
		local count = math.clamp(math.floor(cfg.Count or 2), 1, 4)
		local interval = cfg.Interval or 0.25
		local outT = cfg.OutSec or 0.5
		local backT = cfg.BackSec or 0.45
		local rgb = cfg.Color or def.ThrowColor or { 90, 170, 255 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local mid = (model and model:GetAttribute("MonsterId")) or ""
		local base = root.Position
		local gy = monsterGroundY(base)
		local aimV = (tRoot.Position - base) * Vector3.new(1, 0, 1)
		local lookFlat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		local aimDir = aimV.Magnitude > 0.05 and aimV.Unit or (lookFlat.Magnitude > 0.05 and lookFlat.Unit or Vector3.new(0, 0, -1))
		hum.AutoRotate = false
		root.Anchored = true
		root.CFrame = CFrame.lookAt(base, base + aimDir)
		-- 전조: 구슬 수만큼 밀어넣은 직선 박스(경로). 같은 선을 곹쳐 두 번 지나가므로 1장만 깔다.
		local segCenter = Vector3.new(base.X, gy + AI.HitBoxHeight / 2, base.Z) + aimDir * (range / 2)
		showBoxTelegraph(CFrame.lookAt(segCenter, segCenter + aimDir), Vector3.new(width, AI.HitBoxHeight, range), windup, color)
		playMobSound(root, mid .. "OrbLaunchWindup")
		if not MonsterProcAnim.Play(model, cfg.AnimKey or "OrbLaunch") then
			playAttackAnim(st)
		end
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end
		-- 본체 구슬 수집: Wisp_G 모델 하위 파트를 짝지어 발사체로 쓴다(없으면 네온 구체 폴백).
		local sources = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == (cfg.OrbPartName or "Wisp_Out") then
				table.insert(sources, d)
			end
		end
		local hit = {}
		local dmg = math.floor(def.Atk * (cfg.DamageMul or 0.55) + 0.5)
		local launched = 0
		local done = 0
		for i = 1, count do
			local src = sources[i]
			local startPos = (src and src.Position) or (base + Vector3.new(0, cfg.LaunchHeight or 2.4, 0))
			-- 본체 구슬 숨김(구슬이 몸을 떠난 것처럼)
			if src and src.Parent then
				for _, sib in ipairs(src.Parent:GetChildren()) do
					if sib:IsA("BasePart") and hidden[sib] == nil then
						hidden[sib] = sib.Transparency
						sib.Transparency = 1
					end
				end
			end
			local orb
			if src then
				orb = src:Clone()
				for _, c in ipairs(orb:GetChildren()) do
					if not (c:IsA("ParticleEmitter") or c:IsA("SurfaceAppearance")) then c:Destroy() end
				end
			else
				orb = Instance.new("Part")
				orb.Shape = Enum.PartType.Ball
				orb.Size = Vector3.new(1.6, 1.6, 1.6)
			end
			orb.Name = cfg.ProjName or "WispOrb"
			orb.Anchored = true
			orb.CanCollide = false
			orb.CanQuery = false
			orb.CanTouch = false
			orb.CastShadow = false
			orb.Material = Enum.Material.Neon
			orb.Color = color
			orb.Transparency = 0
			orb.CFrame = CFrame.new(startPos)
			local light = Instance.new("PointLight")
			light.Color = color
			light.Range = 12
			light.Brightness = 2.4
			light.Parent = orb
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0.7, 0)
			a0.Parent = orb
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, -0.7, 0)
			a1.Parent = orb
			local trail = Instance.new("Trail")
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Color = ColorSequence.new(color, color:Lerp(Color3.new(1, 1, 1), 0.7))
			trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
			trail.Lifetime = 0.4
			trail.LightEmission = 1
			trail.Parent = orb
			orb.Parent = monstersFolder
			Debris:AddItem(orb, outT + backT + interval * count + 1.5)
			table.insert(orbs, orb)
			launched += 1
			local myHit = {}
			hit[i] = myHit
			spawnBurst(startPos, color, 10, 10, 0.5)
			playMobSound(root, mid .. "OrbLaunchHit")
			-- 구슬당 비행 코루틴(시차 발사)
			task.spawn(function()
				local far = startPos + aimDir * range
				local function judge(pos)
					for _, p in ipairs(Players:GetPlayers()) do
						local c = p.Character
						local pr = c and c:FindFirstChild("HumanoidRootPart")
						local ph = c and c:FindFirstChildOfClass("Humanoid")
						if pr and ph and ph.Health > 0 and not myHit[p] then
							local d = ((pr.Position - pos) * Vector3.new(1, 0, 1)).Magnitude
							if d <= width / 2 + 1.6 and math.abs(pr.Position.Y - pos.Y) <= 5 then
								myHit[p] = true
								PlayerDamageService.Apply(ph, dmg)
								spawnBurst(pos, color, 8, 10, 0.45)
							end
						end
					end
				end
				local t1 = os.clock()
				while orb.Parent do
					local a = math.min((os.clock() - t1) / outT, 1)
					local pos = startPos:Lerp(far, a) + Vector3.new(0, math.sin(a * math.pi) * 0.9, 0)
					orb.CFrame = CFrame.new(pos)
					judge(pos)
					if a >= 1 then break end
					task.wait()
				end
				local t2 = os.clock()
				while orb.Parent do
					local a = math.min((os.clock() - t2) / backT, 1)
					local home = (src and src.Parent and src.Position) or startPos
					local pos = far:Lerp(home, a) + Vector3.new(0, math.sin(a * math.pi) * 0.9, 0)
					orb.CFrame = CFrame.new(pos)
					judge(pos)
					if a >= 1 then break end
					task.wait()
				end
				if orb.Parent then orb:Destroy() end
				done += 1
			end)
			if i < count then
				local ti = os.clock()
				while os.clock() - ti < interval do
					if hum.Health <= 0 or not root.Parent then return end
					task.wait()
				end
			end
		end
		-- 모든 구슬이 돌아올 때까지 자세 유지(최대 안전시간)
		local tw = os.clock()
		while done < launched and os.clock() - tw < outT + backT + 1 do
			if hum.Health <= 0 or not root.Parent then return end
			task.wait()
		end
	end)
	for _, orb in ipairs(orbs) do
		if orb.Parent then orb:Destroy() end
	end
	for part, transp in pairs(hidden) do
		if part.Parent then part.Transparency = transp end -- pcall 밖 복원(구슬 사라짐 고착 방지)
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

-- 장승 벽 세우기(신전 수호령 주 패턴): 몸에서 타겟 방향으로 장승이 Count개 줄지어 차례로 솔구친다.
-- [2026-09-07] 종전 Throw"Flame"(보라 영혼탄 — 수호석 파편 3연과 회피가 겹침) → 장승 정체성을 주 패턴으로 올렸다.
-- 전조는 줄 전체를 한 번에 깔고(경로가 보임), 솔구침은 앞에서부터 StepDelay 간격으로 다가오듯 이어진다.
-- 판정 = 장승별 원(Radius) · 플레이어 1명당 1회(줄 전체 기준 — 여러 개 겹쳐도 한 번만). 회피 = 줄에서 옆으로 비키기.
-- 사거리·쿨·윈드업은 투척 공용 필드(ThrowRange/ThrowMinRange/ThrowWindup/ThrowCooldown).
local function performPillarWall(st)
	st.KbInterrupt = nil
	local def, hum, root = st.Def, st.Humanoid, st.Root
	local tRoot = st.TargetRoot
	local cfg = def.PillarWall or {}
	local props = {}
	pcall(function()
		if not (tRoot and tRoot.Parent and root.Parent) then
			return
		end
		local count = math.clamp(math.floor(cfg.Count or 5), 2, 8)
		local gap = cfg.Gap or 6
		local radius = cfg.Radius or 4
		local windup = cfg.Windup or def.ThrowWindup or 0.9
		local stepDelay = cfg.StepDelay or 0.15
		local riseT = cfg.RiseSec or 0.18
		local holdT = cfg.HoldSec or 0.5
		local scale = cfg.Scale or 0.7
		local startGap = cfg.StartGap or 5
		local rgb = cfg.Color or { 175, 140, 255 }
		local color = Color3.fromRGB(rgb[1], rgb[2], rgb[3])
		local mid = (st.Model and st.Model:GetAttribute("MonsterId")) or ""
		local base = root.Position
		local aimV = (tRoot.Position - base) * Vector3.new(1, 0, 1)
		local lookFlat = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		local dir = aimV.Magnitude > 0.05 and aimV.Unit or (lookFlat.Magnitude > 0.05 and lookFlat.Unit or Vector3.new(0, 0, -1))
		hum.AutoRotate = false
		root.Anchored = true
		root.CFrame = CFrame.lookAt(base, base + dir)
		-- 줄 지점과 전조(경로 직선 박스 1장 = 예고)
		local spots = {}
		for i = 1, count do
			local p = base + dir * (startGap + gap * (i - 1))
			local gy = monsterGroundY(p)
			spots[i] = Vector3.new(p.X, gy, p.Z)
		end
		local lineLen = startGap + gap * (count - 1) + radius
		local lineCenter = Vector3.new(base.X, monsterGroundY(base) + AI.HitBoxHeight / 2, base.Z) + dir * (lineLen / 2)
		showBoxTelegraph(CFrame.lookAt(lineCenter, lineCenter + dir), Vector3.new(radius * 2, AI.HitBoxHeight, lineLen), windup, color)
		for _, s in ipairs(spots) do
			spawnGroundRing(Vector3.new(s.X, s.Y + 0.3, s.Z), radius, color, windup)
		end
		playMobSound(root, mid .. "PillarWindup")
		if not MonsterProcAnim.Play(st.Model, cfg.AnimKey or "PillarWall") then
			playAttackAnim(st)
		end
		local t0 = os.clock()
		while os.clock() - t0 < windup do
			if hum.Health <= 0 or not root.Parent or st.KbInterrupt then
				return
			end
			task.wait()
		end
		local tpl = findModelPart(st.Model, cfg.PartName or "ShineGuardianPillar")
		local hit = {}
		local dmg = math.floor(def.Atk * (cfg.DamageMul or 0.45) + 0.5)
		playMobSound(root, mid .. "PillarHit")
		for i, spot in ipairs(spots) do
			if hum.Health <= 0 or not root.Parent then
				return
			end
			local pillar
			if tpl then
				pillar = tpl:Clone()
				for _, c in ipairs(pillar:GetChildren()) do
					if not (c:IsA("SurfaceAppearance") or c:IsA("Decal") or c:IsA("Texture")) then c:Destroy() end
				end
				pillar.Size = tpl.Size * scale
			else
				pillar = Instance.new("Part")
				pillar.Size = Vector3.new(4, 9, 2.5)
				pillar.Color = color
			end
			pillar.Name = "GuardianPillarProp"
			pillar.Anchored = true
			pillar.CanCollide = false
			pillar.CanQuery = false
			pillar.CanTouch = false
			pillar.CastShadow = false
			pillar.Parent = monstersFolder
			table.insert(props, pillar)
			local h = pillar.Size.Y
			local topY, botY = spot.Y + h / 2, spot.Y - h / 2 - 1
			pillar.CFrame = CFrame.lookAt(Vector3.new(spot.X, botY, spot.Z), Vector3.new(spot.X, botY, spot.Z) + dir)
			spawnBurst(Vector3.new(spot.X, spot.Y + 0.8, spot.Z), color, 14, 20, 0.6)
			local boxCf = CFrame.new(spot.X, spot.Y + AI.HitBoxHeight / 2, spot.Z)
			local boxSize = Vector3.new(radius * 2, AI.HitBoxHeight, radius * 2)
			-- 솔구침 코루틴(다음 장승은 StepDelay 뒤에 이어진다)
			task.spawn(function()
				local t1 = os.clock()
				while pillar.Parent do
					local a = math.min((os.clock() - t1) / riseT, 1)
					local y = botY + (topY - botY) * a
					pillar.CFrame = CFrame.lookAt(Vector3.new(spot.X, y, spot.Z), Vector3.new(spot.X, y, spot.Z) + dir)
					if a >= 1 then break end
					task.wait()
				end
				for _, p in ipairs(Players:GetPlayers()) do
					local pc = p.Character
					local ppr = pc and pc:FindFirstChild("HumanoidRootPart")
					local ph = pc and pc:FindFirstChildOfClass("Humanoid")
					if ppr and ph and ph.Health > 0 and not hit[p] and pointInBox(boxCf, boxSize, ppr.Position) then
						hit[p] = true
						local damaged = PlayerDamageService.Apply(ph, dmg)
						if damaged and cfg.Knockback then
							MonsterService.KnockbackPlayer(p, Vector3.new(spot.X, ppr.Position.Y, spot.Z),
								cfg.Knockback.Force or 12, cfg.Knockback.Lift or 18)
						end
					end
				end
				local t2 = os.clock()
				while pillar.Parent and os.clock() - t2 < holdT do task.wait() end
				if pillar.Parent then
					pcall(function()
						TweenService:Create(pillar, TweenInfo.new(0.3, Enum.EasingStyle.Quad), {
							CFrame = CFrame.lookAt(Vector3.new(spot.X, botY, spot.Z), Vector3.new(spot.X, botY, spot.Z) + dir),
							Transparency = 1,
						}):Play()
					end)
					Debris:AddItem(pillar, 0.45)
				end
			end)
			if i < count then
				local ts = os.clock()
				while os.clock() - ts < stepDelay do
					if hum.Health <= 0 or not root.Parent then return end
					task.wait()
				end
			end
		end
		-- 마지막 장승이 가라앉을 때까지 자세 유지
		local tw = os.clock()
		while os.clock() - tw < riseT + holdT + 0.3 do
			if hum.Health <= 0 or not root.Parent then return end
			task.wait()
		end
	end)
	for _, p in ipairs(props) do
		if p.Parent then p:Destroy() end -- 조기 중단 시 프롭 잔류 방지
	end
	if root.Parent then
		root.Anchored = false
		hum.AutoRotate = true
	end
	finishAttack(st)
end

local function aiTick()
	for model, st in pairs(active) do
		if not model.Parent or not st.Root.Parent then
			retire(model)
		elseif st.Humanoid.Health <= 0 then
			retire(model) -- 정산 외 사망(디버그 등) 안전망
		else
			local def = st.Def
			local hum = st.Humanoid
			local rootPos = st.Root.Position
			-- [2026-08-20] 부양 몹 둥실거림: HipHeight를 느리게 흔든다. Humanoid가 스프링으로 따라오므로
			-- 틱(0.2s) 갱신인데도 매끄럽게 보인다. 위상은 개체마다 고정 — 팩이 한 몸처럼 오르내리지 않게.
			if def.FlyHeight and not st.AttackBusy then
				st.BobPhase = st.BobPhase or math.random() * math.pi * 2
				local bob = math.sin(os.clock() * 2.4 + st.BobPhase) * (def.FlyBob or 0.35)
				hum.HipHeight = (def.HipOffset or 0) + def.FlyHeight + bob
			end
			-- 비교전(Idle/Return) 점진 회복: 갑작스런 풀힐 없이 자연 회복(어뷰즈 방지 유지)
			if (st.State == "Idle" or st.State == "Return") and hum.Health > 0 and hum.Health < hum.MaxHealth then
				hum.Health = math.min(hum.MaxHealth, hum.Health + hum.MaxHealth * (AI.ReturnRegenPctPerSec or 0) * AI.TickSec)
			end
			-- 전천후 안전망: 심하게 기울었거나(45°+) 땅 아래 박힌 몸 직립+스냅(1s 디바운스, 패턴 앵커 중 제외)
			if not st.AttackBusy and not st.Root.Anchored and st.Root.CFrame.UpVector.Y < 0.7
				and os.clock() - (st.LastUprightAt or 0) > 1 then
				st.LastUprightAt = os.clock()
				local r = st.Root
				local look = r.CFrame.LookVector * Vector3.new(1, 0, 1)
				look = look.Magnitude > 0.05 and look.Unit or Vector3.new(0, 0, 1)
				r.CFrame = CFrame.lookAt(r.Position + Vector3.new(0, 1, 0), r.Position + Vector3.new(0, 1, 0) + look)
				r.AssemblyLinearVelocity = Vector3.zero
				r.AssemblyAngularVelocity = Vector3.zero
			end
			if st.AttackBusy then
				-- 패턴 공격 시퀀스 진행 중 — 이동/전이 개입 금지(종료 시 스스로 해제)
			elseif st.StunnedUntil and os.clock() < st.StunnedUntil then
				hum:Move(Vector3.zero, false) -- 짧은 경직: 넉백 물리와 AI 이동 충돌 방지
			elseif st.State == "Idle" then
				local tRoot, tHum = nearestAlivePlayer(rootPos, def.AggroRange)
				if tRoot then
					st.TargetRoot, st.TargetHum = tRoot, tHum
					st.State = "Chase"
					-- [2026-08-04] 투척 무장: 초기값 nil이라 첫 조우에 원거리 견제가 즉발됐다.
					--   근접(돌진·스핀·슬램)은 이 몹들의 기본 공격이라 즉시 유지 — 투척만 자기 쿨을 채우고 시작한다.
					if def.ThrowRange and not st.ThrowArmed then
						st.ThrowArmed = true
						st.NextThrowAt = os.clock() + (def.ThrowCooldown or 5)
					end
					if def.Cry and not st.CryArmed then
						st.CryArmed = true
						st.NextCryAt = os.clock() + (def.Cry.InitialDelay or def.Cry.Cooldown or 8)
					end
					hum.WalkSpeed = def.WalkSpeed -- 반속 산책 중이었어도 추격은 전속 복원
					-- 어그로 울음(종류별 전역 쿨다운 — 팩 3중첩 방지)
					local mid = model:GetAttribute("MonsterId")
					if mid and os.clock() - (lastAggroSoundAt[mid] or 0) >= AGGRO_SOUND_CD then
						lastAggroSoundAt[mid] = os.clock()
						playMobSound(st.Root, mid .. "Aggro")
					end
				else
					-- 유휴 시 스폰 반경 내 랜덤 지점 산책(AI.Wander) — 별도 루프 없이 기존 틱에서 처리.
					-- 반경이 LeashRange보다 훨씬 작아 리쉬/귀환 로직과 충돌 없음.
					local wander = AI.Wander
					local now = os.clock()
					if not st.NextWanderAt then
						st.NextWanderAt = now + wander.MinSec + math.random() * (wander.MaxSec - wander.MinSec)
					elseif now >= st.NextWanderAt then
						st.NextWanderAt = now + wander.MinSec + math.random() * (wander.MaxSec - wander.MinSec)
						local angle = math.random() * math.pi * 2
						local radius = math.random() * wander.Radius
						hum.WalkSpeed = def.WalkSpeed * wander.SpeedMul
						hum:MoveTo(st.SpawnPos + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
					end
					-- [2026-08-20] 대기 방향 복원(World=2): 산책하다 멈추면 이동 방향 그대로 굳어 마커 방향을 잃는다
					-- (정지 49/54 실측). 멈춰 있을 때만 마커 LookVector로 천천히 되돌린다 — 순찰 자체는 그대로 둔다.
					-- ★AutoRotate는 이동 방향으로만 걸리므로 정지 중 CFrame 직접 회전과 싸우지 않는다.
					if def.World == 2 and not st.Root.Anchored and hum.MoveDirection.Magnitude < 0.05 then
						local want = st.Marker and (st.Marker.CFrame.LookVector * Vector3.new(1, 0, 1)) or nil
						if want and want.Magnitude > 0.05 then
							local cur = st.Root.CFrame.LookVector * Vector3.new(1, 0, 1)
							if cur.Magnitude > 0.05 and cur.Unit:Dot(want.Unit) < 0.985 then
								local blend = cur.Unit:Lerp(want.Unit, 0.25)
								if blend.Magnitude > 0.05 then
									local p = st.Root.Position
									st.Root.CFrame = CFrame.lookAt(p, p + blend.Unit)
									st.Root.AssemblyAngularVelocity = Vector3.zero
								end
							end
						end
					end
				end
			elseif st.State == "Chase" then
				-- [2026-07-25 QA] 반격 추격(RetaliateChase): 스폰 리쉬 대신 플레이어와 RetaliateBreakDist(15) 이상 벌어지면 귀환(사장님 확정)
				local leashBroken
				local retaliateRoot, retaliateHum
				-- [2026-08-12] Pull 유예: 끌려온 직후 GraceSec 동안만 이탈 임계를 BreakDist로 완화.
				--   MaxFromSpawn은 🔴유예 중에만 적용 — 유예 연쇄로 인한 무제한 견인의 실질 상한.
				-- [2026-08-25 파티 AI] 반격 추격도 최초 공격자를 고정하지 않고 몬스터 현재 위치에서 가장 가까운 생존자를 매 틱 다시 고른다.
				local PL = AI.PullLeash
				local pullGrace = (st.PullGraceUntil ~= nil) and (os.clock() < st.PullGraceUntil)
				if st.RetaliateChase then
					local breakDist = pullGrace and ((PL and PL.BreakDist) or 24) or (AI.RetaliateBreakDist or 15)
					retaliateRoot, retaliateHum = nearestAlivePlayer(rootPos, breakDist)
					leashBroken = not retaliateRoot
						or (pullGrace and (rootPos - st.SpawnPos).Magnitude > ((PL and PL.MaxFromSpawn) or 60))
					if not leashBroken then
						st.TargetRoot, st.TargetHum = retaliateRoot, retaliateHum
					end
				else
					leashBroken = (rootPos - st.SpawnPos).Magnitude > def.LeashRange
				end
				if leashBroken then
					st.RetaliateChase = nil
					st.PullGraceUntil = nil -- [2026-08-12] 교전 종료 = 유예 소멸
					st.TargetRoot, st.TargetHum = nil, nil
					st.State = "Return"
					st.ThrowArmed = nil -- 귀환 = 교전 종료. 재조우 시 투척을 다시 무장한다
					st.CryArmed = nil
					hum:MoveTo(st.SpawnPos)
				else
					local tRoot, tHum
					if st.RetaliateChase then
						tRoot, tHum = retaliateRoot, retaliateHum
					else
						tRoot, tHum = nearestAlivePlayer(rootPos, def.LeashRange)
					end
					-- [2026-08-20] 원거리 우선(RangedPriority): 돌진 사거리(14)가 선회 반경(9)보다 넓은 몹은
					-- 돌진 분기가 늘 먼저 걸려 투척이 한 번도 안 나왔다 — 도깨비불 17초 실측 0회.
					-- 투척 쿨(ThrowCooldown)이 찬 순간에만 돌진을 양보시켜 원거리/근접이 번갈아 나온다.
					-- 조건을 여기 한 번만 적어 두 분기가 서로 어긋나지 않게 한다.
					local throwDist = tRoot and (tRoot.Position - rootPos).Magnitude or 0
					local throwReady = tRoot ~= nil
						and def.ThrowRange ~= nil
						and throwDist > (def.ThrowMinRange or def.AttackRange + 3)
						and throwDist <= def.ThrowRange
						and os.clock() - st.LastAtkAt >= def.AtkInterval
						and os.clock() >= (st.NextThrowAt or 0)
						and (not def.RequireLineOfSight or hasLineOfSight(st.Root, tRoot))
						and os.clock() - (lastThrowGlobalAt[model:GetAttribute("MonsterId")] or 0) >= THROW_GLOBAL_CD
					local cryReady = tRoot ~= nil and def.Cry ~= nil
						and throwDist <= (def.Cry.Radius or 10)
						and os.clock() - st.LastAtkAt >= def.AtkInterval
						and os.clock() >= (st.NextCryAt or 0)
					if not tRoot then
						st.TargetRoot, st.TargetHum = nil, nil
						st.State = "Return"
						hum:MoveTo(st.SpawnPos)
					elseif def.AttackStyle == "Flee" then
						-- 도망형: 공격 없음 — 타겟 반대 방향 도주(리쉬 초과 시 Return 경로가 복귀 담당)
						st.TargetRoot, st.TargetHum = tRoot, tHum
						local away = rootPos - tRoot.Position
						away = Vector3.new(away.X, 0, away.Z)
						if away.Magnitude < 0.05 then
							away = Vector3.new(1, 0, 0)
						end
						hum:MoveTo(rootPos + away.Unit * (def.FleeStep or 10))
					elseif cryReady then
						if tryBeginAttack(st, tRoot, tHum) then
							st.NextCryAt = os.clock() + (def.Cry.Cooldown or 9)
							hum:MoveTo(rootPos)
							task.spawn(performCry, st)
						end
					-- [2026-08-20] 사거리 확보 후퇴(kite): 우선순위만 바꿔서는 원거리가 안 나온다.
					-- 밀착(거리 4)에서는 throwReady가 거짓이라 돌진 분기가 그대로 먹고, 물러나는 동작이
					-- 없어 투척 사거리(8+)에 영영 못 닿았다 — 실측 20초 투척 0회.
					-- 투척 쿨이 찼는데 너무 붙어 있으면 때리는 대신 뒤로 물러나 거리를 만든다.
					-- 장승 솟구침: 원거리 견제기라 붙지 않고도 쓴다. 후퇴 분기보다 먼저 본다.
					elseif def.PillarRise
						and os.clock() >= (st.NextPillarAt or 0)
						and os.clock() - st.LastAtkAt >= def.AtkInterval
						and (tRoot.Position - rootPos).Magnitude <= (def.PillarRise.Range or 18) then
						st.TargetRoot, st.TargetHum = tRoot, tHum
						if tryBeginAttack(st, tRoot, tHum) then
							st.NextPillarAt = os.clock() + (def.PillarRise.Cooldown or 7)
							hum:MoveTo(rootPos)
							task.spawn(performPillarRise, st)
						end
					elseif def.RangedPriority and def.ThrowRange
						and os.clock() >= (st.NextThrowAt or 0)
						and os.clock() - (lastThrowGlobalAt[model:GetAttribute("MonsterId")] or 0) >= THROW_GLOBAL_CD
						and throwDist < (def.ThrowMinRange or def.AttackRange + 3) + 2 then
						st.TargetRoot, st.TargetHum = tRoot, tHum
						local away = (rootPos - tRoot.Position) * Vector3.new(1, 0, 1)
						away = away.Magnitude > 0.05 and away.Unit or Vector3.new(1, 0, 0)
						-- 최소 사거리보다 2스터드 더 벌어 경계에서 덜덜대지 않게 한다
						local need = (def.ThrowMinRange or def.AttackRange + 3) + 2 - throwDist
						hum:MoveTo(rootPos + away * math.max(need, 3))
					elseif def.DrumStomp
						and not (def.RangedPriority and throwReady)
						and (tRoot.Position - rootPos).Magnitude <= (def.DrumStomp.Range or 14)
						and os.clock() - st.LastAtkAt >= def.AtkInterval
						and os.clock() >= (st.NextStompAt or 0) then
						-- 북 점프 충격파: 중거리에서 뛰어들어 착지 광역(밀착은 Slam이 받는다)
						if tryBeginAttack(st, tRoot, tHum) then
							st.NextStompAt = os.clock() + (def.DrumStomp.Cooldown or 6)
							hum:MoveTo(rootPos)
							task.spawn(performDrumStomp, st)
						end
					elseif def.BlinkRange
						and not (def.RangedPriority and throwReady)
						and (tRoot.Position - rootPos).Magnitude <= (def.BlinkRange or 16)
						and (not def.SpinRadius or (tRoot.Position - rootPos).Magnitude > def.AttackRange)
						and os.clock() - st.LastAtkAt >= def.AtkInterval
						and os.clock() >= (st.NextBlinkAt or 0) then
						-- 순간이동 기습: 중거리에서 사라져 등 뒤를 친다. 밀착은 Spin(부 패턴)에 양보.
						if tryBeginAttack(st, tRoot, tHum) then
							st.NextBlinkAt = os.clock() + (def.BlinkCooldown or 5)
							hum:MoveTo(rootPos)
							task.spawn(performBlink, st)
						end
					elseif (def.AttackStyle == "Dash" or def.HeavyCharge)
						and not (def.RangedPriority and throwReady) -- 원거리 차례면 돌진을 미룬다
						and (tRoot.Position - rootPos).Magnitude <= (def.DashRange or 12)
						-- HeavyCharge 몹은 돌진을 중거리 전용으로 둔다 — 밀착은 근접 스타일(Slam)이 받는다
						and (not def.HeavyCharge or (tRoot.Position - rootPos).Magnitude > def.AttackRange)
						and (not def.SpinRadius or (tRoot.Position - rootPos).Magnitude > def.AttackRange)
						and os.clock() - st.LastAtkAt >= def.AtkInterval then
						-- 돌진: 근접 도달 전 DashRange에서 선제 발동
						-- SpinRadius 몹은 밀착을 스핀에 양보 — 돌진은 중거리 전용
						if tryBeginAttack(st, tRoot, tHum) then
							hum:MoveTo(rootPos)
							task.spawn(performDash, st)
						end
					elseif throwReady then
						-- 흙덩이 투척: 중거리 견제(근접은 Slam 유지)
						if tryBeginAttack(st, tRoot, tHum) then
							st.NextThrowAt = os.clock() + (def.ThrowCooldown or 5)
							lastThrowGlobalAt[model:GetAttribute("MonsterId")] = os.clock()
							hum:MoveTo(rootPos)
							-- [2026-09-07] def.Spray 몹(술독 정령)은 투사체 대신 부채꼴 분사 — 사거리·쿨 필드는 공용
							task.spawn(def.Spray and performSpray or (def.MaskThrow and performMaskThrow) or (def.StompWave and performStompWave) or ((def.PhantomMask or def.ShardVolley) and performPhantomMasks) or (def.RibbonSweep and performRibbonSweep) or (def.OrbLaunch and performOrbLaunch) or (def.PillarWall and performPillarWall) or performMudThrow, st)
						end
					elseif (tRoot.Position - rootPos).Magnitude <= def.AttackRange then
						st.TargetRoot, st.TargetHum = tRoot, tHum
						st.State = "Attack"
						hum:MoveTo(rootPos) -- 제자리 정지
					else
						st.TargetRoot, st.TargetHum = tRoot, tHum
						-- [2026-08-20 Z1 이식] OrbitChase: 정면으로 곧장 오지 않고 타겟 둘레를 돈다(도깨비불 "맴돌며").
						-- 매 틱 각도를 조금씩 진행시켜 접선 지점으로 MoveTo — 별도 루프 없이 기존 상태머신 안에서 처리.
						-- 돌진(Dash)은 위 분기가 AttackRange 안에서 가로채므로 "맴돌다 덮친다"가 된다.
						local orbit = def.OrbitChase
						-- [2026-08-20] 거리 유지: 선회가 없는 원거리 몹(버섯정령)은 후퇴 직후 곧장 다시
						-- 다가와, "거리 7 초과 + 공격간격 2.3초 경과"가 동시에 성립하는 창이 닫혔다
						-- (26초 실측 최대 8.4까지 물러났는데 투척 0회). 투척 차례엔 접근을 멈춘다.
						-- 도깨비불·박쥐는 선회가 그 역할을 하므로 이 분기를 타지 않는다.
						if not orbit and def.RangedPriority and def.ThrowRange
							and os.clock() >= (st.NextThrowAt or 0) then
							hum:MoveTo(rootPos)
						elseif orbit then
							local to = (rootPos - tRoot.Position) * Vector3.new(1, 0, 1)
							local odist = to.Magnitude
							local ang = (odist > 0.5) and math.atan2(to.Z, to.X) or (math.random() * math.pi * 2)
							st.OrbitDir = st.OrbitDir or (math.random() < 0.5 and -1 or 1) -- 개체마다 도는 방향 고정(팩이 한쪽으로 쏠리지 않게)
							ang += st.OrbitDir * (orbit.Speed or 1.5) * (AI.TickSec or 0.2)
							local r = orbit.Radius or 9
							local want = tRoot.Position + Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r)
							hum:MoveTo(want)
						else
							hum:MoveTo(tRoot.Position)
						end
					end
				end
			elseif st.State == "Attack" then
				-- 이미 시작된 AttackBusy 전조·판정은 위 분기에서 고정하고, 다음 공격을 고르기 전에는 최근접 대상으로 교체한다.
				local nearestRoot, nearestHum = nearestAlivePlayer(rootPos, def.LeashRange)
				if nearestRoot then
					st.TargetRoot, st.TargetHum = nearestRoot, nearestHum
				end
				local tRoot, tHum = st.TargetRoot, st.TargetHum
				if not (tRoot and tRoot.Parent and tHum and tHum.Health > 0) then
					st.TargetRoot, st.TargetHum = nil, nil
					st.State = "Chase" -- 다음 틱에 재타겟 또는 귀환 판단
				elseif (tRoot.Position - rootPos).Magnitude > def.AttackRange then
					st.State = "Chase"
				-- [2026-08-20] 원거리 몹 밀착 고착 해제: 한번 붙으면 Attack 상태를 못 벗어나
				-- 위의 후퇴 분기(Chase 소속)가 아예 실행되지 않았다. 투척 쿨이 차면 추격으로 되돌린다.
				elseif def.RangedPriority and def.ThrowRange and not st.AttackBusy
					and os.clock() >= (st.NextThrowAt or 0) then
					st.State = "Chase"
				elseif def.Cry and not st.AttackBusy
					and (tRoot.Position - rootPos).Magnitude <= (def.Cry.Radius or 10)
					and os.clock() - st.LastAtkAt >= def.AtkInterval
					and os.clock() >= (st.NextCryAt or 0) then
					if tryBeginAttack(st, tRoot, tHum) then
						st.NextCryAt = os.clock() + (def.Cry.Cooldown or 9)
						task.spawn(performCry, st)
					end
				else
					local now = os.clock()
					if now - st.LastAtkAt >= def.AtkInterval then
						-- [2026-08-24] 밀착에서도 쿨마다 순간이동으로 자리를 옮긴다.
						-- 노션 "순간이동하듯 이동한다"는 접근 기술이 아니라 이동 습성이라,
						-- 중거리 진입 때 1회만 쓰면 정체성이 안 드러난다(실측 16초에 1회).
						-- SpinRadius 보다 먼저 보되 쿨(BlinkCooldown)이 찼을 때만 — 평소는 Spin이 그대로 먹는다.
						if def.BlinkRange and os.clock() >= (st.NextBlinkAt or 0) then
							if tryBeginAttack(st, tRoot, tHum) then
								st.NextBlinkAt = os.clock() + (def.BlinkCooldown or 5)
								task.spawn(performBlink, st)
							end
						elseif def.DrumStomp and os.clock() >= (st.NextStompAt or 0) then
							-- 밀착에서도 쿨마다 제자리 점프 충격파 — 주 패턴이 주력으로 보이게 한다.
							if tryBeginAttack(st, tRoot, tHum) then
								st.NextStompAt = os.clock() + (def.DrumStomp.Cooldown or 6)
								task.spawn(performDrumStomp, st)
							end
						elseif def.PillarRise and os.clock() >= (st.NextPillarAt or 0) then
							-- 밀착에서도 발밑에서 장승을 솟게 한다
							if tryBeginAttack(st, tRoot, tHum) then
								st.NextPillarAt = os.clock() + (def.PillarRise.Cooldown or 7)
								task.spawn(performPillarRise, st)
							end
						elseif def.MaskDance then
							-- 탈 환영 연무: 부채 N장 동시 — 사이 틈이 안전 지대(회전 광역과 반대 성격)
							if tryBeginAttack(st, tRoot, tHum) then
								task.spawn(performMaskDance, st)
							end
						elseif def.FlameRing and os.clock() >= (st.NextFlameRingAt or 0) then
							-- 청염 링(밀착): 자기 중심 확산 링 — 밖으로 빠져야 산다. 쿨 중이면 아래 Slam이 받는다.
							if tryBeginAttack(st, tRoot, tHum) then
								st.NextFlameRingAt = os.clock() + (def.FlameRing.Cooldown or 4)
								task.spawn(performStompWave, st)
							end
						elseif def.SpinRadius then
							-- 밀착 회전 후려치기 광역(SpinRadius 몹)
							-- [2026-09-07] SpinCooldown(선택): 쿨 중에는 이 분기에 머물며 대기한다 — 아래 무전조 기본타로 흘러내리지 않게.
							-- 미지정 몹(짗짜·당근 등)은 NextSpinAt이 nil이라 종전과 동일.
							if os.clock() >= (st.NextSpinAt or 0) and tryBeginAttack(st, tRoot, tHum) then
								if def.SpinCooldown then
									st.NextSpinAt = os.clock() + def.SpinCooldown
								end
								task.spawn(performSpin, st)
							end
						elseif def.AttackStyle == "Dash" then
							-- 근접 밀착 상태도 돌진으로 공격(최소 길이 6)
							if tryBeginAttack(st, tRoot, tHum) then
								task.spawn(performDash, st)
							end
						elseif def.AttackStyle == "Slam" then
							if tryBeginAttack(st, tRoot, tHum) then
								task.spawn(performSlam, st)
							end
						elseif tryBeginAttack(st, tRoot, tHum) then
							PlayerDamageService.Apply(tHum, def.Atk) -- 생존·거리 재확인 후 타격
							finishAttack(st)
						end
					end
				end
			elseif st.State == "Return" then
				hum.WalkSpeed = def.WalkSpeed -- 귀환은 항상 전속(반속 산책 잔류 방지)
				-- 도착 판정은 수평(XZ) 거리: SpawnPos.Y는 '지면+모델높이/2+여유'라 루트 힙 높이와 수직 오차가 크면
				-- 3D 거리가 영원히 미달 → Return 갇힘(재어그로 불능)
				if ((rootPos - st.SpawnPos) * Vector3.new(1, 0, 1)).Magnitude < AI.ReturnArriveDist then
					st.State = "Idle"
					st.PullGraceUntil = nil -- [2026-08-12] 스폰 복귀 완료 = 상태 완전 원복
				else
					hum:MoveTo(st.SpawnPos)
				end
			end
		end
	end
end

-- 플레이어 타격 넉백: 공격자 반대 방향 짧은 밀림 + StunSec 동안 AI 정지.
-- 보스 제외는 호출측(CombatService IsBoss 판별) 몫. 패턴 시퀀스(앵커) 중에는 미적용.
-- KnockbackPlayer: 캐릭터=클라 소유 → PlayerKnockback 리모트로 위임(연출 전용, 피해는 서버 이미 확정)
function MonsterService.KnockbackPlayer(player, fromPos, force, lift)
	local character = player.Character
	local proot = character and character:FindFirstChild("HumanoidRootPart")
	if not proot then
		return
	end
	local dir = proot.Position - fromPos
	Net.Event("PlayerKnockback"):FireClient(player, {
		dir = Vector3.new(dir.X, 0, dir.Z),
		force = force or 40,
		lift = lift or 10,
	})
end

-- opts(선택): { Speed, UpSpeed, StunSec } 오버라이드 — 미지정 시 AI.HitKnockback(일반 피격 넉백). 끌어당기기 등 강화 넉백용.
-- control(선택): { KnockbackScale, StunScale } — 지상 평타 타입 보정 전용. opts와 분리해 기존 스킬·캔슬 면역 의미를 보존한다.
function MonsterService.ApplyHitKnockback(model, attackerPos, opts, control)
	local st = active[model]
	if not st then
		return
	end
	-- [2026-07-25 QA] 반격 추격: 타격(공격/스킬) 시 거리 무관 무조건 추적(구 RetaliateRange 20 게이트 폐지 — 사장님 확정).
	-- 대상 = 몬스터 현재 위치 기준 최근접 플레이어. 피해량·최초 공격자와 무관하게 다음 AI 틱에도 최근접을 유지한다.
	-- [2026-08-12] Pull(opts.Sustain)은 Chase/Attack 중이어도 반격 추격으로 전환한다.
	--   스폰 기준 리쉬(def.LeashRange 26~34)로 판정하면 끌려온 즉시 이탈로 오판돼 그 자리에서 돌아간다.
	--   이탈 판정 = Chase 틱의 RetaliateChase 경로(평시 RetaliateBreakDist · 유예 중 PullLeash.BreakDist).
	local pulled = (opts ~= nil and opts.Sustain == true)
	if pulled then
		st.PullGraceUntil = os.clock() + ((AI.PullLeash and AI.PullLeash.GraceSec) or 3)
	end
	if pulled or st.State == "Idle" or st.State == "Return" then
		-- [2026-08-25 파티 AI] 공격자 좌표 대신 몬스터 몸을 기준으로 최근접 대상을 고른다.
		local tRoot, tHum = nearestAlivePlayer(st.Root.Position, math.huge)
		if tRoot then
			st.TargetRoot, st.TargetHum = tRoot, tHum
			st.RetaliateChase = true
			st.State = "Chase"
			st.Humanoid.WalkSpeed = st.Def.WalkSpeed
		end
	end
	if st.AttackBusy then
		-- 긴 앵커 패턴도 피격 반응을 잃지 않도록 최신 요청 1회만 보관한다.
		st.PendingHitKnockback = { AttackerPos = attackerPos, Opts = opts, Control = control }
		-- 캔슬 면역은 공격 중단만 막고, 저장한 넉백은 finishAttack 직후 적용한다.
		local nowC = os.clock()
		local cancelImmune = st.CancelImmuneUntil and nowC < st.CancelImmuneUntil
		if not cancelImmune or opts then
			st.CancelImmuneUntil = nowC + (AI.CancelImmuneSec or 0)
			st.Cancelled = true -- pattern epilogue reads this to shorten the retry cooldown
			st.KbInterrupt = true -- 윈드업/이동/투척 루프가 프레임 단위로 감지
		end
		return
	end
	local kb = opts or AI.HitKnockback -- [2026-07-22] 강화 넉백 오버라이드(끌어당기기)
	local root = st.Root
	local hum = st.Humanoid
	if not (kb and root and root.Parent and hum) or root.Anchored then
		return
	end
	local knockbackScale = math.clamp(tonumber(control and control.KnockbackScale) or 1, 0.8, 1.2)
	local stunScale = math.clamp(tonumber(control and control.StunScale) or 1, 0.8, 1.2)
	local knockbackSpeed = kb.Speed * knockbackScale
	local knockbackUpSpeed = kb.UpSpeed * knockbackScale
	local stunSec = kb.StunSec * stunScale
	local dir = (root.Position - attackerPos) * Vector3.new(1, 0, 1)
	if dir.Magnitude < 0.05 then
		return
	end
	dir = dir.Unit
	st.StunnedUntil = os.clock() + stunSec
	-- 속도 재주입 방식은 서 있는 휴머노이드 모터가 매 프레임 상쇄해 거의 안 밀림(실측).
	-- Physics 상태로 모터를 잠깐 끄고 단발 임펄스 → 경직 후 GettingUp 복구(단발 코루틴 — 상시 루프 아님)
	st.KbToken = (st.KbToken or 0) + 1
	local token = st.KbToken
	task.spawn(function()
		hum:Move(Vector3.zero, false) -- 진행 중이던 이동 의도 즉시 중단
		hum:ChangeState(Enum.HumanoidStateType.Physics)
		root.AssemblyAngularVelocity = Vector3.zero -- Physics 진입 시 회전 관성 제거(경사면 구름 방지)
		root.AssemblyLinearVelocity = dir * knockbackSpeed + Vector3.new(0, knockbackUpSpeed, 0)
		if kb.Sustain then
			-- 흡입 시 서버 소유로 고정(복원 안 함) — 자동 소유권(전투 중=플레이어 클라)이면 서버 속도 주입이 클라 시뮬과 싸워 도착점이 들쭉날쭉.
			pcall(function()
				root:SetNetworkOwner(nil)
			end)
			-- 끌어당기기 전용: 경직 창 동안 수평 속도를 매 프레임 재주입 — 단발 임펄스는 지면 마찰로 약 0.2초에 죽어 이동거리가 Speed×StunSec의 50~70%.
			-- 일반 피격 넉백(단발)은 기존 그대로.
			local t0 = os.clock()
			local hvel = dir * knockbackSpeed
			while os.clock() - t0 < stunSec do
				if st.KbToken ~= token or not root.Parent or hum.Health <= 0 or root.Anchored then
					return
				end
				local vy = root.AssemblyLinearVelocity.Y
				root.AssemblyLinearVelocity = Vector3.new(hvel.X, vy, hvel.Z)
				task.wait()
			end
		else
			task.wait(stunSec)
		end
		if st.KbToken ~= token or not root.Parent or hum.Health <= 0 then
			return -- 후속 넉백/사망이 인수 — 복구는 최신 호출 몸
		end
		if not root.Anchored then
			local vy = root.AssemblyLinearVelocity.Y
			root.AssemblyLinearVelocity = Vector3.new(0, math.min(vy, 0), 0) -- 잔류 미끄러짐 제거(하강은 유지)
		end
		hum:ChangeState(Enum.HumanoidStateType.GettingUp) -- 모터 복구 → Running 재진입
		-- Physics 동안 모터가 꺼져 루트가 지형 아래로 파고들면
		-- 기상 후에도 박힘 — 기대 루트Y(지면+HipHeight+반높이) 미달이면 지면 스냅 복원
		task.wait(0.15)
		if st.KbToken ~= token or not root.Parent or hum.Health <= 0 or root.Anchored then
			return
		end
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		local exclude = { st.Model, monstersFolder }
		local markersFolder = Workspace:FindFirstChild("_Markers")
		if markersFolder then
			table.insert(exclude, markersFolder)
		end
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Character then
				table.insert(exclude, plr.Character)
			end
		end
		rp.FilterDescendantsInstances = exclude
		local hit = Workspace:Raycast(root.Position + Vector3.new(0, 40, 0), Vector3.new(0, -160, 0), rp)
		-- Physics 중 충돌로 기울어진 몸 직립 복원
		local tilted = root.CFrame.UpVector.Y < 0.95
		if hit then
			local expectedY = hit.Position.Y + hum.HipHeight + root.Size.Y * 0.5
			if root.Position.Y < expectedY - 0.75 or tilted then
				local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
				look = look.Magnitude > 0.05 and look.Unit or Vector3.new(0, 0, 1)
				local y = math.max(root.Position.Y, expectedY) -- 박힘만 끌어올림(공중은 중력 복귀)
				if root.Position.Y < expectedY - 0.75 then
					y = expectedY
				end
				root.CFrame = CFrame.lookAt(Vector3.new(root.Position.X, y, root.Position.Z), Vector3.new(root.Position.X + look.X, y, root.Position.Z + look.Z))
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end
		elseif tilted then
			local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
			look = look.Magnitude > 0.05 and look.Unit or Vector3.new(0, 0, 1)
			root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end)
end

-- [2026-08-20] 보스 소환 스폰(마커 없는 1회성) — 임시 마커를 만들어 기존 spawnAt 경로를 그대로 태운다.
-- 이유: AI·애니·피격·넉백 전부가 spawnAt이 만드는 active[] 항목에 얽혔 있다 — 별도 경로를 파면 이중 구현이 된다.
-- 사망 시 마커를 파괴해 리스폰 체인을 끕는다(spawnAt의 marker.Parent 검사가 스스로 멈춰준다).
function MonsterService.SpawnSummon(monsterId, position, opts)
	local def = MonsterDefs[monsterId]
	if not def then
		warn(("[MonsterService] 소환 def 없음: %s"):format(tostring(monsterId)))
		return nil
	end
	opts = opts or {}
	local marker = Instance.new("Part")
	marker.Name = "SummonMarker_" .. monsterId
	marker.Size = Vector3.new(1, 1, 1)
	marker.Transparency = 1
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false -- 지면 레이추스트에 잡히면 자기 마커 위에 스폰된다
	marker.CanTouch = false
	marker.Position = position
	marker:SetAttribute("MonsterId", monsterId)
	marker:SetAttribute("Summoned", true)
	marker:SetAttribute("ScatterRadius", opts.Scatter or 0)
	-- 전용 폴더에 보관: monstersFolder에 두면 클라이언트 몬스터 스캔이 Part를 모델로 오인한다
	marker.Parent = ensureFolder(Workspace, "_SummonMarkers")
	local model = spawnAt(marker)
	if not model then
		marker:Destroy()
		return nil
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Connect(function()
			marker:Destroy() -- 리스폰 차단
		end)
	end
	-- 안전망: 전투가 어떻게 끝나든 수명 초과 소환체는 자동 소멸(방치 누적 방지)
	local life = opts.Lifetime or 60
	task.delay(life, function()
		if marker.Parent then
			marker:Destroy()
		end
		if model.Parent then
			model:Destroy()
		end
	end)
	return model
end

function MonsterService.Init()
	Scheduler = require(script.Parent:WaitForChild("Scheduler"))
	CombatService = require(script.Parent:WaitForChild("CombatService"))
	-- [2026-07-21] 피격 넉백 핸들러 주입 — CombatService 측 인라인 require 폐지(순환 경고 해소)
	CombatService.SetHitKnockback(MonsterService.ApplyHitKnockback)
end

function MonsterService.Start()
	monstersFolder = ensureFolder(ensureFolder(Workspace, "_Runtime"), "Monsters")

	CombatService.OnKilled(function(model)
		retire(model)
	end)

	-- 몬스터·보스 공용 애니 부착: 이미 있는 태그 + 이후 스폰 모두 (마커 루프보다 먼저 연결)
	for _, model in ipairs(CollectionService:GetTagged(MONSTER_TAG)) do
		task.defer(attachMonsterAnimations, model)
	end
	CollectionService:GetInstanceAddedSignal(MONSTER_TAG):Connect(function(model)
		task.defer(attachMonsterAnimations, model)
	end)

	for _, marker in ipairs(CollectionService:GetTagged(MARKER_TAG)) do
		adoptMarker(marker)
	end
	CollectionService:GetInstanceAddedSignal(MARKER_TAG):Connect(adoptMarker)

	Scheduler.Register("MonsterAI", AI.TickSec, aiTick)
end

return MonsterService