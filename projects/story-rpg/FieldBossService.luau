-- FieldBossService: MonsterDefs의 IsBoss=true 개체를 SpawnMarker 태그+MonsterId 마커로 전부 채택해 다중 구동.
-- 공용 파이프라인: 스폰·존 타겟팅·전조 원반·무인 리셋·체력바 동기·재소환 카운트다운·기여 게이팅. 패턴은 def 필드 게이트.
-- 제약: 수치는 MonsterDefs·GameConfig, 문구는 Strings에서만. 주기 작업은 Scheduler 2건(BossAI/BossHpSync)만.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Defs = ReplicatedStorage:WaitForChild("Defs")
local MonsterDefs = require(Defs:WaitForChild("MonsterDefs"))
local AVDefs = require(Defs:WaitForChild("AVDefs"))
local WolfDifficultyDefs = require(Defs:WaitForChild("WolfDifficultyDefs"))
local WeaponDefs = require(Defs:WaitForChild("WeaponDefs"))
local GameConfig = require(Defs:WaitForChild("GameConfig"))
local MovementDefs = require(Defs:WaitForChild("MovementDefs")) -- [버그4] 슬로우 기준 속도(걷기 기본값) 단일 출처
local Strings = require(Defs:WaitForChild("Strings"))
local Net = require(ReplicatedStorage:WaitForChild("Net"))
local PlayerDamageService = require(script.Parent:WaitForChild("PlayerDamageService"))
local MonsterProcAnim = require(script.Parent:WaitForChild("MonsterProcAnim")) -- 게시 애니 없는 보스(숲지기 등) 절차 애니

local FieldBossService = {}

-- 순환 require 방지: 형제 서비스는 Init 시점에 resolve
local Scheduler
local CombatService
local PlayerService
local DataService
local AnalyticsService
local MonsterService
local CosmeticService
local notifyCc
local pickTarget

local AI = MonsterDefs.AI
local MONSTER_TAG = "Monster"
local MARKER_TAG = "SpawnMarker"
-- [2026-07-30] 복귀 완료 후 입구 방향으로 되돌리는 틱당 보간 계수(0~1). 클수록 빨리 돌아본다.
local IDLE_TURN_ALPHA = 0.25
local BOSS_COLLISION_GROUP = "CH1_Boss"
local PLAYER_COLLISION_GROUP = "CH1_PlayerChar"

local DISABLED_STATES = {
	Enum.HumanoidStateType.Climbing, Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.PlatformStanding, Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Seated, Enum.HumanoidStateType.StrafingNoPhysics,
	Enum.HumanoidStateType.Jumping,
}

-- 표시 전용 상수 (판정 수치는 전부 Defs)
local TELEGRAPH_THICKNESS = 0.2
local TELEGRAPH_Y_OFFSET = 0.1
local TELEGRAPH_TRANSPARENCY = 0.45
local TELEGRAPH_COLOR = Color3.fromRGB(255, 60, 40)
local BIND_TELEGRAPH_COLOR = Color3.fromRGB(90, 200, 80) -- 뿌리 속박(초록)
local FIRE_TELEGRAPH_COLOR = Color3.fromRGB(255, 140, 30) -- 불장판(주황)
local COUNTDOWN_HEIGHT_STUDS = 8
local COUNTDOWN_GUI_SIZE = UDim2.fromOffset(220, 48)
local COUNTDOWN_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local ROLL_TELEGRAPH_COLOR = Color3.fromRGB(240, 200, 90)
-- [2026-07-27] 전방 선언 — startTelegraph가 전조 원반 지면 스냅에 사용(정의는 아래 '공용 지면/경로 헬퍼')
local rollGroundY
local ROLL_BALL_COLOR = Color3.fromRGB(227, 190, 88)
local ROLL_HIT_BOX_HEIGHT = 7

-- ===== 런타임 =====
local bossFolder
local runtimes = {} -- [bossId] = rt (아래 필드 참조)
local modelToRt = {} -- [model] = rt
local lastSent = {} -- [player] = { BossId, Active, Hp, My, Total }
-- 존 표시 이탈 패드: 표시 중(lastSent.Active)인 보스만 이탈 반경 +18 — 넉백이 경계를 스치면 HP바/보스카메라가 깜빡인다(실측 61.7스터드 vs 반경 60). 진입 판정은 불변.
local ZONE_EXIT_PAD = 18

local function ensureFolder(parent, name)
	local folder = parent:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = parent
	end
	return folder
end

-- pad: 이탈 히스테리시스(스터드). 원형 마당은 XZ 원통으로 판정해 경사·점프 때문에 전투가 끊기지 않게 한다.
local function isInZone(rt, position, pad)
	local extra = pad or 0
	local offset = position - rt.ZoneCenter
	local halfHeight = tonumber(rt.Def.ZoneHalfHeight)
	if not halfHeight then
		return offset.Magnitude <= rt.Def.ZoneRadius + extra -- 기존 보스의 3D 구 판정 보존
	end
	if math.abs(offset.Y) > halfHeight + extra then
		return false
	end
	local horizontal = Vector3.new(offset.X, 0, offset.Z)
	return horizontal.Magnitude <= rt.Def.ZoneRadius + extra
end

-- [2026-08-04] 추격 목적지 존 클램프 — 존 밖 좌표로는 걷지 않는다(제단 입구·벽 끼임 방어)
local function clampChasePos(rt, pos)
	local c = rt.ZoneCenter or rt.SpawnPos
	if not c then
		return pos
	end
	local off = Vector3.new(pos.X - c.X, 0, pos.Z - c.Z)
	local model = rt.Model
	local bodyRadius = model and tonumber(model:GetAttribute("HitRadius")) or 0
	local maxR = math.max(2, (rt.Def.ZoneRadius or 60) - bodyRadius - 6)
	if off.Magnitude <= maxR then
		return pos
	end
	return Vector3.new(c.X + off.Unit.X * maxR, pos.Y, c.Z + off.Unit.Z * maxR)
end

-- [2026-08-08] 돌진 거리 존 클램프: origin에서 dir(수평 단위벡터)로 나아갈 때 존 경계(반경-4)까지의 허용 거리로 잘라낸다.
-- 앵커 CFrame 슬라이드는 충돌을 무시하고 게이트·벽을 뚫으므로(짚찌왕 존 이탈 실사고) 출발 전에 거리 자체를 줄이는 것이 안전선.
local function clampDashDist(rt, origin, dir, dist)
	local c = rt.ZoneCenter or rt.SpawnPos
	if not c then
		return dist
	end
	local model = rt.Model
	local bodyRadius = model and tonumber(model:GetAttribute("HitRadius")) or 0
	local maxR = math.max(2, (rt.Def.ZoneRadius or 60) - bodyRadius - 6)
	local ox, oz = origin.X - c.X, origin.Z - c.Z
	local od = ox * dir.X + oz * dir.Z
	local oo = ox * ox + oz * oz
	if oo >= maxR * maxR then
		-- 경계 링 위/밖: 바깥 방향은 0, 안쪽(재진입) 방향은 먼 교점까지 허용 — 클램프된 돌진 종점이 정확히 링 위라 가장자리 전투에서 돌진이 침묵하던 것 방지
		if od >= 0 then
			return 0
		end
		local d2 = od * od - (oo - maxR * maxR)
		if d2 < 0 then
			return 0
		end
		return math.min(dist, math.max(0, -od + math.sqrt(d2)))
	end
	local disc = od * od - (oo - maxR * maxR)
	if disc < 0 then
		return dist
	end
	return math.min(dist, math.max(0, -od + math.sqrt(disc)))
end

local function alivePlayerParts(player)
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local proot = character and character:FindFirstChild("HumanoidRootPart")
	if hum and hum.Health > 0 and proot then
		return proot, hum
	end
	return nil, nil
end

-- 패턴 루프용 플레이어 스냅샷: 0.5초마다 재열거, 매 프레임은 root.Parent·Health>0만 검사
local SNAPSHOT_REFRESH_SEC = 0.5

local function capturePlayerSnapshot()
	local snap = { list = {}, at = os.clock() }
	for _, player in ipairs(Players:GetPlayers()) do
		local proot, hum = alivePlayerParts(player)
		if proot then
			snap.list[#snap.list + 1] = { player = player, root = proot, hum = hum }
		end
	end
	return snap
end

local function snapshotAlive(snap)
	if os.clock() - snap.at >= SNAPSHOT_REFRESH_SEC then
		local fresh = capturePlayerSnapshot()
		snap.list, snap.at = fresh.list, fresh.at
	end
	return snap.list
end

-- 전조 외곽선은 경고 영역이며 실제 피해는 이보다 안쪽에서만 발생한다.
-- 플레이어 루트 위치를 점으로 판정해 화면 밖 피격과 경계선 억울함을 없앤다.
local HITBOX_EDGE_GRACE = math.max(0, tonumber(GameConfig.BOSS.HitboxEdgeGrace) or 0.75)
local function fairRadius(radius)
	return math.max(0.25, (tonumber(radius) or 0.25) - HITBOX_EDGE_GRACE)
end

local function fairHalfWidth(width)
	return fairRadius((tonumber(width) or 1) * 0.5)
end

local function withinFairRadius(a, b, radius)
	local dx, dz = a.X - b.X, a.Z - b.Z
	local r = fairRadius(radius)
	return dx * dx + dz * dz <= r * r
end

-- ===== 전조 원반(기본 공격 §6.2 — 원본 보존) =====

local function clearTelegraph(rt)
	if rt.TelegraphPart then
		rt.TelegraphPart:Destroy()
		rt.TelegraphPart = nil
	end
	rt.TelegraphPos = nil
	rt.TelegraphEndAt = nil
end

local function makeDisc(pos, radius, color, lifeSec)
	local part = Instance.new("Part")
	part.Name = "BossTelegraph"
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(TELEGRAPH_THICKNESS, radius * 2, radius * 2)
	part.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = TELEGRAPH_TRANSPARENCY
	part.Parent = bossFolder
	if lifeSec then
		Debris:AddItem(part, lifeSec)
	end
	return part
end

-- makeTimedDisc: 전조 원 + 안쪽 채움 원이 windup 동안 0→full 확장(가득 차면 임팩트 타이밍). 버스트 공격용.
local function makeTimedDisc(pos, radius, color, windup)
	local dur = windup or 0.5
	local outer = makeDisc(pos, radius, color, dur + 0.15)
	-- ImpactIn 어트리뷰트로 임팩트 시점을 클라에 전달 — 없으면 FxController가 모든 전조 원반에 StrawBoss.TelegraphSec를 써서 머드킹 간헐천(0.24초 간격 7지점)의 임팩트음이 어긋난다
	outer:SetAttribute("ImpactIn", dur)
	local fill = Instance.new("Part")
	fill.Name = "BossTelegraphFill"
	fill.Shape = Enum.PartType.Cylinder
	fill.Anchored = true
	fill.CanCollide = false
	fill.CanQuery = false
	fill.CanTouch = false
	fill.CastShadow = false
	fill.Material = Enum.Material.Neon
	fill.Color = color:Lerp(Color3.new(1, 1, 1), 0.65)
	fill.Transparency = 0.08
	fill.CFrame = CFrame.new(pos + Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90))
	fill.Size = Vector3.new(TELEGRAPH_THICKNESS * 1.3, 0.2, 0.2)
	fill.Parent = bossFolder
	Debris:AddItem(fill, dur + 0.15)
	game:GetService("TweenService"):Create(fill, TweenInfo.new(dur, Enum.EasingStyle.Linear), {
		Size = Vector3.new(TELEGRAPH_THICKNESS * 1.3, radius * 2, radius * 2),
	}):Play()
	return outer
end

-- 공격 실애니(AVDefs.MonsterAnims[id].Attack): 전조 시작과 함께 재생, 트랙은 rt 캐시(spawnBoss가 비움 — 구 모델 트랙 재사용 방지). 미정의 보스는 스킵.
-- 보스 키프레임 트랙은 전부 Action2 — 겹쳐 돌면 두 포즈가 블렌드돼 뭉개진다. 새 동작 직전에 나머지를 끊어 항상 1개만(keep = 지금 틀 트랙).
-- [2026-08-20] 절차 패턴 클립 재생 창을 rt에 기록 — bossAnimPlaying이 이걸 보고 절차 조인트 모션을 양보시킨다.
-- ★없으면 MonsterProcAnim(Heartbeat마다 C0 갱신)과 bossAttackMotion·zoneSlamMotion(while 루프)이
-- 같은 Motor6D.C0를 번갈아 덮어써 포즈가 떨리고, 더 나쁜 건 절차 모션이 변형된 C0를 원본으로 캐시해
-- 종료 시 그 값으로 "복원"한다 = 포즈 누적 드리프트.
local function playProcClip(rt, key)
	if not MonsterProcAnim.Play(rt.Model, key) then
		return false -- 클립 미등록 — 기존대로 절차 모션이 담당
	end
	local set = AVDefs.MonsterProcAnims and AVDefs.MonsterProcAnims[rt.Id]
	local clip = set and set[key]
	rt.ProcClipUntil = os.clock() + ((clip and clip.Dur) or 0.6)
	return true
end

local function stopBossAnims(rt, keep)
	if rt.AttackTrack and rt.AttackTrack ~= keep and rt.AttackTrack.IsPlaying then
		rt.AttackTrack:Stop(0.1)
	end
	if rt.PatternTracks then
		for key, track in pairs(rt.PatternTracks) do
			if track ~= keep and track.IsPlaying then
				local markerState = rt.PatternMarkerStates and rt.PatternMarkerStates[key]
				if markerState then markerState.CancelledGeneration = markerState.Generation end
				track:Stop(0.1)
			end
		end
	end
end

local function playBossAttackAnim(rt)
	local animDef = AVDefs.MonsterAnims[rt.Id]
	local animId = animDef and animDef.Attack
	if not animId or animId == "" then
		playProcClip(rt, "Attack") -- 절차 폴백(미등록이면 no-op)
		return
	end
	if not rt.AttackTrack then
		local hum = rt.Humanoid
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if not animator then
			return
		end
		local anim = Instance.new("Animation")
		anim.Name = "BossAttack"
		anim.AnimationId = animId
		local ok, track = pcall(animator.LoadAnimation, animator, anim)
		if not ok or not track then
			return
		end
		track.Priority = Enum.AnimationPriority.Action2
		track.Looped = false
		rt.AttackTrack = track
	end
	stopBossAnims(rt, rt.AttackTrack) -- 직전 패턴 트랙 잔여 컷
	if rt.AttackTrack.IsPlaying then
		rt.AttackTrack:Stop(0)
	end
	rt.AttackTrack:Play(0.1)
end

-- 패턴별 실애니(AVDefs.MonsterAnims[id].Patterns[key]): 패턴 시작과 함께 1회 재생.
-- 늑대 슬롯은 Swing/Hit/Reset 마커 상태도 함께 반환한다. 마커가 없거나 자산이 비어 있으면 호출측이 기존 시간값으로 폴백한다.
local function playBossPatternAnim(rt, key)
	if rt.Id == "Wolf" and rt.Model then
		rt.Model:SetAttribute("WolfLocomotionMode", "Stop")
	end
	local animId
	if rt.Id == "Wolf" and rt.Model then
		local saves = rt.Model:FindFirstChild("AnimSaves")
		local difficultyFolder = saves and saves:FindFirstChild(WolfDifficultyDefs.AnimationFolder)
		local slot = difficultyFolder and difficultyFolder:FindFirstChild(key)
		if slot and slot:IsA("Animation") and slot.AnimationId ~= "" then
			animId = slot.AnimationId
		end
	end
	if not animId then
		local animDef = AVDefs.MonsterAnims[rt.Id]
		local patterns = animDef and animDef.Patterns
		animId = patterns and patterns[key]
	end
	if not animId or animId == "" then
		playProcClip(rt, key)
		return false
	end
	rt.PatternTracks = rt.PatternTracks or {}
	local track = rt.PatternTracks[key]
	if not track then
		local hum = rt.Humanoid
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if not animator then return false end
		local anim = Instance.new("Animation")
		anim.Name = "BossPattern_" .. key
		anim.AnimationId = animId
		local ok, loaded = pcall(animator.LoadAnimation, animator, anim)
		if not ok or not loaded then return false end
		loaded.Priority = Enum.AnimationPriority.Action2
		loaded.Looped = false
		rt.PatternTracks[key] = loaded
		track = loaded
	end

	local markerState, generation
	if rt.Id == "Wolf" then
		rt.PatternMarkerStates = rt.PatternMarkerStates or {}
		markerState = rt.PatternMarkerStates[key]
		if not markerState or markerState.Track ~= track then
			markerState = { Track = track, Generation = 0, Reached = {}, Params = {}, Model = rt.Model, Humanoid = rt.Humanoid }
			rt.PatternMarkerStates[key] = markerState
			for _, markerName in ipairs({ "Swing", "Hit", "Reset" }) do
				local marker = markerName
				track:GetMarkerReachedSignal(marker):Connect(function(param)
					local currentGeneration = markerState.Generation
					markerState.Reached[marker] = currentGeneration
					markerState.Params[marker] = param
					if rt.Model == markerState.Model and rt.Model and rt.Model.Parent then
						rt.Model:SetAttribute("LastWolfAnimationMarker", key .. ":" .. marker)
						rt.Model:SetAttribute("LastWolfAnimationMarkerAt", os.clock())
					end
					if marker == "Swing" and rt.Model == markerState.Model and rt.Root and rt.Root.Parent then
						local soundDef = AVDefs.Sounds.WolfSwing or AVDefs.Sounds.Swing3
						if soundDef and soundDef.Id and soundDef.Id ~= "" then
							local sound = Instance.new("Sound")
							sound.Name = "WolfSwingMarkerSfx"
							sound.SoundId = soundDef.Id
							sound.Volume = math.min(soundDef.Volume or 0.7, 1.1)
							sound.PlaybackSpeed = soundDef.PlaybackSpeed or 0.9
							sound.RollOffMode = Enum.RollOffMode.InverseTapered
							sound.RollOffMaxDistance = 70
							sound.Parent = rt.Root
							sound:Play()
							Debris:AddItem(sound, 5)
						end
					end
				end)
			end
		end
	end

	-- [2026-08-27 사장님] 늑대 외 보스 마커 동기: animDef.Markers를 선언한 보스만 상태를 기록한다.
	-- 위 늑대 전용 분기(효과음 포함)는 그대로 두고, 여긴 순수 기록만 한다.
	if not markerState then
		local anims = AVDefs.MonsterAnims[rt.Id]
		local names = anims and anims.Markers
		if names then
			rt.PatternMarkerStates = rt.PatternMarkerStates or {}
			markerState = rt.PatternMarkerStates[key]
			if not markerState or markerState.Track ~= track then
				markerState = { Track = track, Generation = 0, Reached = {}, Params = {} }
				rt.PatternMarkerStates[key] = markerState
				for _, markerName in ipairs(names) do
					local marker = markerName
					track:GetMarkerReachedSignal(marker):Connect(function(param)
						markerState.Reached[marker] = markerState.Generation
						markerState.Params[marker] = param
					end)
				end
			end
		end
	end

	stopBossAnims(rt, track)
	if track.IsPlaying then track:Stop(0) end
	if markerState then
		markerState.Model = rt.Model
		markerState.Humanoid = rt.Humanoid
		markerState.Generation += 1
		generation = markerState.Generation
		table.clear(markerState.Reached)
		table.clear(markerState.Params)
	end
	-- 임팩트 마커가 def의 Windup 순간에 오도록 재생 속도를 맞춘다.
	-- 예: Boss_Attack은 Effect@0.60인데 ClubShock.Windup은 1.10 → 0.545배로 늘려 1.10에 때리게 한다.
	-- 이렇게 해야 회피 시간(밸런스)을 줄이지 않고도 모션과 피해가 같은 순간에 떨어진다.
	local impactTable = AVDefs.MonsterAnims[rt.Id] and AVDefs.MonsterAnims[rt.Id].ImpactAt
	local impactAt = impactTable and impactTable[key]
	local windupSec = impactAt and rt.Def[key] and tonumber(rt.Def[key].Windup)
	local playSpeed = 1
	if impactAt and windupSec and windupSec > 0.05 then
		playSpeed = math.clamp(impactAt / windupSec, 0.25, 2)
	end
	-- ★Play(fadeTime)은 재생 속도를 1로 되돌린다 — AdjustSpeed를 먼저 불러도 무효하다(실측).
	-- 반드시 Play의 세 번째 인자(speed)로 넘길 것.
	track:Play(0.08, 1, playSpeed)
	return true, track, markerState, generation
end

-- 마커 누락·로드 지연·트랙 중단에도 패턴 코루틴이 멈추지 않는 제한시간 대기.
-- true는 실제 마커 도달, false는 기존 수치 기반 폴백을 뜻한다.
function FieldBossService._waitWolfAnimationMarker(rt, markerState, generation, markerName, fallbackSec, maxWaitSec)
	local fallback = math.max(0, tonumber(fallbackSec) or 0)
	if not (markerState and generation and markerState.Track) then
		if fallback > 0 then task.wait(fallback) end
		return false
	end
	if markerState.Generation ~= generation or markerState.CancelledGeneration == generation
		or rt.Model ~= markerState.Model or rt.Humanoid ~= markerState.Humanoid then
		return false
	end
	if markerState.Reached[markerName] == generation then
		return true
	end
	local track = markerState.Track
	local started = os.clock()
	local remaining = fallback + 0.45
	if track.Length > 0 then
		remaining = math.max(0.08, track.Length - track.TimePosition + 0.15)
	end
	local timeout = math.clamp(math.max(fallback, remaining), 0.08, maxWaitSec or 2.5)
	local deadline = started + timeout
	while os.clock() < deadline do
		if markerState.Generation ~= generation or markerState.CancelledGeneration == generation
			or rt.Model ~= markerState.Model or rt.Humanoid ~= markerState.Humanoid then
			return false
		end
		if markerState.Reached[markerName] == generation then
			return true
		end
		if not (rt.Root and rt.Root.Parent and rt.Humanoid and rt.Humanoid.Health > 0) then
			return false
		end
		if not track.IsPlaying and os.clock() - started > 0.04 then
			break
		end
		RunService.Heartbeat:Wait()
	end
	local elapsed = os.clock() - started
	if elapsed < fallback then
		task.wait(fallback - elapsed)
	end
	if rt.Model == markerState.Model and rt.Model and rt.Model.Parent then
		rt.Model:SetAttribute("LastWolfMarkerFallback", tostring(markerName))
	end
	return markerState.Generation == generation and markerState.CancelledGeneration ~= generation
		and markerState.Reached[markerName] == generation
end

-- 키프레임 애니(AttackTrack+패턴 트랙) 재생 중이면 절차 조인트 모션은 스킵 — 절차는 Motor6D.C0, 애니는 Transform에 써서 겹치면 동작이 이중으로 꺾인다.
local function bossAnimPlaying(rt)
	if rt.ProcClipUntil and os.clock() < rt.ProcClipUntil then
		return true -- [2026-08-20] 절차 패턴 클립 재생 중 — 아래 절차 조인트 모션은 양보(C0 이중 구동 방지)
	end
	if rt.AttackTrack and rt.AttackTrack.IsPlaying then
		return true
	end
	if rt.PatternTracks then
		for _, track in pairs(rt.PatternTracks) do
			if track.IsPlaying then
				return true
			end
		end
	end
	return false
end

-- [v4.1] 보스 기본공격 몸통 모션(절차): 키프레임 공격애니 없는 보스용 — 윈드업에 뒤로 젖혔다 전조 종료 시점에 앞으로 내려침(+팔 스윙). root 앵커 기반이라 리그 무관, 종료 시 CFrame·조인트·앵커 복원.
-- [패턴 모션] 절차 조인트 모션 동시 실행 가드 — 늦게 시작한 모션이 변형 중인 C0를 원본으로 캐시하는 드리프트 방지
local jointMotionBusy = {} -- [rt] = true

-- 조인트 캐시(모델 약참조 키 — 재소환 새 모델은 새 엔트리): 캐시 항목 파괴(Parent=nil) 시에만 재스캔
local bossJointCache = setmetatable({}, { __mode = "k" }) -- [model] = { [namesKey] = Motor6D | false }
local stackJointCache = setmetatable({}, { __mode = "k" }) -- [model] = { Motor6D, ... }

local function findBossJoint(model, names)
	local key = table.concat(names, "|")
	local perModel = bossJointCache[model]
	if perModel then
		local hit = perModel[key]
		if hit == false then
			return nil
		end
		if hit and hit.Parent then
			return hit
		end
	else
		perModel = {}
		bossJointCache[model] = perModel
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") then
			for _, n in ipairs(names) do
				if d.Name == n or (d.Part1 and d.Part1.Name == n) then
					perModel[key] = d
					return d
				end
			end
		end
	end
	perModel[key] = false
	return nil
end

-- [패턴 모션] 팔/몸통 조인트가 없는 적층 리그(벽돌대왕=Brick01~04) 폴백용: 루트 직결 Motor6D를 높이순 수집
local function collectStackJoints(model)
	-- 조인트 발견만 캐시 — rest C0는 산개/합체 트위닝으로 변하므로 호출 시점에 재캡처
	local joints = stackJointCache[model]
	if joints then
		for _, j in ipairs(joints) do
			if not j.Parent or not j.Part1 then
				joints = nil
				break
			end
		end
	end
	if not joints then
		joints = {}
		local root = model:FindFirstChild("HumanoidRootPart")
		if root then
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("Motor6D") and d.Part0 == root and d.Part1 then
					joints[#joints + 1] = d
				end
			end
		end
		stackJointCache[model] = joints
	end
	local list = {}
	for _, j in ipairs(joints) do
		table.insert(list, { j = j, rest = j.C0, y = j.C0.Position.Y })
	end
	table.sort(list, function(a, b)
		return a.y < b.y
	end)
	local n = #list
	for i, e in ipairs(list) do
		e.rank = n > 1 and (i - 1) / (n - 1) or 1 -- 0=최하단, 1=최상단(위일수록 크게 움직임)
	end
	return list
end

local function bossAttackMotion(rt, dur, targetPos)
	-- [v4.1] 키프레임 애니가 '재생 중'일 때만 스킵 — [2026-07-29] 패턴 트랙까지 포함(bossAnimPlaying)
	if bossAnimPlaying(rt) then
		return
	end
	local root, hum = rt.Root, rt.Humanoid
	if not (root and root.Parent and hum and hum.Health > 0) then
		return
	end
	if jointMotionBusy[rt] then
		return -- [패턴 모션] 다른 절차 모션 진행 중(전조 여운 0.18s 등 짧은 겹침 창) — 스킵
	end
	jointMotionBusy[rt] = true
	dur = math.max(0.35, dur or rt.Def.TelegraphSec or 0.8)
	local rArm = findBossJoint(rt.Model, { "RightArm", "Right Arm" })
	local lArm = findBossJoint(rt.Model, { "LeftArm", "Left Arm" })
	local rC0 = rArm and rArm.C0
	local lC0 = lArm and lArm.C0
	local base = root.CFrame
	local tp = targetPos or rt.TelegraphPos
	if tp then
		local look = Vector3.new(tp.X, root.Position.Y, tp.Z)
		if (look - root.Position).Magnitude > 0.5 then
			base = CFrame.lookAt(root.Position, look)
		end
	end
	local wasAnchored = root.Anchored
	local prevAuto = hum.AutoRotate
	root.Anchored = true
	hum.AutoRotate = false
	local strikeAt = dur * 0.65
	local total = dur + 0.18
	local t0 = os.clock()
	while true do
		if not (root.Parent and hum.Health > 0) then
			break
		end
		local t = os.clock() - t0
		if t >= total then
			break
		end
		local pitch, arm
		if t < strikeAt then
			-- 윈드업: 뒤로 젯힘(상체 뒤로) + 팔 오버헤드로 치켜들기
			local a = t / strikeAt
			pitch = math.rad(22 * a)
			arm = math.rad(-125 * a)
		else
			-- 스트라이크: 앞으로 내리침(상체 숭) + 팔 휘두르기
			local a = math.min((t - strikeAt) / (total - strikeAt), 1)
			pitch = math.rad(22 - 54 * a)
			arm = math.rad(-125 + 125 * a)
		end
		root.CFrame = base * CFrame.Angles(pitch, 0, 0)
		if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(arm, 0, 0) end
		if lArm and lC0 then lArm.C0 = lC0 * CFrame.Angles(arm, 0, 0) end
		task.wait()
	end
	if root.Parent then
		root.CFrame = base
	end
	if rArm and rC0 and rArm.Parent then rArm.C0 = rC0 end
	if lArm and lC0 and lArm.Parent then lArm.C0 = lC0 end
	if root.Parent then
		root.Anchored = wasAnchored
	end
	if hum.Parent then
		hum.AutoRotate = prevAuto
	end
	jointMotionBusy[rt] = nil
end

-- [패턴 모션] 투척 1발 모션(performTripleThrow 발사별) — 조인트 전용(루트 무접촉: 발사 조준 lookAt과 무충돌).
-- 오른팔 치켜들기 → 전방 휘두르기 + 상체 스냅. 해당 조인트 없는 리그는 있는 것만 움직인다(전 보스 공용).
local function throwShotMotion(rt)
	local hum = rt.Humanoid
	if bossAnimPlaying(rt) then
		return -- [2026-07-29] 실애니 재생 중이면 절차 모션 양보(이중 꿈힘 방지)
	end
	if jointMotionBusy[rt] or not (rt.Model and rt.Model.Parent and hum and hum.Health > 0) then
		return
	end
	local rArm = findBossJoint(rt.Model, { "RightArm", "Right Arm" })
	local torso = findBossJoint(rt.Model, { "Torso", "UpperTorso", "Body" })
	-- [패턴 모션] 팔·몸통 없는 적층 리그(벽돌대왕): 스택 채챍 폴백(위 벽돌일수록 크게 젖혔다 스냅)
	local stack = (not rArm and not torso) and collectStackJoints(rt.Model) or nil
	if not (rArm or torso or (stack and #stack > 0)) then
		return
	end
	jointMotionBusy[rt] = true
	local rC0 = rArm and rArm.C0
	local tC0 = torso and torso.C0
	local windup, whip, recover = 0.12, 0.1, 0.12
	local t0 = os.clock()
	while true do
		if not (rt.Model.Parent and hum.Health > 0) then
			break
		end
		local t = os.clock() - t0
		local arm, lean
		if t < windup then
			-- 치켜들기: 팔 오버헤드 + 상체 뒤로
			local a = t / windup
			arm, lean = math.rad(-150 * a), math.rad(10 * a)
		elseif t < windup + whip then
			-- 휘두르기: 팔 전방 스윙 + 상체 앞으로 스냅
			local a = (t - windup) / whip
			arm, lean = math.rad(-150 + 175 * a), math.rad(10 - 24 * a)
		elseif t < windup + whip + recover then
			-- 복원(선형 복귀)
			local a = (t - windup - whip) / recover
			arm, lean = math.rad(25 * (1 - a)), math.rad(-14 * (1 - a))
		else
			break
		end
		if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(arm, 0, 0) end
		if torso and tC0 then torso.C0 = tC0 * CFrame.Angles(lean, 0, 0) end
		if stack then
			for _, e in ipairs(stack) do
				e.j.C0 = e.rest * CFrame.Angles(arm * 0.22 * (0.3 + 0.7 * e.rank), 0, 0)
			end
		end
		task.wait()
	end
	if rArm and rC0 and rArm.Parent then rArm.C0 = rC0 end
	if torso and tC0 and torso.Parent then torso.C0 = tC0 end
	if stack then
		for _, e in ipairs(stack) do
			if e.j.Parent then e.j.C0 = e.rest end
		end
	end
	jointMotionBusy[rt] = nil
end

-- [패턴 모션] 장판 소환 모션(performFireZone) — 웅크리며 양팔 치켜들기 → 전조 종료 시점 땅 내리찍기.
-- bossAttackMotion 관례(루트 앵커·타겟 조준·종료 복원) 재사용, 안무만 '땅 찍기'로 차별화(머드킹 진흙탕·벽돌대왕 불장판).
local function zoneSlamMotion(rt, dur, targetPos)
	if bossAnimPlaying(rt) then
		return -- [2026-07-29] 패턴 트랙 포함
	end
	local root, hum = rt.Root, rt.Humanoid
	if jointMotionBusy[rt] or not (root and root.Parent and hum and hum.Health > 0) then
		return
	end
	jointMotionBusy[rt] = true
	dur = math.max(0.35, dur or 0.9)
	local rArm = findBossJoint(rt.Model, { "RightArm", "Right Arm" })
	local lArm = findBossJoint(rt.Model, { "LeftArm", "Left Arm" })
	local rC0 = rArm and rArm.C0
	local lC0 = lArm and lArm.C0
	local base = root.CFrame
	if targetPos then
		local look = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
		if (look - root.Position).Magnitude > 0.5 then
			base = CFrame.lookAt(root.Position, look)
		end
	end
	local sink = math.min(rt.Model:GetExtentsSize().Y * 0.08, 2.5) -- 웅크림 깊이(몸집 비례·상한)
	local wasAnchored = root.Anchored
	local prevAuto = hum.AutoRotate
	root.Anchored = true
	hum.AutoRotate = false
	local slamAt = dur * 0.65
	local total = dur + 0.22
	local t0 = os.clock()
	while true do
		if not (root.Parent and hum.Health > 0) then
			break
		end
		local t = os.clock() - t0
		if t >= total then
			break
		end
		local pitch, arm, dy
		if t < slamAt then
			-- 차징: 웅크리며(하강) 양팔 오버헤드
			local a = t / slamAt
			pitch = math.rad(-8 * a)
			arm = math.rad(-155 * a)
			dy = -sink * a
		else
			-- 내리찍기: 상체 앞으로 꽂으며 양팔 지면으로
			local a = math.min((t - slamAt) / (total - slamAt), 1)
			pitch = math.rad(-8 - 26 * a)
			arm = math.rad(-155 + 185 * a)
			dy = -sink * (1 - a * 0.6)
		end
		root.CFrame = base * CFrame.new(0, dy, 0) * CFrame.Angles(pitch, 0, 0)
		if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(arm, 0, 0) end
		if lArm and lC0 then lArm.C0 = lC0 * CFrame.Angles(arm, 0, 0) end
		task.wait()
	end
	if root.Parent then
		root.CFrame = base
	end
	if rArm and rC0 and rArm.Parent then rArm.C0 = rC0 end
	if lArm and lC0 and lArm.Parent then lArm.C0 = lC0 end
	if root.Parent then
		root.Anchored = wasAnchored
	end
	if hum.Parent then
		hum.AutoRotate = prevAuto
	end
	jointMotionBusy[rt] = nil
end

-- [패턴 모션] 리프 양팔 모션(performLeapSlam cfg.ArmOverhead) — 상승하며 양팔 치켜들기, 착지 순간 내려침.
-- 루트 무접촉(비행 CFrame 루프와 병행) — 나무장군 '거대 광역 내려찍기'.
local function leapArmMotion(rt, airTime)
	local hum = rt.Humanoid
	if bossAnimPlaying(rt) then
		return -- [2026-07-29] 실애니 재생 중이면 절차 모션 양보
	end
	if jointMotionBusy[rt] or not (rt.Model and rt.Model.Parent and hum and hum.Health > 0) then
		return
	end
	local rArm = findBossJoint(rt.Model, { "RightArm", "Right Arm" })
	local lArm = findBossJoint(rt.Model, { "LeftArm", "Left Arm" })
	if not (rArm or lArm) then
		return
	end
	jointMotionBusy[rt] = true
	local rC0 = rArm and rArm.C0
	local lC0 = lArm and lArm.C0
	airTime = airTime or 1.1
	local raiseEnd = airTime * 0.3
	local slamStart = airTime * 0.92
	local slamEnd = airTime + 0.12
	local total = airTime + 0.3
	local t0 = os.clock()
	while true do
		if not (rt.Model.Parent and hum.Health > 0) then
			break
		end
		local t = os.clock() - t0
		if t >= total then
			break
		end
		local arm
		if t < raiseEnd then
			arm = math.rad(-155 * (t / raiseEnd)) -- 상승: 치켜들기
		elseif t < slamStart then
			arm = math.rad(-155) -- 체공: 유지
		elseif t < slamEnd then
			arm = math.rad(-155 + 185 * ((t - slamStart) / (slamEnd - slamStart))) -- 착지: 내려침
		else
			arm = math.rad(30 * (1 - (t - slamEnd) / (total - slamEnd))) -- 복원
		end
		if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(arm, 0, 0) end
		if lArm and lC0 then lArm.C0 = lC0 * CFrame.Angles(arm, 0, 0) end
		task.wait()
	end
	if rArm and rC0 and rArm.Parent then rArm.C0 = rC0 end
	if lArm and lC0 and lArm.Parent then lArm.C0 = lC0 end
	jointMotionBusy[rt] = nil
end

-- [패턴 모션] 뿌리 소환 모션(performRootBind) — 젖히며 양팔 치켜들기 → 땅에 꽂기 → 뿌리 부리는 동안 부르르 유지.
-- bossAttackMotion 관례(루트 앵커·타겟 조준·종료 복원) 재사용 — 나무장군 '뿌리 속박'.
local function rootPlantMotion(rt, dur, targetPos)
	if bossAnimPlaying(rt) then
		return -- [2026-07-29] 패턴 트랙 포함
	end
	local root, hum = rt.Root, rt.Humanoid
	if jointMotionBusy[rt] or not (root and root.Parent and hum and hum.Health > 0) then
		return
	end
	jointMotionBusy[rt] = true
	dur = math.max(0.35, dur or 0.9)
	local rArm = findBossJoint(rt.Model, { "RightArm", "Right Arm" })
	local lArm = findBossJoint(rt.Model, { "LeftArm", "Left Arm" })
	local rC0 = rArm and rArm.C0
	local lC0 = lArm and lArm.C0
	local base = root.CFrame
	if targetPos then
		local look = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
		if (look - root.Position).Magnitude > 0.5 then
			base = CFrame.lookAt(root.Position, look)
		end
	end
	local sink = math.min(rt.Model:GetExtentsSize().Y * 0.06, 2) -- 꽂을 때 웅크림 깊이(몸집 비례·상한)
	local wasAnchored = root.Anchored
	local prevAuto = hum.AutoRotate
	root.Anchored = true
	hum.AutoRotate = false
	local plantAt = dur * 0.5
	local plantedAt = dur * 0.72
	local total = dur + 0.15
	local t0 = os.clock()
	while true do
		if not (root.Parent and hum.Health > 0) then
			break
		end
		local t = os.clock() - t0
		if t >= total then
			break
		end
		local pitch, arm, dy
		if t < plantAt then
			-- 차징: 젖히며 양팔 치켜들기
			local a = t / plantAt
			pitch = math.rad(14 * a)
			arm = math.rad(-150 * a)
			dy = 0
		elseif t < plantedAt then
			-- 꽂기: 앞으로 숙이며 양팔 지면으로 + 웅크림
			local a = (t - plantAt) / (plantedAt - plantAt)
			pitch = math.rad(14 - 32 * a)
			arm = math.rad(-150 + 195 * a)
			dy = -sink * a
		else
			-- 유지: 꽂은 채 부르르(뿌리 부리는 중)
			local sh = math.sin((t - plantedAt) * 42)
			pitch = math.rad(-18 + 1.5 * sh)
			arm = math.rad(45 + 3 * sh)
			dy = -sink
		end
		root.CFrame = base * CFrame.new(0, dy, 0) * CFrame.Angles(pitch, 0, 0)
		if rArm and rC0 then rArm.C0 = rC0 * CFrame.Angles(arm, 0, 0) end
		if lArm and lC0 then lArm.C0 = lC0 * CFrame.Angles(arm, 0, 0) end
		task.wait()
	end
	if root.Parent then
		root.CFrame = base
	end
	if rArm and rC0 and rArm.Parent then rArm.C0 = rC0 end
	if lArm and lC0 and lArm.Parent then lArm.C0 = lC0 end
	if root.Parent then
		root.Anchored = wasAnchored
	end
	if hum.Parent then
		hum.AutoRotate = prevAuto
	end
	jointMotionBusy[rt] = nil
end

-- [난이도 A 2026-07-15] 예측 조준: DEF.LeadAim(0~1 배율) 게이트 — 타겟 수평 속도 × 리드시간만큼 앞 지점을 노린다.
-- '한 방향 계속 걷기 = 자동 회피'를 차단(멈춤·방향전환·대시 요구). 늑대·당근대장은 LeadAim 미등재=기존 고정 조준.
local function leadTargetPos(rt, targetRoot, leadSec)
	local pos = targetRoot.Position
	local f = rt.Def.LeadAim
	if not f or f <= 0 or not leadSec then
		return pos
	end
	local v = targetRoot.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
	local speed = math.min(v.Magnitude, 30)
	if speed < 2 then
		return pos -- 정지/미세 이동 = 리드 없음(제자리 플레이어 오발 방지)
	end
	return pos + v.Unit * speed * leadSec * f
end

local function startTelegraph(rt, targetRoot, targetHum, now)
	local DEF = rt.Def
	-- [난이도 A] 기본 전조도 LeadAim 게이트로 예측 조준(미등재 보스는 고정 조준)
	-- 전조 원반은 항상 지면에 스냅 — 예측 위치를 그대로 쓰면 점프 중 대상일 때 원반이 공중에 뜬다
	local aim = leadTargetPos(rt, targetRoot, DEF.TelegraphSec)
	local footPos = Vector3.new(aim.X, rollGroundY(rt, aim) + TELEGRAPH_Y_OFFSET, aim.Z)
	rt.TelegraphPos = footPos
	rt.TelegraphEndAt = now + DEF.TelegraphSec
	rt.NextCycleAt = now + DEF.AtkInterval

	-- 전투 중 간헐 그르렁(35% + 6초 간격)
	if rt.Root and rt.Root.Parent and now >= rt.NextGrowlAt and math.random() < 0.35 then
		rt.NextGrowlAt = now + 6
		local gdef = AVDefs.Sounds.BossGrowl
		if gdef and gdef.Id and gdef.Id ~= "" then
			local sound = Instance.new("Sound")
			sound.Name = "BossGrowl"
			sound.SoundId = gdef.Id
			sound.Volume = gdef.Volume or 0.7
			sound.PlaybackSpeed = gdef.PlaybackSpeed or 1
			sound.RollOffMode = Enum.RollOffMode.InverseTapered
			sound.RollOffMaxDistance = 100
			sound.Parent = rt.Root
			sound:Play()
			Debris:AddItem(sound, 6)
		end
	end
	rt.TelegraphPart = makeTimedDisc(footPos, DEF.TelegraphRadius, TELEGRAPH_COLOR, DEF.TelegraphSec)
	rt.TelegraphPart:SetAttribute("ImpactIn", DEF.TelegraphSec) -- 차오르는 원이 외곽선에 닿는 순간과 실제 판정 동기
	rt.TelegraphPart:SetAttribute("DamageRadius", fairRadius(DEF.TelegraphRadius)) -- 표시 원보다 0.75스텝 안쪽만 피해 판정
	playBossAttackAnim(rt) -- [2026-07-10] 전조와 동기화된 공격 모션(Attack 정의 보스만)
	task.spawn(bossAttackMotion, rt, rt.Def.TelegraphSec) -- [v4.1] 키프레임 없는 보스 절차 몸통 모션(전조 동기)
end

local function resolveTelegraph(rt)
	local center = rt.TelegraphPos
	clearTelegraph(rt)
	if not center then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local proot, hum = alivePlayerParts(player)
		if proot then
			local offset = proot.Position - center
			-- [2026-07-27] 지면 공격이므로 공중(점프/낙하) 대상은 제외 — 가지 후려치기·덩굴 채찍과 동일 규약.
			-- center는 지면 좌표(startTelegraph에서 스냅) → 높이 차가 그대로 체공 높이다.
			local airborne = hum.FloorMaterial == Enum.Material.Air
				or (proot.Position.Y - center.Y) > (rt.Def.TelegraphJumpClear or 5)
			if not airborne and withinFairRadius(proot.Position, center, rt.Def.TelegraphRadius) then
				PlayerDamageService.Apply(hum, rt.Def.Atk)
			end
		end
	end
end

-- ===== 공용 지면/경로 헬퍼 (원본 보존) =====

function rollGroundY(rt, pos) -- [2026-07-27] 위에서 전방 선언(startTelegraph 소비)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.IgnoreWater = true
	local exclude = { bossFolder }
	local markersFolder = Workspace:FindFirstChild("_Markers")
	if markersFolder then
		exclude[#exclude + 1] = markersFolder
	end
	local runtimeFolder = Workspace:FindFirstChild("_Runtime")
	if runtimeFolder then
		exclude[#exclude + 1] = runtimeFolder
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			exclude[#exclude + 1] = p.Character
		end
	end
	rp.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(Vector3.new(pos.X, pos.Y + 5, pos.Z), Vector3.new(0, -500, 0), rp)
	return hit and hit.Position.Y or (pos.Y - 5)
end

-- 지면 납작 경로 인디케이터(외곽+차오르는 채움 — 원본 보존)
local function showRollTelegraph(pathCf, size, windup)
	local groundY = pathCf.Position.Y - size.Y / 2
	local flatCf = CFrame.new(pathCf.Position.X, groundY + 0.1, pathCf.Position.Z) * (pathCf - pathCf.Position)
	local function makeFlat(sz, transparency, yoff)
		local box = Instance.new("Part")
		box.Name = "BossRollTelegraph"
		box.Material = Enum.Material.Neon
		box.Color = ROLL_TELEGRAPH_COLOR
		box.Transparency = transparency
		box.Anchored = true
		box.CanCollide = false
		box.CanQuery = false
		box.CanTouch = false
		box.CastShadow = false
		box.Size = Vector3.new(size.X, 0.2, sz)
		box.CFrame = flatCf * CFrame.new(0, yoff or 0, (size.Z - sz) / 2)
		box.Parent = bossFolder
		return box
	end
	local outline = makeFlat(size.Z, 0.5)
	local fill = makeFlat(0.6, 0.2, 0.03)
	fill.Name = "BossRollTelegraphFill" -- [QA 2026-07-23] 채움 파트 개명(구명=외곽과 동명) — 클라 ChildAdded 디스패처가 전조 1회당 1번만 반응(멘트/사운드 2중 발화 근절)
	pcall(function()
		TweenService:Create(fill, TweenInfo.new(windup, Enum.EasingStyle.Linear), {
			Size = Vector3.new(size.X, 0.2, size.Z),
			CFrame = flatCf * CFrame.new(0, 0.03, 0),
		}):Play()
	end)
	Debris:AddItem(outline, windup + 0.25)
	Debris:AddItem(fill, windup + 0.25)
end

-- ===== 짚단 굴리기 + 페이즈2 부채꼴 (짚찌왕 — 원본 보존) =====

local function performStrawRoll(rt, targetRoot)
	local DEF = rt.Def
	local myModel = rt.Model
	local humanoid, root = rt.Humanoid, rt.Root
	pcall(function()
		if not (myModel and myModel.Parent and root and humanoid and humanoid.Health > 0) then
			return
		end
		local origin = root.Position
		-- [난이도 A] 굴리기 조준 방향 리드(윈드업+굴림 절반 시점 예측)
		local dirV = (leadTargetPos(rt, targetRoot, (DEF.RollWindup or 0.9) + (DEF.RollTime or 0.75) * 0.5) - origin) * Vector3.new(1, 0, 1)
		if dirV.Magnitude < 0.5 then
			return
		end
		local dir = dirV.Unit
		local width = DEF.RollWidth or 12
		local bodyRadius = myModel:GetAttribute("HitRadius") or 6
		local startGap = bodyRadius + width * 0.5
		local rollDist = DEF.RollDist or 34
		local length = startGap + rollDist
		local gy = rollGroundY(rt, origin)
		local dirs = { dir }
		if humanoid.Health / humanoid.MaxHealth <= (DEF.RollFanHpRatio or 0.5) then
			local fanRad = math.rad(DEF.RollFanAngle or 24)
			dirs = { dir, CFrame.fromAxisAngle(Vector3.yAxis, fanRad) * dir, CFrame.fromAxisAngle(Vector3.yAxis, -fanRad) * dir }
		end
		for _, d in ipairs(dirs) do
			local center = Vector3.new(origin.X, gy + ROLL_HIT_BOX_HEIGHT / 2, origin.Z) + d * (length / 2)
			showRollTelegraph(CFrame.lookAt(center, center + d), Vector3.new(width, ROLL_HIT_BOX_HEIGHT, length), DEF.RollWindup or 0.9)
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local pos0 = root.Position
		root.CFrame = CFrame.lookAt(pos0, pos0 + dir)
		task.spawn(bossAttackMotion, rt, DEF.RollWindup or 0.9, targetRoot.Position) -- [v4.1] 특수패턴 몸통 모션
		task.wait(DEF.RollWindup or 0.9)
		if not (myModel.Parent and humanoid.Health > 0) then
			return
		end
		humanoid.AutoRotate = true
		local rollTime = DEF.RollTime or 0.75
		local hitSet = {}
		local doneCount = 0
		for _, d in ipairs(dirs) do
			task.spawn(function()
				local ballStart = Vector3.new(origin.X, gy + width * 0.5, origin.Z) + d * startGap
				-- [2026-07-22] Straw 메시 굴리기(에셋 교체): 굴림 회전은 아래 CFrame.fromAxisAngle 유지. 미도착 시 기존 볼 폴백.
				local ball
				local strawT = ReplicatedStorage.Assets:FindFirstChild("StrawModel") or ReplicatedStorage.Assets.Drops:FindFirstChild("Straw")
				if strawT then
					ball = strawT:Clone()
					ball.Name = "BossStrawRollBall"
					ball.PivotOffset = CFrame.new()
					local sc = (width * 0.9) / math.max(strawT.Size.X, strawT.Size.Y, strawT.Size.Z, 0.1)
					ball.Size = strawT.Size * sc
				else
					ball = Instance.new("Part")
					ball.Name = "BossStrawRollBall"
					ball.Shape = Enum.PartType.Ball
					ball.Size = Vector3.new(width * 0.9, width * 0.9, width * 0.9)
					ball.Color = ROLL_BALL_COLOR
					ball.Material = Enum.Material.Grass
				end
				ball.Anchored = true
				ball.CanCollide = false
				ball.CanQuery = false
				ball.CanTouch = false
				ball.CFrame = CFrame.new(ballStart)
				local trailTop = Instance.new("Attachment")
				trailTop.Position = Vector3.new(0, width * 0.38, 0)
				trailTop.Parent = ball
				local trailBot = Instance.new("Attachment")
				trailBot.Position = Vector3.new(0, -width * 0.38, 0)
				trailBot.Parent = ball
				local trail = Instance.new("Trail")
				trail.Attachment0 = trailTop
				trail.Attachment1 = trailBot
				trail.Color = ColorSequence.new(Color3.fromRGB(255, 211, 122), Color3.fromRGB(201, 138, 46))
				trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
				trail.Lifetime = 0.55
				trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.35) })
				trail.LightEmission = 0.4
				trail.Parent = ball
				local bitsAtt = Instance.new("Attachment")
				bitsAtt.Parent = ball
				local bits = Instance.new("ParticleEmitter")
				bits.Color = ColorSequence.new(Color3.fromRGB(236, 208, 108), Color3.fromRGB(201, 158, 70))
				bits.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.1), NumberSequenceKeypoint.new(1, 0) })
				bits.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(1, 1) })
				bits.Lifetime = NumberRange.new(0.35, 0.7)
				bits.Speed = NumberRange.new(6, 13)
				bits.SpreadAngle = Vector2.new(180, 180)
				bits.Acceleration = Vector3.new(0, -30, 0)
				bits.Rotation = NumberRange.new(0, 360)
				bits.RotSpeed = NumberRange.new(-200, 200)
				bits.Rate = 45
				bits.Parent = bitsAtt
				do
					local burstAtt = Instance.new("Attachment")
					burstAtt.Parent = ball
					local bp = Instance.new("ParticleEmitter")
					bp.Color = ColorSequence.new(Color3.fromRGB(255, 222, 140))
					bp.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 0) })
					bp.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
					bp.Lifetime = NumberRange.new(0.35, 0.6)
					bp.Speed = NumberRange.new(14, 26)
					bp.SpreadAngle = Vector2.new(180, 180)
					bp.Acceleration = Vector3.new(0, -35, 0)
					bp.Rate = 0
					bp.Parent = burstAtt
					task.defer(function()
						bp:Emit(20)
					end)
				end
				ball.Parent = bossFolder
				Debris:AddItem(ball, rollTime + 2)
				local axis = Vector3.new(-d.Z, 0, d.X)
				local axisU = axis.Magnitude > 0.001 and axis.Unit or Vector3.new(1, 0, 0)
				-- [2026-07-22] 통나무처럼 가로 굴림: 메시 긴 축(local Y)을 수평 축(axisU)에 누이고 그 축으로 굴림
				-- 메시 긴 축 자동 판별(StrawModel=X, Drops.Straw=Y) → axisU에 누임
				local baseRot
				if ball.Size.X >= ball.Size.Y and ball.Size.X >= ball.Size.Z then
					baseRot = CFrame.fromMatrix(Vector3.zero, axisU, Vector3.yAxis) -- 긴축 X → axisU
				else
					baseRot = CFrame.fromMatrix(Vector3.zero, d, axisU) -- 긴축 Y → axisU
				end
				local snap = capturePlayerSnapshot()
				local t0 = os.clock()
				while true do
					if not ball.Parent then
						break
					end
					local a = math.min((os.clock() - t0) / rollTime, 1)
					local ballPos = ballStart + d * (rollDist * a)
					ball.CFrame = CFrame.new(ballPos) * CFrame.fromAxisAngle(axisU, -(rollDist * a) / (width * 0.45)) * baseRot
					for _, se in ipairs(snapshotAlive(snap)) do
						if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
							local pr, ph = se.root, se.hum
							if withinFairRadius(pr.Position, ballPos, width * 0.5) then
								hitSet[se.player] = true
								PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (DEF.RollDamageMul or 1) + 0.5)) -- [v4.1] 짚단굴리기 20dmg
							end
						end
					end
					if a >= 1 then
						break
					end
					task.wait()
				end
				ball:Destroy()
				doneCount += 1
			end)
		end
		local deadline = os.clock() + rollTime + 2
		while doneCount < #dirs and os.clock() < deadline do
			task.wait(0.05)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.PatternBusy = false
end

-- ===== 공중 내려찍기 LeapSlam (짚찌왕 — 원본 보존) =====

-- [2026-07-20] 합체 벽돌대왕 강체 고정: 루트 고속 이동(프레스/돌진) 시 언앵커 벽돌이 관성으로 뒤처져
-- '한 마리 분리'되는 문제 방지. 패턴 시작 시 브릭의 루트-로컬 오프셋 캐처 → 매 프레임 루트 기준 재배치.
local function captureBrickPins(rt)
	local model = rt.Model
	if not (model and rt.Def and rt.Def.MergePhase and not rt.SplitActive and rt.Root) then
		return nil
	end
	local root = rt.Root
	local pins = {}
	for _, m in ipairs(model:GetDescendants()) do
		if m:IsA("Motor6D") and m.Part1 and m.Part1 ~= root then
			pins[#pins + 1] = { part = m.Part1, offset = root.CFrame:ToObjectSpace(m.Part1.CFrame) }
		end
	end
	return pins
end
local function applyBrickPins(rt, pins)
	if not pins then
		return
	end
	local root = rt.Root
	if not (root and root.Parent) then
		return
	end
	for _, e in ipairs(pins) do
		if e.part.Parent then
			e.part.CFrame = root.CFrame * e.offset
			e.part.AssemblyLinearVelocity = Vector3.zero
			e.part.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

-- [2026-07-20] 합체 후 브릭 스택 상시 강체 고정: 매 프레임 루트 기준 재배치 — 피격 플린치·이동·물리 드리프트로
-- 벽돌 1개가 떨어져나가 '분리'되는 것 완전 차단. 재산개/사망/재소환 시 자동 해제.
local function startBrickWeldLoop(rt)
	local model = rt.Model
	local root = rt.Root
	if not (model and root) then
		return
	end
	if rt.BrickWeldConn then
		rt.BrickWeldConn:Disconnect()
		rt.BrickWeldConn = nil
	end
	-- ★Motor6D C0 복제가 불안정해 클라가 브릭 C0를 산개 값으로 desync(서버=rest, 클라=흔어짐).
	-- → 브릭을 앵커하고 매 프레임 root 기준 CFrame으로 강체 추종. 앵커 파트 CFrame은 안정 복제+클라가 C0 무시.
	local pins = {}
	for _, m in ipairs(model:GetDescendants()) do
		if m:IsA("Motor6D") and m.Part0 and m.Part0.Name == "HumanoidRootPart" and m.Part1 then
			local part = m.Part1
			part.Anchored = true
			pins[#pins + 1] = { part = part, offset = root.CFrame:ToObjectSpace(part.CFrame) }
		end
	end
	local lastRootCf = nil
	rt.BrickWeldConn = game:GetService("RunService").Heartbeat:Connect(function()
		if rt.SplitActive or rt.Model ~= model or not model.Parent or not rt.Root then
			for _, e in ipairs(pins) do
				if e.part and e.part.Parent then
					e.part.Anchored = false -- 재소환/재산개 정상화
				end
			end
			if rt.BrickWeldConn then
				rt.BrickWeldConn:Disconnect()
				rt.BrickWeldConn = nil
			end
			return
		end
		local r = rt.Root
		if r.CFrame == lastRootCf then
			return -- 루트 정지 프레임: 브릭 CFrame 재대입 스킵
		end
		lastRootCf = r.CFrame
		for _, e in ipairs(pins) do
			if e.part.Parent then
				e.part.CFrame = r.CFrame * e.offset
			end
		end
	end)
end

local wolfPounceMotion -- [2026-07-21] 늑대 도약 모션 전방선언(정의는 wolfClawMotion 아래 — wolfBaseC0 의존)

-- 긴 패턴의 재사용 대기는 시작 시각이 아니라 종료 시각부터 계산한다.
-- 그렇지 않으면 5~6연속 돌진 도중 쿨이 끝나 같은 패턴만 연속 발동해 다른 기술을 굶긴다.
function finishWolfActionCooldown(rt, timerField, cooldown)
	local finishedAt = os.clock()
	if timerField and cooldown then
		rt[timerField] = finishedAt + math.max(0, cooldown)
	end
	rt.NextWolfActionAt = math.max(rt.NextWolfActionAt or 0, finishedAt + (rt.Def.PatternRecovery or 0))
end

local function performLeapSlam(rt, targetRoot)
	local DEF = rt.Def
	local myModel = rt.Model
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.LeapSlam
	local realPounceAnim = false
	local pounceMarkerState, pounceGeneration
	pcall(function()
		if not (myModel and myModel.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		if rt.Id == "Wolf" then
			realPounceAnim, _, pounceMarkerState, pounceGeneration = playBossPatternAnim(rt, "AirSlam")
		end
		local origin = root.Position
		-- [2026-08-08] 착지점 존 클램프(짚찌왕 게이트 이탈 실사고)
		local targetPos = clampChasePos(rt, targetRoot.Position)
		local gy = rollGroundY(rt, targetPos)
		local impact = Vector3.new(targetPos.X, gy, targetPos.Z)
		local halfH = myModel:GetExtentsSize().Y / 2
		-- [2026-07-14 #2] 착지 높이 자기보정: 루트는 모델 기하 중심보다 높아 'gy+반높이'로 맞추면
		-- 그 차이만큼 공중 부유(실측 6.1). 이륙 직전 '서있는 루트~지면' 실측치로 착지(리그 무관 밀착)
		local standY = origin.Y - rollGroundY(rt, origin)
		if standY < 1 or standY > myModel:GetExtentsSize().Y then
			standY = halfH -- 이륙 지점 이상치(공중/낙젠) 폴백
		end
		local disc = makeDisc(impact + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), cfg.Radius, TELEGRAPH_COLOR, cfg.AirTime + 0.3)
		disc.Name = "BossLeapTelegraph"
		disc:SetAttribute("AirTime", cfg.AirTime)
		humanoid.AutoRotate = false
		humanoid:MoveTo(origin)
		root.Anchored = true
		local lookV = (Vector3.new(impact.X, 0, impact.Z) - Vector3.new(origin.X, 0, origin.Z))
		local lookDir = lookV.Magnitude > 0.5 and lookV.Unit or root.CFrame.LookVector
		local spinRad = math.rad(cfg.SpinDeg or 0) -- [패턴 모션] 공중 회전각(머드킹 '회전 내려찍기' — 0=미회전, 720=착지 시 정면 복귀)
		local pressRad = math.rad(cfg.PressDeg or 0) -- [패턴 모션] 하강 압착 기울기(벽돌대왕 '몸통 프레스' — 0=미적용)
		if cfg.ArmOverhead then
			task.spawn(leapArmMotion, rt, cfg.AirTime) -- [패턴 모션] 양팔 치켜들기→착지 내려침(나무장군)
		end
		if cfg.PounceMotion and wolfPounceMotion and not realPounceAnim then
			task.spawn(wolfPounceMotion, rt, cfg.AirTime or 1) -- 게시 애니가 없을 때만 절차 모션 폴백
		end
		-- [난이도 B 2026-07-15] 공중 추적(cfg.Homing 게이트): 체공 전반 65% 동안 낙하점이 타겟 쪽으로 이동.
		-- 추적 속도 16=도보 동속(걷기론 못 벗어나고 대시 요구), 총 보정량 상한 = Homing 스터드.
		local homingLeft = cfg.Homing or 0
		local lastT = os.clock()
		local t0 = os.clock()
		local pins = captureBrickPins(rt)
		while true do
			if humanoid.Health <= 0 or not root.Parent then
				return
			end
			local nowT = os.clock()
			local dt = math.min(nowT - lastT, 0.1)
			lastT = nowT
			local a = math.min((nowT - t0) / cfg.AirTime, 1)
			if homingLeft > 0 and a < 0.65 and targetRoot.Parent then
				local dv = (Vector3.new(targetRoot.Position.X, impact.Y, targetRoot.Position.Z) - impact) * Vector3.new(1, 0, 1)
				local step = math.min(dv.Magnitude, homingLeft, 16 * dt)
				if step > 0.001 then
					impact += dv.Unit * step
					homingLeft -= step
					impact = clampChasePos(rt, impact) -- [2026-08-08] 유도 추적도 존 안까지만
					disc.CFrame = disc.CFrame.Rotation + (impact + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0))
				end
			end
			local x = origin.X + (impact.X - origin.X) * a
			local z = origin.Z + (impact.Z - origin.Z) * a
			local y = origin.Y + ((impact.Y + standY) - origin.Y) * a + math.sin(a * math.pi) * cfg.RiseHeight
			local press = pressRad > 0 and -pressRad * math.clamp((a - 0.55) / 0.45, 0, 1) or 0 -- [패턴 모션] 하강 55%부터 앞으로 엎어짐
			root.CFrame = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x, y, z) + lookDir)
				* CFrame.Angles(math.rad(-24 * math.sin(a * math.pi)) + press, 0, 0)
				* CFrame.Angles(0, spinRad * a, 0)
			applyBrickPins(rt, pins) -- [패턴 모션] 기울인 몸축 기준 스핀(SpinDeg 게이트)
			if a >= 1 then
				break
			end
			task.wait()
		end
		if (cfg.Homing or 0) > 0 then
			impact = Vector3.new(impact.X, rollGroundY(rt, impact), impact.Z) -- [난이도 B] 추적 이동분 지면 재보정
		end
		-- [2026-07-14 #2] 착지 밀착: SpawnHeightPad(1) 제거 — 바닥이 지면에 닿지 않아 공중 부유 체감(사용자 피드백)
		local landCf = CFrame.lookAt(Vector3.new(impact.X, impact.Y + standY, impact.Z),
			Vector3.new(impact.X, impact.Y + standY, impact.Z) + lookDir)
		-- [패턴 모션] PressDeg: 엎어진 채 착지(압착 여운은 충격파 생성 후 동기 복구)
		root.CFrame = pressRad > 0 and landCf * CFrame.Angles(-pressRad, 0, 0) or landCf
		applyBrickPins(rt, pins)
		if rt.Id == "Wolf" and pounceMarkerState then
			-- 실제 착지 위치에 도달한 뒤 Hit까지 짧게 기다려 충격 판정을 애니메이션과 맞춘다.
			FieldBossService._waitWolfAnimationMarker(rt, pounceMarkerState, pounceGeneration, "Hit", 0, 0.4)
			if pounceMarkerState.Generation ~= pounceGeneration
				or pounceMarkerState.CancelledGeneration == pounceGeneration
				or rt.Model ~= pounceMarkerState.Model then
				return
			end
		end
		local dmg = math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5)
		for _, p in ipairs(Players:GetPlayers()) do
			local pr, ph = alivePlayerParts(p)
			if pr and withinFairRadius(pr.Position, impact, cfg.Radius) then
				PlayerDamageService.Apply(ph, dmg)
			end
		end
		local shock = Instance.new("Part")
		shock.Name = "BossLeapShock"
		shock.Shape = Enum.PartType.Cylinder
		shock.Size = Vector3.new(0.4, cfg.Radius * 0.6, cfg.Radius * 0.6)
		shock.CFrame = CFrame.new(impact + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
		shock.Anchored = true
		shock.CanCollide = false
		shock.CanQuery = false
		shock.CanTouch = false
		shock.CastShadow = false
		shock.Material = Enum.Material.Neon
		shock.Color = Color3.fromRGB(255, 210, 120)
		shock.Transparency = 0.2
		shock.Parent = bossFolder
		pcall(function()
			TweenService:Create(shock, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.new(0.4, cfg.Radius * 2.6, cfg.Radius * 2.6),
				Transparency = 1,
			}):Play()
		end)
		Debris:AddItem(shock, 0.6)
		if rt.Id == "Wolf" then
			if pounceMarkerState then
				FieldBossService._waitWolfAnimationMarker(rt, pounceMarkerState, pounceGeneration, "Reset", 0.05, 1.2)
			end
			playBossPatternAnim(rt, "Landing")
		end
		-- 착지 충격파 링(cfg.ShockRing 게이트 — 타 보스 무영향): 존 전역 확장 파동, 밴드 판정·접지만 피격(점프 회피).
		-- 비동기(task.spawn) — 링이 존 끝까지 퍼지는 동안 보스 행동 재개.
		local ringCfg = cfg.ShockRing
		if ringCfg then
			task.spawn(function()
				local shards = {}
				local emitFx = {}
				local ringN = ringCfg.RingParts or 12
				for ri = 1, ringN do
					local sp = Instance.new("Part")
					sp.Name = "WolfShockRingShard"
					sp.Size = Vector3.new(2.4, 2.8, 1.2)
					sp.Anchored = true
					sp.CanCollide = false
					sp.CanQuery = false
					sp.CanTouch = false
					sp.CastShadow = false
					sp.Material = Enum.Material.Neon
					sp.Color = Color3.fromRGB(255, 140, 70)
					sp.Transparency = 1 -- [2026-07-23c] 파편 비표시(이펙트만 표시 — 사용자 결정) — 위치 캐리어·불티 부착용으로 유지
					sp.Parent = bossFolder
					shards[ri] = sp
					-- [2026-07-23] 파편 이펙트화: 3개마다 불티 이미터(Emit 버스트 구동 — 모바일 규약)
					if ri % 2 == 1 then
						local att = Instance.new("Attachment")
						att.Parent = sp
						local em = Instance.new("ParticleEmitter")
						em.Texture = "rbxasset://textures/particles/fire_main.dds"
						em.Color = ColorSequence.new(Color3.fromRGB(255, 170, 90), Color3.fromRGB(255, 90, 40))
						em.LightEmission = 0.8
						em.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.2), NumberSequenceKeypoint.new(1, 0.4) })
						em.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
						em.Lifetime = NumberRange.new(0.35, 0.6)
						em.Rate = 0
						em.Speed = NumberRange.new(4, 9)
						em.SpreadAngle = Vector2.new(25, 25)
						em.Acceleration = Vector3.new(0, 12, 0)
						em.EmissionDirection = Enum.NormalId.Top
						em.Enabled = false
						em.Parent = att
						table.insert(emitFx, em)
					end
				end
				-- [2026-07-23] 지면 확장 링 메시(클래식 링) — 파편 벽과 동기 확장(순수 연출·판정 무관)
				local ringPart = Instance.new("Part")
				ringPart.Name = "WolfShockRingFx"
				ringPart.Size = Vector3.new(1, 1, 1)
				ringPart.Anchored = true
				ringPart.CanCollide = false
				ringPart.CanQuery = false
				ringPart.CanTouch = false
				ringPart.CastShadow = false
				ringPart.Material = Enum.Material.Neon
				ringPart.Color = Color3.fromRGB(255, 150, 70)
				ringPart.CFrame = CFrame.new(impact.X, impact.Y + 0.35, impact.Z) * CFrame.Angles(math.rad(90), 0, 0)
				local ringMesh = Instance.new("SpecialMesh")
				ringMesh.MeshType = Enum.MeshType.FileMesh
				ringMesh.MeshId = "rbxassetid://3270017"
				ringMesh.Scale = Vector3.new(1, 1, 1)
				ringMesh.Parent = ringPart
				ringPart.Parent = bossFolder
				local hitSet2 = {}
				local snap2 = capturePlayerSnapshot()
				local expand = ringCfg.ExpandTime or 0.6
				local r0 = (cfg.Radius or 9) * 0.6
				local r1 = ringCfg.MaxRadius or 26
				local ringDmg = math.floor(DEF.Atk * (ringCfg.DamageMul or 0.6) + 0.5)
				local rt0 = os.clock()
				local lastEmit = 0
				while root.Parent and humanoid.Health > 0 do
					local a2 = math.min((os.clock() - rt0) / expand, 1)
					local rr = r0 + (r1 - r0) * a2
					local shardW = math.clamp((2 * math.pi * rr) / ringN * 0.85, 2.4, 24) -- 반경 비례 확폭 — 벽처럼 이어짐
					for ri, sp in ipairs(shards) do
						local ang2 = (ri / ringN) * math.pi * 2
						local dx, dz = math.cos(ang2), math.sin(ang2)
						local px, pz = impact.X + dx * rr, impact.Z + dz * rr
						sp.Size = Vector3.new(shardW, 2.8, 1.2)
						sp.CFrame = CFrame.lookAt(Vector3.new(px, impact.Y + 1.4, pz), Vector3.new(px + dx, impact.Y + 1.4, pz + dz))
					end
					-- 지면 링 메시 동기(반경 rr) — 클래식 링 메시는 Scale=지름(목업 캘리브레이션 2026-07-23)
					ringMesh.Scale = Vector3.new(rr * 2, rr * 2, math.max(rr * 0.15, 8))
					ringPart.Transparency = 0.05 + a2 * 0.55
					-- 불티 버스트(0.12s 주기 — 연속 Enabled 금지 규약)
					if os.clock() - lastEmit >= 0.12 then
						lastEmit = os.clock()
						for _, em in ipairs(emitFx) do
							em:Emit(3)
						end
					end
					for _, se in ipairs(snapshotAlive(snap2)) do
						if not hitSet2[se.player] and se.root.Parent and se.hum.Health > 0 then
							local dxz = Vector3.new(se.root.Position.X - impact.X, 0, se.root.Position.Z - impact.Z).Magnitude
							if math.abs(dxz - rr) <= (ringCfg.BandWidth or 4) * 0.5 then
								local airborne = se.hum.FloorMaterial == Enum.Material.Air or (se.root.Position.Y - impact.Y) > (ringCfg.JumpClear or 15)
								if not airborne then
									hitSet2[se.player] = true
									PlayerDamageService.Apply(se.hum, ringDmg)
								end
							end
						end
					end
					if a2 >= 1 then
						break
					end
					task.wait()
				end
				for _, sp in ipairs(shards) do
					sp:Destroy()
				end
				ringPart:Destroy()
			end)
		end
		if pressRad > 0 then -- [패턴 모션] 압착 여운: 0.2s 누른 채 유지 → 0.15s 일어서기(앵커 유지 중 동기 실행)
			task.wait(0.2)
			local tr0 = os.clock()
			while root.Parent and humanoid.Health > 0 and os.clock() - tr0 < 0.15 do
				local ar = math.min((os.clock() - tr0) / 0.15, 1)
				root.CFrame = landCf * CFrame.Angles(-pressRad * (1 - ar), 0, 0)
				task.wait()
			end
			if root.Parent then
				root.CFrame = landCf
			end
		end
	end)
	if rt.Root and rt.Root.Parent then
		rt.Root.Anchored = false
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	finishWolfActionCooldown(rt, "NextLeapAt", rt.Def.LeapSlam and rt.Def.LeapSlam.Cooldown)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== 저체력 공중 도주 Flee (짚찌왕 — 원본 보존) =====

local function performFlee(rt)
	local DEF = rt.Def
	local myModel = rt.Model
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.Flee
	pcall(function()
		if not (myModel and myModel.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local origin = root.Position
		local dest = nil
		for _ = 1, 6 do
			local ang = math.random() * math.pi * 2
			local r = cfg.MinDist + math.random() * (cfg.MaxDist - cfg.MinDist)
			local cand = rt.ZoneCenter + Vector3.new(math.cos(ang) * r, 0, math.sin(ang) * r)
			if (cand - rt.ZoneCenter).Magnitude <= DEF.ZoneRadius * 0.85
				and (cand - origin).Magnitude >= cfg.MinDist * 0.6 then
				dest = cand
				break
			end
		end
		dest = dest or rt.ZoneCenter
		local gy = rollGroundY(rt, dest)
		local halfH = myModel:GetExtentsSize().Y / 2
		-- [2026-07-14 #2] 착지 높이 자기보정(LeapSlam과 동일 규약)
		local standY = origin.Y - rollGroundY(rt, origin)
		if standY < 1 or standY > myModel:GetExtentsSize().Y then
			standY = halfH
		end
		local landPos = Vector3.new(dest.X, gy + standY, dest.Z)
		local cue = Instance.new("Part")
		cue.Name = "BossFleeCue"
		cue.Size = Vector3.new(0.2, 0.2, 0.2)
		cue.Transparency = 1
		cue.Anchored = true
		cue.CanCollide = false
		cue.CanQuery = false
		cue.CanTouch = false
		cue.CFrame = CFrame.new(origin)
		cue.Parent = bossFolder
		Debris:AddItem(cue, 2)
		humanoid.AutoRotate = false
		humanoid:MoveTo(origin)
		root.Anchored = true
		local riseSec = 0.5
		local sinkSec = 0.35
		local _, baseYaw = root.CFrame:ToOrientation()
		local t0 = os.clock()
		while os.clock() - t0 < riseSec do
			if humanoid.Health <= 0 or not root.Parent then
				return
			end
			local a = (os.clock() - t0) / riseSec
			root.CFrame = CFrame.new(origin + Vector3.new(0, cfg.RiseHeight * a * a, 0))
				* CFrame.Angles(0, baseYaw + a * math.pi * 2, 0)
			task.wait()
		end
		local air = origin + Vector3.new(0, cfg.RiseHeight, 0)
		local lookV = (Vector3.new(dest.X, 0, dest.Z) - Vector3.new(origin.X, 0, origin.Z))
		local lookDir = lookV.Magnitude > 0.5 and lookV.Unit or root.CFrame.LookVector
		local t1 = os.clock()
		while true do
			if humanoid.Health <= 0 or not root.Parent then
				return
			end
			local a = math.min((os.clock() - t1) / cfg.FlyTime, 1)
			local x = air.X + (landPos.X - air.X) * a
			local z = air.Z + (landPos.Z - air.Z) * a
			local y = air.Y + math.sin(a * math.pi) * 4
			root.CFrame = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x, y, z) + lookDir)
				* CFrame.Angles(math.rad(10), 0, math.rad(6 * math.sin(a * math.pi * 3)))
			if a >= 1 then
				break
			end
			task.wait()
		end
		local t2 = os.clock()
		local top = Vector3.new(landPos.X, air.Y, landPos.Z)
		while os.clock() - t2 < sinkSec do
			if humanoid.Health <= 0 or not root.Parent then
				return
			end
			local a = (os.clock() - t2) / sinkSec
			root.CFrame = CFrame.lookAt(top:Lerp(landPos, a), top:Lerp(landPos, a) + lookDir)
			task.wait()
		end
		root.CFrame = CFrame.lookAt(landPos, landPos + lookDir)
	end)
	if rt.Root and rt.Root.Parent then
		rt.Root.Anchored = false
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [피벗3 P5] 신규 패턴 1: 돌진 Charge (당근 대장) =====
-- 경로 박스 예고 → 몸통 돌진(앵커 CFrame 슬라이드) → 경로 접촉 1인 1회 피해 + 약넉백

-- [2026-07-31] cfgOverride: 동일 판정·연출을 다른 키의 돌진 설정으로 재사용(MudBoss.MudCharge). 미지정 호출부는 종전과 동일.
local function performCharge(rt, targetRoot, cfgOverride)
	local DEF = rt.Def
	local myModel = rt.Model
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = cfgOverride or DEF.Charge
	pcall(function()
		if not (myModel and myModel.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local origin = root.Position
		-- [난이도 A] 돌진 방향 리드(LeadAim 보스만 — 늑대/당근대장은 미등재로 불변)
		local dirV = (leadTargetPos(rt, targetRoot, (cfg.Windup or 0.8) * 0.8) - origin) * Vector3.new(1, 0, 1)
		if dirV.Magnitude < 0.5 then
			return
		end
		local dir = dirV.Unit
		local width = cfg.Width or 5
		local bodyRadius = tonumber(myModel:GetAttribute("HitRadius")) or 0
		local surfaceOrigin = origin + dir * bodyRadius
		-- [2026-08-08] 존 이탈 봉쇄(짚찌왕 게이트 이탈 실사고): 돌진 거리를 존 경계까지로 클램프
		local dist = clampDashDist(rt, origin, dir, cfg.Dist or 24)
		if dist < 2 then
			return -- 경계 코앞 — 이번 돌진 생략(꼬리에서 쿨·Busy 정상 해제)
		end
		local gy = rollGroundY(rt, surfaceOrigin)
		local center = Vector3.new(surfaceOrigin.X, gy + ROLL_HIT_BOX_HEIGHT / 2, surfaceOrigin.Z) + dir * (dist / 2)
		showRollTelegraph(CFrame.lookAt(center, center + dir), Vector3.new(width, ROLL_HIT_BOX_HEIGHT, dist), cfg.Windup or 0.8)
		humanoid.AutoRotate = false
		humanoid:MoveTo(origin)
		root.CFrame = CFrame.lookAt(origin, origin + dir)
		task.wait(cfg.Windup or 0.8)
		if not (myModel.Parent and humanoid.Health > 0) then
			return
		end
		root.Anchored = true
		local hitSet = {}
		local moveTime = cfg.MoveTime or 0.55
		local baseY = root.Position.Y
		local snap = capturePlayerSnapshot()
		local t0 = os.clock()
		local pins = captureBrickPins(rt)
		while true do
			if humanoid.Health <= 0 or not root.Parent then
				return
			end
			local a = math.min((os.clock() - t0) / moveTime, 1)
			local pos = origin + dir * (dist * a)
			root.CFrame = CFrame.lookAt(Vector3.new(pos.X, baseY, pos.Z), Vector3.new(pos.X, baseY, pos.Z) + dir)
				* CFrame.Angles(math.rad(-14 * math.sin(a * math.pi)), 0, 0)
			applyBrickPins(rt, pins)
			for _, se in ipairs(snapshotAlive(snap)) do
				if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
					local pr, ph = se.root, se.hum
					local hitPos = pos + dir * bodyRadius
					if withinFairRadius(pr.Position, hitPos, width * 0.5) then
						hitSet[se.player] = true
						-- [2026-07-10] DamageMul 지원(늑대 돌진 1.25×) — 미지정 보스(당근대장)는 1× 불변
						local damaged = PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5))
						local kb = cfg.Knockback
						if damaged and kb then
							MonsterService.KnockbackPlayer(se.player, hitPos, kb.Force, kb.Lift)
						end
					end
				end
			end
			if a >= 1 then
				break
			end
			task.wait()
		end
	end)
	if rt.Root and rt.Root.Parent then
		rt.Root.Anchored = false
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== 당근 회오리 Whirl (당근 대장) =====
-- 발밑 차오르는 원반 예고 → 제자리 고속 회전 → 반경 내 플레이어를 밖+접선 방향으로 휘감아 띄움.
-- 피해는 1인 1회(회전 내내 누적 금지 — reported 플래그), 넉백만 반복 적용.
local function performWhirl(rt, targetRoot)
	local DEF = rt.Def
	local myModel = rt.Model
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.Whirl
	pcall(function()
		if not (myModel and myModel.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		local surfaceReach = tonumber(cfg.SurfaceReach)
		local radius = surfaceReach and (bodyRadius + surfaceReach) or (cfg.Radius or 12)
		local windup = cfg.Windup or 0.6
		local duration = cfg.Duration or 1.3
		local spinSpeed = math.rad(cfg.SpinDeg or 900)

		-- 회오리 중심 = 보스 발밑 지면(거대 보스는 루트가 허공에 있으므로 반드시 지면 투영)
		local gy = rollGroundY(rt, root.Position)
		local center = Vector3.new(root.Position.X, gy, root.Position.Z)

		-- [2026-07-10] 토네이도 파티클(Assets.Tornado — Attachment). 미도착 시 조용히 스킵.
		-- 방출은 윈드업 종료 후(회전 시작) — 윈드업 동안은 전조 원반·외침만 보여 발동 타이밍이 읽히게 분리.
		-- 파티클 크기/속도는 보스 몸집(ModelScale)에 맞춰 확대.
		local whirlEmitters = {}
		local fxFolder = nil
		pcall(function()
			local assets = ReplicatedStorage:FindFirstChild("Assets")
			if not assets then
				return
			end
			-- 파티클 배율: cfg.FxScale 우선(보스 실측 기반 튜닝), 미지정이면 원본 공식 폴백
			local fxScale = tonumber(cfg.FxScale) or math.clamp((DEF.ModelScale or 1) / 2.5, 1, 4)
			local anchor = nil
			-- 원본(CarrotBossClient)과 동일 구성: Tornado(깔돀기) + Floor(바닥 소용돌이·잎). 미도착 에셋은 개별 스킵.
			for _, templateName in ipairs({ "Tornado", "Floor" }) do
				local template = assets:FindFirstChild(templateName)
				if template and template:IsA("Attachment") then
					if not anchor then
						fxFolder = Instance.new("Folder")
						fxFolder.Name = "BossWhirlFx"
						fxFolder.Parent = bossFolder
						anchor = Instance.new("Part")
						anchor.Name = "WhirlFxAnchor"
						anchor.Size = Vector3.new(0.2, 0.2, 0.2)
						anchor.Transparency = 1
						anchor.Anchored = true
						anchor.CanCollide = false
						anchor.CanQuery = false
						anchor.CanTouch = false
						anchor.CastShadow = false
						anchor.CFrame = CFrame.new(center)
						anchor.Parent = fxFolder
					end
					local att = template:Clone()
					att.Position = Vector3.zero -- 원본 Attachment는 몸통 기준 오프셋(약 -4.4)을 가짐 — 지면 중심으로 재정렬
					att.Parent = anchor
					for _, d in ipairs(att:GetDescendants()) do
						if d:IsA("ParticleEmitter") then
							pcall(function()
								local kps = {}
								for _, kp in ipairs(d.Size.Keypoints) do
									table.insert(kps, NumberSequenceKeypoint.new(kp.Time, kp.Value * fxScale, kp.Envelope))
								end
								d.Size = NumberSequence.new(kps)
								d.Speed = NumberRange.new(d.Speed.Min * fxScale, d.Speed.Max * fxScale)
							end)
							if cfg.FxColor then d.Color = ColorSequence.new(cfg.FxColor) end -- [v4.1] 보스 테마 색(나무장군 가지휘쓸기=녹색)
							d.Enabled = false -- [QA 2026-07-15] 윈드업 종료 후 일괄 점화(아래 회전 직전)
							table.insert(whirlEmitters, d)
						end
					end
				end
			end
		end)
		local function stopFx()
			for _, pe in ipairs(whirlEmitters) do
				pe.Enabled = false
			end
			if fxFolder then
				Debris:AddItem(fxFolder, 2) -- 잔여 입자 수명(Lifetime 최대 1.5) 후 정리
				fxFolder = nil
			end
		end

		-- 예고: 외곽 링 + 차오르는 내부 원반
		local outline = makeDisc(center + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), radius, TELEGRAPH_COLOR, windup + duration + 0.4)
		outline.Name = "BossWhirlTelegraph"
		outline.Transparency = 0.75
		local fill = makeDisc(center + Vector3.new(0, TELEGRAPH_Y_OFFSET + 0.06, 0), 0.3, TELEGRAPH_COLOR, windup + duration + 0.4)
		fill.Name = "BossWhirlFill"
		pcall(function()
			TweenService:Create(fill, TweenInfo.new(windup, Enum.EasingStyle.Linear), {
				Size = Vector3.new(TELEGRAPH_THICKNESS, radius * 2, radius * 2),
			}):Play()
		end)

		-- 머리 위 외침 말풍선(원본 BossShoutBubble) — Taunt=false 보스는 오표기 방지를 위해 생략
		if cfg.Taunt ~= false then
		pcall(function()
			local head = myModel:FindFirstChild("Head") or root
			local bb = Instance.new("BillboardGui")
			bb.Name = "BossShoutBubble"
			bb.Adornee = head
			bb.AlwaysOnTop = true
			bb.LightInfluence = 0
			bb.Size = UDim2.fromOffset(260, 64)
			-- 머리 위: 모델 상단 기준(거대 스케일에서 고정 +4는 몸통 안) — 앱도니 중심 대비 오프셋
			local topY = 4
			pcall(function()
				topY = (myModel:GetExtentsSize().Y / 2) - (head.Position.Y - myModel:GetPivot().Position.Y) + 3
			end)
			bb.StudsOffset = Vector3.new(0, math.max(topY, 4), 0)
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.Font = Enum.Font.GothamBlack
			label.TextScaled = true
			label.TextColor3 = Color3.fromRGB(255, 235, 120)
			label.TextStrokeTransparency = 0.15
			label.Text = cfg.Taunt or Strings.get("BossTaunt_Whirl") -- [v4.1] 보스별 외침(cfg.Taunt) — 공용 Whirl 재사용 시 ‘당근 회오리’ 오표 방지
			label.Parent = bb
			bb.Parent = myModel
			Debris:AddItem(bb, windup + duration + 0.3)
		end)
		end

		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		task.wait(windup)
		if not (myModel.Parent and humanoid.Health > 0) then
			stopFx() -- 윈드업 중 사망/제거 — 토네이도가 영구히 남지 않게
			return
		end
		for _, pe in ipairs(whirlEmitters) do
			pe.Enabled = true -- [QA 2026-07-15] 전조 종료 → 토네이도 방출과 함께 본타 시작
		end

		-- 제자리 고속 회전 + 반경 판정(피해 1인 1회, 넘침은 0.2초 쓰로틀)
		root.Anchored = true
		local baseCf = root.CFrame
		local damaged = {}
		local lastPush = 0
		local spin = 0
		local t0 = os.clock()
		while true do
			if humanoid.Health <= 0 or not root.Parent then
				break -- 회전 중 사망 — 아래 stopFx()로 토네이도 정리(조기 return 금지)
			end
			local elapsed = os.clock() - t0
			if elapsed >= duration then
				break
			end
			local dt = task.wait()
			spin += spinSpeed * dt
			root.CFrame = baseCf * CFrame.Angles(0, spin, 0)
			local now = os.clock()
			if now - lastPush >= 0.2 then
				lastPush = now
				for _, p in ipairs(Players:GetPlayers()) do
					local pr, ph = alivePlayerParts(p)
					if pr then
						local flat = Vector3.new(pr.Position.X - center.X, 0, pr.Position.Z - center.Z)
						if flat.Magnitude <= fairRadius(radius) then
							if not damaged[p] then
								damaged[p] = true
								PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5))
							end
							-- 대시/진화 무적 중에는 피해와 강제 이동을 함께 막는다. 지속 장판은 무적 종료 후 다시 밀 수 있다.
							if not PlayerDamageService.IsProtected(ph) then
								local outDir = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)
								local tangent = Vector3.new(-outDir.Z, 0, outDir.X)
								local push = outDir * (cfg.PushOut or 20) + tangent * (cfg.PushSpin or 26)
								MonsterService.KnockbackPlayer(p, pr.Position - push, push.Magnitude, cfg.Lift or 15)
							end
						end
					end
				end
			end
		end
		stopFx()
	end)
	if rt.Root and rt.Root.Parent then
		rt.Root.Anchored = false
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== 늑대 페이즈 패턴 WolfPhase (보스 플레이스 BossCombatAI 이식) =====
-- HP≤50% 2페 전환(포효) / 1페 전방 박스 강타·2페 광역 강타 / 스페셜: ≤70% 하울(원형 AoE, 쿨15)·≤30% 돌진(performCharge 재사용, 쿨20).
-- 피해량 = DEF.Atk × Mul, 애니 = AVDefs AttackP1/P2.

local function wolfPlayAttackAnim(rt, phase)
	local animDef = AVDefs.MonsterAnims[rt.Id]
	if not animDef then
		return
	end
	rt.WolfTracks = rt.WolfTracks or {}
	local key = "P" .. tostring(phase)
	if rt.WolfTracks[key] == nil then
		local id = (phase >= 2 and animDef.AttackP2) or animDef.AttackP1 or animDef.Attack
		local hum = rt.Humanoid
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if not (id and id ~= "" and animator) then
			rt.WolfTracks[key] = false
		else
			local anim = Instance.new("Animation")
			anim.Name = "WolfAttack" .. key
			anim.AnimationId = id
			local ok, track = pcall(animator.LoadAnimation, animator, anim)
			if ok and track then
				track.Priority = Enum.AnimationPriority.Action2
				track.Looped = false
				rt.WolfTracks[key] = track
			else
				rt.WolfTracks[key] = false
			end
		end
	end
	for k, t in pairs(rt.WolfTracks) do
		if t and k ~= key and t.IsPlaying then
			t:Stop(0.05)
		end
	end
	local track = rt.WolfTracks[key]
	if track then
		if track.IsPlaying then
			track:Stop(0)
		end
		track:Play(0.05)
	end
end

-- 페이즈 전환 포효(원본 PlayEffect 'BossRoar' 대체): 확장 링 + 그르렁 사운드 — 연출 전용(피해 없음)
local function performWolfRoar(rt)
	local root = rt.Root
	if not (root and root.Parent) then
		return
	end
	local gdef = AVDefs.Sounds.BossGrowl
	if gdef and gdef.Id and gdef.Id ~= "" then
		local sound = Instance.new("Sound")
		sound.SoundId = gdef.Id
		sound.Volume = (gdef.Volume or 0.7) * 1.5
		sound.PlaybackSpeed = 0.85 -- 포효답게 낮게
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMaxDistance = 200
		sound.Parent = root
		sound:Play()
		Debris:AddItem(sound, 5)
		-- [2026-07-14 위엄 연출] 메아리 레이어: 낮은 피치 잔향(0.15s 지연) — 산울림
		local echo = sound:Clone()
		echo.Volume = sound.Volume * 0.5
		echo.PlaybackSpeed = 0.6
		echo.Parent = root
		task.delay(0.15, function()
			if echo.Parent then
				echo:Play()
			end
		end)
		Debris:AddItem(echo, 6)
	end
	local gy = rollGroundY(rt, root.Position)
	-- [2026-07-24 QA] 포효 링 3연속→1개(사장님 지시: 의미없는 파티클 정리). 단발 파문만
	for wave = 1, 1 do
		task.delay((wave - 1) * 0.22, function()
			if not (root and root.Parent) then
				return
			end
			local ring = Instance.new("Part")
			ring.Name = "WolfRoarRing"
			ring.Shape = Enum.PartType.Cylinder
			ring.Size = Vector3.new(0.4, 6, 6)
			ring.CFrame = CFrame.new(root.Position.X, gy + 0.4, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
			ring.Anchored = true
			ring.CanCollide = false
			ring.CanQuery = false
			ring.CanTouch = false
			ring.CastShadow = false
			ring.Material = Enum.Material.Neon
			ring.Color = Color3.fromRGB(255, 60, 150)
			ring.Transparency = 0.15 + (wave - 1) * 0.15
			ring.Parent = bossFolder
			pcall(function()
				TweenService:Create(ring, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = Vector3.new(0.4, 50 + wave * 25, 50 + wave * 25),
					Transparency = 1,
				}):Play()
			end)
			Debris:AddItem(ring, 1)
		end)
	end
end

-- 하울 전용 절차 모션: 고개 젖힘 포즈(Neck +55도/Waist +15도 = 런타임 실측, +X가 고개 위). C0 오프셋은 애니 Transform과 합성되므로 트랙 정지 불필요 — 발동 후 원복 클로저 반환.
-- 원포즈 캐시(약참조 키): 앞 모션의 원복 트윈 전에 다음 모션이 젖혀진 C0를 원자세로 재캡처하면 뒤로 접힘이 누적된다 → 최초 1회(휴식 자세)만 캡처해 재사용.
local wolfPoseBase = setmetatable({}, { __mode = "k" }) -- [model] = { [Motor6D] = 원본 C0 }
local function wolfBaseC0(model, joint)
	local t = wolfPoseBase[model]
	if not t then
		t = setmetatable({}, { __mode = "k" })
		wolfPoseBase[model] = t
	end
	if t[joint] == nil then
		t[joint] = joint.C0
	end
	return t[joint]
end

local HOWL_NECK_DEG = 62
local HOWL_WAIST_DEG = 20
local function wolfHowlMotion(rt, windup)
	local model = rt.Model
	if not (model and model.Parent) then
		return nil
	end
	local neck, waist
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") then
			if d.Name == "Neck" then
				neck = d
			elseif d.Name == "Waist" then
				waist = d
			end
		end
	end
	if not neck then
		return nil
	end
	local neckC0 = wolfBaseC0(model, neck) -- [2026-07-21] 원포즈 캐시(연속 패턴 드리프트 방지)
	local waistC0 = waist and wolfBaseC0(model, waist)
	local cancelled = false
	windup = windup or 0.8
	local dipSec = math.min(0.22, windup * 0.3)
	local upSec = math.max(0.2, windup * 0.5)
	local function tw(joint, sec, style, dir, c0)
		TweenService:Create(joint, TweenInfo.new(sec, style, dir), { C0 = c0 }):Play()
	end
	task.spawn(function()
		pcall(function()
			-- 1) 움추림: 고개 숙이고 상체 낮춤 — 젮힘 직전 낙차가 위엄을 만듦
			tw(neck, dipSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, neckC0 * CFrame.Angles(math.rad(-16), 0, 0))
			if waist then
				tw(waist, dipSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, waistC0 * CFrame.Angles(math.rad(-7), 0, 0))
			end
			task.wait(dipSec)
			if cancelled then
				return
			end
			-- 2) 큰 젮힘: 목+허리 동시 — 상체 전체가 일어서는 실루엣
			tw(neck, upSec, Enum.EasingStyle.Back, Enum.EasingDirection.Out, neckC0 * CFrame.Angles(math.rad(HOWL_NECK_DEG), 0, 0))
			if waist then
				tw(waist, upSec, Enum.EasingStyle.Back, Enum.EasingDirection.Out, waistC0 * CFrame.Angles(math.rad(HOWL_WAIST_DEG), 0, 0))
			end
			task.wait(upSec)
			-- 3) 정점 포효 진동: 원복(cancelled) 전까지 미세 떨림(성대 울림)
			local hi = true
			while not cancelled and neck.Parent do
				local a = hi and (HOWL_NECK_DEG + 4) or (HOWL_NECK_DEG - 3)
				hi = not hi
				tw(neck, 0.09, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, neckC0 * CFrame.Angles(math.rad(a), 0, 0))
				task.wait(0.09)
			end
		end)
	end)
	return function()
		cancelled = true
		if not neck.Parent then
			return
		end
		pcall(function()
			TweenService:Create(neck, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { C0 = neckC0 }):Play()
			if waist and waist.Parent then
				TweenService:Create(waist, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { C0 = waistC0 }):Play()
			end
		end)
	end
end

-- 하울(≤70%): 원형 AoE — 예고 원반 차오름 후 반경 내 전원 피격(원본 runWolfHowl)
local function performWolfHowl(rt)
	local DEF = rt.Def
	local cfg = DEF.Howl
	local humanoid, root = rt.Humanoid, rt.Root
	local restoreHowlPose = nil
	pcall(function()
		if not (cfg and root and root.Parent and humanoid.Health > 0) then
			return
		end
		restoreHowlPose = wolfHowlMotion(rt, cfg.Windup)
		local windup = cfg.Windup or 0.8
		local radius = cfg.Radius or 30
		local gy = rollGroundY(rt, root.Position)
		local center = Vector3.new(root.Position.X, gy, root.Position.Z)
		-- [2026-07-21] 타이밍 게이지(makeTimedDisc) — 채움 완료 = 충격파 임팩트
		local disc = makeTimedDisc(center + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), radius, Color3.fromRGB(255, 60, 150), windup)
		disc.Name = "WolfHowlTelegraph"
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		task.wait(windup)
		if not (root.Parent and humanoid.Health > 0) then
			return
		end
		performWolfRoar(rt) -- 발동 순간 포효 이펙트 겸용
		local dmg = math.floor(DEF.Atk * (cfg.DamageMul or 2.5) + 0.5)
		for _, p in ipairs(Players:GetPlayers()) do
			local pr, phum = alivePlayerParts(p)
			if pr and withinFairRadius(pr.Position, center, radius) then
				local damaged = PlayerDamageService.Apply(phum, dmg)
				-- [2026-07-21 기믹] 공포 감속: 하울 피격 시 FearSec 동안 이속 저하.
				-- 속박(0)·타 시스템 개입 시 불개입(현재값>슬로우 조건+복원 동등비교) — applyPatternSlow는 후방 정의라 인라인 구현
				local fearSlow = cfg.FearSlow
				if damaged and fearSlow and phum.Health > 0 and phum.WalkSpeed > fearSlow then
					local orig = phum.WalkSpeed
					phum.WalkSpeed = fearSlow
					notifyCc(p, "slow", cfg.FearSec or 1.5) -- [2026-07-25 QA] CC 가시화
					local applied = phum.WalkSpeed -- float32 재독(복원 동등비교용)
					task.delay(cfg.FearSec or 1.5, function()
						if phum.Parent and phum.Health > 0 and phum.WalkSpeed == applied then
							phum.WalkSpeed = orig
						end
					end)
				end
			end
		end
	end)
	if restoreHowlPose then
		-- 포효 여운 0.5s 유지 후 스프링백(즉시 내리면 위엄이 죽음) — 조기 return 경로도 지연 원복 보장
		task.delay(0.5, restoreHowlPose)
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	finishWolfActionCooldown(rt, "NextHowlAt", rt.Def.Howl and rt.Def.Howl.Cooldown)
	rt.PatternBusy = false
end

-- 기본 강타: 1페 전방 박스 / 2페 원형 광역 (원본 Update 기본공격 분기)
-- ===== [벽돌대왕 1페] 분리 소환(4벽돌 실개체 독립 자아) =====
-- 벽돌 4개를 별도 모델(프록시)로 소환, 본체는 스폰 지점 은신 앵커. 프록시 피격은 CombatService 리다이렉트(DamageProxyFor+ProxyTarget)로 본체 HP/기여 원장에 합산 — HP바·보상·퀘스트 파이프라인 불변.
-- 고정 구역 4등분(quadX/quadZ): 자기 사분면 플레이어만 추격·공격, 밖은 배회 → 벽돌끼리 안 겹침. HP≤50% 합체(performBrickMerge), 방치 풀힐 시 재분리(resplitBrick).
local BRICK_AGGRO_RANGE = 55 -- 개별 추격 후보 탐색(벽돌 위치 기준, 월드)
local BRICK_ATK_RANGE = 9 -- 근접 슬램 발동 접근 반경
local BRICK_ATK_RADIUS = 7 -- 슬램 피해 반경
local BRICK_ATK_WINDUP = 0.6
local BRICK_ATK_DMG_MUL = 0.8
local BRICK_SLAM_CD_MIN = 2.8 -- 슬램 후 재사용 대기(+VAR 랜덤)
local BRICK_SLAM_CD_VAR = 1.6
local BRICK_HOP_AMP = 0 -- [2026-07-24 QA] 이동 홉 제거(통통 튀는 연출 폐지 — 사장님 지시). 슬라이드만
local BRICK_SLAM_RISE = 7 -- 슬램 치켜오름 높이
local BRICK_MINION_SPEED_MIN = 13 -- 추격 이속
local BRICK_MINION_SPEED_VAR = 4
local BRICK_DASH_MIN = 11 -- 중거리 돌진 발동 최소 거리(슬램 사거리 밖)
local BRICK_DASH_MAX = 34 -- 돌진 발동 최대 거리
local BRICK_DASH_LEN = 30 -- 돌진 경로 길이
local BRICK_DASH_W = 9 -- 돌진 폭
local BRICK_DASH_WINDUP = 0.5 -- 돌진 전조
local BRICK_DASH_SEC = 0.32 -- 돌진 이동 시간
local BRICK_DASH_DMG_MUL = 1.05
local BRICK_DASH_CD_MIN = 7 -- [2026-07-24 QA] 4→7: 미는 공격(돌진) 너무 짦음 → 재사용 간격 확대
local BRICK_DASH_CD_VAR = 3
local BRICK_ROAM_RADIUS = 30 -- 배회/돌진 클램프 반경(존 중심 기준 — 아레나 이탈·낙사 방지)
local BRICK_WANDER_MIN = 2.5 -- 무타겟 배회 리패스 간격(+VAR)
local BRICK_WANDER_VAR = 3
local BRICK_QUAD_MARGIN = 12 -- [2026-07-24 QA] 4→12: 4벽돌 서로 간격 확대(사장님 지시). 축에서 이만큼 떨어뜨려 인접 구역 벽돌과 간격 확보

local function destroyBrickMinions(rt)
	if rt.BrickMirrorConn then
		rt.BrickMirrorConn:Disconnect()
		rt.BrickMirrorConn = nil
	end
	for _, mn in ipairs(rt.BrickMinions or {}) do
		if mn.model and mn.model.Parent then
			mn.model:Destroy()
		end
	end
	rt.BrickMinions = nil
end

-- 본체 은신/해제: 1페 동안 본체는 스폰 지점 앵커+투명+비타겟(Untargetable) — 전투는 프록시가 대행
local function setBrickBossHidden(rt, hidden)
	local model, root = rt.Model, rt.Root
	if not (model and model.Parent and root) then
		return
	end
	if hidden then
		rt.BrickHiddenParts = {}
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") then
				rt.BrickHiddenParts[p] = { t = p.Transparency, col = p.CanCollide, q = p.CanQuery, tou = p.CanTouch }
				p.Transparency = 1
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
			end
		end
		root.Anchored = true
		root.AssemblyLinearVelocity = Vector3.zero
		if rt.BrickBaseHitRadius == nil then
			rt.BrickBaseHitRadius = model:GetAttribute("HitRadius")
		end
		model:SetAttribute("HitRadius", 0)
		model:SetAttribute("Untargetable", true) -- CombatService/SkillService 타겟 탐색 제외
	else
		for p, st in pairs(rt.BrickHiddenParts or {}) do
			if p.Parent then
				p.Transparency = st.t
				p.CanCollide = st.col
				p.CanQuery = st.q
				p.CanTouch = st.tou
			end
		end
		rt.BrickHiddenParts = nil
		model:SetAttribute("Untargetable", nil)
		if rt.BrickBaseHitRadius ~= nil then
			model:SetAttribute("HitRadius", rt.BrickBaseHitRadius)
		end
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

-- 프록시 렌더: pos=발밑 지면 기준점, halfY+치켜오름+홉 가산 후 CFrame 반영(전체 앵커 — 물리 미사용)
local function brickMinionRender(mn, hop)
	if not (mn.part and mn.part.Parent) then
		return
	end
	local y = mn.pos.Y + mn.halfY + 0.15 + (mn.riseY or 0) + (hop or 0)
	mn.part.CFrame = CFrame.new(mn.pos.X, y, mn.pos.Z) * CFrame.Angles(0, mn.yaw, 0)
end

local function spawnBrickMinions(rt)
	local model, root = rt.Model, rt.Root
	if not (model and model.Parent and root and rt.Humanoid) then
		return
	end
	-- [2026-07-25 C5] 모델 스왑(보스=Brick2 골렘)으로 리그 파트 복제 폐지 — 분리 벽돌 = 전용 벽돌 메시(Assets.Drops.Brick) 4개 고정
	local dropsFolder = ReplicatedStorage:FindFirstChild("Assets")
	dropsFolder = dropsFolder and dropsFolder:FindFirstChild("Drops")
	local brickTemplate = dropsFolder and dropsFolder:FindFirstChild("Brick")
	rt.BrickMinions = {}
	local baseC = rt.SpawnPos or root.Position
	for i = 1, 4 do
		local mm = Instance.new("Model")
		mm.Name = "BrickMinion" .. i
		local part
		if brickTemplate and brickTemplate:IsA("BasePart") then
			part = brickTemplate:Clone()
		else
			part = Instance.new("Part")
			part.Color = Color3.fromRGB(198, 96, 72)
			part.Material = Enum.Material.Brick
		end
		part.Size = Vector3.new(9, 3, 4.8) -- 구 리그 벽돌과 유사한 대형 블록
		for _, d in ipairs(part:GetDescendants()) do
			if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("Constraint") then
				d:Destroy()
			end
		end
		part.Name = "Brick"
		part.Anchored = true
		part.CanCollide = false
		part.Massless = true
		part.Parent = mm
		mm.PrimaryPart = part
		local hum = Instance.new("Humanoid")
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.RequiresNeck = false
		hum.BreakJointsOnDeath = false
		pcall(function()
			hum.EvaluateStateMachine = false
		end)
		hum.MaxHealth = rt.Humanoid.MaxHealth
		hum.Health = math.max(rt.Humanoid.Health, 1)
		hum.Parent = mm
		local sz = part.Size
		mm:SetAttribute("MonsterId", rt.Id) -- IsBoss 취급 → 피격 넉백/오버헤드바/플린치 제외
		mm:SetAttribute("HitRadius", (sz.X + sz.Z) / 4)
		mm:SetAttribute("HalfHeight", sz.Y * 0.5)
		mm:SetAttribute("DamageProxyFor", rt.Id)
		local ov = Instance.new("ObjectValue")
		ov.Name = "ProxyTarget"
		ov.Value = model
		ov.Parent = mm
		CollectionService:AddTag(mm, MONSTER_TAG)
		local ang = math.pi * 0.25 + (i - 1) * math.pi * 0.5
		local px = baseC.X + math.sin(ang) * 22
		local pz = baseC.Z + math.cos(ang) * 22
		local gy = rollGroundY(rt, Vector3.new(px, baseC.Y, pz))
		local mn = {
			model = mm, part = part, hum = hum,
			pos = Vector3.new(px, gy, pz), yaw = ang + math.pi, halfY = sz.Y * 0.5, radius = (sz.X + sz.Z) / 4, quadX = (math.sin(ang) >= 0) and 1 or -1, quadZ = (math.cos(ang) >= 0) and 1 or -1,
			speed = BRICK_MINION_SPEED_MIN + math.random() * BRICK_MINION_SPEED_VAR,
			phase = math.random() * math.pi * 2,
			hopFreq = 5.5 + math.random() * 2.5,
			nextAtkAt = os.clock() + 2 + math.random() * 2,
			controlled = false, riseY = 0, slam = nil,
		}
		rt.BrickMinions[i] = mn
		brickMinionRender(mn)
		mm.Parent = bossFolder
	end
end

-- 패턴 전용 강제 슬라이드: dur 동안 from→to 보간(+arcH 포물선 리프트)
local function brickMinionSlideTo(rt, mn, to, dur, arcH, onStep)
	local from = mn.pos
	local t0 = os.clock()
	while mn.part and mn.part.Parent do
		local a = math.min((os.clock() - t0) / math.max(dur, 0.05), 1)
		local p = from:Lerp(to, a)
		local gy = rollGroundY(rt, p)
		mn.pos = Vector3.new(p.X, gy, p.Z)
		local dirV = to - from
		if dirV.Magnitude > 0.5 then
			mn.yaw = math.atan2(dirV.X, dirV.Z)
		end
		mn.riseY = (arcH or 0) * math.sin(a * math.pi)
		brickMinionRender(mn)
		if onStep then
			onStep(mn.pos)
		end
		if a >= 1 then
			break
		end
		task.wait()
	end
	mn.riseY = 0
end

local function brickMinionSlamResolve(rt, mn)
	local dmg = math.floor(rt.Def.Atk * BRICK_ATK_DMG_MUL + 0.5)
	for _, p in ipairs(Players:GetPlayers()) do
		local pr, phum = alivePlayerParts(p)
		if pr and withinFairRadius(pr.Position, mn.slam.center, BRICK_ATK_RADIUS) then
			PlayerDamageService.Apply(phum, dmg)
		end
	end
end

-- 존 중심 기준 배회/돌진 클램프(아레나 밖 이탈·낙사 방지). Y는 유지.
local function brickClampRoam(rt, pos)
	local c = rt.ZoneCenter or rt.SpawnPos
	local off = Vector3.new(pos.X - c.X, 0, pos.Z - c.Z)
	if off.Magnitude > BRICK_ROAM_RADIUS then
		off = off.Unit * BRICK_ROAM_RADIUS
	end
	return Vector3.new(c.X + off.X, pos.Y, c.Z + off.Z)
end

-- [2026-07-22c 고정 구역] 벽돌을 자기 사분면에 confine(겹침 원천 차단). 축에서 BRICK_QUAD_MARGIN 이상 + 반경 클램프.
local function brickClampQuadrant(rt, mn, pos)
	local c = rt.ZoneCenter or rt.SpawnPos
	local dx = pos.X - c.X
	local dz = pos.Z - c.Z
	if mn.quadX >= 0 then dx = math.max(dx, BRICK_QUAD_MARGIN) else dx = math.min(dx, -BRICK_QUAD_MARGIN) end
	if mn.quadZ >= 0 then dz = math.max(dz, BRICK_QUAD_MARGIN) else dz = math.min(dz, -BRICK_QUAD_MARGIN) end
	local off = Vector3.new(dx, 0, dz)
	if off.Magnitude > BRICK_ROAM_RADIUS then
		off = off.Unit * BRICK_ROAM_RADIUS
	end
	return Vector3.new(c.X + off.X, pos.Y, c.Z + off.Z)
end

-- 지정 위치가 이 벽돌의 사분면인지(교전 게이트 — 자기 구역 플레이어만 추격/공격)
local function inMyQuadrant(rt, mn, pos)
	local c = rt.ZoneCenter or rt.SpawnPos
	return ((mn.quadX >= 0) == ((pos.X - c.X) >= 0)) and ((mn.quadZ >= 0) == ((pos.Z - c.Z) >= 0))
end

-- 개별 돌진(중거리): 타겟 방향 직선 경로 전조 → 돌진 슬라이드 + 경로 판정. 각 벽돌이 독립 실행(controlled).
local function brickMinionDash(rt, mn, targetPos)
	local from = mn.pos
	local dirV = Vector3.new(targetPos.X - from.X, 0, targetPos.Z - from.Z)
	local dir = dirV.Magnitude > 0.1 and dirV.Unit or Vector3.new(math.sin(mn.yaw), 0, math.cos(mn.yaw))
	mn.yaw = math.atan2(dir.X, dir.Z)
	brickMinionRender(mn)
	local bc = from + dir * (BRICK_DASH_LEN / 2)
	local boxCf = CFrame.lookAt(Vector3.new(bc.X, from.Y + ROLL_HIT_BOX_HEIGHT / 2, bc.Z),
		Vector3.new(bc.X, from.Y + ROLL_HIT_BOX_HEIGHT / 2, bc.Z) + dir)
	showRollTelegraph(boxCf, Vector3.new(BRICK_DASH_W, ROLL_HIT_BOX_HEIGHT, BRICK_DASH_LEN), BRICK_DASH_WINDUP)
	task.wait(BRICK_DASH_WINDUP)
	if rt.SplitActive and mn.part and mn.part.Parent then
		local start = mn.pos
		local endPos = brickClampQuadrant(rt, mn, start + dir * BRICK_DASH_LEN)
		local dmg = math.floor(rt.Def.Atk * BRICK_DASH_DMG_MUL + 0.5)
		local hitSet = {}
		-- 경로 전체를 돌진 종료 뒤 판정하지 않고, 벽돌이 실제 지나가는 순간의 위치만 판정한다.
		brickMinionSlideTo(rt, mn, endPos, BRICK_DASH_SEC, 1.2, function(pos)
			for _, pl in ipairs(Players:GetPlayers()) do
				if not hitSet[pl] then
					local pr, ph = alivePlayerParts(pl)
					if pr and withinFairRadius(pr.Position, pos, BRICK_DASH_W * 0.5) then
						hitSet[pl] = true
						PlayerDamageService.Apply(ph, dmg)
					end
				end
			end
		end)
	end
	mn.controlled = false
end

-- 1페 루프: 각 벽돌 독립 자아 — 개별 타겟팅·추격/배회·개별 패턴(슬램/돌진). 프록시 전체 앵커 CFrame 구동, 대형/협공 없음.
local function brickMinionLoop(rt, model)
	local snap = capturePlayerSnapshot()
	local lastNow = os.clock()
	while rt.SplitActive and rt.Model == model and model.Parent and rt.Humanoid and rt.Humanoid.Health > 0 do
		task.wait()
		local minions = rt.BrickMinions
		if not minions then
			break
		end
		local now = os.clock()
		local dt = math.min(now - lastNow, 0.1)
		lastNow = now
		local plist = snapshotAlive(snap)
		for _, mn in ipairs(minions) do
			if mn.part.Parent and not mn.controlled then
				if mn.slam then
					-- 슬램 윈드업 진행(제자리 치켜오름) → 만료 시 판정
					local remain = mn.slam.at - now
					if remain > 0 then
						mn.riseY = (1 - remain / BRICK_ATK_WINDUP) * BRICK_SLAM_RISE
					else
						brickMinionSlamResolve(rt, mn)
						mn.slam = nil
						mn.riseY = 0
						mn.nextAtkAt = now + BRICK_SLAM_CD_MIN + math.random() * BRICK_SLAM_CD_VAR
					end
					brickMinionRender(mn)
				else
					-- 개별 타겟: 이 벽돌 위치 기준 존 내 최근접 플레이어
					local tgtRoot, tgtD = nil, math.huge
					for _, se in ipairs(plist) do
						if se.root.Parent and se.hum.Health > 0 and isInZone(rt, se.root.Position) and inMyQuadrant(rt, mn, se.root.Position) then
							local d = Vector3.new(se.root.Position.X - mn.pos.X, 0, se.root.Position.Z - mn.pos.Z).Magnitude
							if d <= BRICK_AGGRO_RANGE and d < tgtD then
								tgtRoot, tgtD = se.root, d
							end
						end
					end
					-- 패턴 판정: 근접=슬램 / 중거리=돌진(각자 자기 쿨)
					local acted = false
					-- [2026-07-24 QA] 슬램(내려찍기) 제거 — 미는 공격(돌진)만 유지(사장님 지시). 근접 포함 전 사거리에서 돌진
					if tgtRoot and now >= mn.nextAtkAt and tgtD <= BRICK_DASH_MAX then
						mn.nextAtkAt = now + BRICK_DASH_CD_MIN + math.random() * BRICK_DASH_CD_VAR
						mn.controlled = true
						local tp = tgtRoot.Position
						task.spawn(function()
							local ok, err = pcall(brickMinionDash, rt, mn, tp)
							if not ok then
								warn("[FieldBossService] BrickMinion dash: " .. tostring(err))
								mn.controlled = false
							end
						end)
						acted = true
					end
					-- 이동(공격 미개시): 타겟 추격 / 무타겟 = 배회(존 중심 반경 클램프)
					if not acted and not mn.slam and not mn.controlled then
						local goal
						if tgtRoot then
							goal = tgtRoot.Position
							mn.wanderTarget = nil
						else
							if not mn.wanderTarget or Vector3.new(mn.wanderTarget.X - mn.pos.X, 0, mn.wanderTarget.Z - mn.pos.Z).Magnitude < 3 or now >= (mn.repathAt or 0) then
								mn.repathAt = now + BRICK_WANDER_MIN + math.random() * BRICK_WANDER_VAR
								local a = math.random() * math.pi * 2
								local r = BRICK_ROAM_RADIUS * (0.3 + 0.6 * math.random())
								local c = rt.ZoneCenter or rt.SpawnPos
								mn.wanderTarget = brickClampQuadrant(rt, mn, Vector3.new(c.X + math.sin(a) * r, mn.pos.Y, c.Z + math.cos(a) * r))
							end
							goal = mn.wanderTarget
						end
						local dirV = Vector3.new(goal.X - mn.pos.X, 0, goal.Z - mn.pos.Z)
						-- 추격은 슬램 사거리 직전까지만 접근(밀착 겹침 방지)
						local stopDist = tgtRoot and (BRICK_ATK_RANGE - 2) or 0.5
						if dirV.Magnitude > stopDist then
							local step = math.min(mn.speed * dt, dirV.Magnitude - stopDist)
							local np = brickClampQuadrant(rt, mn, mn.pos + dirV.Unit * step)
							local gy = rollGroundY(rt, np)
							mn.pos = Vector3.new(np.X, gy, np.Z)
							mn.yaw = math.atan2(dirV.X, dirV.Z)
						end
						local hop = math.abs(math.sin(now * mn.hopFreq + mn.phase)) * BRICK_HOP_AMP
						brickMinionRender(mn, hop)
					end
				end
			end
		end
	end
	-- 비정상 종료(본체 사망/모델 소실): 프록시 정리 — 합체 경로(SplitActive=false 선행)는 performBrickMerge가 정리
	if rt.SplitActive then
		rt.SplitActive = false
		destroyBrickMinions(rt)
	end
end

-- 1페 진입 오케스트레이터(스폰·재분리 공용): 프록시 소환 → 본체 은신 → HP 미러 → 코디네이터 기동
local function enterBrickSplit(rt)
	local model = rt.Model
	if not (model and model.Parent and rt.Root and rt.Humanoid) then
		return
	end
	destroyBrickMinions(rt)
	spawnBrickMinions(rt)
	setBrickBossHidden(rt, true)
	rt.BrickMirrorConn = rt.Humanoid.HealthChanged:Connect(function(h)
		if h <= 0 then
			rt.SplitActive = false
			destroyBrickMinions(rt)
			return
		end
		for _, mn in ipairs(rt.BrickMinions or {}) do
			if mn.hum.Parent then
				mn.hum.Health = h
			end
		end
	end)
	rt.SplitActive = true
	task.spawn(brickMinionLoop, rt, model)
end

local function brickMergeValid(rt, model, root, hum)
	if rt.DeathHandled or rt.Model ~= model or rt.Root ~= root or rt.Humanoid ~= hum then
		return false
	end
	return model ~= nil and model.Parent ~= nil
		and root ~= nil and root.Parent ~= nil
		and hum ~= nil and hum.Parent ~= nil and hum.Health > 0
end

local function performBrickMerge(rt)
	local model, root, hum = rt.Model, rt.Root, rt.Humanoid
	local merged = false
	local ok, err = pcall(function()
		if not brickMergeValid(rt, model, root, hum) then
			return
		end
		-- 진행 중 개별 돌진 종료 대기(프록시 제어권 경합 방지)
		local waited = 0
		while waited < 1.2 do
			local anyBusy = false
			for _, mn in ipairs(rt.BrickMinions or {}) do
				if mn.controlled then
					anyBusy = true
					break
				end
			end
			if not anyBusy then
				break
			end
			task.wait(0.1)
			waited += 0.1
		end
		if not brickMergeValid(rt, model, root, hum) then
			return
		end
		-- 살아있는 프록시들의 무게중심으로 수렴한다.
		local center, csum, cn = rt.SpawnPos, Vector3.zero, 0
		for _, mn in ipairs(rt.BrickMinions or {}) do
			if mn.part and mn.part.Parent then
				csum += mn.pos
				cn += 1
			end
		end
		if cn > 0 then
			center = csum / cn
		end
		local gy = rollGroundY(rt, center)
		center = Vector3.new(center.X, gy, center.Z)
		makeTimedDisc(center + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), 8, Color3.fromRGB(255, 170, 60), 0.65)
		local minions = rt.BrickMinions
		if minions then
			local done = 0
			for i, mn in ipairs(minions) do
				mn.controlled = true
				task.spawn(function()
					if mn.part and mn.part.Parent then
						local inPos = center + Vector3.new(math.sin(i * 1.7) * 1.5, 0, math.cos(i * 1.7) * 1.5)
						brickMinionSlideTo(rt, mn, inPos, 0.65, 6)
					end
					done += 1
				end)
			end
			local deadline = os.clock() + 1.4
			while done < #minions and os.clock() < deadline do
				task.wait(0.05)
			end
		end
		if not brickMergeValid(rt, model, root, hum) then
			return
		end
		destroyBrickMinions(rt)
		-- 루트와 최하단 벽돌의 간격으로 접지 높이를 계산한다.
		local rootToBottom = 0
		for _, m in ipairs(model:GetDescendants()) do
			if m:IsA("Motor6D") and m.Part0 == root and m.Part1 then
				local d = root.Position.Y - (m.Part1.Position.Y - m.Part1.Size.Y / 2)
				if d > rootToBottom then
					rootToBottom = d
				end
			end
		end
		rt.BrickStandY = rootToBottom + 0.15
		root.CFrame = CFrame.new(center.X, gy + rt.BrickStandY, center.Z)
		setBrickBossHidden(rt, false)
		performWolfRoar(rt)
		-- 재소환 시 기본 정의로 복원된다.
		local cfg = rt.Def.MergePhase or {}
		local buffed = table.clone(rt.Def)
		buffed.Atk = math.floor(rt.Def.Atk * (cfg.AtkMul or 1.2) + 0.5)
		buffed.AtkInterval = rt.Def.AtkInterval * (cfg.IntervalMul or 0.8)
		buffed.WalkSpeed = rt.Def.WalkSpeed * (cfg.SpeedMul or 1.3)
		local cdMul = cfg.CooldownMul or 0.7
		for _, key in ipairs({ "TripleThrow", "FireZone", "BrickWalls", "BrickTripleCharge", "BrickRainSlam" }) do
			local pat = rt.Def[key]
			if type(pat) == "table" then
				local p2 = table.clone(pat)
				p2.Cooldown = (tonumber(pat.Cooldown) or 5) * cdMul
				buffed[key] = p2
			end
		end
		rt.Def = buffed
		hum.WalkSpeed = buffed.WalkSpeed
		startBrickWeldLoop(rt)
		merged = true
	end)
	if not ok then
		warn("[FieldBossService] 벽돌 합체 실패 | " .. tostring(err))
	end
	if merged and brickMergeValid(rt, model, root, hum) then
		local now = os.clock()
		rt.NextCycleAt = now + 1.2
		rt.NextBrickWallsAt = now + 2.5
		rt.NextBrickChargeAt = now + 4.5
		rt.NextBrickRainAt = now + 6.5
	end
	rt.PatternBusy = false
end

-- [2026-07-20→22] 방치 완전회복 시 합체(2페)→분리(1페) 복원: 강체고정 해제→스탯 원복→스폰 복귀→재분리.
local function resplitBrick(rt)
	local model = rt.Model
	if not (model and model.Parent and rt.Root) then
		return
	end
	if rt.BrickWeldConn then
		rt.BrickWeldConn:Disconnect()
		rt.BrickWeldConn = nil
	end
	for _, m in ipairs(model:GetDescendants()) do
		if m:IsA("Motor6D") and m.Part0 and m.Part0.Name == "HumanoidRootPart" and m.Part1 then
			m.Part1.Anchored = false
		end
	end
	if rt.BaseDef then
		rt.Def = rt.BaseDef
	end
	if rt.Humanoid then
		rt.Humanoid.WalkSpeed = rt.Def.WalkSpeed
	end
	rt.Root.CFrame = CFrame.new(rt.SpawnPos)
	rt.Root.AssemblyLinearVelocity = Vector3.zero
	enterBrickSplit(rt)
end

-- [2026-07-21 패턴 개편] 물어뜯기 WolfBite: 전방 좁은 박스 전조 → 판정 → 런지 스냅(앞으로 7 찌르고 복귀).
-- WolfBoss_m은 스킨드 메시(조인트 없음) — 모션은 루트 CFrame 구동만 가능(앞초 모션 규약).
local function performWolfBite(rt, targetRoot)
	local DEF = rt.Def
	local cfg = DEF.WolfBite or {}
	local humanoid, root = rt.Humanoid, rt.Root
	pcall(function()
		if not (root and root.Parent and humanoid.Health > 0 and targetRoot) then
			return
		end
		wolfPlayAttackAnim(rt, 1) -- [2026-07-21] 구 Wolf 리그 실애니(AttackP1) — 미보유 리그(WolfBoss_m)는 내부서 조용히 스킵
		local windup = cfg.Windup or 0.55
		local dmg = math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5)
		local gy = rollGroundY(rt, root.Position)
		local center = Vector3.new(root.Position.X, gy, root.Position.Z)
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local dirV = (targetRoot.Position - root.Position) * Vector3.new(1, 0, 1)
		local dir = dirV.Magnitude > 0.1 and dirV.Unit or Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
		local len = cfg.BoxLen or 16
		local width = cfg.BoxWidth or 10
		local bc = center + dir * (len / 2)
		local boxCf = CFrame.lookAt(Vector3.new(bc.X, gy + ROLL_HIT_BOX_HEIGHT / 2, bc.Z),
			Vector3.new(bc.X, gy + ROLL_HIT_BOX_HEIGHT / 2, bc.Z) + dir)
		showRollTelegraph(boxCf, Vector3.new(width, ROLL_HIT_BOX_HEIGHT, len), windup)
		root.CFrame = CFrame.lookAt(root.Position, root.Position + dir) -- 조준 고정(예측 없음 — 정면 회피 가능)
		task.wait(windup)
		if not (root.Parent and humanoid.Health > 0) then
			return
		end
		for _, p in ipairs(Players:GetPlayers()) do
			local pr, phum = alivePlayerParts(p)
			if pr then
				local to = Vector3.new(pr.Position.X - center.X, 0, pr.Position.Z - center.Z)
				local fwd = to:Dot(dir)
				local side = (to - dir * fwd).Magnitude
				if fwd >= 0 and fwd <= fairRadius(len) and side <= fairHalfWidth(width) then
					PlayerDamageService.Apply(phum, dmg)
				end
			end
		end
		-- 런지 모션: 전방 스냅 후 복귀(판정은 위 전조 박스가 진실 — 순수 연출)
		local lunge = cfg.LungeDist or 7
		local baseCf = root.CFrame
		root.Anchored = true
		local OUT_SEC, BACK_SEC = 0.12, 0.18
		local t0 = os.clock()
		while root.Parent and humanoid.Health > 0 do
			local e = os.clock() - t0
			local a
			if e < OUT_SEC then
				a = e / OUT_SEC
			elseif e < OUT_SEC + BACK_SEC then
				a = 1 - ((e - OUT_SEC) / BACK_SEC)
			else
				break
			end
			root.CFrame = baseCf * CFrame.new(0, 0, -lunge * a) * CFrame.Angles(math.rad(-10 * a), 0, 0)
			task.wait()
		end
		if root.Parent then
			root.CFrame = baseCf
		end
	end)
	if rt.Root and rt.Root.Parent then
		rt.Root.Anchored = false
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	finishWolfActionCooldown(rt, "NextCycleAt", rt.Def.WolfBite and rt.Def.WolfBite.Cooldown)
	rt.PatternBusy = false
end

-- [2026-07-21] 광폭화(HP≤50% 1회): 포효 연출+붉은 하이라이트+버프(공/이속/쿨) — 버프는 Def 클론
-- (벽돌대왕 합체 규약: 재소환 spawnBoss·방치 풀힐 updateIdleReset이 BaseDef 원복). FrenzyDash 해금은 rt.WolfFrenzy 플래그.
local function performWolfFrenzy(rt)
	local humanoid, root = rt.Humanoid, rt.Root
	pcall(function()
		if not (root and root.Parent and humanoid.Health > 0) then
			return
		end
		local cfg = rt.Def.Frenzy or {}
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		performWolfRoar(rt)
		-- 클라 대사/셰이크 큐(FxController WolfFrenzyCue 매칭)
		local cue = Instance.new("Part")
		cue.Name = "WolfFrenzyCue"
		cue.Size = Vector3.new(1, 1, 1)
		cue.Transparency = 1
		cue.Anchored = true
		cue.CanCollide = false
		cue.CanQuery = false
		cue.CanTouch = false
		cue.CFrame = CFrame.new(root.Position)
		cue.Parent = bossFolder
		Debris:AddItem(cue, 1)
		-- 광폭화 상시 시각 상태: 붉은 하이라이트(풀힐 리셋/재소환 시 제거)
		if rt.Model and not rt.Model:FindFirstChild("WolfFrenzyGlow") then
			local glow = Instance.new("Highlight")
			glow.Name = "WolfFrenzyGlow"
			glow.FillColor = Color3.fromRGB(255, 40, 40)
			glow.FillTransparency = 0.85
			glow.OutlineColor = Color3.fromRGB(255, 70, 70)
			glow.OutlineTransparency = 0.4
			glow.Parent = rt.Model
		end
		local encounter = rt.BaseDef or rt.Def -- 누적 배율 방지: 항상 이번 시도의 비광폭 Def에서 재생성
		local buffed = table.clone(encounter)
		buffed.Atk = math.floor(encounter.Atk * (cfg.AtkMul or 1.2) + 0.5)
		buffed.WalkSpeed = encounter.WalkSpeed * (cfg.SpeedMul or 1.4)
		local cdMul = cfg.CooldownMul or 0.75
		for _, key in ipairs({ "WolfBite", "LeapSlam", "Howl", "FrenzyDash", "ClawWave" }) do
			local pat = encounter[key]
			if type(pat) == "table" then
				local p2 = table.clone(pat)
				p2.Cooldown = (tonumber(pat.Cooldown) or 5) * cdMul
				buffed[key] = p2
			end
		end
		rt.Def = buffed
		humanoid.WalkSpeed = buffed.WalkSpeed
		task.wait(1.1) -- 포효 여운(행동 정지 — 플레이어 프리딜 타임)
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + 0.5
	-- [2026-08-12] 🔴광폭 전환 즉시 3연타 돌진 방지 유예.
	--   FrenzyDash는 ARM_SPECS에 없어 포효 여운 직후 바로 터질 수 있는데,
	--   3연타 누계가 Lv16 기본 HP의 96%라 '광폭 전환 = 즉사'가 된다.
	--   피해를 낮추는 대신 타이밍만 고쳐 술 돌릴 틈을 보장한다.
	rt.NextFrenzyDashAt = os.clock() + 4
	rt.NextBloodHuntAt = os.clock() + 6
	rt.PatternBusy = false
end

-- [2026-07-21] 광폭화 시그니처: 연속 돌진(DashCount회) — 회마다 재조준·짧아지는 윈드업, 옆 회피 반복.
-- 판정/모션은 performCharge 규약(스냅샷·1인 1회·넉백·root 앵커 슬라이드) 재사용.
local function performWolfFrenzyDash(rt, targetRoot)
	local humanoid, root = rt.Humanoid, rt.Root
	pcall(function()
		local cfg = rt.Def.FrenzyDash
		if not (cfg and root and root.Parent and humanoid.Health > 0 and targetRoot) then
			return
		end
		humanoid.AutoRotate = false
		for i = 1, (cfg.DashCount or 3) do
			if not (root.Parent and humanoid.Health > 0 and targetRoot.Parent) then
				break
			end
			local origin = root.Position
			local dirV = (targetRoot.Position - origin) * Vector3.new(1, 0, 1)
			if dirV.Magnitude < 0.5 then
				break
			end
			local dir = dirV.Unit
			local width = cfg.Width or 12
			local dist = clampDashDist(rt, origin, dir, cfg.Dist or 30) -- [2026-08-08] 존 이탈 봉쇄
			if dist < 2 then
				break -- 경계 코앞 — 남은 돌진 생략(꼬리에서 정상 해제)
			end
			local windup = (cfg.Windups and cfg.Windups[i]) or 0.5
			local gy = rollGroundY(rt, origin)
			local center = Vector3.new(origin.X, gy + ROLL_HIT_BOX_HEIGHT / 2, origin.Z) + dir * (dist / 2)
			showRollTelegraph(CFrame.lookAt(center, center + dir), Vector3.new(width, ROLL_HIT_BOX_HEIGHT, dist), windup)
			local realFrontDash = playBossPatternAnim(rt, "FrontDash")
			if not realFrontDash then
				wolfPlayAttackAnim(rt, 2) -- 게시된 FrontDash가 없을 때만 기존 AttackP2 폴백
			end
			humanoid:MoveTo(origin)
			root.CFrame = CFrame.lookAt(origin, origin + dir)
			task.wait(windup)
			if not (root.Parent and humanoid.Health > 0) then
				break
			end
			local _, _, dashMarkerState, dashGeneration = playBossPatternAnim(rt, "DashAttack")
			if dashMarkerState then
				FieldBossService._waitWolfAnimationMarker(rt, dashMarkerState, dashGeneration, "Swing", 0, 0.18)
				if dashMarkerState.Generation ~= dashGeneration
					or dashMarkerState.CancelledGeneration == dashGeneration
					or rt.Model ~= dashMarkerState.Model then
					break
				end
			end
			root.Anchored = true
			local hitSet = {}
			local snap = capturePlayerSnapshot()
			local moveTime = cfg.MoveTime or 0.42
			local baseY = root.Position.Y
			local t0 = os.clock()
			while true do
				if humanoid.Health <= 0 or not root.Parent then
					return
				end
				local a = math.min((os.clock() - t0) / moveTime, 1)
				local pos = origin + dir * (dist * a)
				root.CFrame = CFrame.lookAt(Vector3.new(pos.X, baseY, pos.Z), Vector3.new(pos.X, baseY, pos.Z) + dir)
					* CFrame.Angles(math.rad(-16 * math.sin(a * math.pi)), 0, 0)
				local hitWindowOpen = not dashMarkerState
					or dashMarkerState.Reached.Hit == dashGeneration
					or a >= 0.55 -- 잘못 게시된 마커 때문에 무피해 돌진이 되지 않는 안전 폴백
				if hitWindowOpen then
					for _, se in ipairs(snapshotAlive(snap)) do
						if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
							local pr, ph = se.root, se.hum
							if withinFairRadius(pr.Position, pos, width * 0.5) then
								hitSet[se.player] = true
								local falloff = (cfg.HitFalloff and cfg.HitFalloff[i]) or 1
								local damaged = PlayerDamageService.Apply(ph, math.floor(rt.Def.Atk * (cfg.DamageMul or 1) * falloff + 0.5))
								local kb = cfg.Knockback
								if damaged and kb then
									MonsterService.KnockbackPlayer(se.player, pos, kb.Force, kb.Lift)
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
			root.Anchored = false
			if dashMarkerState then
				FieldBossService._waitWolfAnimationMarker(rt, dashMarkerState, dashGeneration, "Reset", 0, 0.75)
			end
			-- [2026-07-21 최종보스] 발톱 자국 장판: 돌진 경로 잔류 지대(틱댐) — 광폭화 아레나 통제
			if cfg.ScarSec then
				for s = 1, (cfg.ScarCount or 3) do
					local sp = origin + dir * (dist * (s - 0.5) / (cfg.ScarCount or 3))
					local sy = rollGroundY(rt, sp)
					local scar = Instance.new("Part")
					scar.Name = "WolfScarZone"
					scar.Shape = Enum.PartType.Cylinder
					scar.Size = Vector3.new(0.3, (cfg.ScarRadius or 5) * 2, (cfg.ScarRadius or 5) * 2)
					scar.CFrame = CFrame.new(sp.X, sy + 0.15, sp.Z) * CFrame.Angles(0, 0, math.rad(90))
					scar.Anchored = true
					scar.CanCollide = false
					scar.CanQuery = false
					scar.CanTouch = false
					scar.CastShadow = false
					scar.Material = Enum.Material.Neon
					scar.Color = Color3.fromRGB(255, 80, 60)
					scar.Transparency = 0.5
					scar.Parent = bossFolder
					Debris:AddItem(scar, cfg.ScarSec)
					task.spawn(function()
						local zt0 = os.clock()
						while scar.Parent and os.clock() - zt0 < (cfg.ScarSec or 3) do
							for _, zp in ipairs(Players:GetPlayers()) do
								local zr, zh = alivePlayerParts(zp)
								if zr and withinFairRadius(zr.Position, sp, cfg.ScarRadius or 5) then
									PlayerDamageService.Apply(zh, cfg.ScarTick or 5)
								end
							end
							task.wait(0.5)
						end
					end)
				end
			end
			task.wait(cfg.DashGap or 0.25)
		end
	end)
	if rt.Root and rt.Root.Parent then
		rt.Root.Anchored = false
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	finishWolfActionCooldown(rt, "NextFrenzyDashAt", rt.Def.FrenzyDash and rt.Def.FrenzyDash.Cooldown)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- [2026-07-21] 발톱 파동 전용 모션: 윈드업 동안 양팔 치켜들기+상체 젣힘 → 발사 순간 내리긁기.
-- wolfHowlMotion 규약(C0 캐처→트윈→원복 클로저, 애니 Transform과 합성). R15 조인트명 — 미보유 리그는 no-op.
local function wolfClawMotion(rt, windup)
	local model = rt.Model
	if not (model and model.Parent) then
		return nil
	end
	local rs, ls, waist
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") then
			if d.Name == "RightShoulder" then
				rs = d
			elseif d.Name == "LeftShoulder" then
				ls = d
			elseif d.Name == "Waist" then
				waist = d
			end
		end
	end
	if not (rs or ls) then
		return nil
	end
	local rsC0 = rs and wolfBaseC0(model, rs) -- [2026-07-21] 원포즈 캐시(연속 패턴 드리프트 방지)
	local lsC0 = ls and wolfBaseC0(model, ls)
	local waistC0 = waist and wolfBaseC0(model, waist)
	local cancelled = false
	windup = windup or 0.85
	local function tw(joint, sec, style, dir, c0)
		TweenService:Create(joint, TweenInfo.new(sec, style, dir), { C0 = c0 }):Play()
	end
	task.spawn(function()
		pcall(function()
			-- 1) 치켜들기: 양팔 위로 + 상체 뒤로(윈드업 내내 유지)
			local upSec = math.min(0.4, windup * 0.5)
			if rs then
				tw(rs, upSec, Enum.EasingStyle.Back, Enum.EasingDirection.Out, rsC0 * CFrame.Angles(math.rad(-150), 0, math.rad(18)))
			end
			if ls then
				tw(ls, upSec, Enum.EasingStyle.Back, Enum.EasingDirection.Out, lsC0 * CFrame.Angles(math.rad(-150), 0, math.rad(-18)))
			end
			if waist then
				tw(waist, upSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, waistC0 * CFrame.Angles(math.rad(14), 0, 0))
			end
			local t0 = os.clock()
			while not cancelled and os.clock() - t0 < math.max(windup - 0.08, upSec) do
				task.wait(0.03)
			end
			if cancelled then
				return
			end
			-- 2) 내리긁기(발사 동기): 빠른 다운스잉 + 상체 숙임
			if rs then
				tw(rs, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In, rsC0 * CFrame.Angles(math.rad(38), 0, math.rad(-8)))
			end
			if ls then
				tw(ls, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In, lsC0 * CFrame.Angles(math.rad(38), 0, math.rad(8)))
			end
			if waist then
				tw(waist, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In, waistC0 * CFrame.Angles(math.rad(-20), 0, 0))
			end
			task.wait(0.35)
			if cancelled then
				return
			end
			-- 3) 원복
			if rs and rs.Parent then
				tw(rs, 0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, rsC0)
			end
			if ls and ls.Parent then
				tw(ls, 0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, lsC0)
			end
			if waist and waist.Parent then
				tw(waist, 0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, waistC0)
			end
		end)
	end)
	return function()
		if cancelled then
			return
		end
		cancelled = true
		pcall(function()
			if rs and rs.Parent then
				tw(rs, 0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, rsC0)
			end
			if ls and ls.Parent then
				tw(ls, 0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, lsC0)
			end
			if waist and waist.Parent then
				tw(waist, 0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, waistC0)
			end
		end)
	end
end

-- [2026-07-21] 도약 덮치기 모션(전방선언 바인딩 — performLeapSlam이 cfg.PounceMotion 게이트로 호출):
-- 공중 양팔 크게 벌려 치켜들기(덮치기 자세) → 착지 직전 내리찍기 → 원복. 원포즈 캐시 사용(드리프트 방지).
wolfPounceMotion = function(rt, airTime)
	local model = rt.Model
	if not (model and model.Parent) then
		return
	end
	local rs, ls
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Motor6D") then
			if d.Name == "RightShoulder" then
				rs = d
			elseif d.Name == "LeftShoulder" then
				ls = d
			end
		end
	end
	if not (rs or ls) then
		return
	end
	local rsC0 = rs and wolfBaseC0(model, rs)
	local lsC0 = ls and wolfBaseC0(model, ls)
	pcall(function()
		airTime = airTime or 0.9
		local up = math.max(airTime * 0.4, 0.2)
		-- 공중: 양팔 위+옆으로 크게 벌림(덮치기 준비)
		if rs then
			TweenService:Create(rs, TweenInfo.new(up, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { C0 = rsC0 * CFrame.Angles(math.rad(-135), 0, math.rad(38)) }):Play()
		end
		if ls then
			TweenService:Create(ls, TweenInfo.new(up, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { C0 = lsC0 * CFrame.Angles(math.rad(-135), 0, math.rad(-38)) }):Play()
		end
		task.wait(math.max(airTime - 0.12, up))
		if not (model.Parent and rs and rs.Parent or ls and ls.Parent) then
			return
		end
		-- 착지: 내리찍기
		if rs and rs.Parent then
			TweenService:Create(rs, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { C0 = rsC0 * CFrame.Angles(math.rad(40), 0, math.rad(-6)) }):Play()
		end
		if ls and ls.Parent then
			TweenService:Create(ls, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { C0 = lsC0 * CFrame.Angles(math.rad(40), 0, math.rad(6)) }):Play()
		end
		task.wait(0.3)
	end)
	-- 원복(조기 이탈 포함 보장)
	pcall(function()
		if rs and rs.Parent then
			TweenService:Create(rs, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { C0 = rsC0 }):Play()
		end
		if ls and ls.Parent then
			TweenService:Create(ls, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { C0 = lsC0 }):Play()
		end
	end)
end

-- [2026-07-23] 발톱 파동 비주얼: 열파참 SwordWave 메시 재사용(적색 틴트·확대) — 구 3날 네온 박스 대체, 판정 불변
local function makeClawWavePart(scaleMul)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local effect = assets and assets:FindFirstChild("Effect")
	local models = effect and effect:FindFirstChild("SkillFxModels")
	local template = models and models:FindFirstChild("SwordWave")
	if not template then
		return nil -- 템플릿 부재 시 호출부가 네온 폴백
	end
	local wp = template:Clone()
	wp.Name = "WolfClawWaveFx"
	wp.Anchored = true
	wp.CanCollide = false
	wp.CanQuery = false
	wp.CanTouch = false
	local mesh = wp:FindFirstChildOfClass("SpecialMesh")
	if mesh then
		mesh.Scale = mesh.Scale * (scaleMul or 1.5)
		mesh.VertexColor = Vector3.new(1, 0.35, 0.3) -- 늑대 발톱 = 적색 틴트
	end
	for _, d in ipairs(wp:GetDescendants()) do
		if d:IsA("Decal") then
			d.Color3 = Color3.fromRGB(255, 70, 60)
		elseif d:IsA("ParticleEmitter") then
			d.Color = ColorSequence.new(Color3.fromRGB(255, 100, 80))
		elseif d:IsA("Trail") then
			d.Color = ColorSequence.new(Color3.fromRGB(255, 80, 70))
		elseif d:IsA("Light") then
			d.Color = Color3.fromRGB(255, 90, 70)
		end
	end
	return wp
end

-- [2026-07-21 최종보스] 발톱 파동 ClawWave: 앞발 내려찍기 → 전방 3갈래 낮은 지면 파동 전진.
-- 점프로 넘거나 갈래 사이 회피 — 접지 판정은 VineWhip 규약(FloorMaterial Air + JumpClear).
local function performWolfClawWave(rt, targetRoot)
	local DEF = rt.Def
	local cfg = DEF.ClawWave
	local humanoid, root = rt.Humanoid, rt.Root
	local restoreClawPose = nil
	pcall(function()
		if not (cfg and root and root.Parent and humanoid.Health > 0 and targetRoot) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		-- 전용 모션(치켜들기→내리긁기) — 펌치 애니(AttackP1) 대체(사용자 피드백 2026-07-21)
		restoreClawPose = wolfClawMotion(rt, cfg.Windup or 0.85)
		local origin = root.Position
		local fwd = Vector3.new(targetRoot.Position.X - origin.X, 0, targetRoot.Position.Z - origin.Z)
		fwd = fwd.Magnitude > 0.5 and fwd.Unit or Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
		root.CFrame = CFrame.lookAt(origin, origin + fwd)
		local gy = rollGroundY(rt, origin)
		local baseAngle = math.atan2(fwd.X, fwd.Z)
		local dist = cfg.Dist or 34
		local waves = cfg.Waves or 3
		local dirs = {}
		for i = 1, waves do
			local off = math.rad((i - (waves + 1) / 2) * (cfg.SpreadDeg or 16))
			local d = Vector3.new(math.sin(baseAngle + off), 0, math.cos(baseAngle + off))
			dirs[i] = d
			-- [2026-07-21 직관화] 예고 3층: ①판정폭 그대로의 밴드(파동 종료까지 유지 — 범위 WYSIWYG)
			-- ②윈드업 동안 보스→끝으로 차오르는 채움(가득=발사 — makeTimedDisc 언어) ③가는 3선(할탐 프리뷰)
			local mid = origin + d * (dist / 2)
			local right = Vector3.new(-d.Z, 0, d.X)
			local windupSec = cfg.Windup or 0.85
			local bandW = ((cfg.HitPerp or 3) + 1.5) * 2 -- 판정(HitPerp+슬랭 1.5)과 동일 폭
			local band = Instance.new("Part")
			band.Name = (i == math.ceil(waves / 2)) and "WolfClawTelegraph" or "WolfClawTelegraphLine"
			band.Size = Vector3.new(bandW, 0.25, dist)
			band.CFrame = CFrame.lookAt(Vector3.new(mid.X, gy + TELEGRAPH_Y_OFFSET, mid.Z), Vector3.new(mid.X + d.X, gy + TELEGRAPH_Y_OFFSET, mid.Z + d.Z))
			band.Anchored = true
			band.CanCollide = false
			band.CanQuery = false
			band.CanTouch = false
			band.CastShadow = false
			band.Material = Enum.Material.Neon
			band.Color = Color3.fromRGB(255, 90, 90)
			band.Transparency = TELEGRAPH_TRANSPARENCY
			band.Parent = bossFolder
			Debris:AddItem(band, windupSec + (cfg.WaveTime or 1.15) + 0.2)
			local fill = Instance.new("Part")
			fill.Name = "BossTelegraphFill"
			fill.Size = Vector3.new(bandW - 1, 0.18, 0.5)
			local fs = origin + d * 0.25
			fill.CFrame = CFrame.lookAt(Vector3.new(fs.X, gy + 0.32, fs.Z), Vector3.new(fs.X + d.X, gy + 0.32, fs.Z + d.Z))
			fill.Anchored = true
			fill.CanCollide = false
			fill.CanQuery = false
			fill.CanTouch = false
			fill.CastShadow = false
			fill.Material = Enum.Material.Neon
			fill.Color = Color3.fromRGB(255, 90, 90):Lerp(Color3.new(1, 1, 1), 0.65)
			fill.Transparency = 0.12
			fill.Parent = bossFolder
			Debris:AddItem(fill, windupSec + 0.15)
			pcall(function()
				TweenService:Create(fill, TweenInfo.new(windupSec, Enum.EasingStyle.Linear), {
					Size = Vector3.new(bandW - 1, 0.18, dist),
					CFrame = CFrame.lookAt(Vector3.new(mid.X, gy + 0.32, mid.Z), Vector3.new(mid.X + d.X, gy + 0.32, mid.Z + d.Z)),
				}):Play()
			end)
			for li = -1, 1 do
				local tg = Instance.new("Part")
				tg.Name = "WolfClawScratchLine"
				tg.Size = Vector3.new(0.7, 0.3, dist)
				local lp = mid + right * (li * 2.1)
				tg.CFrame = CFrame.lookAt(Vector3.new(lp.X, gy + 0.42, lp.Z), Vector3.new(lp.X + d.X, gy + 0.42, lp.Z + d.Z))
				tg.Anchored = true
				tg.CanCollide = false
				tg.CanQuery = false
				tg.CanTouch = false
				tg.CastShadow = false
				tg.Material = Enum.Material.Neon
				tg.Color = Color3.fromRGB(255, 60, 60)
				tg.Transparency = 0.35
				tg.Parent = bossFolder
				Debris:AddItem(tg, windupSec + 0.1)
			end
		end
		task.wait(cfg.Windup or 0.85)
		if not (root.Parent and humanoid.Health > 0) then
			return
		end
		-- 발사 순간 임팩트 링(타이밍 앵커): 보스 발밑 확장 링 1회
		local launchRing = Instance.new("Part")
		launchRing.Name = "WolfClawLaunchRing"
		launchRing.Shape = Enum.PartType.Cylinder
		launchRing.Size = Vector3.new(0.35, 4, 4)
		launchRing.CFrame = CFrame.new(origin.X, gy + 0.4, origin.Z) * CFrame.Angles(0, 0, math.rad(90))
		launchRing.Anchored = true
		launchRing.CanCollide = false
		launchRing.CanQuery = false
		launchRing.CanTouch = false
		launchRing.CastShadow = false
		launchRing.Material = Enum.Material.Neon
		launchRing.Color = Color3.fromRGB(255, 120, 90)
		launchRing.Transparency = 0.15
		launchRing.Parent = bossFolder
		pcall(function()
			TweenService:Create(launchRing, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.new(0.35, 22, 22),
				Transparency = 1,
			}):Play()
		end)
		Debris:AddItem(launchRing, 0.45)
		local hitSet = {}
		local snap = capturePlayerSnapshot()
		-- [2026-07-23b] 갈래당 발톱날 3매(가운데가 크고 앞선다 — 앞발 발톱 실루엣): SwordWave 검기 3장 나란히
		local waveFronts = {}
		for i = 1, waves do
			local set = {}
			for li = -1, 1 do
				local wp = makeClawWavePart(li == 0 and 0.95 or 0.7)
				if not wp then
					wp = Instance.new("Part")
					wp.Name = "WolfClawWaveFx"
					wp.Size = Vector3.new(2.6, 4.2 - math.abs(li) * 0.8, 0.7)
					wp.Anchored = true
					wp.CanCollide = false
					wp.CanQuery = false
					wp.CanTouch = false
					wp.CastShadow = false
					wp.Material = Enum.Material.Neon
					wp.Color = Color3.fromRGB(255, 70, 70)
					wp.Transparency = 0.1
				end
				wp.Parent = bossFolder
				set[li + 2] = wp
			end
			waveFronts[i] = set
		end
		local lastDrop = table.create(waves, 0)
		local dur = cfg.WaveTime or 0.9
		local dmg = math.floor(DEF.Atk * (cfg.DamageMul or 0.7) + 0.5)
		local t0 = os.clock()
		while true do
			if not (root.Parent and humanoid.Health > 0) then
				break
			end
			local a = math.min((os.clock() - t0) / dur, 1)
			local reach = dist * a
			for i, d in ipairs(dirs) do
				local pos = origin + d * reach
				local wy = rollGroundY(rt, pos)
				local right = Vector3.new(-d.Z, 0, d.X)
				for li = -1, 1 do
					local wp = waveFronts[i][li + 2]
					if wp and wp.Parent then
						-- 발톱 3날: 양옆 ±2.6 스터드 + 가운데 날이 약간 높고 앞선다. 각도 = SwordWave 규약(WAVE_ANGLES)
						local lead = (li == 0) and 1.2 or 0
						local yOff = (li == 0) and 2.2 or 1.7
						local lp = pos + right * (li * 2.6) + d * lead
						wp.CFrame = CFrame.lookAt(Vector3.new(lp.X, wy + yOff, lp.Z), Vector3.new(lp.X + d.X, wy + yOff, lp.Z + d.Z))
							* CFrame.Angles(math.rad(90), math.rad(45), math.rad(90))
					end
				end
				-- 긁힌 자국 트레일: 5스터드마다 3선 잔흔(0.8s 페이드)
				if reach - lastDrop[i] >= 5 and reach < dist then
					lastDrop[i] = reach
					for li = -1, 1 do
						local sp2 = pos + right * (li * 2.1)
						local mark = Instance.new("Part")
						mark.Name = "WolfClawMark"
						mark.Size = Vector3.new(0.5, 0.12, 4.6)
						mark.CFrame = CFrame.lookAt(Vector3.new(sp2.X, wy + 0.1, sp2.Z), Vector3.new(sp2.X + d.X, wy + 0.1, sp2.Z + d.Z))
						mark.Anchored = true
						mark.CanCollide = false
						mark.CanQuery = false
						mark.CanTouch = false
						mark.CastShadow = false
						mark.Material = Enum.Material.Neon
						mark.Color = Color3.fromRGB(180, 40, 30)
						mark.Transparency = 0.25
						mark.Parent = bossFolder
						pcall(function()
							TweenService:Create(mark, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
						end)
						Debris:AddItem(mark, 0.9)
					end
				end
				for _, se in ipairs(snapshotAlive(snap)) do
					if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
						local rel = Vector3.new(se.root.Position.X - pos.X, 0, se.root.Position.Z - pos.Z)
						if rel.Magnitude <= fairRadius(cfg.HitPerp or 3) then
							local airborne = se.hum.FloorMaterial == Enum.Material.Air or (se.root.Position.Y - wy) > (cfg.JumpClear or 15)
							if not airborne then
								hitSet[se.player] = true
								PlayerDamageService.Apply(se.hum, dmg)
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
		for _, set in ipairs(waveFronts) do
			for _, wp in ipairs(set) do
				wp:Destroy()
			end
		end
	end)
	if restoreClawPose then
		restoreClawPose() -- 정상 종료=이미 원복(무해), 조기 이탈(사망 등)=강제 원복
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	finishWolfActionCooldown(rt, "NextClawAt", rt.Def.ClawWave and rt.Def.ClawWave.Cooldown)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

local tickWolfPhase

do
-- 난이도 전용 원자 패턴: 판정은 서버 고정 전조에만 의존하고 게시 애니메이션은 시각 표현으로만 사용한다.
local function wolfDifficultyStrike(rt, targetRoot, hitIndex, windup, damageMul, boxLen, boxWidth, animationKey)
	local humanoid, root = rt.Humanoid, rt.Root
	if not (root and root.Parent and humanoid and humanoid.Health > 0 and targetRoot and targetRoot.Parent) then
		return false
	end
	local origin = root.Position
	local dirV = (targetRoot.Position - origin) * Vector3.new(1, 0, 1)
	local dir = dirV.Magnitude > 0.2 and dirV.Unit or Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
	local len, width = boxLen or 17, boxWidth or 13
	local gy = rollGroundY(rt, origin)
	local center = Vector3.new(origin.X, gy + ROLL_HIT_BOX_HEIGHT / 2, origin.Z) + dir * (len / 2)
	showRollTelegraph(CFrame.lookAt(center, center + dir), Vector3.new(width, ROLL_HIT_BOX_HEIGHT, len), windup)
	humanoid:MoveTo(origin)
	humanoid.AutoRotate = false
	root.CFrame = CFrame.lookAt(origin, origin + dir)
	local key = animationKey or ("ClawCombo" .. tostring(math.clamp(hitIndex or 1, 1, 5)))
	local played, _, markerState, generation = playBossPatternAnim(rt, key)
	if played and markerState then
		FieldBossService._waitWolfAnimationMarker(rt, markerState, generation, "Hit", windup, 2.5)
		if markerState.Generation ~= generation or markerState.CancelledGeneration == generation
			or rt.Model ~= markerState.Model then
			return false
		end
	else
		task.wait(windup)
	end
	if not (root.Parent and humanoid.Health > 0) then return false end
	local damage = math.floor(rt.Def.Atk * damageMul + 0.5)
	for _, player in ipairs(Players:GetPlayers()) do
		local playerRoot, playerHum = alivePlayerParts(player)
		if playerRoot then
			local delta = Vector3.new(playerRoot.Position.X - origin.X, 0, playerRoot.Position.Z - origin.Z)
			local fwd = delta:Dot(dir)
			local side = (delta - dir * fwd).Magnitude
			if fwd >= 0 and fwd <= fairRadius(len) and side <= fairHalfWidth(width) then
				PlayerDamageService.Apply(playerHum, damage)
			end
		end
	end
	local baseCf = root.CFrame
	root.Anchored = true
	root.CFrame = baseCf * CFrame.new(0, 0, -2.2)
	task.wait(0.06)
	if root.Parent then root.CFrame = baseCf end
	root.Anchored = false
	if markerState then
		-- 다음 연격은 애니메이션의 Reset 프레임에서 즉시 시작한다.
		FieldBossService._waitWolfAnimationMarker(rt, markerState, generation, "Reset", 0, 1.5)
	end
	return true
end

local function wolfDifficultySlide(rt, direction, distance, seconds, animationKey)
	local humanoid, root = rt.Humanoid, rt.Root
	if not (root and root.Parent and humanoid and humanoid.Health > 0) then return false end
	local flat = direction * Vector3.new(1, 0, 1)
	if flat.Magnitude < 0.1 then return false end
	flat = flat.Unit
	local startPos = root.Position
	local desired = clampChasePos(rt, startPos + flat * distance)
	local delta = (desired - startPos) * Vector3.new(1, 0, 1)
	if delta.Magnitude < 1 then return false end
	local gy = rollGroundY(rt, startPos)
	local mid = startPos + delta * 0.5
	local trail = Instance.new("Part")
	trail.Name = "WolfRepositionTrail"
	trail.Size = Vector3.new(2.5, 0.12, delta.Magnitude)
	trail.CFrame = CFrame.lookAt(Vector3.new(mid.X, gy + 0.18, mid.Z), Vector3.new(mid.X, gy + 0.18, mid.Z) + delta.Unit)
	trail.Anchored, trail.CanCollide, trail.CanTouch, trail.CanQuery = true, false, false, false
	trail.Material, trail.Color, trail.Transparency = Enum.Material.Neon, Color3.fromRGB(170, 125, 255), 0.45
	trail.Parent = bossFolder
	Debris:AddItem(trail, seconds + 0.15)
	playBossPatternAnim(rt, animationKey)
	humanoid.AutoRotate = false
	humanoid:MoveTo(startPos)
	root.Anchored = true
	local startCf = root.CFrame
	local t0 = os.clock()
	while root.Parent and humanoid.Health > 0 do
		local alpha = math.min((os.clock() - t0) / seconds, 1)
		local eased = 1 - (1 - alpha) * (1 - alpha)
		local pos = startPos:Lerp(desired, eased)
		local lookAt = pos + Vector3.new(startCf.LookVector.X, 0, startCf.LookVector.Z)
		root.CFrame = CFrame.lookAt(pos, lookAt)
		if alpha >= 1 then break end
		task.wait()
	end
	if root.Parent then root.Anchored = false end
	return true
end

local function finishWolfDifficultyPattern(rt, timerField, cooldown)
	if rt.Root and rt.Root.Parent then rt.Root.Anchored = false end
	if rt.Humanoid and rt.Humanoid.Parent then rt.Humanoid.AutoRotate = true end
	finishWolfActionCooldown(rt, timerField, cooldown)
	rt.NextCycleAt = os.clock() + (rt.Def.AtkInterval or 1)
	rt.PatternBusy = false
end

local function performWolfDifficultyCombo(rt, targetRoot)
	local patterns = rt.Def.WolfDifficultyPatterns or {}
	local hits = math.clamp(patterns.ComboHits or 3, 1, 5)
	local perHit = math.max(0.34, 0.48 - math.max(0, hits - 3) * 0.06)
	pcall(function()
		for hit = 1, hits do
			local windup = hit == 1 and 0.52 or math.max(0.24, 0.38 - hit * 0.025)
			if not wolfDifficultyStrike(rt, targetRoot, hit, windup, perHit, 17 + hit, 13) then break end
		end
	end)
	finishWolfDifficultyPattern(rt, "NextComboAt", patterns.ComboCooldown)
end

local function performWolfDifficultyFlank(rt, targetRoot)
	local patterns = rt.Def.WolfDifficultyPatterns or {}
	pcall(function()
		if not (targetRoot and targetRoot.Parent) then return end
		rt.WolfFlankSide = -(rt.WolfFlankSide or -1)
		local side = rt.Root.CFrame.RightVector * rt.WolfFlankSide
		local key = rt.WolfFlankSide < 0 and "SideDashLeft" or "SideDashRight"
		wolfDifficultySlide(rt, side, 9, 0.24, key)
		for hit = 1, 2 do
			if not wolfDifficultyStrike(rt, targetRoot, hit + 1, hit == 1 and 0.38 or 0.28, 0.46, 16, 12) then break end
		end
	end)
	finishWolfDifficultyPattern(rt, "NextFlankAt", patterns.FlankCooldown)
end

local function performWolfSkyHunt(rt, targetRoot)
	local patterns = rt.Def.WolfDifficultyPatterns or {}
	local succeeded = false
	pcall(function()
		if not wolfDifficultyStrike(rt, targetRoot, 1, 0.50, 0.50, 14, 12, "UpTilt") then return end
		if not wolfDifficultyStrike(rt, targetRoot, 2, 0.34, 0.34, 16, 10, "AirAttack") then return end
		succeeded = true
		performLeapSlam(rt, targetRoot) -- AirSlam/Landing 슬롯과 기존 점프 회피 충격파를 재사용
		finishWolfActionCooldown(rt, "NextSkyHuntAt", patterns.SkyHuntCooldown)
	end)
	if not succeeded then finishWolfDifficultyPattern(rt, "NextSkyHuntAt", patterns.SkyHuntCooldown) end
end

local function performWolfBloodHunt(rt, targetRoot)
	local patterns = rt.Def.WolfDifficultyPatterns or {}
	pcall(function()
		if not (targetRoot and targetRoot.Parent) then return end
		wolfDifficultySlide(rt, -rt.Root.CFrame.RightVector, 8, 0.20, "SideDashLeft")
		for hit = 1, 3 do
			if not wolfDifficultyStrike(rt, targetRoot, hit, hit == 1 and 0.34 or 0.23, 0.36, 18, 12) then break end
		end
		wolfDifficultySlide(rt, -rt.Root.CFrame.LookVector, 7, 0.20, "BackDash")
		wolfDifficultyStrike(rt, targetRoot, 5, 0.40, 0.78, 26, 12, "ShieldHeavy")
	end)
	finishWolfDifficultyPattern(rt, "NextBloodHuntAt", patterns.BloodHuntCooldown)
end

-- WolfPhase 틱 [2026-07-21 패턴 개편]: 사냥꾼 컨셉 — 물어뜯기/도약 덮치기(+착지 충격파 링)/발톱 파동/하울(공포).
-- HP 게이트 없는 혼합 로테이션(QA 0715 사용자 결정 유지) + 광폭화(HP≤40% 1회): 버프+연속 돌진 해금. 무리 소환은 2026-07-21 삭제.
tickWolfPhase = function(rt, targetRoot, targetHum, now, dist)
	local DEF = rt.Def
	rt.Humanoid.WalkSpeed = DEF.WalkSpeed
	-- [2026-07-24 QA] 대형 스킬(하울/도약/발톱파동/광폭돌진) 사이 최소 휴식: 이 시간 동안은 기본 물기만 발동해 "쉰 틈" 확보(사장님 지시)
	local WOLF_PATTERN_REST = DEF.PatternRest or 1.6
	local difficultyPatterns = DEF.WolfDifficultyPatterns or {}

	-- 광폭화 전환(최우선·1회)
	if DEF.Frenzy and not rt.WolfFrenzy
		and rt.Humanoid.Health / rt.Humanoid.MaxHealth <= (DEF.Frenzy.HpRatio or DEF.Frenzy.HpFrac or 0.5) then
		rt.WolfFrenzy = true
		rt.PatternBusy = true
		task.spawn(performWolfFrenzy, rt)
		return
	end
	-- 광기 전용 핏빛 추격: 측면 잠입→3연격→후퇴→긴 마무리. 광폭화 이후만 해금.
	if rt.WolfFrenzy and difficultyPatterns.BloodHunt and not rt.TelegraphEndAt
		and now >= (rt.NextBloodHuntAt or 0) and now >= (rt.NextWolfActionAt or 0)
		and dist >= 4 and dist <= 42 then
		rt.NextBloodHuntAt = now + (difficultyPatterns.BloodHuntCooldown or 14)
		rt.NextWolfActionAt = now + WOLF_PATTERN_REST
		rt.PatternBusy = true
		if rt.Model then rt.Model:SetAttribute("LastWolfDifficultyPattern", "BloodHunt") end
		task.spawn(performWolfBloodHunt, rt, targetRoot)
		return
	end
	-- 연속 돌진(광폭화 해금 시그니처) — 도약보다 선행(도약이 사거리를 먼저 소비하면 밀착 고착되어 미발동)
	if rt.WolfFrenzy and DEF.FrenzyDash and not rt.TelegraphEndAt and now >= (rt.NextFrenzyDashAt or 0)
		and now >= (rt.NextWolfActionAt or 0)
		and dist >= DEF.FrenzyDash.MinRange and dist <= DEF.FrenzyDash.MaxRange then
		rt.NextFrenzyDashAt = now + DEF.FrenzyDash.Cooldown
		rt.NextWolfActionAt = now + WOLF_PATTERN_REST
		rt.PatternBusy = true
		task.spawn(performWolfFrenzyDash, rt, targetRoot)
		return
	end
	-- 어려움 이상 공중 사냥: 올려치기 후 도약 덮치기.
	if difficultyPatterns.SkyHunt and not rt.TelegraphEndAt
		and now >= (rt.NextSkyHuntAt or 0) and now >= (rt.NextWolfActionAt or 0)
		and dist >= 6 and dist <= 45 then
		rt.NextSkyHuntAt = now + (difficultyPatterns.SkyHuntCooldown or 12)
		rt.NextWolfActionAt = now + WOLF_PATTERN_REST
		rt.PatternBusy = true
		if rt.Model then rt.Model:SetAttribute("LastWolfDifficultyPattern", "SkyHunt") end
		task.spawn(performWolfSkyHunt, rt, targetRoot)
		return
	end
	-- 보통 이상 측면 사냥: 좌우 이동 후 2연격.
	if difficultyPatterns.Flank and not rt.TelegraphEndAt
		and now >= (rt.NextFlankAt or 0) and now >= (rt.NextWolfActionAt or 0)
		and dist >= 3 and dist <= 32 then
		rt.NextFlankAt = now + (difficultyPatterns.FlankCooldown or 10)
		rt.NextWolfActionAt = now + WOLF_PATTERN_REST
		rt.PatternBusy = true
		if rt.Model then rt.Model:SetAttribute("LastWolfDifficultyPattern", "Flank") end
		task.spawn(performWolfDifficultyFlank, rt, targetRoot)
		return
	end
	-- 난이도별 3/4/5연격. 각 타마다 새 전조가 생겨 연속 회피 리듬이 분명하다.
	if (difficultyPatterns.ComboHits or 0) > 0 and not rt.TelegraphEndAt
		and now >= (rt.NextComboAt or 0) and now >= (rt.NextWolfActionAt or 0)
		and dist <= 20 then
		rt.NextComboAt = now + (difficultyPatterns.ComboCooldown or 8)
		rt.NextWolfActionAt = now + WOLF_PATTERN_REST
		rt.PatternBusy = true
		if rt.Model then rt.Model:SetAttribute("LastWolfDifficultyPattern", "Combo") end
		task.spawn(performWolfDifficultyCombo, rt, targetRoot)
		return
	end
	-- 도약 덮치기(중거리 갭클로저) — performLeapSlam 공용(Homing 미지정=추적 없음, 이동 회피)
	if DEF.LeapSlam and not rt.TelegraphEndAt and now >= rt.NextLeapAt
		and now >= (rt.NextWolfActionAt or 0)
		and dist >= DEF.LeapSlam.MinRange and dist <= DEF.LeapSlam.MaxRange then
		rt.NextLeapAt = now + DEF.LeapSlam.Cooldown
		rt.NextWolfActionAt = now + WOLF_PATTERN_REST
		rt.PatternBusy = true
		task.spawn(performLeapSlam, rt, targetRoot)
		return
	end
	-- 발톱 파동(중거리 3선 — 점프 회피)
	if DEF.ClawWave and not rt.TelegraphEndAt and now >= (rt.NextClawAt or 0)
		and now >= (rt.NextWolfActionAt or 0)
		and dist >= DEF.ClawWave.MinRange and dist <= DEF.ClawWave.MaxRange then
		rt.NextClawAt = now + (DEF.ClawWave.Cooldown or 7)
		rt.NextWolfActionAt = now + WOLF_PATTERN_REST
		rt.PatternBusy = true
		task.spawn(performWolfClawWave, rt, targetRoot)
		return
	end
	-- 하울(광역+공포 감속 기믹)
	if DEF.Howl and not rt.TelegraphEndAt and now >= rt.NextHowlAt
		and now >= (rt.NextWolfActionAt or 0) then
		rt.NextHowlAt = now + (DEF.Howl.Cooldown or 12)
		rt.NextWolfActionAt = now + WOLF_PATTERN_REST
		rt.PatternBusy = true
		task.spawn(performWolfHowl, rt)
		return
	end
	-- 기본: 물어뜯기(근접 박스+런지) / 사거리 밖 추격
	local bite = DEF.WolfBite or {}
	local range = bite.Range or DEF.AttackRange
	if dist > range then
		if isInZone(rt, targetRoot.Position) then
			rt.Humanoid:MoveTo(clampChasePos(rt, targetRoot.Position))
		else
			rt.Humanoid:MoveTo(rt.Root.Position)
		end
	else
		rt.Humanoid:MoveTo(rt.Root.Position)
		if now >= rt.NextCycleAt then
			rt.NextCycleAt = now + (bite.Cooldown or DEF.AtkInterval)
			rt.PatternBusy = true
			task.spawn(performWolfBite, rt, targetRoot)
		end
	end
end
end -- 난이도 전용 패턴 헬퍼 스코프 종료(대형 모듈 로컬 레지스터 재사용)

-- ===== [피벗3 P5] 신규 패턴 2: 뿌리 속박 RootBind (나무장군) =====
-- 대상 발밑 초록 원반 → 만료 시 반경 내 피해 + 속박(WalkSpeed 0, BindSec) + 뿌리 연출

-- [2026-07-25 QA] CC 가시화: 감속/속박을 대상 클라에 통지(FxController가 머리 위 상태 표시 — 사장님 확정)
function notifyCc(player, kind, sec)
	Net.Event("PlayerCc"):FireClient(player, { kind = kind, sec = sec })
end

local bindState = setmetatable({}, { __mode = "k" }) -- [humanoid]={count,origSpeed,origJump} 재진입 안전 복원

local function bindPlayer(player, bindSec)
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local proot = character and character:FindFirstChild("HumanoidRootPart")
	if not hum or hum.Health <= 0 or not proot then
		return
	end
	local st = bindState[hum]
	if not st then
		st = { count = 0, origSpeed = hum.WalkSpeed, origJump = hum.JumpHeight }
		bindState[hum] = st
	end
	st.count += 1
	hum.WalkSpeed = 0
	hum.JumpHeight = 0
	notifyCc(player, "root", bindSec) -- [2026-07-25 QA] CC 가시화
	-- 뿌리 연출: 발밑 링 4개(갈색 파트)
	for i = 1, 4 do
		local ang = (i / 4) * math.pi * 2
		local rootPart = Instance.new("Part")
		rootPart.Name = "BindRoot"
		rootPart.Size = Vector3.new(0.6, 2.4, 0.6)
		rootPart.Color = Color3.fromRGB(112, 78, 40)
		rootPart.Material = Enum.Material.Wood
		rootPart.Anchored = true
		rootPart.CanCollide = false
		rootPart.CanQuery = false
		rootPart.CanTouch = false
		rootPart.CFrame = CFrame.new(proot.Position + Vector3.new(math.cos(ang) * 1.6, -1.4, math.sin(ang) * 1.6))
			* CFrame.Angles(math.rad(14 * math.cos(ang)), 0, math.rad(14 * math.sin(ang)))
		rootPart.Parent = bossFolder
		Debris:AddItem(rootPart, bindSec)
	end
	task.delay(bindSec, function()
		if bindState[hum] ~= st then
			return -- 이 속박 사이클은 이미 종료/교체됨(스테일 타이머 무시)
		end
		st.count -= 1
		if st.count <= 0 then
			bindState[hum] = nil
			if hum.Parent and hum.Health > 0 then
				-- 최초 캐프처 원값으로만 복원(중복 속박이 0을 재캐프처하던 버그 제거)
				hum.WalkSpeed = st.origSpeed
				hum.JumpHeight = st.origJump
			end
		end
	end)
end

-- 패턴 슬로우: 최초 1회 원 WalkSpeed 저장 후 슬로우 값 대입(속박=0 중이면 불개입), 해제는 현재 속도가 자신이 마지막에 설정한 값일 때만 저장값 복원.
-- 해제 시 WalkSpeed=16 하드코딩 금지 — 스프린트 속도가 끊기고 속박이 조기 해제된다.
local slowState = setmetatable({}, { __mode = "k" }) -- [humanoid]={orig,applied}

local function applyPatternSlow(hum, slowSpeed)
	if bindState[hum] then
		return -- 속박(WalkSpeed 0) 중에는 슬로우가 덮어쓰지 않는다
	end
	local st = slowState[hum]
	if not st then
		st = { orig = hum.WalkSpeed }
		slowState[hum] = st
	end
	hum.WalkSpeed = slowSpeed
	st.applied = hum.WalkSpeed -- 대입 후 재독 값 저장(float32 반올림 — 복원 동등 비교용)
end

local function releasePatternSlow(hum)
	local st = slowState[hum]
	if not st then
		return
	end
	slowState[hum] = nil
	if hum.Parent and hum.Health > 0 and hum.WalkSpeed == st.applied then
		hum.WalkSpeed = st.orig
	end
end

local function performRootBind(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.RootBind
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local targetPos = leadTargetPos(rt, targetRoot, cfg.Windup or 0.9) -- [난이도 A] 속박 지점 리드
		local gy = rollGroundY(rt, targetPos)
		local impact = Vector3.new(targetPos.X, gy + TELEGRAPH_Y_OFFSET, targetPos.Z)
		makeDisc(impact, cfg.Radius, BIND_TELEGRAPH_COLOR, (cfg.Windup or 0.9) + 0.1)
		humanoid:MoveTo(root.Position)
		task.spawn(rootPlantMotion, rt, cfg.Windup or 0.9, targetRoot.Position) -- [패턴 모션] 젖힘→땅 꽂기→부르르 유지(뿌리 속박 전용)
		task.wait(cfg.Windup or 0.9)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		for _, p in ipairs(Players:GetPlayers()) do
			local pr, ph = alivePlayerParts(p)
			if pr and withinFairRadius(pr.Position, impact, cfg.Radius) then
				local damaged = PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5)) -- [v4.1] 뿌리속박 12dmg
				if damaged then
					bindPlayer(p, cfg.BindSec or 1.5)
				end
			end
		end
	end)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [피벗3 P5] 신규 패턴 3: 3연속 투척 TripleThrow (벽돌대왕) =====
-- 발마다 현재 타겟 위치 고정(리드 없음) — 착탄 원반 예고 + 벽돌 포물선 파트 + 반경 피해

local function performTripleThrow(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.TripleThrow
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		-- [패턴 모션] 윈드업 모션은 첫 발사 전에 종료(발사별 throwShotMotion과 조인트 C0 캐시 충돌 방지)
		task.spawn(bossAttackMotion, rt, math.max((cfg.Windup or 0.8) - 0.3, 0.35), targetRoot.Position)
		task.wait(cfg.Windup or 0.8)
		for shot = 1, cfg.Count or 3 do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local tr = targetRoot.Parent and targetRoot or nil
			local aim = tr and leadTargetPos(rt, tr, (cfg.FlightSec or 0.45) + 0.1) or root.Position + root.CFrame.LookVector * 15 -- [난이도 A] 발사별 리드샷
			local gy = rollGroundY(rt, aim)
			local impact = Vector3.new(aim.X, gy, aim.Z)
			local lookV = (Vector3.new(impact.X, 0, impact.Z) - Vector3.new(root.Position.X, 0, root.Position.Z))
			if lookV.Magnitude > 0.5 then
				local p0 = root.Position
				root.CFrame = CFrame.lookAt(p0, p0 + lookV.Unit)
			end
			makeDisc(impact + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), cfg.Radius, cfg.TeleColor or FIRE_TELEGRAPH_COLOR, (cfg.FlightSec or 0.45) + 0.15)
			task.spawn(throwShotMotion, rt) -- [패턴 모션] 발사별 투척 스냅(팔 휘두르기+상체)
			-- 보스별 실제 손 소품(엄마깨비 Handle=밥주걱)을 복제해 포물선으로 던진다.
			task.spawn(function()
				local heldProp
				if cfg.ProjModelPart then
					for _, inst in ipairs(rt.Model:GetDescendants()) do
						if inst:IsA("BasePart") and inst.Name == cfg.ProjModelPart then
							heldProp = inst
							break
						end
					end
				end
				local heldTransparency = heldProp and heldProp.Transparency
				local projectile
				local ok, err = pcall(function()
					local flatAim = Vector3.new(impact.X - root.Position.X, 0, impact.Z - root.Position.Z)
					local forward = flatAim.Magnitude > 0.01 and flatAim.Unit or root.CFrame.LookVector
					local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
					local frontStart = root.Position
						+ forward * (bodyRadius + math.max(1, (tonumber(cfg.ProjSize) or 2.2) * 0.35))
						+ Vector3.new(0, rt.Model:GetExtentsSize().Y * 0.18, 0)
					local start = heldProp and heldProp.Position or frontStart
					local fromRoot = Vector3.new(start.X - root.Position.X, 0, start.Z - root.Position.Z)
					if fromRoot.Magnitude < bodyRadius then
						start = frontStart
					end
					if heldProp then
						projectile = heldProp:Clone()
						projectile.Name = "BossThrowProp_" .. heldProp.Name
						local maxSize = math.max(projectile.Size.X, projectile.Size.Y, projectile.Size.Z)
						if maxSize > 0.01 then
							projectile.Size *= (cfg.ProjSize or 3.4) / maxSize
						end
						projectile.Transparency = 0
						heldProp.Transparency = 1
					else
						projectile = Instance.new("Part")
						projectile.Name = "BossThrowBrick"
						projectile.Size = Vector3.new(2.2, 1.4, 1.4)
						projectile.Color = cfg.ProjColor or Color3.fromRGB(178, 62, 48)
						projectile.Material = cfg.ProjMaterial or Enum.Material.Brick
					end
					projectile.Anchored = true
					projectile.CanCollide = false
					projectile.CanQuery = false
					projectile.CanTouch = false
					projectile.Parent = bossFolder
					local flight = cfg.FlightSec or 0.45
					local arc = cfg.ArcHeight or 9
					local t0 = os.clock()
					while true do
						local a = math.min((os.clock() - t0) / flight, 1)
						local pos = start:Lerp(impact, a) + Vector3.new(0, math.sin(a * math.pi) * arc, 0)
						projectile.CFrame = CFrame.new(pos) * CFrame.Angles(a * math.pi * 2, a * math.pi, 0)
						if a >= 1 then
							break
						end
						task.wait()
					end
					projectile:Destroy()
					projectile = nil
					for _, p in ipairs(Players:GetPlayers()) do
						local pr, ph = alivePlayerParts(p)
						if pr and withinFairRadius(pr.Position, impact, cfg.Radius) then
							PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5))
						end
					end
				end)
				if projectile and projectile.Parent then
					projectile:Destroy()
				end
				if heldProp and heldProp.Parent then
					heldProp.Transparency = heldTransparency
				end
				if not ok then
					warn("[FieldBossService] 보스 투척 소품 오류: " .. tostring(err))
				end
			end)
			task.wait(cfg.Interval or 0.55)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [피벗3 P5] 신규 패턴 4: 불장판 FireZone (벽돌대왕) =====
-- 대상 위치 주황 전조 → DurationSec 동안 장판(TickSec마다 반경 내 TickDamage)

local function performFireZone(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.FireZone
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local targetPos = leadTargetPos(rt, targetRoot, cfg.Windup or 0.9) -- [난이도 A] 장판 설치 지점 리드
		local gy = rollGroundY(rt, targetPos)
		local impact = Vector3.new(targetPos.X, gy + TELEGRAPH_Y_OFFSET, targetPos.Z)
		makeDisc(impact, cfg.Radius, cfg.ZoneColor or FIRE_TELEGRAPH_COLOR, (cfg.Windup or 0.9) + 0.1)
		humanoid:MoveTo(root.Position)
		task.spawn(zoneSlamMotion, rt, cfg.Windup or 0.9, targetRoot.Position) -- [패턴 모션] 웅크림→양팔 땅 내리찍기(장판 소환 전용)
		task.wait(cfg.Windup or 0.9)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		-- 장판 본체(지속 데미지 존)
		local zone = makeDisc(impact, cfg.Radius, cfg.ZoneColor or FIRE_TELEGRAPH_COLOR, (cfg.DurationSec or 4) + 0.2)
		zone.Name = "BossFireZone"
		zone.Transparency = 0.3
		local fire = Instance.new("ParticleEmitter")
		fire.Color = cfg.ZoneColor and ColorSequence.new(cfg.ZoneColor) or ColorSequence.new(Color3.fromRGB(255, 160, 40), Color3.fromRGB(255, 80, 20))
		fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.6), NumberSequenceKeypoint.new(1, 0.2) })
		fire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		fire.Lifetime = NumberRange.new(0.4, 0.8)
		fire.Speed = NumberRange.new(3, 7)
		fire.SpreadAngle = Vector2.new(25, 25)
		fire.Rate = 40
		fire.Parent = zone
		local endsAt = os.clock() + (cfg.DurationSec or 4)
		while os.clock() < endsAt do
			for _, p in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(p)
				if pr and withinFairRadius(pr.Position, impact, cfg.Radius) then
					local damaged = PlayerDamageService.Apply(ph, cfg.TickDamage or 5)
					if damaged and cfg.Slow then -- [v4.1] 진흙탕 장판 슬로우(머드킹) — [버그4] 원속도 저장·조건부 복원
						applyPatternSlow(ph, MovementDefs.WALK.DefaultSpeed * cfg.Slow)
						notifyCc(p, "slow", (cfg.TickSec or 0.5) + 0.35) -- [2026-07-25 QA] CC 가시화
						task.delay((cfg.TickSec or 0.5) + 0.35, function()
							releasePatternSlow(ph)
						end)
					end
				end
			end
			task.wait(cfg.TickSec or 0.5)
		end
	end)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-07-20] MudBoss rework: terrain-control 3 patterns =====

-- MudGeyser: sequential eruptions on tiles around target (multi small circles to dodge)
local function performMudGeyser(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.MudGeyser
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		task.spawn(zoneSlamMotion, rt, cfg.Windup or 0.8, targetRoot.Position)
		local base = leadTargetPos(rt, targetRoot, cfg.Windup or 0.8)
		local spots = {}
		for i = 1, (cfg.Count or 5) do
			local ang = math.random() * math.pi * 2
			local rad = (i <= (cfg.TrackCount or 1)) and (math.random() * 3) or (math.random() * (cfg.Spread or 16))
			local p = base + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
			local gy = rollGroundY(rt, p)
			spots[i] = Vector3.new(p.X, gy, p.Z)
			makeTimedDisc(spots[i] + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), cfg.Radius or 6, cfg.Color or FIRE_TELEGRAPH_COLOR, (cfg.Windup or 0.55) + (i - 1) * (cfg.EruptGap or 0.24))
		end
		task.wait(cfg.Windup or 0.8)
		for _, spot in ipairs(spots) do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			-- [2026-07-22] Soil 메시 분출(에셋 교체): 묻힌 상태에서 솔구침+페이드. 미도착 시 기존 모래기둥 폴백.
			local soilT = ReplicatedStorage.Assets:FindFirstChild("Soil")
			if soilT then
				local geyser = soilT:Clone()
				geyser.Name = "MudGeyser"
				local sc = ((cfg.Radius or 6) * 1.6) / math.max(soilT.Size.X, soilT.Size.Z, 0.1)
				geyser.Size = soilT.Size * sc
				geyser.Anchored = true
				geyser.CanCollide = false
				geyser.CanQuery = false
				geyser.CanTouch = false
				geyser.CastShadow = false
				local topCf = CFrame.new(spot.X, spot.Y + geyser.Size.Y * 0.4, spot.Z) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
				geyser.CFrame = topCf * CFrame.new(0, -geyser.Size.Y, 0) -- 묻힌 시작
				geyser.Parent = bossFolder
				pcall(function()
					local TS = game:GetService("TweenService")
					TS:Create(geyser, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = topCf }):Play()
					TS:Create(geyser, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
				end)
				Debris:AddItem(geyser, 0.45)
			else
				local col = Instance.new("Part")
				col.Name = "MudGeyser"
				col.Anchored = true
				col.CanCollide = false
				col.CanQuery = false
				col.CanTouch = false
				col.CastShadow = false
				col.Material = Enum.Material.Sand
				col.Color = cfg.Color or Color3.fromRGB(120, 84, 50)
				col.Size = Vector3.new((cfg.Radius or 5) * 1.5, 11, (cfg.Radius or 5) * 1.5)
				col.CFrame = CFrame.new(spot + Vector3.new(0, 5, 0))
				col.Transparency = 0.35
				col.Parent = bossFolder
				Debris:AddItem(col, 0.35)
			end
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and withinFairRadius(pr.Position, spot, cfg.Radius or 5) then
					PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 0.85) + 0.5))
				end
			end
			task.wait(cfg.EruptGap or 0.28)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- MudLine: forward piercing mud projectile (line telegraph, dodge sideways)
local function performMudLine(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.MudLine
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local aim = leadTargetPos(rt, targetRoot, cfg.Windup or 0.6)
		local origin = root.Position
		local dir = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
		dir = dir.Magnitude > 0.5 and dir.Unit or root.CFrame.LookVector
		root.CFrame = CFrame.lookAt(origin, origin + dir)
		task.spawn(bossAttackMotion, rt, cfg.Windup or 0.6, aim)
		local width = cfg.Width or 6
		local length = cfg.Length or 44
		local gy = rollGroundY(rt, origin) + TELEGRAPH_Y_OFFSET
		local center = origin + dir * (length / 2)
		local tele = Instance.new("Part")
		tele.Name = "BossLineTelegraph"
		tele.Anchored = true
		tele.CanCollide = false
		tele.CanQuery = false
		tele.CanTouch = false
		tele.CastShadow = false
		tele.Material = Enum.Material.Neon
		tele.Color = cfg.Color or Color3.fromRGB(110, 76, 46)
		tele.Transparency = TELEGRAPH_TRANSPARENCY
		tele.Size = Vector3.new(width, TELEGRAPH_THICKNESS, length)
		tele.CFrame = CFrame.lookAt(Vector3.new(center.X, gy, center.Z), Vector3.new(center.X, gy, center.Z) + dir)
		tele.Parent = bossFolder
		Debris:AddItem(tele, (cfg.Windup or 0.6) + (cfg.TravelSec or 0.5) + 0.2)
		task.wait(cfg.Windup or 0.6)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		local ball = Instance.new("Part")
		ball.Name = "BossMudLine"
		ball.Shape = Enum.PartType.Ball
		ball.Anchored = true
		ball.CanCollide = false
		ball.CanQuery = false
		ball.CanTouch = false
		ball.CastShadow = false
		ball.Material = Enum.Material.Sand
		ball.Color = cfg.Color or Color3.fromRGB(110, 76, 46)
		ball.Size = Vector3.new(width, width, width)
		ball.Parent = bossFolder
		local hitSet = {}
		local startPos = origin + Vector3.new(0, 2, 0)
		local snap = capturePlayerSnapshot()
		local t0 = os.clock()
		local travel = cfg.TravelSec or 0.5
		while true do
			local a = math.min((os.clock() - t0) / travel, 1)
			local pos = startPos + dir * (length * a)
			ball.CFrame = CFrame.new(pos)
			for _, se in ipairs(snapshotAlive(snap)) do
				if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
					local pr, ph = se.root, se.hum
					if withinFairRadius(pr.Position, pos, width * 0.5) then
						hitSet[se.player] = true
						PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5))
					end
				end
			end
			if a >= 1 then
				break
			end
			task.wait()
		end
		ball:Destroy()
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- MudFlood (signature): expanding mud zone; stacking slow -> root (dodge to dry ground)
local function performMudFlood(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.MudFlood
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local c3 = leadTargetPos(rt, targetRoot, 0.6)
		local gy = rollGroundY(rt, c3)
		local center = Vector3.new(c3.X, gy + TELEGRAPH_Y_OFFSET, c3.Z)
		humanoid:MoveTo(root.Position)
		local windup = cfg.Windup or 0.6
		task.spawn(zoneSlamMotion, rt, windup, c3)
		local waves = cfg.Waves or 4
		local startR = cfg.StartRadius or 6
		local maxR = cfg.MaxRadius or 15
		local waveGap = cfg.WaveGap or 0.8
		local tickSec = cfg.TickSec or 0.5
		-- warn gauge: fill over windup before the flood activates (곱 생성 예고)
		makeTimedDisc(center, startR, cfg.Color or FIRE_TELEGRAPH_COLOR, windup)
		task.wait(windup)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		-- [2026-07-22] Mad 진흙 웅덩이(에셋 교체): 서서히 확대(매 프레임 스케일). 데미지 반경 curR도 연속 성장.
		local dur = waves * waveGap
		local floodT0 = os.clock()
		local function floodRadius()
			return startR + (maxR - startR) * math.clamp((os.clock() - floodT0) / dur, 0, 1)
		end
		local madT = ReplicatedStorage.Assets:FindFirstChild("Mad")
		local usingMad = madT ~= nil
		local floorY = gy + 0.15
		local zone
		if usingMad then
			zone = madT:Clone()
			zone.Name = "BossMudFlood"
			zone.Anchored = true
			zone.CanCollide = false
			zone.CanQuery = false
			zone.CanTouch = false
			zone.CastShadow = false
			local baseXZ = math.max(madT.Size.X, madT.Size.Z, 0.1)
			local function applyR(r)
				local s = (r * 2) / baseXZ
				zone.Size = Vector3.new(madT.Size.X * s, math.min(madT.Size.Y * s, 1.5), madT.Size.Z * s)
				zone.CFrame = CFrame.new(c3.X, floorY + zone.Size.Y * 0.5, c3.Z)
			end
			applyR(startR)
			zone.Parent = bossFolder
			task.spawn(function()
				while zone.Parent and os.clock() - floodT0 < dur do
					applyR(floodRadius())
					task.wait()
				end
			end)
			Debris:AddItem(zone, dur + 0.6)
		else
			zone = makeDisc(center, startR, cfg.Color or FIRE_TELEGRAPH_COLOR, dur + 0.6)
			zone.Name = "BossMudFlood"
			zone.Transparency = 0.35
		end
		local stacks = {}
		local slowed = {}
		local endAt = floodT0 + dur
		while os.clock() < endAt do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local curR = floodRadius()
			if not usingMad then
				zone.Size = Vector3.new(TELEGRAPH_THICKNESS, curR * 2, curR * 2)
			end
			local inNow = {}
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and withinFairRadius(pr.Position, center, curR) then
					inNow[ph] = true
					local damaged = PlayerDamageService.Apply(ph, cfg.TickDamage or 4)
					if damaged then
						-- [2026-07-25 QA] 만스택 속박(이동 불가) 폐지 — 스택 비례 감속(최대 cfg.Slow)만 + CC 통지(사장님 확정)
						local maxStacks = cfg.SlowStacks or cfg.RootStacks or 4
						stacks[ph] = math.min((stacks[ph] or 0) + 1, maxStacks)
						slowed[ph] = true
						ph:SetAttribute("MudTrapped", true) -- 진흙 웅덩이 구속 중 대쉠 봉쇄(클라 MovementController.RequestDash 소비)
						rt.LastMudTrapAt = os.clock() -- [2026-07-31] MudCharge 게이트용 갱신(웅덩이가 도는 동안은 PatternBusy라 디스패치가 안 돌아간다)
						applyPatternSlow(ph, MovementDefs.WALK.DefaultSpeed * (1 - (1 - (cfg.Slow or 0.6)) * (stacks[ph] / maxStacks)))
						notifyCc(pl, "slow", tickSec + 0.4)
					end
				end
			end
			for ph in pairs(slowed) do
				if not inNow[ph] then
					releasePatternSlow(ph)
					ph:SetAttribute("MudTrapped", nil) -- [2026-07-24 QA] 웅덩이 이탈 시 대쉠 봉쇄 해제
					slowed[ph] = nil
					stacks[ph] = nil
				end
			end
			task.wait(tickSec)
		end
		for ph in pairs(slowed) do
			releasePatternSlow(ph)
			ph:SetAttribute("MudTrapped", nil) -- [2026-07-24 QA] 패턴 종료 시 대쉠 봉쇄 전원 해제
		end
	end)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- [2026-07-31] 진흙 웅덩이에 갇혀 감속 중인 플레이어가 하나라도 있는가.
-- performMudFlood가 웅덩이 안에서만 MudTrapped를 세우고 이탈·종료 시 지우므로, 이 값이 곳 '진흙이 깔려 느려진 상태'다.
local function anyMudTrapped()
	for _, pl in ipairs(Players:GetPlayers()) do
		local _, ph = alivePlayerParts(pl)
		if ph and ph:GetAttribute("MudTrapped") then
			return true
		end
	end
	return false
end

-- MudSmash: boss crashes a large mud AoE on predicted player position (short windup, big radius; hard to escape when slowed)
local function performMudSmash(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.MudSmash
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		task.spawn(zoneSlamMotion, rt, cfg.Windup or 0.55, targetRoot.Position)
		local aim = leadTargetPos(rt, targetRoot, cfg.Windup or 0.55)
		local gy = rollGroundY(rt, aim)
		local impact = Vector3.new(aim.X, gy, aim.Z)
		makeTimedDisc(impact + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), cfg.Radius or 9, cfg.Color or FIRE_TELEGRAPH_COLOR, cfg.Windup or 0.55)
		task.wait(cfg.Windup or 0.55)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		-- [2026-07-22] Stone 메시 내리찍기(에셋 교체): 위에서 떨어져 임팩트+페이드. 미도착 시 기존 모래 버스트 폴백.
		local stoneT = ReplicatedStorage.Assets:FindFirstChild("Stone")
		if stoneT then
			local rock = stoneT:Clone()
			rock.Name = "MudSmash"
			rock.PivotOffset = CFrame.new()
			local sc = ((cfg.Radius or 9) * 2) / math.max(stoneT.Size.X, stoneT.Size.Z, 0.1)
			rock.Size = stoneT.Size * sc
			rock.Anchored = true
			rock.CanCollide = false
			rock.CanQuery = false
			rock.CanTouch = false
			rock.CastShadow = false
			local restCf = CFrame.new(impact.X, gy + rock.Size.Y * 0.35, impact.Z) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
			rock.CFrame = restCf * CFrame.new(0, 16, 0) -- 위에서 시작
			rock.Parent = bossFolder
			pcall(function()
				local TS = game:GetService("TweenService")
				TS:Create(rock, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = restCf }):Play()
				TS:Create(rock, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
			end)
			Debris:AddItem(rock, 0.5)
		else
			local burst = Instance.new("Part")
			burst.Name = "MudSmash"
			burst.Anchored = true
			burst.CanCollide = false
			burst.CanQuery = false
			burst.CanTouch = false
			burst.CastShadow = false
			burst.Material = Enum.Material.Sand
			burst.Color = cfg.Color or Color3.fromRGB(120, 84, 50)
			burst.Size = Vector3.new((cfg.Radius or 9) * 2, 6, (cfg.Radius or 9) * 2)
			burst.CFrame = CFrame.new(impact + Vector3.new(0, 3, 0))
			burst.Transparency = 0.3
			burst.Parent = bossFolder
			Debris:AddItem(burst, 0.4)
		end
		for _, pl in ipairs(Players:GetPlayers()) do
			local pr, ph = alivePlayerParts(pl)
			if pr and withinFairRadius(pr.Position, impact, cfg.Radius or 9) then
				PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1.3) + 0.5))
			end
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-07-20] WoodBoss rework: immobilize + summon =====

-- RootField: multi-point roots erupt; hit players are rooted (bind). per-point timing gauges.
local function performRootField(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.RootField
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		task.spawn(rootPlantMotion, rt, cfg.Windup or 0.6, targetRoot.Position)
		local base = leadTargetPos(rt, targetRoot, cfg.Windup or 0.6)
		local spots = {}
		for i = 1, (cfg.Count or 6) do
			local ang = math.random() * math.pi * 2
			local rad = (i <= (cfg.TrackCount or 1)) and (math.random() * 3) or (math.random() * (cfg.Spread or 20))
			local p = base + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
			local gy = rollGroundY(rt, p)
			spots[i] = Vector3.new(p.X, gy, p.Z)
			makeTimedDisc(spots[i] + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), cfg.Radius or 6, cfg.Color or BIND_TELEGRAPH_COLOR, (cfg.Windup or 0.6) + (i - 1) * (cfg.EruptGap or 0.22))
		end
		task.wait(cfg.Windup or 0.6)
		for _, spot in ipairs(spots) do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			-- [2026-07-22] Branch 메시 솟음(에셋 교체): 묻힌 상태서 솔구침. 미도착 시 기존 뾌리 파트 폴백.
			local branchT = ReplicatedStorage.Assets.Drops:FindFirstChild("Branch")
			if branchT then
				local rp = branchT:Clone()
				rp.Name = "WoodRoot"
				rp.PivotOffset = CFrame.new()
				local sc = 8 / math.max(branchT.Size.Y, 0.1)
				rp.Size = branchT.Size * sc
				rp.Anchored = true
				rp.CanCollide = false
				rp.CanQuery = false
				rp.CanTouch = false
				rp.CastShadow = false
				local topCf = CFrame.new(spot.X, spot.Y + rp.Size.Y * 0.35, spot.Z) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
				rp.CFrame = topCf * CFrame.new(0, -rp.Size.Y, 0) -- 묻힌 시작
				rp.Parent = bossFolder
				pcall(function()
					game:GetService("TweenService"):Create(rp, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = topCf }):Play()
				end)
				Debris:AddItem(rp, 0.5)
			else
				local rp = Instance.new("Part")
				rp.Name = "WoodRoot"
				rp.Anchored = true
				rp.CanCollide = false
				rp.CanQuery = false
				rp.CanTouch = false
				rp.CastShadow = false
				rp.Material = Enum.Material.Wood
				rp.Color = Color3.fromRGB(112, 78, 40)
				rp.Size = Vector3.new(1.5, 8, 1.5)
				rp.CFrame = CFrame.new(spot + Vector3.new(0, 4, 0))
				rp.Parent = bossFolder
				Debris:AddItem(rp, 0.5)
			end
			for _, p in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(p)
				if pr and withinFairRadius(pr.Position, spot, cfg.Radius or 6) then
					local damaged = PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 0.6) + 0.5))
					if damaged then
						bindPlayer(p, cfg.BindSec or 1.3)
					end
				end
			end
			task.wait(cfg.EruptGap or 0.22)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- BranchSweep: frontal cone sweep + knockback (dodge by getting behind)
local function performBranchSweep(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.BranchSweep
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local rootOrigin = root.Position
		local aim = targetRoot.Position
		local dir = Vector3.new(aim.X - rootOrigin.X, 0, aim.Z - rootOrigin.Z)
		dir = dir.Magnitude > 0.5 and dir.Unit or root.CFrame.LookVector
		root.CFrame = CFrame.lookAt(rootOrigin, rootOrigin + dir)
		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		local origin = rootOrigin + dir * bodyRadius
		local range = cfg.Range or 18
		-- [2026-07-27] 지면 기준선 — 공중 대상 제외 판정에 사용(VineWhip과 동일 규약)
		local gy = rollGroundY(rt, origin)
		local tp = origin + dir * (range * 0.5)
		local telePos = Vector3.new(tp.X, rollGroundY(rt, tp) + TELEGRAPH_Y_OFFSET, tp.Z)
		makeTimedDisc(telePos, range * 0.6, cfg.Color or FIRE_TELEGRAPH_COLOR, cfg.Windup or 0.6)
		task.spawn(bossAttackMotion, rt, cfg.Windup or 0.6, aim)
		task.wait(cfg.Windup or 0.6)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		local cosHalf = math.cos(math.rad(cfg.HalfAngle or 60))
		local kb = cfg.Knockback
		for _, p in ipairs(Players:GetPlayers()) do
			local pr, ph = alivePlayerParts(p)
			if pr then
				local to = Vector3.new(pr.Position.X - origin.X, 0, pr.Position.Z - origin.Z)
				-- [2026-07-27] 가지 후려치기는 지면 스윙 — 공중(점프/낙하) 대상은 판정 제외.
				-- 지시: "저 패턴이 공중에서 나오면 안되고 바닥에서만 나와야함". 구판정은 XZ 평면만 봐서 공중까지 닿았다.
				local airborne = ph.FloorMaterial == Enum.Material.Air or (pr.Position.Y - gy) > (cfg.JumpClear or 5)
				if not airborne and to.Magnitude <= fairRadius(range) and to.Magnitude > 0.5 and to.Unit:Dot(dir) >= cosHalf then
					local damaged = PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1.1) + 0.5))
					if damaged and kb then
						Net.Event("PlayerKnockback"):FireClient(p, { dir = to.Unit, force = kb.Force or 40, lift = kb.Lift or 10 })
					end
				end
			end
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-08-20 ForestKeeper dedicated] SporeBurst =====
-- Spore burst. Fixed radius makes "step outside and you are safe" legible; time inside stacks a slow.
-- Spec S7 mobile input budget: telegraph >= 0.9s.
local function performSporeBurst(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.SporeBurst
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local c3 = leadTargetPos(rt, targetRoot, 0.5)
		local gy = rollGroundY(rt, c3)
		local center = Vector3.new(c3.X, gy + TELEGRAPH_Y_OFFSET, c3.Z)
		humanoid:MoveTo(root.Position)
		local windup = cfg.Windup or 0.9
		local radius = cfg.Radius or 13
		local dur = cfg.Duration or 3.5
		local color = cfg.Color or Color3.fromRGB(150, 205, 110)
		task.spawn(zoneSlamMotion, rt, windup, c3)
		makeTimedDisc(center, radius, color, windup)
		task.wait(windup)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		local zone = makeDisc(center, radius, color, dur + 0.6)
		zone.Name = "BossSporeZone"
		zone.Transparency = 0.4
		local puffs = cfg.Puffs or 7
		for i = 1, puffs do
			local ang = (i / puffs) * math.pi * 2 + math.random() * 0.5
			local rad = radius * (0.15 + math.random() * 0.7)
			local p = Instance.new("Part")
			p.Name = "BossSporePuff"
			p.Shape = Enum.PartType.Ball
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
			p.Material = Enum.Material.Neon
			p.Color = color
			p.Transparency = 0.45
			local s0 = radius * 0.18
			p.Size = Vector3.new(s0, s0, s0)
			p.CFrame = CFrame.new(center + Vector3.new(math.cos(ang) * rad, 1.2, math.sin(ang) * rad))
			p.Parent = bossFolder
			local s1 = radius * (0.5 + math.random() * 0.3)
			TweenService:Create(p, TweenInfo.new(dur * 0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.new(s1, s1, s1),
				Transparency = 1,
			}):Play()
			Debris:AddItem(p, dur + 0.4)
		end
		local tickSec = cfg.TickSec or 0.6
		local maxStacks = cfg.SlowStacks or 3
		local stacks, slowed = {}, {}
		local endAt = os.clock() + dur
		while os.clock() < endAt do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and Vector3.new(pr.Position.X - center.X, 0, pr.Position.Z - center.Z).Magnitude <= radius then
					-- 피해가 실제 적용된 틱만 감속 스택을 준다(대시·진화 무적·ForceField와 의미 일치).
					local damaged = PlayerDamageService.Apply(ph, cfg.TickDamage or 12)
					if damaged then
						stacks[ph] = math.min((stacks[ph] or 0) + 1, maxStacks)
						slowed[ph] = true
						local ratio = 1 - (1 - (cfg.Slow or 0.6)) * (stacks[ph] / maxStacks)
						applyPatternSlow(ph, MovementDefs.WALK.DefaultSpeed * ratio)
					end
				end
			end
			task.wait(tickSec)
		end
		for ph in pairs(slowed) do
			releasePatternSlow(ph)
		end
	end)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-08-20 MotherGoblin dedicated] BabySummon / MotherScold =====
-- BabySummon: 실제 AI를 가진 족속을 붙인다(숲지기 묘목은 정지·회복형) — 보스만 보면 뒤에서 맞는 구조.
-- 보상 없는 전용 def(MotherBabyGoblin)라 무한 파밍 이득이 없다.
local function performBabySummon(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.BabySummon
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid:MoveTo(root.Position)
		local windup = cfg.Windup or 1.0
		local color = cfg.Color or Color3.fromRGB(225, 130, 140)
		task.spawn(rootPlantMotion, rt, windup, root.Position)
		local n = cfg.Count or 2
		local spots = {}
		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		for i = 1, n do
			local ang = (i / n) * math.pi * 2 + math.random() * 0.7
			local surfaceGap = tonumber(cfg.SurfaceGap)
			local rad = surfaceGap
				and (bodyRadius + surfaceGap + math.random() * (tonumber(cfg.SurfaceSpread) or 8))
				or ((cfg.Spread or 14) * (0.6 + math.random() * 0.4))
			local offset = Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
			local p = root.Position + offset
			-- 커진 보스 몸 밖의 간격은 유지하면서 전투 존 밖으로 나간 점만 안쪽으로 뒤집는다.
			if rt.ZoneCenter and rt.ZoneRadius then
				local maxFromCenter = math.max(0, rt.ZoneRadius - 8)
				local function zoneDist(pos)
					return Vector3.new(pos.X - rt.ZoneCenter.X, 0, pos.Z - rt.ZoneCenter.Z).Magnitude
				end
				if zoneDist(p) > maxFromCenter then
					local mirrored = root.Position - offset
					if zoneDist(mirrored) <= maxFromCenter then
						p = mirrored
					else
						local flat = Vector3.new(p.X - rt.ZoneCenter.X, 0, p.Z - rt.ZoneCenter.Z)
						if flat.Magnitude > 0 then
							local safe = rt.ZoneCenter + flat.Unit * maxFromCenter
							p = Vector3.new(safe.X, p.Y, safe.Z)
						end
					end
				end
			end
			local gy = rollGroundY(rt, p)
			spots[i] = Vector3.new(p.X, gy, p.Z)
			makeTimedDisc(spots[i] + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), cfg.SpotRadius or 3.5, color, windup)
		end
		task.wait(windup)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		rt.Summons = rt.Summons or {}
		local alive = 0
		for m in pairs(rt.Summons) do
			if m.Parent then
				alive = alive + 1
			else
				rt.Summons[m] = nil
			end
		end
		local room = math.max(0, (cfg.MaxAlive or 4) - alive)
		for i = 1, math.min(n, room) do
			local m = MonsterService.SpawnSummon(cfg.MonsterId or "MotherBabyGoblin", spots[i] + Vector3.new(0, 2, 0), {
				Scatter = 0,
				Lifetime = cfg.Lifetime or 45,
			})
			if m then
				rt.Summons[m] = true
			end
		end
	end)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- MotherScold(호통): 보스 발밑에서 밖으로 퍼지는 고함 링 — 닿는 순간 1회 피격 + 넘어트림 + 공포 감속.
-- 회피는 점프(JumpClear) — 다른 패턴과 회피법이 겹치지 않게 분리했다.
local function performMotherScold(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.MotherScold
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local gy = rollGroundY(rt, root.Position)
		local c = Vector3.new(root.Position.X, gy + TELEGRAPH_Y_OFFSET, root.Position.Z)
		local maxR = cfg.Radius or 26
		local windup = cfg.Windup or 0.9
		local color = cfg.Color or Color3.fromRGB(235, 140, 150)
		humanoid:MoveTo(root.Position)
		task.spawn(zoneSlamMotion, rt, windup, root.Position)
		makeTimedDisc(c, maxR, color, windup)
		task.wait(windup)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		local expandT = cfg.ExpandTime or 0.6
		local ring = Instance.new("Part")
		ring.Name = "BossScoldDonutRing"
		ring.Size = Vector3.new(1, 1, 1)
		ring.CFrame = CFrame.new(c) * CFrame.Angles(math.rad(90), 0, 0)
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.CastShadow = false
		ring.Material = Enum.Material.Neon
		ring.Color = color
		ring.Transparency = 0.12
		local ringMesh = Instance.new("SpecialMesh")
		ringMesh.MeshType = Enum.MeshType.FileMesh
		ringMesh.MeshId = "rbxassetid://3270017"
		ringMesh.Parent = ring
		ring.Parent = bossFolder
		local dmg = math.floor(DEF.Atk * (cfg.DamageMul or 0.8) + 0.5)
		local jumpClear = cfg.JumpClear or 6
		local bandWidth = cfg.BandWidth or 5
		local hitSet = {}
		local t0 = os.clock()
		while os.clock() - t0 < expandT do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local a = math.clamp((os.clock() - t0) / expandT, 0, 1)
			local r = 2 + (maxR - 2) * a
			ringMesh.Scale = Vector3.new(r * 2, r * 2, math.max(r * 0.16, 2.5))
			ring.Transparency = 0.12 + a * 0.42
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and not hitSet[ph] then
					local flat = Vector3.new(pr.Position.X - c.X, 0, pr.Position.Z - c.Z).Magnitude
					if math.abs(flat - r) <= bandWidth * 0.5 then
						local airborne = ph.FloorMaterial == Enum.Material.Air or (pr.Position.Y - gy) > jumpClear
						if not airborne then
							hitSet[ph] = true
							local damaged = PlayerDamageService.Apply(ph, dmg)
							if damaged then
								applyPatternSlow(ph, MovementDefs.WALK.DefaultSpeed * (cfg.Slow or 0.55))
								task.delay(cfg.SlowSec or 1.6, function()
									releasePatternSlow(ph)
								end)
								local kb = cfg.Knockback
								if kb then
									MonsterService.KnockbackPlayer(pl, c, kb.Force or 30, kb.Lift or 8)
								end
							end
						end
					end
				end
			end
			task.wait()
		end
		ring:Destroy()
	end)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- SaplingSummon (signature): summon destructible pods; alive pods heal the boss after HealDelay (DPS check)
local function performSaplingSummon(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.SaplingSummon
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		task.spawn(rootPlantMotion, rt, 0.5, root.Position)
		-- [2026-08-27 사장님] 치유 기믹 안내는 소환될 때마다. 전투당 1회로 두면 정작 패턴이
		-- 나온 순간에 아무 설명이 없어, 왜 보스 체력이 차오르는지 끝까지 모른 채 끝난다.
		-- 제한 시간은 MonsterDefs가 SSOT — 문구에 박지 않고 서식 인자로 넘긴다.
		for _, pl in ipairs(Players:GetPlayers()) do
			local pr = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
			if pr and isInZone(rt, pr.Position) then
				Net.Event("Notice"):FireClient(pl, {
					locKey = "Notice.BossSaplingHeal_Fmt",
					locArgs = { math.ceil(cfg.HealDelay or 7) },
				})
			end
		end
		local CollectionService = game:GetService("CollectionService")
		local pods = {}
		local n = cfg.Count or 3
		-- [2026-08-27 사장님] 묘목 외형 = ReplicatedStorage.Assets.WoodSapling 메시.
		-- 원본이 75스터드라 그대로 쓰면 숲지기 본체(54)보다 커진다 — 이 높이로 정규화한다.
		-- ★상수·헬퍼를 모듈 최상단에 두면 이 파일은 Luau 로컬 200개 한도를 넘겨
		-- 모듈이 통째로 로드 실패한다("Out of local registers"). 반드시 함수 안에 둔다.
		local SAPLING_H = 14
		local saplingAssets = ReplicatedStorage:FindFirstChild("Assets")
		local saplingTpl = saplingAssets and saplingAssets:FindFirstChild("WoodSapling")
		if saplingTpl and not saplingTpl:IsA("BasePart") then
			saplingTpl = nil
		end
		-- [2026-08-27] 치유 링크 시각화: 묘목 → 보스 초록 Beam.
		-- 텍스트 경고 없이 "저게 보스를 살린다"를 보여주는 게 목적이라 서버에서 만들어 전원에게 복제한다.
		local linkAtt = Instance.new("Attachment")
		linkAtt.Name = "SaplingLink"
		linkAtt.Position = Vector3.new(0, 2, 0)
		linkAtt.Parent = root
		for i = 1, n do
			local ang = (i / n) * math.pi * 2 + math.random() * 0.6
			local rad = (cfg.Spread or 22) * (0.6 + math.random() * 0.4)
			local p = root.Position + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
			local gy = rollGroundY(rt, p)
			local m = Instance.new("Model")
			m.Name = "WoodSapling"
			m:SetAttribute("MonsterId", "WoodSapling")
			local hrp = Instance.new("Part")
			hrp.Name = "HumanoidRootPart"
			hrp.Size = Vector3.new(3, 6, 3)
			hrp.Anchored = true
			hrp.CanCollide = false
			hrp.CFrame = CFrame.new(p.X, gy + 3, p.Z)
			hrp.Parent = m
			m.PrimaryPart = hrp
			if saplingTpl then
				hrp.Transparency = 1 -- 외형은 메시가 담당 — 루트는 판정용 박스
				local mesh = saplingTpl:Clone()
				mesh.Name = "Trunk"
				mesh.Size = saplingTpl.Size * (SAPLING_H / saplingTpl.Size.Y)
				mesh.PivotOffset = CFrame.new() -- ★구운 PivotOffset 제거(회전·부양 사고 방지)
				mesh.Anchored = true
				mesh.CanCollide = false -- 메시 쿡 헬은 부양·진동을 부른다
				mesh.CanQuery = false -- 레이캐스트는 종전대로 루트 박스가 받는다
				mesh.CastShadow = false
				-- 메시는 바운딩박스 중앙 기준이라 중심을 반높이에 두면 밑동이 지면에 닿는다.
				-- yaw를 무작위로 돌려 같은 메시 여러 그루가 복사본처럼 보이지 않게 한다.
				mesh.CFrame = CFrame.new(p.X, gy + SAPLING_H * 0.5, p.Z)
					* CFrame.Angles(0, math.random() * math.pi * 2, 0)
				mesh.Parent = m
				-- 타격 반경은 MonsterService와 같은 규약((X+Z)/4), 하한은 종전 값 3 유지
				m:SetAttribute("HitRadius", math.max(3, (mesh.Size.X + mesh.Size.Z) / 4))
			else
				hrp.Color = Color3.fromRGB(96, 150, 60)
				hrp.Material = Enum.Material.Grass
				m:SetAttribute("HitRadius", 3)
			end
			local hum = Instance.new("Humanoid")
			hum.MaxHealth = cfg.PodHp or 150
			hum.Health = hum.MaxHealth
			hum.Parent = m
			m.Parent = bossFolder
			CollectionService:AddTag(m, "Monster")

			local podAtt = Instance.new("Attachment")
			podAtt.Name = "SaplingLink"
			podAtt.Position = Vector3.new(0, SAPLING_H - 3, 0) -- 뺔은 나무 꼭대기에서 뽑는다
			podAtt.Parent = hrp
			local beam = Instance.new("Beam")
			beam.Name = "SaplingHealBeam"
			beam.Attachment0 = podAtt
			beam.Attachment1 = linkAtt
			beam.Color = ColorSequence.new(Color3.fromRGB(120, 235, 110), Color3.fromRGB(70, 180, 80))
			beam.LightEmission = 1
			beam.FaceCamera = true
			beam.Width0 = 0.9
			beam.Width1 = 0.35
			beam.CurveSize0 = 6
			beam.CurveSize1 = -6
			beam.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.15),
				NumberSequenceKeypoint.new(1, 0.55),
			})
			beam.Parent = podAtt -- 묘목이 사라지면 Beam도 같이 사라진다

			local timerGui = Instance.new("BillboardGui")
			timerGui.Name = "SaplingTimer"
			timerGui.Adornee = hrp
			timerGui.AlwaysOnTop = true
			timerGui.LightInfluence = 0
			timerGui.MaxDistance = 150
			timerGui.Size = UDim2.fromOffset(64, 64)
			timerGui.StudsOffset = Vector3.new(0, SAPLING_H - 1, 0) -- 수관 위로 띄운다
			timerGui.Parent = m -- 묘목과 함께 사라진다
			local timerLabel = Instance.new("TextLabel")
			timerLabel.Name = "Left"
			timerLabel.BackgroundTransparency = 1
			timerLabel.Size = UDim2.fromScale(1, 1)
			timerLabel.Font = Enum.Font.GothamBold
			timerLabel.TextScaled = true
			timerLabel.TextColor3 = Color3.fromRGB(185, 255, 165)
			timerLabel.TextStrokeColor3 = Color3.fromRGB(12, 32, 12)
			timerLabel.TextStrokeTransparency = 0.2
			timerLabel.Text = tostring(math.ceil(cfg.HealDelay or 7))
			timerLabel.Parent = timerGui

			-- 부순 묘목은 즉시 치워 링크를 끊는다. 방치하면 MonsterDefs에 없는 모델이라
			-- 죽은 채 HealDelay까지 Beam·카운트다운과 함께 그대로 서 있게 된다.
			hum.Died:Connect(function()
				if m.Parent then
					m:Destroy()
				end
			end)
			pods[i] = m
		end
		-- [2026-08-27] 묘목 위 카운트다운 — 남은 시간이 보여야 "지금 부순다"는 압박이 생긴다.
		-- 숫자만 쓴다: 서버 생성 UI라 클라이언트별 언어를 모른다(글자를 넣으면 현지화가 깨진다).
		local healDelay = cfg.HealDelay or 7
		task.spawn(function()
			local deadline = os.clock() + healDelay
			local lastShown = nil
			while os.clock() < deadline do
				local left = deadline - os.clock()
				local shown = math.max(0, math.ceil(left))
				if shown ~= lastShown then
					lastShown = shown
					local urgent = left <= 3
					for _, m in ipairs(pods) do
						local gui = m.Parent and m:FindFirstChild("SaplingTimer")
						local lb = gui and gui:FindFirstChildOfClass("TextLabel")
						if lb then
							lb.Text = tostring(shown)
							lb.TextColor3 = urgent and Color3.fromRGB(255, 120, 110)
								or Color3.fromRGB(185, 255, 165)
						end
					end
				end
				task.wait(0.15)
			end
		end)
		-- [2026-08-27] 치유 정산(HealDelay)을 패턴 점유 시간에 포함하면 PatternBusy가 8초간 잡혀
		-- 보스가 그동안 완전히 멈춰 있게 된다(tickBoss는 PatternBusy면 즉시 return).
		-- 소환은 여기서 끝내고, 회복 정산만 분리 스레드로 넘긴다.
		task.spawn(function()
			task.wait(healDelay)
			local healed = 0
			for _, m in ipairs(pods) do
				if m.Parent then
					local h = m:FindFirstChildOfClass("Humanoid")
					if h and h.Health > 0 and humanoid.Parent and humanoid.Health > 0 then
						local before = humanoid.Health
						humanoid.Health = math.min(humanoid.MaxHealth, before + (cfg.HealPerPod or 400))
						healed += humanoid.Health - before
					end
					m:Destroy()
				end
			end
			if linkAtt.Parent then
				linkAtt:Destroy()
			end
			-- 실제로 들어간 회복량만 초록 숫자로 알린다(0이면 전원 처치 = 알릴 것 없음).
			-- MonsterHit은 가해자 전용이라 못 쓴다 — 비어 있던 ShowDamage 채널을 전체 브로드캐스트로 쓴다.
			if healed > 0 and root and root.Parent then
				Net.Event("ShowDamage"):FireAllClients({
					pos = root.Position + Vector3.new(0, 8, 0),
					dmg = math.floor(healed + 0.5),
					heal = true,
				})
			end
		end)
	end)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- 덩굴 채찍 전용 모션: 몸통을 한쪽으로 비틀었다 반대편으로 도는 수평 회전(기본 bossAttackMotion의 오버헤드 내리침과 구분).
-- 몸통 yaw를 덩굴 스윙 각도와 동기화하고 왕복(DoubleSweep)도 따라간다. 조인트 없는 리그는 있는 것만 움직인다.
local function vineSweepMotion(rt, windup, sweepTime, sweepDeg, doubleSweep, targetPos)
	local root, hum = rt.Root, rt.Humanoid
	if not (root and root.Parent and hum and hum.Health > 0) then
		return
	end
	if bossAnimPlaying(rt) then
		return -- [2026-07-29] 실애니 재생 중이면 절차 모션 양보
	end
	if jointMotionBusy[rt] then
		return
	end
	jointMotionBusy[rt] = true
	windup = math.max(0.2, windup or 0.7)
	sweepTime = math.max(0.2, sweepTime or 0.75)
	local half = math.rad(sweepDeg or 110) * 0.5
	local rArm = findBossJoint(rt.Model, { "RightArm", "Right Arm" })
	local lArm = findBossJoint(rt.Model, { "LeftArm", "Left Arm" })
	local rC0 = rArm and rArm.C0
	local lC0 = lArm and lArm.C0
	local base = root.CFrame
	local tp = targetPos or rt.TelegraphPos
	if tp then
		local look = Vector3.new(tp.X, root.Position.Y, tp.Z)
		if (look - root.Position).Magnitude > 0.5 then
			base = CFrame.lookAt(root.Position, look)
		end
	end
	local wasAnchored = root.Anchored
	local prevAuto = hum.AutoRotate
	root.Anchored = true
	hum.AutoRotate = false
	local passes = doubleSweep and 2 or 1
	local gap = 0.1 -- performVineWhip의 왽복 사이 대기와 동일
	local total = windup + sweepTime * passes + gap * (passes - 1)
	local t0 = os.clock()
	while true do
		if not (root.Parent and hum.Health > 0) then
			break
		end
		local t = os.clock() - t0
		if t >= total then
			break
		end
		local yaw, armZ, lean
		if t < windup then
			-- 윈드업: 시작쪽(-)으로 몸을 비틀며 양팔을 옆으로 벌려 든다
			local a = t / windup
			yaw = -half * a
			armZ = math.rad(-95 * a) -- 옆으로 벌림(오버헤드 피치와 축이 다름)
			lean = math.rad(-8 * a)
		else
			-- 스윙: 덩굴과 같은 속도로 몸통 회전(왽복 시 방향 반전)
			local st = t - windup
			local pass = math.clamp(math.floor(st / (sweepTime + gap)), 0, passes - 1)
			local a = math.clamp((st - pass * (sweepTime + gap)) / sweepTime, 0, 1)
			local from = (pass % 2 == 0) and -half or half
			local to = (pass % 2 == 0) and half or -half
			yaw = from + (to - from) * a
			armZ = math.rad(-95)
			lean = math.rad(-8)
		end
		root.CFrame = base * CFrame.Angles(lean, yaw, 0)
		if rArm and rC0 then
			rArm.C0 = rC0 * CFrame.Angles(0, 0, armZ)
		end
		if lArm and lC0 then
			lArm.C0 = lC0 * CFrame.Angles(0, 0, -armZ)
		end
		task.wait()
	end
	if root.Parent then
		root.CFrame = base
	end
	if rArm and rC0 and rArm.Parent then
		rArm.C0 = rC0
	end
	if lArm and lC0 and lArm.Parent then
		lArm.C0 = lC0
	end
	if root.Parent then
		root.Anchored = wasAnchored
	end
	if hum.Parent then
		hum.AutoRotate = prevAuto
	end
	jointMotionBusy[rt] = nil
end

-- VineWhip: low horizontal ground sweep (left<->right); JUMP over it to dodge (grounded = hit).
local function performVineWhip(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.VineWhip
	local vine -- [2026-08-04] 파괴를 pcall 밖에서 보장(오류 삼킴 시 잔재 방지)
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local aim = targetRoot.Position
		local origin = root.Position
		local fwd = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
		fwd = fwd.Magnitude > 0.5 and fwd.Unit or root.CFrame.LookVector
		root.CFrame = CFrame.lookAt(origin, origin + fwd)
		local length = cfg.Length or 34
		local sweepAngle = math.rad(cfg.SweepAngle or 110)
		local height = cfg.Height or 2
		local gy = rollGroundY(rt, origin)
		local baseAngle = math.atan2(fwd.X, fwd.Z)
		-- [QA 2026-07-22] 발동 타이밍 표시: 반투명 덩굴 예고만으론 '언제 휘두르는지'를 알 수 없었다
		-- → 윈드업 동안 수축하는 타이밍 원반(같은 보스 BranchSweep과 동일 규약).
		makeTimedDisc(Vector3.new(origin.X, gy + TELEGRAPH_Y_OFFSET, origin.Z), length * 0.55, cfg.Color or Color3.fromRGB(90, 160, 60), cfg.Windup or 0.7)
		task.spawn(vineSweepMotion, rt, cfg.Windup or 0.7, cfg.SweepTime or 0.75, cfg.SweepAngle or 110, cfg.DoubleSweep, aim)
		local function placeVine(v, ang)
			local d = Vector3.new(math.sin(baseAngle + ang), 0, math.cos(baseAngle + ang))
			local mid = origin + d * (length / 2)
			v.CFrame = CFrame.lookAt(Vector3.new(mid.X, gy + height, mid.Z), Vector3.new(mid.X, gy + height, mid.Z) + d)
			return d
		end
		-- [2026-07-22] 나무장군 덩굴채찍: Assets.Drops.Wood 메시로 교체(길이방향 스트레치). 미도착 시 기존 네온 파트.
		local isWoodVine = false
		local woodT = ReplicatedStorage.Assets.Drops:FindFirstChild("Wood")
		if woodT then
			vine = woodT:Clone()
			vine.Name = "BossTelegraph"
			vine.PivotOffset = CFrame.new()
			vine.Size = Vector3.new(2.4, 2.4, length) -- 길이=local Z
			vine.Transparency = TELEGRAPH_TRANSPARENCY -- 윈드업 경고(반투명)
			isWoodVine = true
		else
			vine = Instance.new("Part")
			vine.Name = "BossTelegraph"
			vine.Material = Enum.Material.Neon
			vine.Color = cfg.Color or Color3.fromRGB(90, 160, 60)
			vine.Transparency = TELEGRAPH_TRANSPARENCY
			vine.Size = Vector3.new(1.6, 1.6, length)
		end
		vine.Anchored = true
		vine.CanCollide = false
		vine.CanQuery = false
		vine.CanTouch = false
		vine.CastShadow = false
		placeVine(vine, -sweepAngle)
		vine.Parent = bossFolder
		Debris:AddItem(vine, (cfg.Windup or 0.7) + (cfg.SweepTime or 0.75) * (cfg.DoubleSweep and 2 or 1) + 1.5)
		task.wait(cfg.Windup or 0.7)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			vine:Destroy()
			return
		end
		vine.Transparency = 0
		if not isWoodVine then
			vine.Material = Enum.Material.Grass
			vine.Color = Color3.fromRGB(80, 140, 55)
		end
		local function doSweep(fromA, toA, dur)
			local hitSet = {}
			local snap = capturePlayerSnapshot()
			local t0 = os.clock()
			while true do
				if not (rt.Model.Parent and humanoid.Health > 0) then
					break
				end
				local a = math.min((os.clock() - t0) / dur, 1)
				local ang = fromA + (toA - fromA) * a
				local d = placeVine(vine, ang)
				for _, se in ipairs(snapshotAlive(snap)) do
					if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
						local pr, ph = se.root, se.hum
						if pr then
							local rel = Vector3.new(pr.Position.X - origin.X, 0, pr.Position.Z - origin.Z)
							local along = rel:Dot(d)
							if along >= 1 and along <= length then
								local perp = (rel - d * along).Magnitude
								if perp <= 2.4 then
									local airborne = ph.FloorMaterial == Enum.Material.Air or (pr.Position.Y - gy) > (cfg.JumpClear or 5)
									if not airborne then
										hitSet[se.player] = true
										PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5))
									end
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
		end
		doSweep(-sweepAngle, sweepAngle, cfg.SweepTime or 0.75)
		if cfg.DoubleSweep then
			task.wait(0.1)
			doSweep(sweepAngle, -sweepAngle, cfg.SweepTime or 0.75)
		end
	end)
	if vine then
		vine:Destroy()
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-07-20] BrickBoss 페이즈 개편: 1페(산개) BrickBarrage =====
-- 하늘에서 벽돌이 여러 지점 순차 낙하(다중원 산개 회피). 산개 포즈 방해 방지 위해 몸통 모션 없음.
local function performBrickBarrage(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.BrickBarrage
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		local base = leadTargetPos(rt, targetRoot, cfg.Windup or 0.6)
		local spots = {}
		for i = 1, (cfg.Count or 6) do
			local ang = math.random() * math.pi * 2
			local rad = (i <= (cfg.TrackCount or 2)) and (math.random() * 3) or (math.random() * (cfg.Spread or 22))
			local p = base + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
			local gy = rollGroundY(rt, p)
			spots[i] = Vector3.new(p.X, gy, p.Z)
			makeTimedDisc(spots[i] + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), cfg.Radius or 6, cfg.Color or Color3.fromRGB(190, 92, 66), (cfg.Windup or 0.6) + (i - 1) * (cfg.EruptGap or 0.28))
		end
		task.wait(cfg.Windup or 0.6)
		local TweenService = game:GetService("TweenService")
		for _, spot in ipairs(spots) do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local sz = (cfg.Radius or 6) * 1.2
			-- [2026-07-22d] 낙하 파트 = Assets.Drops.Brick 메시(기존 큐브 Part 대신). 미도착 시 벽돌 큐브 폴백.
			local brick
			local dropsF = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Drops")
			local brickTpl = dropsF and dropsF:FindFirstChild("Brick")
			if brickTpl and brickTpl:IsA("BasePart") then
				brick = brickTpl:Clone()
				brick.Transparency = 0
			else
				brick = Instance.new("Part")
				brick.Material = Enum.Material.Brick
				brick.Color = cfg.Color or Color3.fromRGB(190, 92, 66)
			end
			brick.Name = "BrickBarrage"
			brick.Anchored = true
			brick.CanCollide = false
			brick.CanQuery = false
			brick.CanTouch = false
			brick.CastShadow = false
			brick.Size = Vector3.new(sz * 1.15, sz * 0.42, sz * 0.62) -- [2026-07-22d] 납짝한 벽돌 비율(높이 Y 얕게) — 낙하 중 회전해 바닥에 납짝히 착지
			brick.CFrame = CFrame.new(spot + Vector3.new(0, cfg.DropHeight or 42, 0))
				* CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
			brick.Parent = bossFolder
			local drop = cfg.DropTime or 0.16
			TweenService:Create(brick, TweenInfo.new(drop, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				CFrame = CFrame.new(spot + Vector3.new(0, brick.Size.Y * 0.5, 0)), -- 납짝 벽돌 실측 반높이로 바닥 정착
			}):Play()
			task.wait(drop)
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and withinFairRadius(pr.Position, spot, cfg.Radius or 6) then
					PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 0.75) + 0.5))
				end
			end
			Debris:AddItem(brick, 0.5)
			task.wait(math.max((cfg.EruptGap or 0.28) - drop, 0))
		end
	end)
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- BrickQuake (2페이즈·합체): 내려찍기 → 바깥으로 퍼지는 벽돌 링 충격파. 점프로 넘거나 보스 발밑(중심) 안전.
local function performBrickQuake(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.BrickQuake
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local center = root.Position
		local gy = rollGroundY(rt, center)
		local startR = cfg.StartRadius or 6
		-- [2026-07-20] 벽돌 스택 강체 유지: zoneSlamMotion(조인트 팬아웃) 미사용 — 링이 주 연출
		makeTimedDisc(Vector3.new(center.X, gy + TELEGRAPH_Y_OFFSET, center.Z), startR, cfg.Color or Color3.fromRGB(180, 90, 60), cfg.Windup or 0.6)
		task.wait(cfg.Windup or 0.6)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		-- 벽돌 링 생성 후 바깥으로 확장
		local ringCount = cfg.RingCount or 18
		local bricks = {}
		for i = 1, ringCount do
			local ang = (i / ringCount) * math.pi * 2
			local b = Instance.new("Part")
			b.Name = "BrickQuakeRing"
			b.Anchored = true
			b.CanCollide = false
			b.CanQuery = false
			b.CanTouch = false
			b.CastShadow = false
			b.Material = Enum.Material.Brick
			b.Color = cfg.Color or Color3.fromRGB(180, 90, 60)
			b.Size = Vector3.new(3, 2.4, 2.2)
			b.CFrame = CFrame.new(center.X + math.cos(ang) * startR, gy + 1.2, center.Z + math.sin(ang) * startR) * CFrame.Angles(0, -ang, 0)
			b.Parent = bossFolder
			bricks[i] = { part = b, ang = ang }
			Debris:AddItem(b, (cfg.ExpandTime or 0.9) + 0.3)
		end
		local maxR = cfg.MaxRadius or 34
		local band = cfg.BandWidth or 4
		local expand = cfg.ExpandTime or 0.9
		local hitSet = {}
		local snap = capturePlayerSnapshot()
		local t0 = os.clock()
		while true do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local a = math.min((os.clock() - t0) / expand, 1)
			local curR = startR + (maxR - startR) * a
			for _, e in ipairs(bricks) do
				if e.part.Parent then
					e.part.CFrame = CFrame.new(center.X + math.cos(e.ang) * curR, gy + 1.2, center.Z + math.sin(e.ang) * curR) * CFrame.Angles(0, -e.ang, math.rad(curR * 8))
				end
			end
			for _, se in ipairs(snapshotAlive(snap)) do
				if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
					local pr, ph = se.root, se.hum
					local d = Vector3.new(pr.Position.X - center.X, 0, pr.Position.Z - center.Z).Magnitude
					if math.abs(d - curR) <= band then
						local airborne = ph.FloorMaterial == Enum.Material.Air or (pr.Position.Y - gy) > (cfg.JumpClear or 15)
						if not airborne then
							hitSet[se.player] = true
							PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5))
						end
					end
				end
			end
			if a >= 1 then
				break
			end
			task.wait()
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-07-22e] 벽돌대왕 2페(합체) 재설계 패턴 3종 =====
-- 납작 벽돌 파트 생성(Assets.Drops.Brick 메시, 미도착 시 브릭 큐브 폴백). 1페 낙하와 시각 통일.
local function makeFlatBrick(name, size, color)
	local dropsF = ReplicatedStorage:FindFirstChild("Assets") and ReplicatedStorage.Assets:FindFirstChild("Drops")
	local tpl = dropsF and dropsF:FindFirstChild("Brick")
	local p
	if tpl and tpl:IsA("BasePart") then
		p = tpl:Clone()
		p.Transparency = 0
	else
		p = Instance.new("Part")
		p.Material = Enum.Material.Brick
		p.Color = color or Color3.fromRGB(190, 92, 66)
	end
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	return p
end

-- A. 십자 벽돌벽: 발밑에서 4방(월드 축) 벽돌 벽이 솟아 바깥으로 밀려남. 대각선 45° 틈이 안전지대.
local function performBrickWalls(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.BrickWalls
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local center = root.Position
		local gy = rollGroundY(rt, center)
		local windup = cfg.Windup or 0.7
		local laneW = cfg.LaneWidth or 11
		local pushDist = cfg.PushDist or 42
		local pushTime = cfg.PushTime or 0.8
		local wallH = cfg.WallHeight or 6
		local color = cfg.Color or Color3.fromRGB(190, 92, 66)
		local dirs = { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }
		for _, d in ipairs(dirs) do
			local mid = center + d * (pushDist / 2)
			local mc = Vector3.new(mid.X, gy + ROLL_HIT_BOX_HEIGHT / 2, mid.Z)
			showRollTelegraph(CFrame.lookAt(mc, mc + d), Vector3.new(laneW, ROLL_HIT_BOX_HEIGHT, pushDist), windup)
		end
		task.wait(windup)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end
		local walls = {}
		for _, d in ipairs(dirs) do
			local w = makeFlatBrick("BrickWall", Vector3.new(laneW, wallH, 3.5), color)
			w.Parent = bossFolder
			-- 생성 즉시 안전망: 아래 밀어내기 루프가 중단(사망·오류)되면 정리 코드에 도달하지 못해 벽돌벽이 중앙에 영구히 남는다
			Debris:AddItem(w, pushTime + 1.5)
			walls[#walls + 1] = { part = w, dir = d }
		end
		local dmg = math.floor(DEF.Atk * (cfg.DamageMul or 1) + 0.5)
		local hitSet = {}
		local snap = capturePlayerSnapshot()
		local t0 = os.clock()
		while true do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local a2 = math.min((os.clock() - t0) / pushTime, 1)
			local travel = a2 * pushDist
			for _, w in ipairs(walls) do
				local wp = center + w.dir * travel
				w.part.CFrame = CFrame.lookAt(Vector3.new(wp.X, gy + wallH / 2, wp.Z), Vector3.new(wp.X, gy + wallH / 2, wp.Z) + w.dir)
			end
			for _, se in ipairs(snapshotAlive(snap)) do
				if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
					local rel = Vector3.new(se.root.Position.X - center.X, 0, se.root.Position.Z - center.Z)
					for _, w in ipairs(walls) do
						local fwd = rel:Dot(w.dir)
						local side = (rel - w.dir * fwd).Magnitude
						if side <= fairHalfWidth(laneW) and fwd >= 0 and fwd <= fairRadius(pushDist) and travel >= fwd then
							hitSet[se.player] = true
							PlayerDamageService.Apply(se.hum, dmg)
							break
						end
					end
				end
			end
			if a2 >= 1 then
				break
			end
			task.wait()
		end
		for _, w in ipairs(walls) do
			Debris:AddItem(w.part, 0.3)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- B. 3연속 돌격: 방향 재조준하며 3연속 직선 돌진(전조 가속). performCharge 규약(앵커 CFrame 슬라이드+브릭 핀+넉백).
local function performBrickTripleCharge(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.BrickTripleCharge
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		local dashCount = cfg.DashCount or 3
		local windups = cfg.Windups or { 0.5, 0.4, 0.35 }
		local width = cfg.Width or 14
		local dist = cfg.Dist or 30
		local moveTime = cfg.MoveTime or 0.4
		local dmg = math.floor(DEF.Atk * (cfg.DamageMul or 1.1) + 0.5)
		for i = 1, dashCount do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local tr = (targetRoot and targetRoot.Parent) and targetRoot or (pickTarget(rt, CombatService.GetContributors(rt.Model)))
			local origin = root.Position
			local wu = windups[i] or windups[#windups] or 0.4
			local dirV
			if tr and tr.Parent then
				dirV = (leadTargetPos(rt, tr, wu * 0.8) - origin) * Vector3.new(1, 0, 1)
			end
			if not dirV or dirV.Magnitude < 0.5 then
				dirV = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			end
			local dir = dirV.Unit
			local dashDist = clampDashDist(rt, origin, dir, dist) -- [2026-08-08] 존 이탈 봉쇄(회마다 재조준=회마다 클램프)
			if dashDist < 2 then
				break
			end
			local gy = rollGroundY(rt, origin)
			local mc = Vector3.new(origin.X, gy + ROLL_HIT_BOX_HEIGHT / 2, origin.Z) + dir * (dashDist / 2)
			showRollTelegraph(CFrame.lookAt(mc, mc + dir), Vector3.new(width, ROLL_HIT_BOX_HEIGHT, dashDist), wu)
			humanoid:MoveTo(origin)
			root.CFrame = CFrame.lookAt(origin, origin + dir)
			task.wait(wu)
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			root.Anchored = true
			local hitSet = {}
			local snap = capturePlayerSnapshot()
			-- [QA 2026-07-22 부양 수정] 합체 후엔 브릭 앵커(startBrickWeldLoop)로 물리 낙하가 없어
			-- baseY 고정 슬라이드가 낮은 지형으로 돌진하면 그 높이에 영구 고착된다 → 매 프레임 지면+접지높이로 재산출.
			local standY = rt.BrickStandY or (root.Position.Y - rollGroundY(rt, origin))
			local t0 = os.clock()
			local pins = captureBrickPins(rt)
			while true do
				if humanoid.Health <= 0 or not root.Parent then
					break
				end
				local a2 = math.min((os.clock() - t0) / moveTime, 1)
				local pos = origin + dir * (dashDist * a2)
				local py = rollGroundY(rt, pos) + standY
				root.CFrame = CFrame.lookAt(Vector3.new(pos.X, py, pos.Z), Vector3.new(pos.X, py, pos.Z) + dir)
					* CFrame.Angles(math.rad(-14 * math.sin(a2 * math.pi)), 0, 0)
				applyBrickPins(rt, pins)
				for _, se in ipairs(snapshotAlive(snap)) do
					if not hitSet[se.player] and se.root.Parent and se.hum.Health > 0 then
						if withinFairRadius(se.root.Position, pos, width * 0.5) then
							hitSet[se.player] = true
							local damaged = PlayerDamageService.Apply(se.hum, dmg)
							local kb = cfg.Knockback
							if damaged and kb then
								MonsterService.KnockbackPlayer(se.player, pos, kb.Force, kb.Lift)
							end
						end
					end
				end
				if a2 >= 1 then
					break
				end
				task.wait()
			end
			if root.Parent then
				root.Anchored = false
			end
			task.wait(cfg.DashGap or 0.3)
		end
	end)
	if rt.Root and rt.Root.Parent then
		rt.Root.Anchored = false
		rt.Root.AssemblyLinearVelocity = Vector3.zero
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- C. 벽돌비 강타: 점프 도약 → 착지 압착(PressRadius) + 동시에 하늘에서 납작 벽돌 다수 낙하(BrickBarrage 강화판).
local function performBrickRainSlam(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.BrickRainSlam
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg and targetRoot) then
			return
		end
		local origin = root.Position
		-- [2026-08-08] 착지점 존 클램프
		local targetPos = clampChasePos(rt, targetRoot.Position)
		local gy = rollGroundY(rt, targetPos)
		local impact = Vector3.new(targetPos.X, gy, targetPos.Z)
		local extY = rt.Model:GetExtentsSize().Y
		-- [QA 2026-07-22] 합체 기준 접지 높이 우선: 현재 루트에서 역산하면 이미 떠 있는 부양이 그대로 승계된다.
		local standY = rt.BrickStandY or (origin.Y - rollGroundY(rt, origin))
		if standY < 1 or standY > extY then
			standY = extY / 2
		end
		local airTime = cfg.AirTime or 0.9
		local pressRadius = cfg.PressRadius or 10
		local disc = makeDisc(impact + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), pressRadius, TELEGRAPH_COLOR, airTime + 0.3)
		disc.Name = "BossLeapTelegraph"
		disc:SetAttribute("AirTime", airTime)
		humanoid.AutoRotate = false
		humanoid:MoveTo(origin)
		root.Anchored = true
		local lookV = (Vector3.new(impact.X, 0, impact.Z) - Vector3.new(origin.X, 0, origin.Z))
		local lookDir = lookV.Magnitude > 0.5 and lookV.Unit or root.CFrame.LookVector
		local pins = captureBrickPins(rt)
		local t0 = os.clock()
		while true do
			if humanoid.Health <= 0 or not root.Parent then
				return
			end
			local a2 = math.min((os.clock() - t0) / airTime, 1)
			local x = origin.X + (impact.X - origin.X) * a2
			local z = origin.Z + (impact.Z - origin.Z) * a2
			local y = origin.Y + ((impact.Y + standY) - origin.Y) * a2 + math.sin(a2 * math.pi) * (cfg.RiseHeight or 18)
			root.CFrame = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x, y, z) + lookDir)
				* CFrame.Angles(math.rad(-20 * math.sin(a2 * math.pi)), 0, 0)
			applyBrickPins(rt, pins)
			if a2 >= 1 then
				break
			end
			task.wait()
		end
		local landCf = CFrame.lookAt(Vector3.new(impact.X, impact.Y + standY, impact.Z), Vector3.new(impact.X, impact.Y + standY, impact.Z) + lookDir)
		root.CFrame = landCf
		applyBrickPins(rt, pins)
		local pdmg = math.floor(DEF.Atk * (cfg.PressDamageMul or 1) + 0.5)
		for _, p in ipairs(Players:GetPlayers()) do
			local pr, ph = alivePlayerParts(p)
			if pr and withinFairRadius(pr.Position, impact, pressRadius) then
				PlayerDamageService.Apply(ph, pdmg)
			end
		end
		local shock = Instance.new("Part")
		shock.Name = "BossLeapShock"
		shock.Shape = Enum.PartType.Cylinder
		shock.Size = Vector3.new(0.4, pressRadius * 0.6, pressRadius * 0.6)
		shock.CFrame = CFrame.new(impact + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
		shock.Anchored = true
		shock.CanCollide = false
		shock.CanQuery = false
		shock.CanTouch = false
		shock.CastShadow = false
		shock.Material = Enum.Material.Neon
		shock.Color = Color3.fromRGB(255, 180, 120)
		shock.Transparency = 0.2
		shock.Parent = bossFolder
		pcall(function()
			TweenService:Create(shock, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = Vector3.new(0.4, pressRadius * 2.6, pressRadius * 2.6),
				Transparency = 1,
			}):Play()
		end)
		Debris:AddItem(shock, 0.6)
		local base = (targetRoot and targetRoot.Parent) and targetRoot.Position or impact
		local rainCount = cfg.RainCount or 9
		local rainRadius = cfg.RainRadius or 6
		local rainSpread = cfg.RainSpread or 26
		local trackCount = cfg.RainTrackCount or 3
		local color = cfg.Color or Color3.fromRGB(190, 92, 66)
		local spots = {}
		for i = 1, rainCount do
			local ang = math.random() * math.pi * 2
			local rad = (i <= trackCount) and (math.random() * 4) or (math.random() * rainSpread)
			local bp = base + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
			local ggy = rollGroundY(rt, bp)
			spots[i] = Vector3.new(bp.X, ggy, bp.Z)
			makeTimedDisc(spots[i] + Vector3.new(0, TELEGRAPH_Y_OFFSET, 0), rainRadius, color, 0.3 + (i - 1) * (cfg.RainEruptGap or 0.22))
		end
		task.wait(0.3)
		local dropH = cfg.RainDropHeight or 42
		local dropT = cfg.RainDropTime or 0.16
		local rdmg = math.floor(DEF.Atk * (cfg.RainDamageMul or 0.7) + 0.5)
		for _, spot in ipairs(spots) do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local rsz = rainRadius * 1.2
			local brick = makeFlatBrick("BrickBarrage", Vector3.new(rsz * 1.15, rsz * 0.42, rsz * 0.62), color)
			brick.CFrame = CFrame.new(spot + Vector3.new(0, dropH, 0)) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
			brick.Parent = bossFolder
			TweenService:Create(brick, TweenInfo.new(dropT, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				CFrame = CFrame.new(spot + Vector3.new(0, brick.Size.Y * 0.5, 0)),
			}):Play()
			task.wait(dropT)
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and withinFairRadius(pr.Position, spot, rainRadius) then
					PlayerDamageService.Apply(ph, rdmg)
				end
			end
			Debris:AddItem(brick, 0.5)
			task.wait(math.max((cfg.RainEruptGap or 0.22) - dropT, 0))
		end
	end)
	if rt.Root and rt.Root.Parent then
		rt.Root.Anchored = false
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-08-24] 챕텀2 보스 전용 패턴 모음 =====
-- ★최상위 `local function`으로 늘어놓지 않고 테이블 하나에 담는다.
--   이 모듈은 메인 청크 로컬이 이미 한도(200) 근처라, 함수 7개를 따로 선언하면
--   "Out of local registers"로 모듈 전체가 컴파일 안 된다(실제로 밟음).
local Ch2Pat = {}

-- [2026-08-27 사장님] 마커까지 대기. 배선돼 있으면 그 순간까지, 아니면 fallbackSec만큼 쉼다.
-- ★모듈 최상단 local로 빼지 말 것 — 이 파일은 Luau 로컬 200개 한도에 닿아 있어 모듈이 통째로 로드 실패한다.
-- 반환 true = 마커 도달 / false = 미배선·트랙 끊김·사망·타임아웃(호출측은 그대로 진행하면 된다).
function Ch2Pat.WaitImpact(rt, key, marker, fallbackSec)
	local st = rt.PatternMarkerStates and rt.PatternMarkerStates[key]
	if not st then
		task.wait(fallbackSec) -- 마커 미배선 보스 — 종전 시간값 그대로
		return false
	end
	local gen = st.Generation
	local deadline = os.clock() + fallbackSec + 0.8 -- 마커 유실 안전망(영원히 멈추지 않게)
	while os.clock() < deadline do
		if st.Reached[marker] == gen then
			return true
		end
		if st.CancelledGeneration == gen then
			return false -- 다른 패턴이 트랙을 끊음
		end
		if not (rt.Model and rt.Model.Parent) then
			return false
		end
		if rt.Humanoid and rt.Humanoid.Health <= 0 then
			return false
		end
		task.wait(0.03)
	end
	return false
end

-- ===== [2026-08-24 잔치대감 전용] LiquorSplash / DrumWave =====
-- 노션 "몬스터 외형 참고" — 잔치 도깨비: "춤, 북소리, 술을 이용한 다양한 패턴을 번갈아 사용한다".
-- 모델이 실제로 든 무기(AlcoholCup / DrumStick)를 그대로 두 패턴의 근거로 삼는다.

-- LiquorSplash(주): 술잔을 뿌려 전방 부채꼴로 술 웅덩이를 깔는다.
-- 웅덩이는 예고 원으로 먼저 보이고(피할 수 있음), 이후 체류 시 틱 피해 + 감속.
-- 발밑이 아니라 "서 있을 자리"를 줌여 가는 압박형 패턴 — 돌진형 LeapSlam과 성격이 겁치지 않는다.
-- [2026-09-08] 교전 개시 등장 모션 — AVDefs.MonsterAnims[id].Start를 선언한 보스만 동작하는 전면 옵트인.
-- 첫 조우(rt.Engaged 엣지 전이)에서 1회 재생하고, 클립이 끝날 때까지 PatternBusy로 AI를 세운다
-- = "등장 모션이 끝나야 전투 시작". Start 미선언 보스는 no-op이라 기존 흐름 그대로다.
-- ★모듈 최상단 local로 빼지 말 것 — 이 파일은 Luau 로컬 200개 한도에 닿아 있다(Ch2Pat 테이블에 얹는다).
-- 반환: 실제로 재생을 시작했으면 true — 호출측은 이번 틱을 종료해 추격·공격이 겹치지 않게 한다.
-- [2026-09-08] 왕좌 착석 대기 — Boss_Start의 0프레임(웅크린 자세)을 speed 0으로 홀드해 "앉아 있는" 포즈를 만든다.
-- 전용 착석 클립이 없어 등장 클립의 시작 포즈를 재사용한다 — PlayIntro가 같은 트랙을 0부터 다시 틀므로
-- "앉은 포즈 → 일어서기"가 이음매 없이 이어진다. animDef.SeatIdle을 선언한 보스만 동작(전면 옵트인).
-- ★위치도 CFrame으로 못박는다 — 왕좌는 MeshPart라 쿡 햬 위에 물리로 앉히면 뜨거나 떨린다.
function Ch2Pat.SeatHold(rt)
	local animDef = AVDefs.MonsterAnims[rt.Id]
	if not (animDef and animDef.SeatIdle and animDef.Start and animDef.Start ~= "") then
		return false
	end
	if rt.Root and rt.Root.Parent and rt.SpawnPos and rt.IdleLook then
		-- ★앛커 필수: CFrame만 매 틱 집어넣으면 그 사이 60fps 물리가 Humanoid HipHeight만큼 다시 세워
		-- 좌석에서 5.2스터드 떠 있다(실측 609.32 목표 → 614.50 착지). 앉혀두는 동안은 정적으로 고정한다.
		rt.Root.Anchored = true
		rt.Root.CFrame = CFrame.lookAt(rt.SpawnPos, rt.SpawnPos + rt.IdleLook)
		rt.Root.AssemblyLinearVelocity = Vector3.zero
		rt.Seated = true
	end
	local track = rt.IntroTrack
	if not track or rt.IntroTrackModel ~= rt.Model then
		local animator = rt.Humanoid and rt.Humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			return false
		end
		local anim = Instance.new("Animation")
		anim.Name = "BossIntro"
		anim.AnimationId = animDef.Start
		local ok, loaded = pcall(animator.LoadAnimation, animator, anim)
		if not ok or not loaded then
			return false
		end
		loaded.Priority = Enum.AnimationPriority.Action3
		loaded.Looped = false
		rt.IntroTrack = loaded
		rt.IntroTrackModel = rt.Model
		track = loaded
	end
	if not track.IsPlaying then
		track:Play(0.25, 1, 0) -- ★speed 0 — 세 번째 인자를 빼면 1로 리셋돼 그냥 일어서 버린다
	end
	track:AdjustSpeed(0)
	track.TimePosition = 0
	return true
end

-- 복귀 보행 중·전투 중에는 착석 홀드를 놓는다(걷기 애니가 보이도록). 안 앉아 있으면 no-op.
function Ch2Pat.SeatRelease(rt)
	if rt.Seated then
		rt.Seated = false
		if rt.Root and rt.Root.Parent then
			rt.Root.Anchored = false
			rt.Root.AssemblyLinearVelocity = Vector3.zero
			-- ★앛커를 풀면 네트워크 소유권이 Auto로 돌아가 클라이언트로 넘어간다
			-- → 서버 MoveTo가 무시돼 보스가 그 자리에 고착한다(실사고 이력). 명시적으로 서버 소유로 되돌린다.
			pcall(function()
				rt.Root:SetNetworkOwner(nil)
			end)
		end
	end
	local track = rt.IntroTrack
	if track and track.IsPlaying and track.Speed == 0 then
		track:Stop(0.2)
	end
end

-- 착석 → 기립 전이: 앛커를 유지한 채 클립 길이 동안 좌석 높이 → 물리 안착 높이로 올린 뒤 해제한다.
-- ★그냥 해제하면 한 프레임에 튀어오른다 — 왕좌 MeshPart의 쿡 충돌 햬이 시각 좌석면보다 위라
--   물리 안착 지점이 레이쳨스트 지면 기준보다 SeatRise만큼 높다(실측 614.50 - 609.32 = 5.2).
function Ch2Pat.SeatStandUp(rt)
	if not rt.Seated then
		Ch2Pat.SeatRelease(rt)
		return false
	end
	local animDef = AVDefs.MonsterAnims[rt.Id]
	local rise = tonumber(animDef and animDef.SeatRise) or 0
	local root, model = rt.Root, rt.Model
	if rise <= 0 or not root or not root.Parent or not root.Anchored then
		Ch2Pat.SeatRelease(rt)
		return false
	end
	local track = rt.IntroTrack
	local dur = (track and track.Length > 0.05) and track.Length or 1.6
	local from = root.CFrame
	rt.SeatGen = (rt.SeatGen or 0) + 1
	local gen = rt.SeatGen
	task.spawn(function()
		local t0 = os.clock()
		while rt.SeatGen == gen and rt.Model == model and root.Parent and root.Anchored do
			local a = math.min((os.clock() - t0) / dur, 1)
			root.CFrame = from + Vector3.new(0, rise * a, 0)
			if a >= 1 then
				break
			end
			task.wait()
		end
		if rt.SeatGen == gen and rt.Model == model then
			Ch2Pat.SeatRelease(rt)
		end
	end)
	return true
end

function Ch2Pat.PlayIntro(rt, now)
	local animDef = AVDefs.MonsterAnims[rt.Id]
	local animId = animDef and animDef.Start
	if not animId or animId == "" then
		return false
	end
	local animator = rt.Humanoid and rt.Humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return false
	end
	if rt.IntroTrackModel ~= rt.Model then
		rt.IntroTrack = nil -- 재소환된 새 모델 — 구 Animator에 묶인 트랙은 재사용하지 않는다
	end
	if not rt.IntroTrack then
		local anim = Instance.new("Animation")
		anim.Name = "BossIntro"
		anim.AnimationId = animId
		local ok, loaded = pcall(animator.LoadAnimation, animator, anim)
		if not ok or not loaded then
			return false
		end
		loaded.Priority = Enum.AnimationPriority.Action3 -- 공격(Action2)·Idle/Run(Core)보다 위
		loaded.Looped = false
		rt.IntroTrack = loaded
		rt.IntroTrackModel = rt.Model
	end
	stopBossAnims(rt, nil)
	if rt.IntroTrack.IsPlaying then
		rt.IntroTrack:Stop(0)
	end
	rt.IntroTrack:Play(0.1, 1, 1) -- ★speed 인자를 빼면 재생속도가 1로 리셋된다(도깨비왕 애니 규약)
	local dur = rt.IntroTrack.Length
	if dur <= 0.05 then
		dur = 1.6 -- 자산 미로드 시 Length=0 — Boss_Start 실측 1.567 폴백
	end
	rt.PatternBusy = true
	rt.PatternBusySince = now
	rt.IntroGen = (rt.IntroGen or 0) + 1
	local gen = rt.IntroGen
	task.delay(dur, function()
		if rt.IntroGen == gen and rt.PatternBusy then
			rt.PatternBusy = false
			rt.PatternBusySince = nil
		end
	end)
	return true
end

function Ch2Pat.LiquorSplash(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.LiquorSplash
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local origin = root.Position
		local aim = targetRoot.Position
		local dir = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
		dir = dir.Magnitude > 0.5 and dir.Unit or root.CFrame.LookVector
		root.CFrame = CFrame.lookAt(origin, origin + dir)

		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		local pools = cfg.Pools or 3
		local windup = cfg.Windup or 1.0
		local radius = cfg.Radius or 9
		local nearGap = cfg.NearGap or 6
		local reach = cfg.Reach or 26
		local spread = math.rad(cfg.SpreadDeg or 55)
		local color = cfg.Color or Color3.fromRGB(240, 228, 200)

		-- ★웅덩이 거리는 **타겟까지의 실제 거리** 기준으로 잡는다.
		-- 고정 reach로 깔았더니 몸집 큰 보스에서 웅덩이가 전부 플레이어 뒤로 넘어갔다(실측 틱 0회).
		local flatToTarget = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z).Magnitude
		local minD = bodyRadius + nearGap
		local maxD = bodyRadius + nearGap + reach
		local spots = {}
		for i = 1, pools do
			local t = (pools == 1) and 0.5 or ((i - 1) / (pools - 1))
			local ang = -spread / 2 + spread * t
			local d = math.clamp(flatToTarget * (0.8 + math.random() * 0.4), minD, maxD)
			local off = (CFrame.Angles(0, ang, 0) * CFrame.new(0, 0, -d)).Position
			local fwd = CFrame.lookAt(origin, origin + dir)
			local p = (fwd * CFrame.new(off)).Position
			local gy = rollGroundY(rt, p)
			spots[i] = Vector3.new(p.X, gy, p.Z)
			makeTimedDisc(Vector3.new(p.X, gy + TELEGRAPH_Y_OFFSET, p.Z), radius, color, windup)
		end
		task.wait(windup)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end

		-- 웅덩이 생성(장식 원판) + 체류 틱
		local dur = cfg.Duration or 6
		local zones = {}
		for _, s in ipairs(spots) do
			local z = Instance.new("Part")
			z.Name = "LiquorPool"
			z.Shape = Enum.PartType.Cylinder
			z.Size = Vector3.new(0.25, radius * 2, radius * 2)
			z.CFrame = CFrame.new(s.X, s.Y + 0.12, s.Z) * CFrame.Angles(0, 0, math.rad(90))
			z.Anchored = true
			z.CanCollide = false
			z.CanQuery = false
			z.CanTouch = false
			z.CastShadow = false
			z.Material = Enum.Material.SmoothPlastic
			z.Color = color
			z.Transparency = 0.45
			z.Parent = bossFolder
			zones[#zones + 1] = z
			Debris:AddItem(z, dur + 0.6)
		end

		local tickSec = cfg.TickSec or 0.7
		local slowed = {}
		local endAt = os.clock() + dur
		while os.clock() < endAt do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr then
					local inPool = false
					for _, s in ipairs(spots) do
						if withinFairRadius(pr.Position, s, radius) then
							inPool = true
							break
						end
					end
					if inPool then
						local damaged = PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.TickDamageMul or 0.18) + 0.5))
						if damaged then
							slowed[ph] = true
							applyPatternSlow(ph, MovementDefs.WALK.DefaultSpeed * (cfg.Slow or 0.65))
						end
					end
				end
			end
			task.wait(tickSec)
		end
		for ph in pairs(slowed) do
			releasePatternSlow(ph)
		end
		for _, z in ipairs(zones) do
			if z.Parent then
				pcall(function()
					TweenService:Create(z, TweenInfo.new(0.4), { Transparency = 1 }):Play()
				end)
			end
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- DrumWave(부): 북을 연타해 몸 중심에서 링이 점점 넓게 퍼진다.
-- ★각 타는 **고리(직전 반경~이번 반경) 구간만** 타격한다 — 링을 따라 밖으로 도망가면 계속 맞고,
--   제자리(몸 근처)에 붙어 있으면 첫 타만 맞는다. "밖으로 도망가기"가 오답인 드문 구조.
function Ch2Pat.DrumWave(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.DrumWave
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid:MoveTo(root.Position)
		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		local beats = cfg.Beats or 3
		local windup = cfg.Windup or 1.0
		local step = cfg.Step or 10
		local gap = cfg.BeatGap or 0.55
		local color = cfg.Color or Color3.fromRGB(255, 205, 130)
		local origin = root.Position
		local gy = rollGroundY(rt, origin)
		local maxR = bodyRadius + step * beats
		makeTimedDisc(Vector3.new(origin.X, gy + TELEGRAPH_Y_OFFSET, origin.Z), maxR, color, windup)
		task.wait(windup)
		local prevR = 0
		for b = 1, beats do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local r = bodyRadius + step * b
			-- 링 시각화
			local ring = Instance.new("Part")
			ring.Name = "DrumWaveRing"
			ring.Shape = Enum.PartType.Cylinder
			ring.Size = Vector3.new(0.3, prevR * 2 + 1, prevR * 2 + 1)
			ring.CFrame = CFrame.new(origin.X, gy + 0.2, origin.Z) * CFrame.Angles(0, 0, math.rad(90))
			ring.Anchored = true
			ring.CanCollide = false
			ring.CanQuery = false
			ring.CanTouch = false
			ring.CastShadow = false
			ring.Material = Enum.Material.Neon
			ring.Color = color
			ring.Transparency = 0.35
			ring.Parent = bossFolder
			pcall(function()
				TweenService:Create(ring, TweenInfo.new(gap * 0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = Vector3.new(0.3, r * 2, r * 2),
					Transparency = 1,
				}):Play()
			end)
			Debris:AddItem(ring, gap + 0.4)
			-- 고리 판정
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr then
					local flat = Vector3.new(pr.Position.X - origin.X, 0, pr.Position.Z - origin.Z).Magnitude
					if flat > prevR and flat <= r then
						local damaged = PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 0.75) + 0.5))
						if damaged and cfg.Knockback then
							MonsterService.KnockbackPlayer(pl, origin, cfg.Knockback.Force or 26, cfg.Knockback.Lift or 8)
						end
					end
				end
			end
			prevR = r
			task.wait(gap)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-08-24 돌장군 전용] RockThrow / RockFall =====
-- 노션 "몬스터 외형 참고" — 돌 골렘: "바위를 던지고 지면을 내려쳐 난석을 떨어뜨린다" · 공격 에셋 Crystal01/Crystal02.
-- 둘 다 던지는 안으로 모델의 수정 파트를 복제해 쓴다(별도 에셋 불필요).

-- 모델에서 투사체용 수정 파트를 복제한다. 없으면 회색 바위 폴백.
function Ch2Pat.makeRockProp(rt, partName, size)
	local src
	for _, d in ipairs(rt.Model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == partName then
			src = d
			break
		end
	end
	local rock
	if src then
		rock = src:Clone()
		for _, c in ipairs(rock:GetChildren()) do
			if not (c:IsA("SurfaceAppearance") or c:IsA("Decal") or c:IsA("Texture")) then
				c:Destroy()
			end
		end
		local ms = math.max(rock.Size.X, rock.Size.Y, rock.Size.Z)
		if ms > 0.01 then
			rock.Size = rock.Size * (size / ms)
		end
	else
		rock = Instance.new("Part")
		rock.Material = Enum.Material.Slate
		rock.Color = Color3.fromRGB(120, 122, 130)
		rock.Size = Vector3.new(size, size, size)
	end
	rock.Name = "GolemRock"
	rock.Anchored = true
	rock.CanCollide = false
	rock.CanQuery = false
	rock.CanTouch = false
	rock.CastShadow = false
	rock.Transparency = 0
	rock.Parent = bossFolder
	return rock
end

-- RockThrow(주): 착탄 지점을 먼저 예고하고 수정 바위를 포물선으로 던진다.
-- 판정은 예고 원(투사체 접촉 아님) — 자리를 비키는 게 정답이 되게 한다.
function Ch2Pat.RockThrow(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.RockThrow
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local origin = root.Position
		local aim = targetRoot.Position
		local dir = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
		dir = dir.Magnitude > 0.5 and dir.Unit or root.CFrame.LookVector
		root.CFrame = CFrame.lookAt(origin, origin + dir)

		local windup = cfg.Windup or 1.1
		local flight = cfg.FlightSec or 0.7
		local radius = cfg.Radius or 8
		local color = cfg.Color or Color3.fromRGB(150, 200, 215)
		local gy = rollGroundY(rt, aim)
		local land = Vector3.new(aim.X, gy, aim.Z)
		makeTimedDisc(Vector3.new(land.X, gy + TELEGRAPH_Y_OFFSET, land.Z), radius, color, windup + flight)
		task.wait(windup)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end

		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		local from = origin + dir * (bodyRadius * 0.6) + Vector3.new(0, cfg.LaunchUp or 8, 0)
		local rock = Ch2Pat.makeRockProp(rt, cfg.PartName or "Crystal01", cfg.RockSize or 7)
		rock.CFrame = CFrame.new(from)
		local arc = cfg.ArcHeight or 14
		local t0 = os.clock()
		while true do
			local a = math.min((os.clock() - t0) / flight, 1)
			if rock.Parent then
				local p = from:Lerp(land + Vector3.new(0, 2, 0), a) + Vector3.new(0, math.sin(a * math.pi) * arc, 0)
				rock.CFrame = CFrame.new(p) * CFrame.Angles(a * 6, a * 4, 0)
			end
			if a >= 1 then
				break
			end
			task.wait()
		end
		if rock.Parent then
			Debris:AddItem(rock, 1.2)
			pcall(function()
				TweenService:Create(rock, TweenInfo.new(1.0), { Transparency = 1 }):Play()
			end)
		end
		for _, pl in ipairs(Players:GetPlayers()) do
			local pr, ph = alivePlayerParts(pl)
			if pr and withinFairRadius(pr.Position, land, radius) then
				local damaged = PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1.0) + 0.5))
				if damaged and cfg.Knockback then
					MonsterService.KnockbackPlayer(pl, land, cfg.Knockback.Force or 28, cfg.Knockback.Lift or 10)
				end
			end
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- RockFall(부): 지면을 내려치면 하늘에서 난석이 순차 낙하한다.
-- 지점을 한 번에 예고하고 순차 떨군다 — "예고 원을 이어 밟고 빠져나가는" 이동이 해법이 된다.
function Ch2Pat.RockFall(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.RockFall
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid:MoveTo(root.Position)
		local windup = cfg.Windup or 1.2
		-- [2026-09-07] 광폭화 시 난석 개수 가산(Def는 건드리지 않고 rt에서만 더한다).
		local n = (cfg.Count or 5) + (rt.GolemRockFallBonus or 0)
		local radius = cfg.Radius or 7
		local spread = cfg.Spread or 20
		local gap = cfg.Gap or 0.35
		local fall = cfg.FallSec or 0.4
		local color = cfg.Color or Color3.fromRGB(150, 200, 215)
		local center = targetRoot.Position
		local spots = {}
		for i = 1, n do
			local ang = math.random() * math.pi * 2
			local rad = (i == 1) and 0 or (spread * math.sqrt(math.random()))
			local p = center + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
			local gy = rollGroundY(rt, p)
			spots[i] = Vector3.new(p.X, gy, p.Z)
			makeTimedDisc(Vector3.new(p.X, gy + TELEGRAPH_Y_OFFSET, p.Z), radius, color, windup + gap * (i - 1) + fall)
		end
		task.wait(windup)
		for i, s in ipairs(spots) do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			task.spawn(function()
				local rock = Ch2Pat.makeRockProp(rt, cfg.PartName or "Crystal02_out", cfg.RockSize or 8)
				local top = s + Vector3.new(0, cfg.DropHeight or 34, 0)
				rock.CFrame = CFrame.new(top)
				local t0 = os.clock()
				while true do
					local a = math.min((os.clock() - t0) / fall, 1)
					if rock.Parent then
						rock.CFrame = CFrame.new(top:Lerp(s + Vector3.new(0, 1.5, 0), a * a))
					end
					if a >= 1 then
						break
					end
					task.wait()
				end
				for _, pl in ipairs(Players:GetPlayers()) do
					local pr, ph = alivePlayerParts(pl)
					if pr and withinFairRadius(pr.Position, s, radius) then
						PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 0.6) + 0.5))
					end
				end
				if rock.Parent then
					pcall(function()
						TweenService:Create(rock, TweenInfo.new(0.8), { Transparency = 1 }):Play()
					end)
					Debris:AddItem(rock, 0.9)
				end
			end)
			task.wait(gap)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== [2026-09-07 돌장군 전용] GroundQuake / updateGolemPhase =====
-- 노션 수치 명세 v1.3 ③ "지면 강타 — 광역 + 0.8초 기절". 종전에는 공용 LeapSlam으로 대체되어 명세 3패턴이 비어 있었다.
-- 양손을 들어올렸다 내려찍으면 정면으로 균열이 금가 나간다 — 선에서 옆으로 비키는 게 해법(도깨비왕 ClubShock과 같은 직선 규약).
-- 기절 = 기존 bindPlayer(WalkSpeed 0 + 속박 표시) 재사용 — 별도 스턴 시스템을 만들지 않는다.
function Ch2Pat.GroundQuake(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.GroundQuake
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg and targetRoot and targetRoot.Parent) then
			return
		end
		local windup = (cfg.Windup or 1.2) * (rt.PhaseCdMul or 1)
		local length = cfg.Length or 30
		local width = cfg.Width or 6
		local segs = math.clamp(math.floor(cfg.Segments or 6), 2, 12)
		local stepGap = cfg.StepGap or 0.06
		local color = cfg.Color or Color3.fromRGB(150, 200, 215)
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local base = root.Position
		local aim = (targetRoot.Position - base) * Vector3.new(1, 0, 1)
		local dir = aim.Magnitude > 0.05 and aim.Unit or (root.CFrame.LookVector * Vector3.new(1, 0, 1)).Unit
		root.CFrame = CFrame.lookAt(base, base + dir)
		-- 전조: 균열이 지나갈 자리를 원반 여러 개로 깔아 선을 보여준다(막대 박스 전조는 이 서비스에 없다)
		local spots = {}
		for i = 1, segs do
			local p = base + dir * (length * (i - 0.5) / segs)
			local gy = rollGroundY(rt, p)
			spots[i] = Vector3.new(p.X, gy, p.Z)
			makeTimedDisc(Vector3.new(p.X, gy + TELEGRAPH_Y_OFFSET, p.Z), width * 0.5, color, windup + stepGap * (i - 1) + 0.35)
		end
		Ch2Pat.WaitImpact(rt, "GroundQuake", "Effect", windup) -- 양손이 바닥에 닿는 순간
		local hit = {}
		local dmg = math.floor(DEF.Atk * (cfg.DamageMul or 0.8) + 0.5)
		local bindSec = cfg.StunSec or 0.8
		for i, s in ipairs(spots) do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			-- 균열 파편(연출) — 바닥에서 솔았다 가라앉는다
			task.spawn(function()
				local shard = Ch2Pat.makeRockProp(rt, cfg.PartName or "Crystal02_out", cfg.ShardSize or 5)
				if shard then
					shard.CFrame = CFrame.new(s + Vector3.new(0, -2, 0)) * CFrame.Angles(math.rad(math.random(-18, 18)), math.rad(math.random(0, 360)), math.rad(math.random(-18, 18)))
					pcall(function()
						TweenService:Create(shard, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = CFrame.new(s + Vector3.new(0, 1.6, 0)) * (shard.CFrame - shard.CFrame.Position) }):Play()
					end)
					task.delay(0.5, function()
						if shard.Parent then
							pcall(function()
								TweenService:Create(shard, TweenInfo.new(0.5), { Transparency = 1, CFrame = CFrame.new(s + Vector3.new(0, -2, 0)) * (shard.CFrame - shard.CFrame.Position) }):Play()
							end)
							Debris:AddItem(shard, 0.6)
						end
					end)
				end
			end)
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and ph and not hit[pl] and withinFairRadius(pr.Position, s, width * 0.5 + 1.5) then
					hit[pl] = true
					local damaged = PlayerDamageService.Apply(ph, dmg)
					if damaged and bindSec > 0 then
						bindPlayer(pl, bindSec) -- 기절: 이동·점프 정지 + 머리 위 상태 표시
					end
				end
			end
			task.wait(stepGap)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- 돌장군 광폭화: HP 임계 아래로 떨어지면 난석 개수·쿨을 한 번 강화한다(도깨비왕 updateKingPhase와 같은 구조).
-- ★Def 테이블을 직접 고치면 리스폰 후에도 남는다 — rt(런타임)에만 기록하고 디스패치에서 곱한다.
function Ch2Pat.updateGolemPhase(rt)
	local DEF = rt.Def
	local cfg = DEF and DEF.GolemPhase
	local hum = rt.Humanoid
	if not (cfg and hum and hum.Parent and hum.MaxHealth > 0) then
		return
	end
	if rt.GolemEnraged then
		return
	end
	if hum.Health / hum.MaxHealth > (cfg.HpPct or 0.4) then
		return
	end
	rt.GolemEnraged = true
	rt.PhaseCdMul = math.min(rt.PhaseCdMul or 1, cfg.CdMul or 0.8)
	rt.GolemRockFallBonus = cfg.RockFallBonus or 2
	-- 광폭화 안내(존 안 플레이어에게만) — 묘목 치유 안내와 같은 경로를 쓴다.
	pcall(function()
		for _, pl in ipairs(Players:GetPlayers()) do
			local pr = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
			if pr and isInZone(rt, pr.Position) then
				Net.Event("Notice"):FireClient(pl, { locKey = cfg.NoticeKey or "Notice.BossGolemEnrage" })
			end
		end
	end)
	-- 어깨 수정이 붉게 달아오른다(외형으로 페이즈를 알린다)
	pcall(function()
		for _, p in ipairs(rt.Model:GetDescendants()) do
			if p:IsA("BasePart") and p.Name:find("Crystal") then
				p.Color = cfg.CrystalColor or Color3.fromRGB(255, 120, 90)
				p.Material = Enum.Material.Neon
			end
		end
	end)
end

-- ===== [2026-08-24 도깨비왕 전용] ClubShock / WispSummon =====
-- 노션 "몬스터 외형 참고" — 도깨비 왕: "방망이 충격파, 도깨비불 소환, 분신 생성, 번개 공격을 사용한다".
-- 네 개 중 주/부 두 개만 먼저 세운다 — 분신·번개와 페이즈 강화는 별도 작업.

-- ClubShock(주): 방망이를 내리쳤 전방으로 길게 뻗는 충격파. 좌우로 비키는 게 해법.
function Ch2Pat.ClubShock(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.ClubShock
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local origin = root.Position
		local aim = targetRoot.Position
		local dir = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
		dir = dir.Magnitude > 0.5 and dir.Unit or root.CFrame.LookVector
		root.CFrame = CFrame.lookAt(origin, origin + dir)

		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		local windup = cfg.Windup or 1.1
		local steps = (cfg.Steps or 5) + ((rt.PhaseBonus and rt.PhaseBonus.Steps) or 0)
		local stepLen = cfg.StepLen or 9
		local halfWidth = cfg.HalfWidth or 7
		local gap = cfg.StepGap or 0.08
		local color = cfg.Color or Color3.fromRGB(255, 150, 90)
		-- 경로 예고: 몸 표면에서 시작해 직선으로 느러진다
		local marks = {}
		for i = 1, steps do
			local p = origin + dir * (bodyRadius + stepLen * (i - 0.5))
			local gy = rollGroundY(rt, p)
			marks[i] = Vector3.new(p.X, gy, p.Z)
			makeTimedDisc(Vector3.new(p.X, gy + TELEGRAPH_Y_OFFSET, p.Z), halfWidth, color, windup)
		end
		Ch2Pat.WaitImpact(rt, "ClubShock", "Effect", windup) -- 방망이가 바닥에 닿는 순간
		for i, m in ipairs(marks) do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			local burst = Instance.new("Part")
			burst.Name = "ClubShockBurst"
			burst.Shape = Enum.PartType.Cylinder
			burst.Size = Vector3.new(0.4, halfWidth, halfWidth)
			burst.CFrame = CFrame.new(m.X, m.Y + 0.25, m.Z) * CFrame.Angles(0, 0, math.rad(90))
			burst.Anchored = true
			burst.CanCollide = false
			burst.CanQuery = false
			burst.CanTouch = false
			burst.CastShadow = false
			burst.Material = Enum.Material.Neon
			burst.Color = color
			burst.Transparency = 0.25
			burst.Parent = bossFolder
			pcall(function()
				TweenService:Create(burst, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = Vector3.new(0.4, halfWidth * 2.2, halfWidth * 2.2),
					Transparency = 1,
				}):Play()
			end)
			Debris:AddItem(burst, 0.6)
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and withinFairRadius(pr.Position, m, halfWidth) then
					local damaged = PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 1.0) + 0.5))
					if damaged and cfg.Knockback then
						MonsterService.KnockbackPlayer(pl, origin, cfg.Knockback.Force or 34, cfg.Knockback.Lift or 10)
					end
				end
			end
			task.wait(gap)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- WispSummon(부): 도깨비불을 불러 플레이어를 느리게 쪼아가게 한다. 수명이 다하거나 닿으면 터진다.
-- ★몹 스폰이 아니라 순수 파트라 보상·어그로가 없다 — 무한 파밍 이득이 생기지 않는다.
function Ch2Pat.WispSummon(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.WispSummon
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid:MoveTo(root.Position)
		local windup = cfg.Windup or 1.0
		local n = (cfg.Count or 3) + ((rt.PhaseBonus and rt.PhaseBonus.Wisps) or 0)
		local life = cfg.LifeSec or 6
		local speed = cfg.Speed or 11
		local radius = cfg.Radius or 5
		local color = cfg.Color or Color3.fromRGB(90, 170, 255)
		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		local origin = root.Position
		local aimPos = targetRoot.Position
		local gy = rollGroundY(rt, origin)
		makeTimedDisc(Vector3.new(origin.X, gy + TELEGRAPH_Y_OFFSET, origin.Z), bodyRadius + 6, color, windup)
		Ch2Pat.WaitImpact(rt, "WispSummon", "Effect", windup) -- 빛나는 순간 = 소환 시작
		for i = 1, n do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			-- ★타겟 쪽으로 부채꼴 소환. 전방위 균등 배치로 둔 데에는 반대편 구슬이 몸집(반경 55)을
			-- 돌아오다 수명이 먼저 끝난다(실측 12발 중 1발만 명중).
			local toT = Vector3.new(aimPos.X - origin.X, 0, aimPos.Z - origin.Z)
			local baseAng = (toT.Magnitude > 0.5) and math.atan2(toT.Z, toT.X) or 0
			local fan = math.rad(cfg.SpawnSpreadDeg or 70)
			local ang = baseAng + ((n == 1) and 0 or (-fan / 2 + fan * ((i - 1) / (n - 1))))
			local spawnPos = origin + Vector3.new(math.cos(ang) * (bodyRadius + 4), cfg.SpawnUp or 6, math.sin(ang) * (bodyRadius + 4))
			task.spawn(function()
				local orb = Instance.new("Part")
				orb.Name = "KingWisp"
				orb.Shape = Enum.PartType.Ball
				orb.Size = Vector3.new(3, 3, 3)
				orb.Color = color
				orb.Material = Enum.Material.Neon
				orb.Anchored = true
				orb.CanCollide = false
				orb.CanQuery = false
				orb.CanTouch = false
				orb.CastShadow = false
				orb.CFrame = CFrame.new(spawnPos)
				local lt = Instance.new("PointLight")
				lt.Color = color
				lt.Range = 14
				lt.Brightness = 2
				lt.Parent = orb
				orb.Parent = bossFolder
				local endAt = os.clock() + life
				local hit = false
				while os.clock() < endAt and orb.Parent do
					-- ★rt에는 TargetRoot 필드가 없다(오기) — 패턴에 넘어온 targetRoot를 그대로 쓴다.
					-- 이걸 틀렸더니 구슬이 제자리에서 수명만 다해 피해 0회였다(실측 9개 생성/0피해).
					local tr = targetRoot
					if tr and tr.Parent then
						local to = tr.Position - orb.Position
						if to.Magnitude <= radius then
							hit = true
							break
						end
						orb.CFrame = CFrame.new(orb.Position + to.Unit * speed * 0.03)
					end
					task.wait(0.03)
				end
				if orb.Parent then
					local at = orb.Position
					for _, pl in ipairs(Players:GetPlayers()) do
						local pr, ph = alivePlayerParts(pl)
						if pr and (pr.Position - at).Magnitude <= radius + 2 then
							PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 0.55) + 0.5))
						end
					end
					pcall(function()
						TweenService:Create(orb, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
							Size = Vector3.new(radius * 2, radius * 2, radius * 2),
							Transparency = 1,
						}):Play()
					end)
					Debris:AddItem(orb, 0.5)
				end
			end)
			task.wait(cfg.SpawnGap or 0.12)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- 페이즈 강화(왕): 체력이 임계 아래로 내려가면 한 번씩 각성한다.
-- ★DEF는 MonsterDefs의 **공유 테이블**이라 절대 변형하지 않는다(리스폰·다른 인스턴스에 영구 오염).
--   강화치는 rt(런타임 인스턴스)에만 얹고, 패턴은 rt.PhaseBonus를 더해 읽는다.
-- 리스폰 시에는 체력이 차서 want=1로 돌아오므로 자동 초기화된다(연출은 상승할 때만).
function Ch2Pat.updateKingPhase(rt)
	local DEF = rt.Def
	local list = DEF.PhaseEscalate
	if not (list and rt.Humanoid and rt.Humanoid.Parent and rt.Root and rt.Root.Parent) then
		return
	end
	local ratio = rt.Humanoid.Health / math.max(1, rt.Humanoid.MaxHealth)
	local want = 1
	for i, ph in ipairs(list) do
		if ratio <= (ph.Hp or 0) then
			want = i + 1
		end
	end
	local prev = rt.KingPhase or 1
	if want == prev then
		return
	end
	rt.KingPhase = want
	local ph = list[want - 1]
	rt.PhaseCdMul = (ph and ph.CooldownMul) or 1
	rt.PhaseBonus = ph and ph.Bonus or nil
	if want < prev then
		return -- 리스폰 등으로 내려갈 때는 연출 생략
	end
	pcall(function()
		rt.Model:SetAttribute("KingPhase", want)
		local root = rt.Root
		local gy = rollGroundY(rt, root.Position)
		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 20
		local color = (ph and ph.Color) or Color3.fromRGB(255, 120, 90)
		-- 각성 연출: 바닥을 훑는 큰 링
		local ring = Instance.new("Part")
		ring.Name = "KingPhaseRing"
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(0.6, bodyRadius * 0.6, bodyRadius * 0.6)
		ring.CFrame = CFrame.new(root.Position.X, gy + 0.4, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.CastShadow = false
		ring.Material = Enum.Material.Neon
		ring.Color = color
		ring.Transparency = 0.15
		ring.Parent = bossFolder
		TweenService:Create(ring, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.6, bodyRadius * 4, bodyRadius * 4),
			Transparency = 1,
		}):Play()
		Debris:AddItem(ring, 1.0)

		-- 몸집 확대: 본체 메시만 키우고 Motor6D C0를 올려 발끝을 지면에 유지한다.
		-- 리그를 건드리지 않으므로 안전하고, 커진 만큼 HitRadius를 다시 재산한다
		-- (안 하면 사거리 판정이 예전 몸집 기준으로 남아 패턴이 오발한다).
		local grow = ph and ph.Grow
		if grow and grow ~= 1 then
			local mesh, joint
			for _, d in ipairs(rt.Model:GetDescendants()) do
				if d:IsA("BasePart") and d ~= root then
					mesh = d
					break
				end
			end
			for _, d in ipairs(rt.Model:GetDescendants()) do
				if d:IsA("Motor6D") and d.Part1 == mesh then
					joint = d
					break
				end
			end
			if mesh and joint then
				local beforeY = mesh.Size.Y
				mesh.Size = mesh.Size * grow
				joint.C0 = CFrame.new(0, (mesh.Size.Y - beforeY) / 2, 0) * joint.C0
				local ext = rt.Model:GetExtentsSize()
				rt.Model:SetAttribute("HitRadius", math.max(2, (ext.X + ext.Z) / 4))
			end
		end
	end)
end

-- PhantomClone(왕): 좌우에 반투명 분신 2기를 세우고, 본체 포함 **세 곳에서 동시에** 직선 충격파를 친다.
-- 세 줄이 서로 다른 지점에서 나오므로 제자리에 있으면 거의 맞고, 측면으로 빠지면 틈이 생긴다.
-- ★분신은 모델 통째 복제가 아니라 **본체 메시 파트만** 복제한다(makeRockProp 재사용) —
--   모델을 통째로 복제하면 Humanoid·태그·어트리뷰트가 딴려가 타겟팅·체력바 시스템이 오인한다.
function Ch2Pat.PhantomClone(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.PhantomClone
	local phantoms = {}
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid.AutoRotate = false
		humanoid:MoveTo(root.Position)
		local origin = root.Position
		local aim = targetRoot.Position
		local dir = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
		dir = dir.Magnitude > 0.5 and dir.Unit or root.CFrame.LookVector
		root.CFrame = CFrame.lookAt(origin, origin + dir)

		local bodyRadius = tonumber(rt.Model:GetAttribute("HitRadius")) or 0
		local windup = cfg.Windup or 1.2
		local steps = (cfg.Steps or 4) + ((rt.PhaseBonus and rt.PhaseBonus.Steps) or 0)
		local stepLen = cfg.StepLen or 9
		local halfWidth = cfg.HalfWidth or 6
		local color = cfg.Color or Color3.fromRGB(160, 120, 255)
		local sideAng = math.rad(cfg.SideDeg or 55)
		local sideGap = cfg.SideGap or 10
		local baseAng = math.atan2(dir.Z, dir.X)

		-- 발사점: 본체 1 + 분신 2
		local shooters = { { pos = origin, phantom = false } }
		for _, sgn in ipairs({ -1, 1 }) do
			local a = baseAng + sgn * sideAng
			local p = origin + Vector3.new(math.cos(a) * (bodyRadius + sideGap), 0, math.sin(a) * (bodyRadius + sideGap))
			shooters[#shooters + 1] = { pos = Vector3.new(p.X, origin.Y, p.Z), phantom = true }
		end

		-- 분신 비주얼
		for _, sh in ipairs(shooters) do
			if sh.phantom then
				local ph = Ch2Pat.makeRockProp(rt, cfg.PartName or "BossDokkaebo_m", cfg.PhantomSize or 60)
				ph.Name = "KingPhantom"
				ph.Transparency = cfg.Alpha or 0.55
				local gy = rollGroundY(rt, sh.pos)
				ph.CFrame = CFrame.lookAt(Vector3.new(sh.pos.X, gy + ph.Size.Y / 2, sh.pos.Z),
					Vector3.new(sh.pos.X, gy + ph.Size.Y / 2, sh.pos.Z) + dir)
				phantoms[#phantoms + 1] = ph
			end
		end

		-- 세 줄 예고
		local lines = {}
		for si, sh in ipairs(shooters) do
			local start = sh.phantom and 4 or bodyRadius
			local marks = {}
			for i = 1, steps do
				local p = sh.pos + dir * (start + stepLen * (i - 0.5))
				local gy = rollGroundY(rt, p)
				marks[i] = Vector3.new(p.X, gy, p.Z)
				makeTimedDisc(Vector3.new(p.X, gy + TELEGRAPH_Y_OFFSET, p.Z), halfWidth, color, windup)
			end
			lines[si] = marks
		end
		-- Clone(분신 페이드인)은 Effect 뒤에 오므로, 세 줄 발사는 Clone 기준으로 맞춘다.
		Ch2Pat.WaitImpact(rt, "PhantomClone", "Clone", windup)
		if not (rt.Model.Parent and humanoid.Health > 0) then
			return
		end

		-- 동시 발사(중복 타격 방지: 플레이어당 1회)
		local hitOnce = {}
		for _, marks in ipairs(lines) do
			for _, m in ipairs(marks) do
				local burst = Instance.new("Part")
				burst.Name = "PhantomShockBurst"
				burst.Shape = Enum.PartType.Cylinder
				burst.Size = Vector3.new(0.4, halfWidth, halfWidth)
				burst.CFrame = CFrame.new(m.X, m.Y + 0.25, m.Z) * CFrame.Angles(0, 0, math.rad(90))
				burst.Anchored = true
				burst.CanCollide = false
				burst.CanQuery = false
				burst.CanTouch = false
				burst.CastShadow = false
				burst.Material = Enum.Material.Neon
				burst.Color = color
				burst.Transparency = 0.25
				burst.Parent = bossFolder
				pcall(function()
					TweenService:Create(burst, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Size = Vector3.new(0.4, halfWidth * 2.2, halfWidth * 2.2),
						Transparency = 1,
					}):Play()
				end)
				Debris:AddItem(burst, 0.5)
				for _, pl in ipairs(Players:GetPlayers()) do
					local pr, ph2 = alivePlayerParts(pl)
					if pr and not hitOnce[pl] and withinFairRadius(pr.Position, m, halfWidth) then
						hitOnce[pl] = true
						local damaged = PlayerDamageService.Apply(ph2, math.floor(DEF.Atk * (cfg.DamageMul or 0.9) + 0.5))
						if damaged and cfg.Knockback then
							MonsterService.KnockbackPlayer(pl, origin, cfg.Knockback.Force or 30, cfg.Knockback.Lift or 9)
						end
					end
				end
			end
		end
		task.wait(cfg.LingerSec or 0.5)
	end)
	for _, ph in ipairs(phantoms) do
		if ph.Parent then
			pcall(function()
				TweenService:Create(ph, TweenInfo.new(0.4), { Transparency = 1 }):Play()
			end)
			Debris:AddItem(ph, 0.5)
		end
	end
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- LightningStrike(왕): 플레이어 자리에 번개가 연속으로 내리친다.
-- 매 회차마다 **그 순간의 플레이어 위치**를 잡아 예고하므로, 멈췄 때만 맞는다 — 계속 움직이게 만드는 압박기.
function Ch2Pat.LightningStrike(rt, targetRoot)
	local DEF = rt.Def
	local humanoid, root = rt.Humanoid, rt.Root
	local cfg = DEF.LightningStrike
	pcall(function()
		if not (rt.Model and rt.Model.Parent and root and humanoid and humanoid.Health > 0 and cfg) then
			return
		end
		humanoid:MoveTo(root.Position)
		local bolts = (cfg.Bolts or 4) + ((rt.PhaseBonus and rt.PhaseBonus.Bolts) or 0)
		local windup = cfg.Windup or 0.85
		local gap = cfg.Gap or 0.45
		local radius = cfg.Radius or 7
		local color = cfg.Color or Color3.fromRGB(255, 240, 140)
		for i = 1, bolts do
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			-- ★매 회차 재조준: targetRoot가 사라졌으면 중단(사망·리스폰)
			if not (targetRoot and targetRoot.Parent) then
				break
			end
			local spot = targetRoot.Position
			local gy = rollGroundY(rt, spot)
			local at = Vector3.new(spot.X, gy, spot.Z)
			makeTimedDisc(Vector3.new(at.X, gy + TELEGRAPH_Y_OFFSET, at.Z), radius, color, windup)
			-- 첫 발만 마커에 맞춘다(애니의 Effect는 1회) — 이후 발은 종전 Gap 간격 유지.
			if i == 1 then
				Ch2Pat.WaitImpact(rt, "LightningStrike", "Effect", windup)
			else
				task.wait(windup)
			end
			if not (rt.Model.Parent and humanoid.Health > 0) then
				break
			end
			-- 낙뢰 기둥
			local bolt = Instance.new("Part")
			bolt.Name = "KingLightning"
			bolt.Size = Vector3.new(radius * 0.5, cfg.BoltHeight or 80, radius * 0.5)
			bolt.CFrame = CFrame.new(at.X, gy + (cfg.BoltHeight or 80) / 2, at.Z)
			bolt.Anchored = true
			bolt.CanCollide = false
			bolt.CanQuery = false
			bolt.CanTouch = false
			bolt.CastShadow = false
			bolt.Material = Enum.Material.Neon
			bolt.Color = color
			bolt.Transparency = 0.1
			local lt = Instance.new("PointLight")
			lt.Color = color
			lt.Range = 30
			lt.Brightness = 4
			lt.Parent = bolt
			bolt.Parent = bossFolder
			pcall(function()
				TweenService:Create(bolt, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = Vector3.new(radius * 1.6, cfg.BoltHeight or 80, radius * 1.6),
					Transparency = 1,
				}):Play()
			end)
			Debris:AddItem(bolt, 0.4)
			for _, pl in ipairs(Players:GetPlayers()) do
				local pr, ph = alivePlayerParts(pl)
				if pr and withinFairRadius(pr.Position, at, radius) then
					PlayerDamageService.Apply(ph, math.floor(DEF.Atk * (cfg.DamageMul or 0.7) + 0.5))
				end
			end
			task.wait(gap)
		end
	end)
	if rt.Humanoid and rt.Humanoid.Parent then
		rt.Humanoid.AutoRotate = true
	end
	rt.NextCycleAt = os.clock() + rt.Def.AtkInterval
	rt.PatternBusy = false
end

-- ===== 재소환 카운트다운 (원본 보존) =====

local function clearCountdown(rt)
	if rt.CountdownPart then
		rt.CountdownPart:Destroy()
		rt.CountdownPart = nil
		rt.CountdownLabel = nil
	end
	rt.LastCountdownShown = nil
end

local function createCountdown(rt)
	clearCountdown(rt)
	local part = Instance.new("Part")
	part.Name = "BossCountdownAnchor"
	part.Size = Vector3.new(1, 1, 1)
	part.Position = rt.Marker.Position + Vector3.new(0, COUNTDOWN_HEIGHT_STUDS, 0)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	local gui = Instance.new("BillboardGui")
	gui.Name = "BossCountdown"
	gui.Size = COUNTDOWN_GUI_SIZE
	gui.AlwaysOnTop = true
	gui.MaxDistance = rt.Def.ZoneRadius * 2
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.Name = "Remaining"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = COUNTDOWN_TEXT_COLOR
	label.TextStrokeTransparency = 0.4
	label.Text = ""
	label.Parent = gui
	part.Parent = bossFolder
	rt.CountdownPart = part
	rt.CountdownLabel = label
end

local function updateCountdown(rt, now)
	if not rt.CountdownLabel then
		return
	end
	local remaining = math.max(math.ceil(rt.RespawnAt - now), 0)
	if remaining ~= rt.LastCountdownShown then
		rt.LastCountdownShown = remaining
		rt.CountdownLabel.Text = Strings.get("BossRespawn_Fmt"):format(remaining)
	end
end

local function beginRespawn(rt)
	if rt.DeathHandled then
		return
	end
	rt.DeathHandled = true
	rt.SplitActive = false
	destroyBrickMinions(rt)
	clearTelegraph(rt)
	rt.IdleSince = nil
	rt.RespawnAt = os.clock() + rt.Def.RespawnSec
	createCountdown(rt)
	local corpse = rt.Model
	if corpse then
		modelToRt[corpse] = nil
	end
	if rt.PatternMarkerStates then
		for _, markerState in pairs(rt.PatternMarkerStates) do
			markerState.CancelledGeneration = markerState.Generation
		end
	end
	stopBossAnims(rt, nil)
	rt.Model, rt.Humanoid, rt.Root = nil, nil, nil
	if corpse then
		-- Dead 애니 보유(짚찌왕/머드킹/늑대)는 앵커를 1.2s 늦춰 쓰러짐 애니 여유를 주고, 미보유(당근대장/나무장군/벽돌대왕)는 절차 전복(80° 옆으로)으로 대체
		local animDef = AVDefs.MonsterAnims[rt.Id]
		local hasDeadAnim = animDef ~= nil and animDef.Dead ~= nil and animDef.Dead ~= ""
		task.delay(hasDeadAnim and 1.2 or 0.5, function()
			if not corpse.Parent then
				return
			end
			for _, part in ipairs(corpse:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.Anchored = true
				end
			end
			if not hasDeadAnim then
				-- 절차 전복: 발밑 우측 모서리를 축으로 회전(전 파트 앱커 상태 — PivotTo 스텝, 사체만)
				task.spawn(function()
					local baseCf = corpse:GetPivot()
					local ext = corpse:GetExtentsSize()
					local dur = 0.7
					local t0 = os.clock()
					while corpse.Parent do
						local a = math.min((os.clock() - t0) / dur, 1)
						local ang = math.rad(80) * a * a -- 가속 낙하감
						corpse:PivotTo(baseCf * CFrame.new(ext.X * 0.5, -ext.Y * 0.5, 0)
							* CFrame.Angles(0, 0, -ang) * CFrame.new(-ext.X * 0.5, ext.Y * 0.5, 0))
						if a >= 1 then
							break
						end
						task.wait()
					end
				end)
			end
		end)
		task.delay(GameConfig.BOSS.CorpseSec, function()
			if not corpse.Parent then
				return
			end
			-- [QA 2026-07-15 보스 페이드] 팝 소멸 → 1.2s 투명도 페이드 후 제거
			local FADE = 1.2
			local ti = TweenInfo.new(FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			for _, d in ipairs(corpse:GetDescendants()) do
				if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
					pcall(function()
						TweenService:Create(d, ti, { Transparency = 1 }):Play()
					end)
				elseif d:IsA("ParticleEmitter") then
					d.Enabled = false
				elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") then
					d.Enabled = false
				end
			end
			task.delay(FADE + 0.15, function()
				if corpse.Parent then
					corpse:Destroy()
				end
			end)
		end)
	end
end

-- ===== 스폰 (원본 보존 — DEF/마커만 rt 기준) =====

-- [2026-07-20] 스킨드 메시 보스(Humanoid 없음, 예: WolfBoss_m) 자동 래핑: HRP+Humanoid 추가·메시 용접.
-- 프레임워크가 Humanoid 전제라, 메시만 있는 모델은 이 래퍼로 초기화해 체력바/드래그/이동을 재사용.
local function ensureBossRig(model)
	if model:FindFirstChildOfClass("Humanoid") then
		return
	end
	local mesh = model.PrimaryPart or model:FindFirstChildWhichIsA("MeshPart")
	if not mesh then
		return
	end
	local ext = model:GetExtentsSize()
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(math.max(ext.X * 0.3, 2), math.max(ext.Y * 0.5, 2), math.max(ext.Z * 0.3, 2))
	hrp.Transparency = 1
	hrp.CanCollide = false
	hrp.CFrame = mesh.CFrame -- 메시 중심에 정렬(모델 pivot이 발끕이라 어긋나는 것 방지)
	hrp.Parent = model
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hrp
	weld.Part1 = mesh
	weld.Parent = hrp
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d ~= hrp then
			d.CanCollide = false
		end
	end
	local hum = Instance.new("Humanoid")
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- 접지: Humanoid는 루트 하단을 지면에 세움 — 메시(HRP 중심 정렬, 전고 ext.Y)가 HRP보다 길어
	-- 하반신이 묻히므로 그 차이의 절반만큼 HipHeight로 들어올림(음수 금지 규약).
	hum.HipHeight = math.max((ext.Y - hrp.Size.Y) * 0.5, 0)
	model:SetAttribute("RigHipHeight", hum.HipHeight) -- 스폰 쪽 HipOffset 덮어쓰기에서 복원용
	hum.Parent = model
	model.PrimaryPart = hrp
end

local SPAWN_RETRY_SEC = 5

local function spawnBoss(rt)
	if rt.Id == "Wolf" and rt.DifficultyEndsAt and os.clock() >= rt.DifficultyEndsAt then
		rt.DifficultyEndsAt = nil
		rt.DifficultyRaisedByUserId = nil
		rt.DifficultyRaisedByName = nil
		rt.PendingDifficultyId = WolfDifficultyDefs.Default
		rt.DifficultyId = WolfDifficultyDefs.Default
		rt.WolfDifficultyRespawnQueued = nil
	end
	if rt.Id == "Wolf" and rt.SourceDef then
		local selected = WolfDifficultyDefs.IsValid(rt.PendingDifficultyId) and rt.PendingDifficultyId or WolfDifficultyDefs.Default
		rt.DifficultyId = selected
		rt.BaseDef = WolfDifficultyDefs.Compose(rt.SourceDef, selected)
		rt.Def = rt.BaseDef -- 이번 생애의 난이도 Def를 동결
	else
		rt.BaseDef = rt.SourceDef or rt.BaseDef
		if rt.BaseDef then rt.Def = rt.BaseDef end
	end
	rt.SplitActive = false
	destroyBrickMinions(rt) -- [2026-07-22] 전생 분리 프록시 잔재 정리
	rt.BrickBaseHitRadius = nil
	if rt.BrickWeldConn then
		rt.BrickWeldConn:Disconnect()
		rt.BrickWeldConn = nil
	end
	local DEF = rt.Def
	clearTelegraph(rt)
	clearCountdown(rt)
	rt.RespawnAt = nil
	rt.DeathHandled = false
	rt.IdleSince = nil
	rt.NextCycleAt = 0
	rt.Engaged = false -- 무장은 교전 개시 시점에(스폰 시 걸면 대기 중 쿨이 다 찬다)
	rt.AttemptSent = {}
	rt.PatternBusy = false
	rt.PatternBusySince = nil -- [2026-08-08] 전 생애 잔존 스테일 타이머 오염 방지
	rt.OutZoneSince = nil
	rt.StuckPos = nil
	rt.StuckCheckAt = nil
	rt.NextRollAt = 0
	rt.NextLeapAt = 0
	rt.NextFleeAt = 0
	rt.NextChargeAt = 0
	rt.NextWhirlAt = 0 -- [2026-07-10] 회오리 쿼다운
	rt.AttackTrack = nil -- [2026-07-10] 구 모델 공격 트랙 무효화(재소환 시 재로드)
	rt.PatternTracks = nil -- [2026-07-29] 패턴 트랙도 동일(구 모델 Animator에 묶인 트랙 재사용 방지)
	rt.PatternMarkerStates = nil -- 새 모델 트랙의 Swing/Hit/Reset 세대 상태로 재생성
	rt.WolfPhase = 1 -- [2026-07-10] 늑대 페이즈 리셋
	rt.WolfTracks = nil -- 페이즈 공격 트랙 재로드
	rt.WolfFrenzy = false -- [2026-07-21] 광폭화 리셋(버프 Def는 상단 BaseDef 원복이 담당)
	rt.NextHowlAt = 0
	rt.NextFrenzyDashAt = 0
	rt.NextClawAt = 0
	rt.NextWolfActionAt = 0
	rt.NextComboAt = 0
	rt.NextFlankAt = 0
	rt.NextSkyHuntAt = 0
	rt.NextBloodHuntAt = 0
	rt.WolfFlankSide = -1
	rt.NextBindAt = 0
	rt.NextThrowAt = 0
	rt.NextFireAt = 0
	rt.NextFloodAt = 0
	rt.NextGeyserAt = 0
	rt.NextSmashAt = 0
	rt.NextMudChargeAt = 0 -- [2026-07-31] 진흙 추격 돌진
	rt.NextWhipAt = 0
	rt.NextRootFieldAt = 0
	rt.NextSaplingAt = 0
	rt.NextSporeAt = 0
	rt.NextBabyAt = 0
	rt.NextScoldAt = 0
	rt.NextSweepAt = 0
	rt.NextBarrageAt = 0
	rt.NextQuakeAt = 0
	rt.BrickStandY = nil -- 재소환 시 접지 기준 초기화(합체 시 재측정)
	rt.NextBrickWallsAt = 0
	rt.NextBrickChargeAt = 0
	rt.NextBrickRainAt = 0

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local monsters = assets and assets:FindFirstChild("Monsters")
	local template = monsters and monsters:FindFirstChild(DEF.ModelName)
	if not template then
		local bm = ReplicatedStorage:FindFirstChild("BossMonster") -- [2026-07-20] WolfBoss_m 등 별도 폴더 폴백
		template = bm and bm:FindFirstChild(DEF.ModelName)
	end
	if not template then
		local reason = ("모델 없음: %s"):format(tostring(DEF.ModelName))
		warn("[FieldBossService] " .. reason)
		return false, reason
	end
	local clone = template:Clone()
	if DEF.PersistentStreaming then
		-- 필드 보스가 원거리 포탈 직후 껍데기만 복제되고 외형 파츠가 늦게 스트리밍되는 현상 차단.
		clone.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end
	ensureBossRig(clone) -- [2026-07-20] 스킨드 메시 보스 자동 래핑(Humanoid 없으면 HRP+Humanoid 추가)
	local cloneRoot = clone.PrimaryPart or clone:FindFirstChild("HumanoidRootPart")
	local cloneHum = clone:FindFirstChildOfClass("Humanoid")
	if not cloneRoot or not cloneHum then
		local reason = ("루트/휴머노이드 없음: %s"):format(DEF.ModelName)
		warn("[FieldBossService] " .. reason)
		clone:Destroy()
		return false, reason
	end
	if DEF.ModelScale ~= 1 then
		clone:ScaleTo(DEF.ModelScale)
	end
	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CollisionGroup = BOSS_COLLISION_GROUP
		end
	end
	cloneHum.MaxHealth = DEF.Hp
	cloneHum.Health = DEF.Hp
	cloneHum.WalkSpeed = DEF.WalkSpeed
	-- [2026-07-10] 보스는 HipOffset을 아예 적용하지 않아 전부 hip=0이었다(MonsterService와 규약 일치)
	cloneHum.HipHeight = DEF.HipOffset or clone:GetAttribute("RigHipHeight") or 0 -- 래핑 리그(WolfBoss_m)는 계산값 유지
	-- [2026-07-10] MeshPart 루트의 쿡된 충돌 헐이 크기박스 밖으로 돌출 → 공중 부양(당근 대장)
	if DEF.RootNoCollide then
		cloneRoot.CanCollide = false
	end
	cloneHum.RequiresNeck = false
	cloneHum.BreakJointsOnDeath = false
	for _, state in ipairs(DISABLED_STATES) do
		cloneHum:SetStateEnabled(state, false)
	end
	local extents = clone:GetExtentsSize()
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = { bossFolder, rt.Marker }
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
	local groundHit = Workspace:Raycast(rt.Marker.Position + Vector3.new(0, 2, 0), Vector3.new(0, -300, 0), rayParams)
	local baseY = groundHit and groundHit.Position.Y or rt.Marker.Position.Y
	rt.SpawnPos = Vector3.new(rt.Marker.Position.X, baseY + extents.Y / 2 + AI.SpawnHeightPad, rt.Marker.Position.Z)
	-- 대기 방향 = 스폰 마커의 LookVector(수평 성분) — 마커를 돌리면 대기 방향이 바뀐다(조정 지점 단일)
	local markerLook = rt.Marker.CFrame.LookVector * Vector3.new(1, 0, 1)
	rt.IdleLook = markerLook.Magnitude > 0.05 and markerLook.Unit or Vector3.new(0, 0, -1)
	clone:PivotTo(CFrame.lookAt(rt.SpawnPos, rt.SpawnPos + rt.IdleLook))
	rt.AttemptSerial = (rt.AttemptSerial or 0) + 1
	clone:SetAttribute("MonsterId", rt.Id)
	clone:SetAttribute("RewardShareMin", (GameConfig.HUNT and GameConfig.HUNT.BossShareMin) or (GameConfig.BOSS and GameConfig.BOSS.RewardShareMin))
	clone:SetAttribute("ExpReward", DEF.Exp)
	clone:SetAttribute("CoinRewardMul", DEF.CoinRewardMul or 1)
	clone:SetAttribute("Defense", DEF.Def or 0)
	clone:SetAttribute("BossDifficulty", rt.DifficultyId or WolfDifficultyDefs.Default)
	clone:SetAttribute("BossAttemptId", rt.AttemptSerial)
	if rt.Id == "Wolf" then clone:SetAttribute("WolfLocomotionMode", "Stop") end
	clone:SetAttribute("HitRadius", math.max(WeaponDefs.HIT_RADIUS_MIN, (extents.X + extents.Z) / 4))
	CollectionService:AddTag(clone, MONSTER_TAG)
	clone.Parent = bossFolder
	pcall(function()
		cloneRoot:SetNetworkOwner(nil)
	end)
	rt.Model, rt.Humanoid, rt.Root = clone, cloneHum, cloneRoot
	modelToRt[clone] = rt
	-- [QA 2026-07-15] 분리 페이즈 진입(벽돌대왕 등 MergePhase 보유 보스) — 물리 안정화 후 산개
	if DEF.MergePhase then
		task.delay(0.2, function()
			if rt.Model == clone and clone.Parent then
				enterBrickSplit(rt)
			end
		end)
	end
	clone.Destroying:Connect(function()
		if rt.Model == clone then
			beginRespawn(rt)
		end
	end)
	return true
end

local function scheduleSpawnRetry(rt, reason)
	if rt.RespawnAt or rt.Spawning then
		return
	end
	-- 잘못 남은 런타임 참조가 있으면 Destroying 콜백이 60초 사망 쿨을 다시 걸지 않도록 먼저 분리한다.
	local stale = rt.Model
	if stale then
		modelToRt[stale] = nil
	end
	rt.Model, rt.Humanoid, rt.Root = nil, nil, nil
	if stale and stale.Parent then
		pcall(function()
			stale:Destroy()
		end)
	end
	rt.RespawnAt = os.clock() + SPAWN_RETRY_SEC
	local countdownOk, countdownErr = pcall(createCountdown, rt)
	if not countdownOk then
		warn("[FieldBossService] 스폰 재시도 카운트다운 생성 실패 | " .. tostring(countdownErr))
	end
	warn(("[FieldBossService] 보스 스폰 재시도 예약(%ds) | %s | %s")
		:format(SPAWN_RETRY_SEC, tostring(rt.Id), tostring(reason or "unknown")))
end

-- 늑대 각성 난이도의 서버 단일 상태 전이. 세이브에는 저장하지 않고 현재 서버 생애에만 유지한다.
function FieldBossService._setWolfDifficultyRuntime(rt, difficultyId, expiresAt, raisedBy, reason)
	difficultyId = WolfDifficultyDefs.IsValid(difficultyId) and difficultyId or WolfDifficultyDefs.Default
	rt.PendingDifficultyId = difficultyId
	rt.DifficultyId = difficultyId
	rt.DifficultyEndsAt = difficultyId ~= WolfDifficultyDefs.Default and expiresAt or nil
	rt.DifficultyRaisedByUserId = raisedBy and raisedBy.UserId or nil
	rt.DifficultyRaisedByName = raisedBy and raisedBy.DisplayName or nil
	rt.DifficultyGeneration = (rt.DifficultyGeneration or 0) + 1
	rt.DifficultyResetReason = reason
	if difficultyId == WolfDifficultyDefs.Default then
		rt.WolfDifficultyRespawnQueued = nil
	end
	rt.BaseDef = WolfDifficultyDefs.Compose(rt.SourceDef, difficultyId)
	rt.Def = rt.BaseDef
end

-- 보상/사망 경로를 타지 않는 무보상 즉시 재소환. 진행 중 패턴과 기여 원장까지 완전히 새 시도로 교체한다.
function FieldBossService._resetWolfAttemptNow(rt, difficultyId, expiresAt, raisedBy, reason)
	if rt.Spawning or rt.DifficultyMutationBusy then
		return false, "busy"
	end
	rt.DifficultyMutationBusy = true
	rt.WolfDifficultyRespawnQueued = nil
	FieldBossService._setWolfDifficultyRuntime(rt, difficultyId, expiresAt, raisedBy, reason)
	local oldModel = rt.Model
	if oldModel then
		pcall(function() CombatService.ClearDamageLog(oldModel) end)
		modelToRt[oldModel] = nil
	end
	if rt.PatternMarkerStates then
		for _, markerState in pairs(rt.PatternMarkerStates) do
			markerState.CancelledGeneration = markerState.Generation
		end
	end
	stopBossAnims(rt, nil)
	clearTelegraph(rt)
	clearCountdown(rt)
	destroyBrickMinions(rt)
	rt.RespawnAt = nil
	rt.DeathHandled = false
	rt.Model, rt.Humanoid, rt.Root = nil, nil, nil
	if oldModel and oldModel.Parent then
		pcall(function() oldModel:Destroy() end)
	end
	rt.Spawning = true
	local ok, spawned, spawnReason = pcall(spawnBoss, rt)
	rt.Spawning = false
	rt.DifficultyMutationBusy = false
	if not ok then
		scheduleSpawnRetry(rt, spawned)
		return true, "retry"
	elseif spawned ~= true then
		scheduleSpawnRetry(rt, spawnReason)
		return true, "retry"
	end
	return true
end

-- 스폰 도중 들어온 각성 요청은 현재 스폰 모델의 실제 난이도를 확인한 뒤 필요하면 무보상 재소환한다.
-- 요청 시점에 각성석을 이미 소비했으므로, 스폰 타이밍과 무관하게 선택 난이도의 늑대가 반드시 나오게 하는 보장 큐다.
function FieldBossService._finishWolfDifficultyRespawnQueue(rt)
	if not rt or rt.Id ~= "Wolf" or rt.Spawning then
		return false
	end
	local hadQueue = rt.WolfDifficultyRespawnQueued == true
	local intendedId = WolfDifficultyDefs.IsValid(rt.PendingDifficultyId) and rt.PendingDifficultyId or WolfDifficultyDefs.Default
	local alive = rt.Model and rt.Model.Parent and rt.Humanoid and rt.Humanoid.Health > 0
	local modelDifficulty = alive and rt.Model:GetAttribute("BossDifficulty") or nil
	rt.WolfDifficultyRespawnQueued = nil
	if hadQueue and alive and modelDifficulty ~= intendedId then
		local raisedByUserId = rt.DifficultyRaisedByUserId
		local raisedByName = rt.DifficultyRaisedByName
		local raisedBy = raisedByUserId and Players:GetPlayerByUserId(raisedByUserId) or nil
		local applied, reason = FieldBossService._resetWolfAttemptNow(rt, intendedId, rt.DifficultyEndsAt, raisedBy, "queued-respawn")
		if not raisedBy then
			rt.DifficultyRaisedByUserId = raisedByUserId
			rt.DifficultyRaisedByName = raisedByName
		end
		if not applied then
			rt.WolfDifficultyRespawnQueued = true
			return false, reason
		end
	end
	-- 일반 사망 카운트다운 소환도 새 상태를 보내 모달의 countdown/spawning 표시가 남지 않게 한다.
	Net.Event("WolfDifficultyChanged"):FireAllClients(FieldBossService._wolfDifficultyState(rt))
	return hadQueue
end

-- ===== 처치 (원본 보존 — 조각 시네마틱은 DEF.DeathCinematic 게이트) =====

-- [2026-08-10 계측 v3] FirstRun boss_engage(9)/boss_clear(10) — CarrotBoss 전용.
-- 게이트 퀘Idx≥3(W1Q02 제작 완료 후) — 보스 러시가 craft 스텝을 백필로 오염시키지 않게.
-- step9 CF = 장착 무기(Starter/Crafted) — '만들고 장착 안 함' 진단은 퍼널 스텝 대신 이 CF로 본다
-- (장착→보스 순서가 강제되지 않아 스텝으로 넣으면 백필 오염).
-- 🔴onKilled·syncTick 둘 다 쓰므로 반드시 둘보다 앞에 정의(뒤에 두면 nil 전역 호출).
local function fireFirstRunBoss(player, bossCf, step)
	if bossCf ~= "CarrotBoss" then
		return
	end
	if not DataService.IsLoaded(player) then
		return
	end
	local profile = DataService.GetProfile(player)
	if not profile or (profile.QuestChain.Index or 1) < 3 then
		return
	end
	if step == 9 then
		local uid = profile.Inventory and profile.Inventory.EquippedWeaponUid
		AnalyticsService.FirstRun(player, 9, (uid and uid ~= 0) and "Weapon - Crafted" or "Weapon - Starter")
	else
		AnalyticsService.FirstRun(player, step)
	end
end

local function onKilled(killedModel, contributors, _lastHitter, settlement)
	local rt = modelToRt[killedModel]
	if not rt or killedModel ~= rt.Model then
		return
	end
	-- [2026-07-27 M5] ch1_boss_attempt → BossAttempt(보스Id·레벨밴드 CF) + BossClear 신설.
	-- attempt 대비 clear 비율이 보스 난이도의 유일한 직접 지표다(지금까지는 attempt만 있어 분모가 없었다).
	local bossCf = killedModel:GetAttribute("MonsterId")
	if type(bossCf) ~= "string" or bossCf == "" then
		bossCf = "Unknown"
	end
	local killedDifficulty = killedModel:GetAttribute("BossDifficulty") or WolfDifficultyDefs.Default
	for userId in pairs(contributors) do
		local contributor = Players:GetPlayerByUserId(userId)
		if contributor then
			local band = "Lv - " .. AnalyticsService.LevelBand(tonumber(contributor:GetAttribute("Level")) or 1)
			if not rt.AttemptSent[userId] then
				rt.AttemptSent[userId] = true
				AnalyticsService.CustomCF(contributor, "BossAttempt", 1, bossCf, band)
				fireFirstRunBoss(contributor, bossCf, 9) -- [계측 v3] 교전 없이 바로 처치한 케이스(attempt 미전송) 커버
			end
			AnalyticsService.CustomCF(contributor, "BossClear", 1, bossCf, band)
			local eligible = settlement and settlement.eligible
			if not eligible or eligible[userId] then
				AnalyticsService.BossCleared(contributor, bossCf)
				if bossCf == "Wolf" then
					CosmeticService.RollWolfDifficultyDrop(contributor, killedDifficulty)
				end
			end
			fireFirstRunBoss(contributor, bossCf, 10) -- [계측 v3] FirstRun boss_clear(CarrotBoss만)
		end
	end
	-- [GuiRenewal E2] 보스 사망 컷씬(CutsceneGui — 시안 375:2): 기여자(피해 1 이상 = contributors 등재) 전용 연출 신호.
	-- 보상/드랍 정산(LootService·QuestChainService 등 OnKilled 병렬 소비자)과 무접촉 — 순수 연출 추가분.
	for userId in pairs(contributors) do
		local viewer = Players:GetPlayerByUserId(userId)
		if viewer then
			Net.Event("BossDefeatFx"):FireClient(viewer, { bossId = rt.Id })
		end
	end
	-- 상위 난이도 늑대를 처치하면 15분이 남아 있어도 즉시 계약을 종료하고 다음 시도는 쉬움으로 복귀한다.
	local resetWolfState = rt.Id == "Wolf"
	if resetWolfState then
		FieldBossService._setWolfDifficultyRuntime(rt, WolfDifficultyDefs.Default, nil, nil, "killed")
	end
	beginRespawn(rt)
	if resetWolfState then
		Net.Event("WolfDifficultyChanged"):FireAllClients(FieldBossService._wolfDifficultyState(rt))
	end
end

-- ===== 타겟·무인 리셋 (원본 보존) =====

-- 보스 AI 거리 = 수평거리 - 몸 반경(표면 기준): 거대 보스는 루트가 몸 높이 절반만큼 떠 있어 3D 중심거리로는 발밑에 붙어도 근접이 안 나가고 원거리 패턴이 오발한다.
-- AttackRange / MinRange / MaxRange는 전부 몸 표면으로부터의 거리로 읽는다.
local function edgeDist(rt, pos)
	local r = rt.Root.Position
	local flat = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(r.X, 0, r.Z)).Magnitude
	local bodyRadius = (rt.Model and rt.Model:GetAttribute("HitRadius")) or 0
	return math.max(0, flat - bodyRadius)
end

function pickTarget(rt, contributors)
	local bestRoot, bestHum, bestDist
	for _, player in ipairs(Players:GetPlayers()) do
		local proot, hum = alivePlayerParts(player)
		if proot and isInZone(rt, proot.Position) then
			local contributed = (contributors[player.UserId] or 0) > 0
			local dist = edgeDist(rt, proot.Position)
			-- 기여도는 후보 자격·보상에만 쓰고 공격 우선순위에는 쓰지 않는다.
			-- 전투 참여자 또는 인식 범위 안의 플레이어 중 몸 표면 기준 가장 가까운 대상을 매 AI 틱 선택한다.
			if (contributed or dist <= rt.Def.AggroRange)
				and (not bestRoot or dist < bestDist) then
				bestRoot, bestHum, bestDist = proot, hum, dist
			end
		end
	end
	return bestRoot, bestHum
end

local function updateIdleReset(rt: any, now, contributors) -- rt: any — 런타임 조립 테이블(신 솔버 free-type 경고 억제, 2026-07-21)
	local inCombat = next(contributors) ~= nil or rt.Humanoid.Health < rt.Humanoid.MaxHealth
	if not inCombat then
		rt.IdleSince = nil
		return
	end
	for userId in pairs(contributors) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			local proot = alivePlayerParts(player)
			if proot and isInZone(rt, proot.Position) then
				rt.IdleSince = nil
				return
			end
		end
	end
	if not rt.IdleSince then
		rt.IdleSince = now
		return
	end
	if now - rt.IdleSince >= rt.Def.IdleResetSec then
		rt.IdleSince = nil
		clearTelegraph(rt)
		-- 무인 리셋 완화(늑대 제외): IdleResetSec마다 MaxHp×IdleRecoverPct씩 점진 회복,
		-- 완전 회복 도달 시에만 기여 원장 초기화(부분 회복 중 복귀 = 딜·기여도 유지)
		if rt.Id == "Wolf" then
			rt.Humanoid.Health = rt.Humanoid.MaxHealth
			CombatService.ClearDamageLog(rt.Model)
			-- 풀힐 리셋은 같은 난이도의 1페이즈로 복원한다.
			rt.WolfFrenzy = false
			rt.WolfPhase = 1
			if rt.BaseDef then rt.Def = rt.BaseDef end
			rt.NextWolfActionAt, rt.NextComboAt, rt.NextFlankAt, rt.NextSkyHuntAt, rt.NextBloodHuntAt = 0, 0, 0, 0, 0
			if rt.Humanoid then rt.Humanoid.WalkSpeed = rt.Def.WalkSpeed end
			local glow = rt.Model and rt.Model:FindFirstChild("WolfFrenzyGlow")
			if glow then glow:Destroy() end
		else
			local hum = rt.Humanoid
			hum.Health = math.min(hum.MaxHealth, hum.Health + hum.MaxHealth * (GameConfig.BOSS.IdleRecoverPct or 0.3))
			if hum.Health >= hum.MaxHealth then
				CombatService.ClearDamageLog(rt.Model)
				-- [2026-07-20] 벽돌대왕: 방치 완전회복 시 1페(분리)로 리셋(합체 편도 보정)
				if rt.Def.MergePhase and not rt.SplitActive and rt.Model then
					resplitBrick(rt)
				end
			end
		end
	end
end

-- ===== 교전 개시 무장 =====
-- spawnBoss가 Next*At를 전부 0으로 두기 때문에, 무장이 없으면 첫 조우 순간 모든 특수 패턴이
-- 동시에 쿨 완료 상태가 되어 연달아 터진다. 교전이 시작될 때 각 패턴을 자기 쿨만큼 채워 둔다.
-- 제외: 기본 사이클(NextCycleAt — 즉시 발동 유지) / Flee·FrenzyDash(HP 게이트라 개시와 무관하고
--   무장하면 저체력 도주·광폭화 시그니처가 그만큼 침묵한다).
local ARM_SPECS = {
	{ field = "NextRollAt", cd = function(d) return d.AttackPattern == "StrawRoll" and (d.RollCooldown or 6) or nil end },
	{ field = "NextLeapAt", cd = function(d) return d.LeapSlam and d.LeapSlam.Cooldown end },
	{ field = "NextChargeAt", cd = function(d) return d.Charge and d.Charge.Cooldown end },
	{ field = "NextWhirlAt", cd = function(d) return d.Whirl and d.Whirl.Cooldown end },
	{ field = "NextThrowAt", cd = function(d) return d.TripleThrow and d.TripleThrow.Cooldown end },
	{ field = "NextMudChargeAt", cd = function(d) return d.MudCharge and d.MudCharge.Cooldown end },
	{ field = "NextFloodAt", cd = function(d) return d.MudFlood and d.MudFlood.Cooldown end },
	{ field = "NextGeyserAt", cd = function(d) return d.MudGeyser and d.MudGeyser.Cooldown end },
	{ field = "NextSmashAt", cd = function(d) return d.MudSmash and d.MudSmash.Cooldown end },
	{ field = "NextWhipAt", cd = function(d) return d.VineWhip and d.VineWhip.Cooldown end },
	{ field = "NextRootFieldAt", cd = function(d) return d.RootField and d.RootField.Cooldown end },
	{ field = "NextSaplingAt", cd = function(d) return d.SaplingSummon and d.SaplingSummon.Cooldown end },
	{ field = "NextSporeAt", cd = function(d) return d.SporeBurst and d.SporeBurst.Cooldown end },
	{ field = "NextBabyAt", cd = function(d) return d.BabySummon and d.BabySummon.Cooldown end },
	{ field = "NextScoldAt", cd = function(d) return d.MotherScold and d.MotherScold.Cooldown end },
	{ field = "NextSweepAt", cd = function(d) return d.BranchSweep and d.BranchSweep.Cooldown end },
	{ field = "NextBrickWallsAt", cd = function(d) return d.BrickWalls and d.BrickWalls.Cooldown end },
	{ field = "NextBrickChargeAt", cd = function(d) return d.BrickTripleCharge and d.BrickTripleCharge.Cooldown end },
	{ field = "NextBrickRainAt", cd = function(d) return d.BrickRainSlam and d.BrickRainSlam.Cooldown end },
	{ field = "NextHowlAt", cd = function(d) return d.Howl and (d.Howl.Cooldown or 12) end },
	{ field = "NextClawAt", cd = function(d) return d.ClawWave and (d.ClawWave.Cooldown or 7) end },
	{ field = "NextComboAt", cd = function(d) local p=d.WolfDifficultyPatterns; return p and p.ComboCooldown end },
	{ field = "NextFlankAt", cd = function(d) local p=d.WolfDifficultyPatterns; return p and p.Flank and p.FlankCooldown end },
	{ field = "NextSkyHuntAt", cd = function(d) local p=d.WolfDifficultyPatterns; return p and p.SkyHunt and p.SkyHuntCooldown end },
}

local function armPatterns(rt, now)
	local DEF = rt.Def
	for _, spec in ipairs(ARM_SPECS) do
		local ok, cd = pcall(spec.cd, DEF)
		if ok and type(cd) == "number" and cd > 0 then
			rt[spec.field] = now + cd
		end
	end
end

-- ===== 파티 동적 HP (2026-08-09 밸런스 패키지 ④) =====
-- PartyHpPerExtra 보유 보스(전 보스 — 2026-08-20 재밸런스): 최근 타격자 수로 MaxHealth 스케일.
-- 스냅샷 방식 — 전투 중 난입/이탈은 반영하지 않는다(중도 상향은 딜 무효화 체감, 하향은 악용 여지).
-- 재조우(부분 HP)는 유지, 늑대 무인 풀리셋 후 다음 교전에서 재계산. 기준 HP는 BaseDef(광폭화 Def 스왑 무관).
-- 🔴[2026-08-13 재작성] 구 스냅샷 방식의 구멍: 교전 개시 순간에만 인원을 셌다.
--   난입자가 개시 때만 서 있다가 빠지면 남은 사람이 부풀려진 HP를 혼자 떠안았다(고의 트롤 가능).
--   PartyHpPerExtra 상향(4500->12000)으로 피해가 2.7배가 돼 재작성한다.
-- 해법 = 비율 보존 재스케일. 남은 HP를 퍼센트로 옮기므로
--   (1) 인원이 빠지면 절대 HP도 같이 줄어 혼자 남아도 솔로 분량만 남는다
--   (2) 인원이 늘어도 진행률(%)이 뒤로 밀리지 않아 '내 딜이 무효화됐다'는 체감이 없다
--   (3) 빠져도 남은 비율은 그대로라 '막판에 빠져 이득' 같은 역악용도 성립하지 않는다
-- 인원 미변화면 newMax == curMax 로 조기 반환되므로 매 틱 호출해도 불필요한 복제가 없다.
local function scalePartyHp(rt)
	local baseDef = rt.BaseDef or rt.Def
	local per = tonumber(baseDef.PartyHpPerExtra)
	if not per or per <= 0 then
		return
	end
	local hum = rt.Humanoid
	if not hum or hum.Health <= 0 then
		return
	end
	-- [2026-08-20 재밸런스 D2-b] 존 재실 집계 → 최근 타격자 집계(CombatService.lastHitLog 창 조회)로 교체.
	--   구경꾼·잠수·리스폰 대기자가 존에 서 있기만 해도 HP를 인당 +45%씩 부풀리던 그리핑 차단.
	--   창(BOSS.PartyCountSec=15s) 동안은 사망·존 이탈도 카운트 유지 — 교대 릴레이(1인씩 번갈아 존 재실)로
	--   인원 가산을 회피하는 것도 같은 창이 완화한다. 아무도 안 때렸으면 n=0 → 기본 HP.
	local n = CombatService.GetRecentAttackerCount(rt.Model, GameConfig.BOSS.PartyCountSec or 15)
	local newMax = baseDef.Hp + per * math.max(0, n - 1)
	local curMax = hum.MaxHealth
	if curMax == newMax or curMax <= 0 then
		return
	end
	local ratio = math.clamp(hum.Health / curMax, 0, 1)
	hum.MaxHealth = newMax
	hum.Health = math.max(1, math.floor(newMax * ratio + 0.5))
end

-- ===== AI 틱 (Scheduler "BossAI" — 전 보스 순회) =====

local function tickBoss(rt: any, now) -- rt: any — 런타임 조립 테이블(신 솔버 free-type 경고 억제, 2026-07-21)
	-- 15분 계약 만료는 지연 콜백이 아니라 서버 시계로 판정해, 재각성 후 오래된 타이머가 Easy로 덮는 경합을 막는다.
	if rt.Id == "Wolf" and rt.DifficultyEndsAt and now >= rt.DifficultyEndsAt then
		if not rt.DifficultyExpireQueued then
			rt.DifficultyExpireQueued = true
			task.spawn(function()
				local changed = false
				local alive = rt.Model and rt.Model.Parent and rt.Humanoid and rt.Humanoid.Health > 0
				if not rt.Spawning and not rt.DifficultyMutationBusy then
					if alive then
						changed = FieldBossService._resetWolfAttemptNow(rt, WolfDifficultyDefs.Default, nil, nil, "expired") == true
					else
						FieldBossService._setWolfDifficultyRuntime(rt, WolfDifficultyDefs.Default, nil, nil, "expired")
						changed = true
					end
				end
				rt.DifficultyExpireQueued = false
				if changed then
					Net.Event("WolfDifficultyChanged"):FireAllClients(FieldBossService._wolfDifficultyState(rt))
				end
			end)
		end
		return
	end
	local DEF = rt.Def
	if rt.RespawnAt then
		if now >= rt.RespawnAt then
			-- 재소환은 Scheduler 틱 밖에서(spawnBoss = Clone+ScaleTo라 Heartbeat 한 프레임 점유)
			-- 🔴RespawnAt을 먼저 지운다 — 안 지우면 다음 틱이 같은 보스를 또 소환한다(중복 스폰)
			rt.RespawnAt = nil
			rt.Spawning = true
			task.spawn(function()
				local ok, spawned, reason = pcall(spawnBoss, rt)
				rt.Spawning = false
				if not ok then
					scheduleSpawnRetry(rt, spawned)
				elseif spawned ~= true then
					scheduleSpawnRetry(rt, reason)
				else
					FieldBossService._finishWolfDifficultyRespawnQueue(rt)
				end
			end)
		else
			updateCountdown(rt, now)
		end
		return
	end
	if rt.Spawning then
		return -- 소환 진행 중 — 완성 전까지 이 보스의 AI 개입 금지
	end
	if not rt.Model or rt.Model.Parent ~= bossFolder
		or not rt.Humanoid or not rt.Humanoid.Parent
		or not rt.Root or not rt.Root.Parent then
		scheduleSpawnRetry(rt, "runtime model/rig missing or reparented")
		return
	end
	if rt.Humanoid.Health <= 0 then
		-- CombatService 정산 콜백 밖에서 사망한 예외 경로도 상위 난이도를 다음 생애로 넘기지 않는다.
		local resetWolfState = rt.Id == "Wolf" and ((rt.DifficultyId or WolfDifficultyDefs.Default) ~= WolfDifficultyDefs.Default or rt.DifficultyEndsAt ~= nil)
		if resetWolfState then
			FieldBossService._setWolfDifficultyRuntime(rt, WolfDifficultyDefs.Default, nil, nil, "killed")
		end
		beginRespawn(rt)
		if resetWolfState then
			Net.Event("WolfDifficultyChanged"):FireAllClients(FieldBossService._wolfDifficultyState(rt))
		end
		return
	end
	local contributors = CombatService.GetContributors(rt.Model)
	updateIdleReset(rt, now, contributors)
	if rt.TelegraphEndAt and now >= rt.TelegraphEndAt then
		resolveTelegraph(rt)
	end
	if rt.PatternBusy then
		if rt.Id == "Wolf" and rt.Model then rt.Model:SetAttribute("WolfLocomotionMode", "Stop") end
		-- 의도적으로 제자리에 서는 패턴 시간을 6초 끼임 판정에 포함하면 패턴 직후 스폰점으로 순간이동한다.
		if rt.Root and rt.Root.Parent then
			rt.StuckPos = rt.Root.Position
			rt.StuckCheckAt = now
		end
		-- [2026-08-08] 패턴 스레드가 죽으면 Busy 영구 고착 = AI 전체(존 이탈 복구 포함) 마비 — 12초 상한
		rt.PatternBusySince = rt.PatternBusySince or now
		if now - rt.PatternBusySince < 12 then
			return
		end
		if rt.PatternMarkerStates then
			for _, markerState in pairs(rt.PatternMarkerStates) do
				markerState.CancelledGeneration = markerState.Generation
			end
		end
		stopBossAnims(rt, nil)
		rt.PatternBusy = false
		rt.PatternBusySince = nil
		-- 죽은 스레드가 못 돌은 꼬리 몫(앵커·AutoRotate)까지 대신 복구 — 앵커 잔류는 MoveTo 전면 무력화.
		-- 복구 후 이번 틱은 종료(느린-생존 스레드와의 이중 디스패치 방지).
		if rt.Root and rt.Root.Parent then
			rt.Root.Anchored = false
			rt.Root.AssemblyLinearVelocity = Vector3.zero
		end
		if rt.Humanoid and rt.Humanoid.Parent then
			rt.Humanoid.AutoRotate = true
		end
		warn("[FieldBossService] PatternBusy 12초 고착 — 강제 해제 | " .. tostring(rt.Id))
		return
	end
	rt.PatternBusySince = nil
	-- [QA 2026-07-15] 벽돌대왕 합체 트리거(HP≤비율, 분리 상태에서 1회)
	if DEF.MergePhase and rt.SplitActive and rt.Humanoid.Health / rt.Humanoid.MaxHealth <= (DEF.MergePhase.HpRatio or 0.5) then
		rt.SplitActive = false
		rt.PatternBusy = true
		task.spawn(performBrickMerge, rt)
		return
	end
	local targetRoot, targetHum = pickTarget(rt, contributors)
	if targetRoot then
		if rt.Id == "Wolf" and rt.Model then rt.Model:SetAttribute("WolfLocomotionMode", "Auto") end
		if not rt.Engaged then
			rt.Engaged = true -- 엣지 전이에서 1회만. 매 틱 무장하면 패턴이 영영 안 나온다
			armPatterns(rt, now)
			-- [2026-09-08] 등장 모션(animDef.Start 선언 보스만): 클립 길이만큼 PatternBusy로 AI를 세운다.
			-- 재생을 시작했으면 이번 틱은 여기서 끝 — 아래 추격·공격이 등장 모션 위로 겹치지 않게.
			-- 왕좌 기립: 앛커를 유지한 채 등장 클립을 먼저 태우고, SeatStandUp이 클립 길이 동안
			-- 좌석 높이 → 물리 안착 높이로 올린 뒤 앛커·네트워크 소유권을 복구한다(안 풀면 영영 못 움직인다).
			local introStarted = Ch2Pat.PlayIntro(rt, now)
			Ch2Pat.SeatStandUp(rt)
			if introStarted then
				return
			end
		end
		scalePartyHp(rt) -- [2026-08-13] 매 틱 재계산(비율 보존) — 난입·이탈 즉시 반영, 트롤 방지
	else
		rt.Engaged = false -- 무인 복귀 — 다음 교전에서 다시 무장(이탈 중 쿨이 흘러 재폭발하던 경로 차단)
	end
	if not targetRoot then
		rt.OutZoneSince = nil -- [2026-08-08] 무타깃 복귀 보행 중 타이머 동결(복귀 도중 접근 시 스냅 팝 방지)
		-- 거대 스케일 보스는 Humanoid:MoveTo가 무시된다(md=0 실측) → 복귀는 매 틱 CFrame 스텝:
		-- root.CFrame+속도0(PivotTo 금지), Y=지면 레이캐스트+현재 호버 유지, 도착판정 XZ
		local flat = Vector3.new(rt.SpawnPos.X - rt.Root.Position.X, 0, rt.SpawnPos.Z - rt.Root.Position.Z)
		if flat.Magnitude > AI.ReturnArriveDist then
			if rt.Id == "Wolf" and rt.Model then rt.Model:SetAttribute("WolfLocomotionMode", "Walk") end
			local step = math.min(rt.Def.WalkSpeed * AI.TickSec, flat.Magnitude)
			local dir = flat.Unit
			local cur = rt.Root.Position
			local hover = cur.Y - rollGroundY(rt, cur)
			local nextPos = cur + dir * step
			local ny = rollGroundY(rt, nextPos) + hover
			rt.Root.CFrame = CFrame.lookAt(Vector3.new(nextPos.X, ny, nextPos.Z), Vector3.new(nextPos.X + dir.X, ny, nextPos.Z + dir.Z))
			rt.Root.AssemblyLinearVelocity = Vector3.zero
		else
			if rt.Id == "Wolf" and rt.Model then rt.Model:SetAttribute("WolfLocomotionMode", "Stop") end
		end
		if flat.Magnitude <= AI.ReturnArriveDist and rt.IdleLook then
			-- 복귀 완료 — 입구 방향으로 틱당 조금씩 되돌린다(순간 회전은 눈에 띔, 위치는 불변)
			local curLook = rt.Root.CFrame.LookVector * Vector3.new(1, 0, 1)
			if curLook.Magnitude > 0.05 and curLook.Unit:Dot(rt.IdleLook) < 0.999 then
				local cur = rt.Root.Position
				local target = CFrame.lookAt(cur, cur + rt.IdleLook)
				rt.Root.CFrame = rt.Root.CFrame:Lerp(target, IDLE_TURN_ALPHA)
				rt.Root.AssemblyLinearVelocity = Vector3.zero
			end
		end
		-- [2026-09-08] 왕좌 착석: 스폰점(=왕좌 좌석)에 도착해 있는 동안만 착석 포즈를 홀드한다.
		-- 복귀 보행 중에는 놓아야 걷기 애니가 보인다. SeatIdle 미선언 보스는 양쪽 다 no-op.
		if flat.Magnitude <= AI.ReturnArriveDist then
			Ch2Pat.SeatHold(rt)
		else
			Ch2Pat.SeatRelease(rt)
		end
		return
	end
	local dist = edgeDist(rt, targetRoot.Position)
	-- [2026-08-24 GoblinKing] 페이즈 강화 갱신(임계 통과 순간 1회만 동작)
	if DEF.PhaseEscalate then
		Ch2Pat.updateKingPhase(rt)
	end
	-- [2026-09-07 StoneGolem] 광폭화 — ★위 PhaseEscalate 블록 안에 두면 도깨비왕만 통과해 돌장군은 영영 안 걸린다(실측).
	if DEF.GolemPhase then
		Ch2Pat.updateGolemPhase(rt)
	end

	-- 보스 위치 안전망(존 이탈·벽 끼임): 넉백/돌진이 존 경계를 넘거나 지형에 끼면 MoveTo가 영구 차단된다.
	-- 복구는 도주 복귀와 동일한 CFrame 직접 세팅(충돌 무시·지면 Y 보정)으로 스폰 재배치.
	do
		local cur = rt.Root.Position
		local outOfZone = not isInZone(rt, cur, 8)
		-- [2026-08-08] 사각 보완: 게이트 아치 끼임은 존 밖 0~8스터드라 pad 8 감지를 통과했다(실사고).
		-- 경계 밖(pad 1)이 3초 지속되면 패턴 사이의 정상 위치가 아니다 — 복구 대상.
		if not isInZone(rt, cur, 1) then
			rt.OutZoneSince = rt.OutZoneSince or now
			if now - rt.OutZoneSince >= 3 then
				outOfZone = true
			end
		else
			rt.OutZoneSince = nil
		end
		local stuck = false
		if now - (rt.StuckCheckAt or 0) >= 6 then
			if rt.StuckPos and (cur - rt.StuckPos).Magnitude < 1.5 and dist > DEF.AttackRange then
				stuck = true -- 사거리 밖 추격 중인데 6초간 제자리 = 지형 끼임
			end
			rt.StuckPos = cur
			rt.StuckCheckAt = now
		end
		if outOfZone or stuck then
			local hover = math.clamp(cur.Y - rollGroundY(rt, cur), 0, 20) -- 벽 내부 레이 이상치 방어
			local sp = rt.SpawnPos
			local ny = rollGroundY(rt, sp) + hover
			rt.Root.CFrame = CFrame.lookAt(Vector3.new(sp.X, ny, sp.Z), Vector3.new(cur.X, ny, cur.Z))
			rt.Root.AssemblyLinearVelocity = Vector3.zero
			rt.StuckPos = nil
			rt.OutZoneSince = nil
			return -- 이번 틱은 복구만 — 패턴 디스패치 생략
		end
	end

	-- [2026-07-22] 산개 페이즈: 본체 은신 — 전투는 프록시 4벽돌(brickMinionLoop)이 전담
	if DEF.MergePhase and rt.SplitActive then
		-- [2026-07-24 QA] 1페 하늘 벽돌 포격 제거(사장님 지시: 통통 튀기·포격 빼고 미는 공격만) — 전투는 프록시 4벽돌가 전담
		return
	end

	-- [QA 2026-07-22] 합체 벽돌대왕 접지 안전망: 브릭 앵커로 물리 낙하가 없어 패턴이 Y를 한 번 잘못 놓으면
	-- 영구 부양이 된다 → 패턴 비실행 틱에 편차 0.5 초과 시 지면으로 스냅.
	if DEF.MergePhase and not rt.SplitActive and rt.BrickStandY and rt.Root then
		local cur = rt.Root.Position
		local wantY = rollGroundY(rt, cur) + rt.BrickStandY
		if math.abs(cur.Y - wantY) > 0.5 then
			rt.Root.CFrame = rt.Root.CFrame - Vector3.new(0, cur.Y - wantY, 0)
			rt.Root.AssemblyLinearVelocity = Vector3.zero
		end
	end

	-- [2026-07-10] 늑대 페이즈 패턴: 기본 전조 공격 대신 전담 분기(이동·기본강타·스페셜 포함)
	if DEF.AttackPattern == "WolfPhase" then
		tickWolfPhase(rt, targetRoot, targetHum, now, dist)
		return
	end

	-- 저체력 도주(짚찌왕 — 최우선)
	if DEF.Flee and not rt.TelegraphEndAt and now >= rt.NextFleeAt
		and rt.Humanoid.Health / rt.Humanoid.MaxHealth <= DEF.Flee.HpPct then
		rt.NextFleeAt = now + DEF.Flee.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "Flee")
		task.spawn(performFlee, rt)
		return
	end
	-- 공중 내려찍기(짚찌왕)
	if DEF.LeapSlam and not rt.TelegraphEndAt and now >= rt.NextLeapAt
		and dist >= DEF.LeapSlam.MinRange and dist <= DEF.LeapSlam.MaxRange then
		rt.NextLeapAt = now + DEF.LeapSlam.Cooldown
		if math.random() < (DEF.LeapSlam.Chance or 1) then
			rt.PatternBusy = true
			playBossPatternAnim(rt, "LeapSlam")
			task.spawn(performLeapSlam, rt, targetRoot)
			return
		end
	end
	-- 짚단 굴리기(짚찌왕)
	if DEF.AttackPattern == "StrawRoll" and not rt.TelegraphEndAt and now >= rt.NextRollAt
		and dist > DEF.AttackRange and dist <= (DEF.RollRange or 30) then
		rt.PatternBusy = true
		rt.NextRollAt = now + (DEF.RollCooldown or 6)
		playBossPatternAnim(rt, "StrawRoll")
		task.spawn(performStrawRoll, rt, targetRoot)
		return
	end
	-- [2026-07-10] 당근 회오리(당근 대장) — 근접 광역. 돌진보다 먼저 판정해 밀착 시 우선 발동
	if DEF.Whirl and not rt.TelegraphEndAt and now >= rt.NextWhirlAt
		and dist <= (DEF.Whirl.SurfaceReach or DEF.Whirl.Range or 8) then
		rt.NextWhirlAt = now + (DEF.Whirl.Cooldown or 9)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "Whirl")
		task.spawn(performWhirl, rt, targetRoot)
		return
	end
	-- [피벗3 P5] 돌진(당근 대장)
	if DEF.Charge and not rt.TelegraphEndAt and now >= rt.NextChargeAt
		and dist >= DEF.Charge.MinRange and dist <= DEF.Charge.MaxRange then
		rt.NextChargeAt = now + DEF.Charge.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "Charge")
		task.spawn(performCharge, rt, targetRoot)
		return
	end
	-- [피벗3 P5] 뿌리 속박(나무장군)
	if DEF.RootBind and not rt.TelegraphEndAt and now >= rt.NextBindAt
		and dist >= DEF.RootBind.MinRange and dist <= DEF.RootBind.MaxRange then
		rt.NextBindAt = now + DEF.RootBind.Cooldown
		rt.PatternBusy = true
		task.spawn(performRootBind, rt, targetRoot)
		return
	end
	-- [피벗3 P5] 3연속 투척(벽돌대왕)
	if DEF.TripleThrow and not rt.TelegraphEndAt and now >= rt.NextThrowAt
		and dist >= DEF.TripleThrow.MinRange and dist <= DEF.TripleThrow.MaxRange then
		rt.NextThrowAt = now + DEF.TripleThrow.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "TripleThrow")
		task.spawn(performTripleThrow, rt, targetRoot)
		return
	end
	-- [피벗3 P5] 불장판(벽돌대왕 — 보조)
	if DEF.FireZone and not rt.TelegraphEndAt and now >= rt.NextFireAt
		and dist >= DEF.FireZone.MinRange and dist <= DEF.FireZone.MaxRange then
		rt.NextFireAt = now + DEF.FireZone.Cooldown
		rt.PatternBusy = true
		task.spawn(performFireZone, rt, targetRoot)
		return
	end
	-- [2026-07-20 BrickBoss 2페] BrickQuake (충격 고리 — 점프/중심 회피)
	if DEF.BrickQuake and not rt.TelegraphEndAt and now >= rt.NextQuakeAt
		and dist >= DEF.BrickQuake.MinRange and dist <= DEF.BrickQuake.MaxRange then
		rt.NextQuakeAt = now + DEF.BrickQuake.Cooldown
		rt.PatternBusy = true
		task.spawn(performBrickQuake, rt, targetRoot)
		return
	end
	-- [2026-07-22e BrickBoss 2페 재설계] A. 십자 벽돌벽
	if DEF.BrickWalls and not rt.TelegraphEndAt and now >= rt.NextBrickWallsAt
		and dist >= DEF.BrickWalls.MinRange and dist <= DEF.BrickWalls.MaxRange then
		rt.NextBrickWallsAt = now + DEF.BrickWalls.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "BrickWalls")
		task.spawn(performBrickWalls, rt, targetRoot)
		return
	end
	-- B. 3연속 돌격
	if DEF.BrickTripleCharge and not rt.TelegraphEndAt and now >= rt.NextBrickChargeAt
		and dist >= DEF.BrickTripleCharge.MinRange and dist <= DEF.BrickTripleCharge.MaxRange then
		rt.NextBrickChargeAt = now + DEF.BrickTripleCharge.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "BrickTripleCharge")
		task.spawn(performBrickTripleCharge, rt, targetRoot)
		return
	end
	-- C. 벽돌비 강타
	if DEF.BrickRainSlam and not rt.TelegraphEndAt and now >= rt.NextBrickRainAt
		and dist >= DEF.BrickRainSlam.MinRange and dist <= DEF.BrickRainSlam.MaxRange then
		rt.NextBrickRainAt = now + DEF.BrickRainSlam.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "BrickRainSlam")
		task.spawn(performBrickRainSlam, rt, targetRoot)
		return
	end
	-- [2026-07-31 MudBoss] MudCharge: 진흙에 발 묶인 상대를 덮치는 추격 돌진.
	-- MudFlood보다 먼저 본다 — '감속시키고 마무리'가 되려면 감속이 살아있는 동안 터져야 한다.
	if DEF.MudCharge and not rt.TelegraphEndAt and now >= rt.NextMudChargeAt
		and dist >= DEF.MudCharge.MinRange and dist <= DEF.MudCharge.MaxRange
		and (anyMudTrapped() or (now - (rt.LastMudTrapAt or -1e9)) <= (DEF.MudCharge.TrapWindow or 4)) then
		rt.NextMudChargeAt = now + DEF.MudCharge.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "MudCharge")
		task.spawn(performCharge, rt, targetRoot, DEF.MudCharge)
		return
	end
	-- [2026-07-20 MudBoss] MudFlood (signature)
	if DEF.MudFlood and not rt.TelegraphEndAt and now >= rt.NextFloodAt
		and dist >= DEF.MudFlood.MinRange and dist <= DEF.MudFlood.MaxRange then
		rt.NextFloodAt = now + DEF.MudFlood.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "MudFlood")
		task.spawn(function()
			performMudFlood(rt, targetRoot)
			-- 어떤 경로로 끝나도(에러 포함) 잔류 MudTrapped·슬로우가 남지 않게 전원 해제
			for _, pl in ipairs(Players:GetPlayers()) do
				local ch = pl.Character
				local ph = ch and ch:FindFirstChildOfClass("Humanoid")
				if ph and ph:GetAttribute("MudTrapped") then
					releasePatternSlow(ph)
					ph:SetAttribute("MudTrapped", nil)
				end
			end
		end)
		return
	end
	-- [2026-07-20 MudBoss] MudGeyser
	if DEF.MudGeyser and not rt.TelegraphEndAt and now >= rt.NextGeyserAt
		and dist >= DEF.MudGeyser.MinRange and dist <= DEF.MudGeyser.MaxRange then
		rt.NextGeyserAt = now + DEF.MudGeyser.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "MudGeyser")
		task.spawn(performMudGeyser, rt, targetRoot)
		return
	end
	-- [2026-07-20 MudBoss] MudSmash (근접 대형 융기)
	if DEF.MudSmash and not rt.TelegraphEndAt and now >= rt.NextSmashAt
		and dist >= DEF.MudSmash.MinRange and dist <= DEF.MudSmash.MaxRange then
		rt.NextSmashAt = now + DEF.MudSmash.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "MudSmash")
		task.spawn(performMudSmash, rt, targetRoot)
		return
	end
	-- [2026-07-20 WoodBoss] VineWhip (front line)
	if DEF.VineWhip and not rt.TelegraphEndAt and now >= rt.NextWhipAt
		and dist >= DEF.VineWhip.MinRange and dist <= DEF.VineWhip.MaxRange then
		rt.NextWhipAt = now + DEF.VineWhip.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "VineWhip")
		task.spawn(performVineWhip, rt, targetRoot)
		return
	end
	-- [2026-08-20 MotherGoblin] BabySummon (signature) -- 족속 소환. 보스만 때리면 뒤가 뚚린다
	if DEF.BabySummon and not rt.TelegraphEndAt and now >= (rt.NextBabyAt or 0)
		and dist <= (DEF.BabySummon.MaxRange or 45) then
		rt.NextBabyAt = now + DEF.BabySummon.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "BabySummon")
		task.spawn(performBabySummon, rt, targetRoot)
		return
	end
	-- [2026-08-20 MotherGoblin] MotherScold -- 호통(확장 링·점프 회피)
	if DEF.MotherScold and not rt.TelegraphEndAt and now >= (rt.NextScoldAt or 0)
		and dist <= (DEF.MotherScold.MaxRange or DEF.MotherScold.Radius or 26) then
		rt.NextScoldAt = now + DEF.MotherScold.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "MotherScold")
		task.spawn(performMotherScold, rt, targetRoot)
		return
	end
	-- [2026-08-24 GoblinKing] PhantomClone -- 분신 2기 + 본체 동시 3줄 충격파
	if DEF.PhantomClone and not rt.TelegraphEndAt and now >= (rt.NextPhantomAt or 0)
		and dist <= (DEF.PhantomClone.MaxRange or 42) then
		rt.NextPhantomAt = now + (DEF.PhantomClone.Cooldown or 16) * (rt.PhaseCdMul or 1)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "PhantomClone")
		task.spawn(Ch2Pat.PhantomClone, rt, targetRoot)
		return
	end
	-- [2026-08-24 GoblinKing] LightningStrike -- 발밑 추적 낙뢰 연속(멈추면 맞는다)
	if DEF.LightningStrike and not rt.TelegraphEndAt and now >= (rt.NextLightningAt or 0)
		and dist <= (DEF.LightningStrike.MaxRange or 45) then
		rt.NextLightningAt = now + (DEF.LightningStrike.Cooldown or 14) * (rt.PhaseCdMul or 1)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "LightningStrike")
		task.spawn(Ch2Pat.LightningStrike, rt, targetRoot)
		return
	end
	-- [2026-08-24 GoblinKing] ClubShock -- 방망이 충격파(직선 — 좌우로 비킨다)
	if DEF.ClubShock and not rt.TelegraphEndAt and now >= (rt.NextClubShockAt or 0)
		and dist <= (DEF.ClubShock.MaxRange or 40) then
		rt.NextClubShockAt = now + (DEF.ClubShock.Cooldown or 8) * (rt.PhaseCdMul or 1)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "ClubShock")
		task.spawn(Ch2Pat.ClubShock, rt, targetRoot)
		return
	end
	-- [2026-08-24 GoblinKing] WispSummon -- 유도 도깨비불(계속 움직이게 만드는 압박)
	if DEF.WispSummon and not rt.TelegraphEndAt and now >= (rt.NextWispSummonAt or 0)
		and dist <= (DEF.WispSummon.MaxRange or 45) then
		rt.NextWispSummonAt = now + (DEF.WispSummon.Cooldown or 13) * (rt.PhaseCdMul or 1)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "WispSummon")
		task.spawn(Ch2Pat.WispSummon, rt, targetRoot)
		return
	end
	-- [2026-09-07 StoneGolem] GroundQuake -- 지면 강타 균열(명세 ③). 직선이라 먼저 본다.
	if DEF.GroundQuake and not rt.TelegraphEndAt and now >= (rt.NextQuakeAt or 0)
		and dist <= (DEF.GroundQuake.MaxRange or 32) then
		rt.NextQuakeAt = now + (DEF.GroundQuake.Cooldown or 7) * (rt.PhaseCdMul or 1)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "GroundQuake")
		task.spawn(Ch2Pat.GroundQuake, rt, targetRoot)
		return
	end
	-- [2026-08-24 StoneGolem] RockThrow -- 원거리 주력(예고 원 판정)
	if DEF.RockThrow and not rt.TelegraphEndAt and now >= (rt.NextRockThrowAt or 0)
		and dist >= (DEF.RockThrow.MinRange or 0) and dist <= (DEF.RockThrow.MaxRange or 40) then
		rt.NextRockThrowAt = now + (DEF.RockThrow.Cooldown or 8) * (rt.PhaseCdMul or 1)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "RockThrow")
		task.spawn(Ch2Pat.RockThrow, rt, targetRoot)
		return
	end
	-- [2026-08-24 StoneGolem] RockFall -- 난석 순차 낙하(이어 밟고 빠져나가기)
	if DEF.RockFall and not rt.TelegraphEndAt and now >= (rt.NextRockFallAt or 0)
		and dist <= (DEF.RockFall.MaxRange or 32) then
		rt.NextRockFallAt = now + (DEF.RockFall.Cooldown or 11) * (rt.PhaseCdMul or 1)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "RockFall")
		task.spawn(Ch2Pat.RockFall, rt, targetRoot)
		return
	end
	-- [2026-08-24 FeastGoblin] LiquorSplash -- 서 있을 자리를 줌이는 압박형이라 시그니처로 먼저 본다
	if DEF.LiquorSplash and not rt.TelegraphEndAt and now >= (rt.NextLiquorAt or 0)
		and dist <= (DEF.LiquorSplash.MaxRange or 34) then
		rt.NextLiquorAt = now + (DEF.LiquorSplash.Cooldown or 12)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "LiquorSplash")
		task.spawn(Ch2Pat.LiquorSplash, rt, targetRoot)
		return
	end
	-- [2026-08-24 FeastGoblin] DrumWave -- 고리형 연타(밖으로 도망가면 계속 맞는다)
	if DEF.DrumWave and not rt.TelegraphEndAt and now >= (rt.NextDrumWaveAt or 0)
		and dist <= (DEF.DrumWave.MaxRange or 30) then
		rt.NextDrumWaveAt = now + (DEF.DrumWave.Cooldown or 9)
		rt.PatternBusy = true
		playBossPatternAnim(rt, "DrumWave")
		task.spawn(Ch2Pat.DrumWave, rt, targetRoot)
		return
	end
	-- [2026-08-20 ForestKeeper] SaplingSummon -- signature pattern, so it takes priority:
	-- left alone the pods heal the boss, which makes it the DPS check of the fight.
	if DEF.SaplingSummon and not rt.TelegraphEndAt and now >= (rt.NextSaplingAt or 0)
		and dist <= (DEF.SaplingSummon.MaxRange or 40) then
		rt.NextSaplingAt = now + DEF.SaplingSummon.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "SaplingSummon")
		task.spawn(performSaplingSummon, rt, targetRoot)
		return
	end
	-- [2026-08-20 ForestKeeper] SporeBurst -- fixed-radius poison zone
	if DEF.SporeBurst and not rt.TelegraphEndAt and now >= (rt.NextSporeAt or 0)
		and dist >= (DEF.SporeBurst.MinRange or 0) and dist <= (DEF.SporeBurst.MaxRange or 30) then
		rt.NextSporeAt = now + DEF.SporeBurst.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "SporeBurst")
		task.spawn(performSporeBurst, rt, targetRoot)
		return
	end
	-- [2026-07-20 WoodBoss] RootField
	if DEF.RootField and not rt.TelegraphEndAt and now >= rt.NextRootFieldAt
		and dist >= DEF.RootField.MinRange and dist <= DEF.RootField.MaxRange then
		rt.NextRootFieldAt = now + DEF.RootField.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "RootField")
		task.spawn(performRootField, rt, targetRoot)
		return
	end
	-- [2026-07-20 WoodBoss] BranchSweep (front cone)
	if DEF.BranchSweep and not rt.TelegraphEndAt and now >= rt.NextSweepAt
		and dist <= (DEF.BranchSweep.Range or 18) then
		rt.NextSweepAt = now + DEF.BranchSweep.Cooldown
		rt.PatternBusy = true
		playBossPatternAnim(rt, "BranchSweep")
		task.spawn(performBranchSweep, rt, targetRoot)
		return
	end

	if dist > DEF.AttackRange then
		if isInZone(rt, targetRoot.Position) then
			if DEF.DirectRootChase then
				-- 거대 HRP는 열린 보스 마당에서도 Humanoid:MoveTo가 정지할 수 있다.
				-- 복귀 이동과 같은 서버 CFrame 스텝으로 부드럽게 추격해 false-stuck 순간이동을 없앤다.
				rt.Humanoid:MoveTo(rt.Root.Position)
				local destination = clampChasePos(rt, targetRoot.Position)
				local cur = rt.Root.Position
				local flat = Vector3.new(destination.X - cur.X, 0, destination.Z - cur.Z)
				if flat.Magnitude > 0.05 then
					local step = math.min(DEF.WalkSpeed * AI.TickSec, flat.Magnitude)
					local dir = flat.Unit
					local hover = math.clamp(cur.Y - rollGroundY(rt, cur), 0, 20)
					local nextPos = cur + dir * step
					local ny = rollGroundY(rt, nextPos) + hover
					rt.Root.CFrame = CFrame.lookAt(Vector3.new(nextPos.X, ny, nextPos.Z), Vector3.new(nextPos.X + dir.X, ny, nextPos.Z + dir.Z))
					rt.Root.AssemblyLinearVelocity = Vector3.zero
				end
			else
				rt.Humanoid:MoveTo(clampChasePos(rt, targetRoot.Position))
			end
		else
			rt.Humanoid:MoveTo(rt.Root.Position)
		end
	else
		rt.Humanoid:MoveTo(rt.Root.Position)
		if not rt.TelegraphEndAt and now >= rt.NextCycleAt then
			startTelegraph(rt, targetRoot, targetHum, now)
		end
	end
end

local function aiTick()
	local now = os.clock()
	for _, rt in pairs(runtimes) do
		tickBoss(rt, now)
	end
end

-- ===== 체력바 동기화 (Scheduler "BossHpSync" — 플레이어별 존 내 최근접 보스 1기) =====

local function syncTick()
	-- 보스별 기여 합계·랭크 선계산
	local infos = {} -- [rt] = { Contributors, Total, Ranks }
	for _, rt in pairs(runtimes) do
		local alive = rt.Model ~= nil and rt.Model.Parent ~= nil and rt.Humanoid ~= nil and rt.Humanoid.Health > 0
		if alive then
			local contributors = CombatService.GetContributors(rt.Model)
			local total = 0
			for _, dmg in pairs(contributors) do
				total += dmg
			end
			-- [2026-07-27 M5] 교전 감지 시점의 attempt(사이클당 1회/인) — 처치 직전까지 못 간 이탈자를 잡는 경로
			local bossCf = rt.Model:GetAttribute("MonsterId")
			if type(bossCf) ~= "string" or bossCf == "" then
				bossCf = "Unknown"
			end
			for userId in pairs(contributors) do
				if not rt.AttemptSent[userId] then
					rt.AttemptSent[userId] = true
					local contributor = Players:GetPlayerByUserId(userId)
					if contributor then
						AnalyticsService.CustomCF(contributor, "BossAttempt", 1, bossCf,
							"Lv - " .. AnalyticsService.LevelBand(tonumber(contributor:GetAttribute("Level")) or 1))
						fireFirstRunBoss(contributor, bossCf, 9) -- [계측 v3] FirstRun boss_engage(CarrotBoss만·무기 CF)
					end
				end
			end
			local ranksTop = {}
			if total > 0 then
				local arr = {}
				for uid, dmg in pairs(contributors) do
					arr[#arr + 1] = { userId = uid, pct = math.floor(dmg / total * 100 + 0.5) }
				end
				table.sort(arr, function(a, b)
					return a.pct > b.pct
				end)
				for k = 1, math.min(3, #arr) do
					ranksTop[k] = arr[k]
				end
			end
			infos[rt] = { Contributors = contributors, Total = total, Ranks = ranksTop }
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local proot = alivePlayerParts(player)

		-- 전투 가이드 등 공용 보스 존 상태. 생존 보스 유무와 무관하게 서버의 동일 존 판정을 사용한다.
		-- 기존 존이면 이탈 패드를 적용해 경계 넉백/왕복 때 UI가 깜빡이지 않게 한다.
		local previousZoneId = player:GetAttribute("BossZoneId")
		local zoneRt, zoneDist
		if proot then
			for _, rt in pairs(runtimes) do
				local pad = rt.Id == previousZoneId and ZONE_EXIT_PAD or 0
				if isInZone(rt, proot.Position, pad) then
					local d = (proot.Position - rt.ZoneCenter).Magnitude
					if not zoneRt or d < zoneDist then
						zoneRt, zoneDist = rt, d
					end
				end
			end
		end
		local inBossZone = zoneRt ~= nil
		if player:GetAttribute("InBossZone") ~= inBossZone then
			player:SetAttribute("InBossZone", inBossZone)
		end
		local zoneId = zoneRt and zoneRt.Id or nil
		if previousZoneId ~= zoneId then
			player:SetAttribute("BossZoneId", zoneId)
			if previousZoneId then
				AnalyticsService.BossZoneChanged(player, tostring(previousZoneId), false)
			end
			if zoneId then
				AnalyticsService.BossZoneChanged(player, tostring(zoneId), true)
			end
		end

		-- 존 내 살아있는 보스 중 최근접 1기(존은 지리적으로 분리 — 겹침 시 최근접 우선)
		local activeRt, activeDist
		if proot then
			local prev = lastSent[player]
			local stickyId = (prev and prev.Active == true) and prev.BossId or nil
			for rt, _ in pairs(infos) do
				-- 표시 중인 보스만 이탈 히스테리시스 적용(깜빡임 방지) — 신규 진입은 원 반경
				if isInZone(rt, proot.Position, rt.Id == stickyId and ZONE_EXIT_PAD or 0) then
					local d = (proot.Position - rt.ZoneCenter).Magnitude
					if not activeRt or d < activeDist then
						activeRt, activeDist = rt, d
					end
				end
			end
		end
		if activeRt then
			local rt = activeRt
			local info = infos[rt]
			local my = info.Contributors[player.UserId] or 0
			local rewardShareMin = tonumber(GameConfig.HUNT and GameConfig.HUNT.BossShareMin)
				or tonumber(GameConfig.BOSS and GameConfig.BOSS.RewardShareMin) or 0.1
			if my > 0 and info.Total > 0 and my / info.Total >= rewardShareMin then
				AnalyticsService.BossContributionReady(player, rt.Id)
			end
			local hp = rt.Humanoid.Health
			local maxHp = rt.Humanoid.MaxHealth
			local difficulty = rt.Id == "Wolf" and (rt.DifficultyId or WolfDifficultyDefs.Default) or nil
			local difficultyEndsAt = nil
			if rt.Id == "Wolf" and rt.DifficultyEndsAt then
				difficultyEndsAt = Workspace:GetServerTimeNow() + math.max(0, rt.DifficultyEndsAt - os.clock())
			end
			local difficultyGeneration = rt.Id == "Wolf" and (rt.DifficultyGeneration or 0) or nil
			local last = lastSent[player]
			if not last or last.Active ~= true or last.BossId ~= rt.Id or last.Hp ~= hp or last.MaxHp ~= maxHp
				or last.Difficulty ~= difficulty or last.DifficultyGeneration ~= difficultyGeneration or last.My ~= my or last.Total ~= info.Total then
				lastSent[player] = { BossId = rt.Id, Active = true, Hp = hp, MaxHp = maxHp, Difficulty = difficulty, DifficultyGeneration = difficultyGeneration, My = my, Total = info.Total }
				Net.Event("BossHpSync"):FireClient(player, {
					bossId = rt.Id, -- [2026-08-21] 보스별 전투 카메라 거리(BossCameraController.DistanceByBoss)
					hp = hp,
					maxHp = maxHp,
					difficulty = difficulty,
					difficultyEndsAt = difficultyEndsAt,
					difficultyDurationSec = WolfDifficultyDefs.DurationSec,
					myDamage = my,
					totalDamage = info.Total,
					active = true,
					ranks = info.Ranks,
				})
			end
		else
			local last = lastSent[player]
			if last and last.Active == true then
				lastSent[player] = { Active = false }
				Net.Event("BossHpSync"):FireClient(player, { active = false })
			end
		end
	end
end

-- ===== 디버그 조회 (DebugService.BossState) =====

function FieldBossService._debugState()
	local out = {}
	for bossId, rt in pairs(runtimes) do
		local alive = rt.Model ~= nil and rt.Model.Parent ~= nil and rt.Humanoid ~= nil and rt.Humanoid.Health > 0
		out[bossId] = {
			Hp = alive and rt.Humanoid.Health or 0,
			MaxHp = alive and rt.Humanoid.MaxHealth or rt.Def.Hp,
			Difficulty = rt.DifficultyId,
			PendingDifficulty = rt.PendingDifficultyId,
			DifficultyRemaining = rt.DifficultyEndsAt and math.max(0, math.ceil(rt.DifficultyEndsAt - os.clock())) or 0,
			DifficultyGeneration = rt.DifficultyGeneration or 0,
			Alive = alive,
			Countdown = rt.RespawnAt ~= nil,
			CountdownRemaining = rt.RespawnAt and math.max(math.ceil(rt.RespawnAt - os.clock()), 0) or 0,
		}
	end
	return out
end

-- ===== 부팅 =====

FieldBossService._difficultyRequestAt = {}

function FieldBossService._wolfDifficultyState(rt)
	if not rt then return { ok = false, reason = "missing" } end
	local now = os.clock()
	local alive = rt.Model and rt.Model.Parent and rt.Humanoid and rt.Humanoid.Health > 0
	local difficulty = rt.PendingDifficultyId or rt.DifficultyId or WolfDifficultyDefs.Default
	local remaining = rt.DifficultyEndsAt and math.max(0, rt.DifficultyEndsAt - now) or 0
	local difficultyEndsAt = remaining > 0 and (Workspace:GetServerTimeNow() + remaining) or nil
	return {
		ok = true,
		bossId = "Wolf",
		difficulty = difficulty,
		activeDifficulty = rt.DifficultyId or WolfDifficultyDefs.Default,
		locked = rt.DifficultyMutationBusy == true,
		spawning = rt.Spawning == true,
		respawnQueued = rt.WolfDifficultyRespawnQueued == true,
		respawnGuaranteed = alive == true or rt.RespawnAt ~= nil or rt.Spawning == true or rt.WolfDifficultyRespawnQueued == true,
		alive = alive == true,
		countdown = rt.RespawnAt ~= nil,
		countdownRemaining = rt.RespawnAt and math.max(0, math.ceil(rt.RespawnAt - now)) or 0,
		difficultyEndsAt = difficultyEndsAt,
		difficultyRemaining = math.ceil(remaining),
		difficultyDurationSec = WolfDifficultyDefs.DurationSec,
		difficultyGeneration = rt.DifficultyGeneration or 0,
		raisedByUserId = rt.DifficultyRaisedByUserId,
		raisedByName = rt.DifficultyRaisedByName,
		resetReason = rt.DifficultyResetReason,
	}
end

function FieldBossService._applyWolfDifficulty(rt, difficultyId, player)
	local expiresAt = os.clock() + WolfDifficultyDefs.DurationSec
	if rt.DifficultyMutationBusy then
		return false, FieldBossService._wolfDifficultyState(rt), "busy"
	end
	if rt.Spawning then
		-- 모델이 이미 생겼더라도 spawnBoss 완료 전이면 구 Def로 조립 중일 수 있다. 요청을 보장 큐에 넣고 완료 후 실제 난이도를 검사한다.
		FieldBossService._setWolfDifficultyRuntime(rt, difficultyId, expiresAt, player, "selected")
		rt.WolfDifficultyRespawnQueued = true
		return true, FieldBossService._wolfDifficultyState(rt), "queued"
	end

	local alive = rt.Model and rt.Model.Parent and rt.Humanoid and rt.Humanoid.Health > 0
	if alive then
		local applied, reason = FieldBossService._resetWolfAttemptNow(rt, difficultyId, expiresAt, player, "selected")
		return applied, FieldBossService._wolfDifficultyState(rt), reason
	end

	FieldBossService._setWolfDifficultyRuntime(rt, difficultyId, expiresAt, player, "selected")
	if not rt.RespawnAt then
		-- 모델이 없는데 카운트다운도 없는 비정상 틈에서도 5초 내 재시도 예약을 명시적으로 만든다.
		rt.RespawnAt = os.clock() + SPAWN_RETRY_SEC
		local countdownOk, countdownErr = pcall(createCountdown, rt)
		if not countdownOk then
			warn("[FieldBossService] 늑대 각성 재소환 카운트다운 생성 실패 | " .. tostring(countdownErr))
		end
	end
	return true, FieldBossService._wolfDifficultyState(rt), "scheduled"
end

function FieldBossService._requestWolfDifficulty(player, action, difficultyId)
	local rt = runtimes.Wolf
	if not rt then return { ok = false, reason = "missing" } end
	if action == "get" then return FieldBossService._wolfDifficultyState(rt) end
	if action ~= "set" or difficultyId == WolfDifficultyDefs.Default or not WolfDifficultyDefs.IsValid(difficultyId) then
		return { ok = false, reason = "invalid" }
	end
	local now = os.clock()
	if now - (FieldBossService._difficultyRequestAt[player] or 0) < 0.6 then
		return { ok = false, reason = "cooldown" }
	end
	FieldBossService._difficultyRequestAt[player] = now
	local level = tonumber(player:GetAttribute("Level")) or 1
	if not RunService:IsStudio() and level < (rt.SourceDef.Level or 1) then
		return { ok = false, reason = "level" }
	end
	local state = FieldBossService._wolfDifficultyState(rt)
	if state.locked then return { ok = false, reason = "busy", state = state } end
	local currentRank = table.find(WolfDifficultyDefs.Order, state.difficulty) or 1
	local targetRank = table.find(WolfDifficultyDefs.Order, difficultyId) or 0
	if targetRank <= currentRank then
		return { ok = false, reason = "notHigher", state = state }
	end
	if not DataService.IsLoaded(player) then return { ok = false, reason = "loading" } end
	local profile = DataService.GetProfile(player)
	local inventory = profile and profile.Inventory
	local materials = inventory and inventory.Materials
	if type(materials) ~= "table" then return { ok = false, reason = "loading" } end
	local mode = WolfDifficultyDefs.Modes[difficultyId]
	local stoneCost = math.max(1, tonumber(mode.StoneCost) or 0)
	local itemId = WolfDifficultyDefs.ItemId
	local have = tonumber(materials[itemId]) or 0
	if have < stoneCost then
		return { ok = false, reason = "stone", need = stoneCost, have = have, state = state }
	end

	-- 차감과 서버 공용 상태 전이를 하나의 원자 구간처럼 처리한다. 상태 전이가 거부되면 즉시 재고를 복원한다.
	materials[itemId] = have - stoneCost
	local callOk, applied, nextState, applyReason = pcall(FieldBossService._applyWolfDifficulty, rt, difficultyId, player)
	if not callOk or applied ~= true then
		materials[itemId] = have
		PlayerService.SyncState(player, { "Inventory" })
		return { ok = false, reason = applyReason or "apply", state = FieldBossService._wolfDifficultyState(rt) }
	end
	DataService.MarkDirty(player, "WolfAwakeningStone")
	PlayerService.SyncState(player, { "Inventory" })
	AnalyticsService.Batch(player, "WolfAwakeningStoneSpent", stoneCost, difficultyId)
	Net.Event("WolfDifficultyChanged"):FireAllClients(nextState)
	-- 서버 공용 상태라도 알림 문장은 수신자 로케일별로 조합한다.
	for _, recipient in ipairs(Players:GetPlayers()) do
		local respawnNotice
		if nextState.alive then
			respawnNotice = Strings.getFor(recipient, "WolfAwaken_Respawned")
		elseif nextState.countdown then
			respawnNotice = string.format(Strings.getFor(recipient, "WolfAwaken_RespawnCountdown_Fmt"), nextState.countdownRemaining or 0)
		else
			respawnNotice = Strings.getFor(recipient, "WolfAwaken_RespawnQueued")
		end
		local modeName = Strings.defsFor(recipient, "WolfDifficultyDefs.Modes." .. difficultyId .. ".NameKo") or mode.NameKo
		Net.Event("Notice"):FireClient(recipient, {
			text = string.format(Strings.getFor(recipient, "WolfAwaken_Notice_Fmt"), player.DisplayName, modeName, stoneCost, respawnNotice),
		})
	end
	return nextState
end

local function adoptBossMarker(marker)
	local bossId = marker:GetAttribute("MonsterId")
	local def = bossId and MonsterDefs[bossId]
	if not def or def.IsBoss ~= true then
		return
	end
	if runtimes[bossId] then
		return -- 보스당 마커 1개(중복 배치 시 최초 채택)
	end
	local rt = {
		Id = bossId,
		SourceDef = def,
		Def = def,
		BaseDef = def,
		DifficultyId = bossId == "Wolf" and WolfDifficultyDefs.Default or nil,
		PendingDifficultyId = bossId == "Wolf" and WolfDifficultyDefs.Default or nil,
		DifficultyEndsAt = nil,
		DifficultyGeneration = 0,
		DifficultyMutationBusy = false,
		WolfDifficultyRespawnQueued = false,
		AttemptSerial = 0,
		Marker = marker,
		ZoneCenter = marker.Position + (def.ZoneCenterOffset or Vector3.zero),
		NextGrowlAt = 0,
	}
	runtimes[bossId] = rt
	local ok, spawned, reason = pcall(spawnBoss, rt)
	if not ok then
		scheduleSpawnRetry(rt, spawned)
	elseif spawned ~= true then
		scheduleSpawnRetry(rt, reason)
	end
end

function FieldBossService.Init()
	local servicesFolder = script.Parent
	Scheduler = require(servicesFolder:WaitForChild("Scheduler"))
	CombatService = require(servicesFolder:WaitForChild("CombatService"))
	PlayerService = require(servicesFolder:WaitForChild("PlayerService"))
	DataService = require(servicesFolder:WaitForChild("DataService"))
	AnalyticsService = require(servicesFolder:WaitForChild("AnalyticsService"))
	MonsterService = require(servicesFolder:WaitForChild("MonsterService"))
	CosmeticService = require(servicesFolder:WaitForChild("CosmeticService"))
	CombatService.OnKilled(onKilled)
	CombatService.SetBossZoneCheck(function(model, attackerPos)
		local rt = modelToRt[model]
		if not rt then
			return false
		end
		return isInZone(rt, attackerPos, 6)
	end)
	Net.Function("WolfDifficulty").OnServerInvoke = FieldBossService._requestWolfDifficulty
end

local function assignCharacterGroup(character)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = PLAYER_COLLISION_GROUP
		end
	end
	character.DescendantAdded:Connect(function(desc)
		if desc:IsA("BasePart") then
			desc.CollisionGroup = PLAYER_COLLISION_GROUP
		end
	end)
end

local function hookPlayerCollision(player)
	player.CharacterAdded:Connect(assignCharacterGroup)
	if player.Character then
		assignCharacterGroup(player.Character)
	end
end

function FieldBossService.Start()
	PhysicsService:RegisterCollisionGroup(BOSS_COLLISION_GROUP)
	PhysicsService:RegisterCollisionGroup(PLAYER_COLLISION_GROUP)
	PhysicsService:CollisionGroupSetCollidable(BOSS_COLLISION_GROUP, PLAYER_COLLISION_GROUP, false)
	Players.PlayerAdded:Connect(hookPlayerCollision)
	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayerCollision(player)
	end
	bossFolder = ensureFolder(ensureFolder(Workspace, "_Runtime"), "Boss")
	-- 보스 마커 채택: SpawnMarker 태그 + MonsterId가 IsBoss인 것 전부(팀이 마커만 배치하면 동작)
	for _, marker in ipairs(CollectionService:GetTagged(MARKER_TAG)) do
		adoptBossMarker(marker)
	end
	CollectionService:GetInstanceAddedSignal(MARKER_TAG):Connect(adoptBossMarker)
	Players.PlayerRemoving:Connect(function(player)
		lastSent[player] = nil
		FieldBossService._difficultyRequestAt[player] = nil
		local character = player.Character -- [버그4] 슬로우 저장 테이블 정리
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if hum then
			slowState[hum] = nil
		end
	end)
	Scheduler.Register("BossAI", AI.TickSec, aiTick)
	Scheduler.Register("BossHpSync", GameConfig.BOSS.SyncSec, syncTick)
end

-- 자동 QA용: 시각 경고 범위와 실제 피해 범위의 안전 여백 검증
FieldBossService._debugFairRadius = fairRadius
FieldBossService._debugWithinFairRadius = withinFairRadius

return FieldBossService
