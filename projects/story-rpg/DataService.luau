-- DataService: 프로필 로드/세션락/저장 (챕터1 신규 스토어)
-- 제약: loadOk 게이트 — 로드 미확인 세션은 절대 저장하지 않음(빈 데이터 덮어쓰기 원천 차단)
-- 제약: 세션락 — 한 프로필은 한 서버만 소유. UpdateAsync로 원자적 획득/탈취/해제
-- 제약: Studio에서 DataStore 접근 불가 시 인메모리 Mock 폴백, 라이브는 재시도 소진 후 kick

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- 킥 메시지 플레이어별 언어(getFor) — Defs 순서 의존 없음(모듈 데이터 전용)
local Strings = require(ReplicatedStorage:WaitForChild("Defs"):WaitForChild("Strings"))

local DataService = {}

-- Bootstrap의 Init 시점에 해석(모듈 생성 순서 의존 제거)
local GameConfig, ProfileTemplate, Util

-- 인프라 튜닝 상수(게임플레이 수치 아님 — Defs 관리 대상 외)
local RETRY_COUNT = 3
-- [2026-07-29 감사 C4] 종료 중엔 재시도를 줄인다 — 평상 경로는 3회 재시도+백오프(1+2+4=7초)에 UpdateAsync 왕복까지 더해지는데,
-- 로블록스 종료 유예는 30초라 인원이 많으면 뒤에 서서 저장되는 플레이어가 누락된다.
local RETRY_COUNT_CLOSING = 2
local closing = false -- BindToClose 진입 플래그 — 오토세이브 정지·재시도 축소
local RETRY_DELAY = 1              -- 초
local BACKOFF_MAX = 5
local LOCKED_WAIT = 2              -- 살아있는 타 세션 락 대기 간격
local STALE_SAVING_SEC = 10        -- 죽은 saving 플래그 강제 해제 임계
local BIND_TO_CLOSE_WAIT = 25      -- BindToClose 30초 한도 내 병렬 저장 대기
-- Studio는 빠른 반복 Play, 라이브는 보수적
local LOCK_STEAL_AFTER = RunService:IsStudio() and 10 or 90
local LOCK_ACQUIRE_TIMEOUT = RunService:IsStudio() and 6 or 25

-- Studio는 JobId가 비어 세션마다 GUID가 바뀌면 직전 자기 락을 타인으로 오인(데드락) → 고정 ID
local SESSION_ID = (game.JobId ~= "" and game.JobId)
	or (RunService:IsStudio() and "studio-local-session" or ("server-" .. HttpService:GenerateGUID(false)))

local store = nil
local usingMock = false

local cache = {}
local dirty = {}
local dirtyGen = {} -- 저장 중(yield) 들어온 새 변경 감지용 세대 카운터
local loading = {}
local saving = {}   -- [uid] = 저장 시작 os.clock()
local loadOk = {}   -- true인 세션만 저장 허용
local newDefault = {} -- 빈(raw=nil) 로드 세션 표시 — 첫 정상 저장 전까지 회귀가드 강제

local flushers = {}        -- 저장 직전 호출할 fn(player, profile) 배열(등록 순서 유지)
local loadedCallbacks = {}

local function key(player)
	return tostring(player.UserId)
end

-- Studio 폴백용 인메모리 스토어(UpdateAsync 시그니처 호환)
local MockStore = {}
MockStore.__index = MockStore
function MockStore.new()
	return setmetatable({ _data = {} }, MockStore)
end
function MockStore:UpdateAsync(k, transform)
	local result = transform(self._data[k])
	if result ~= nil then
		self._data[k] = result
	end
	return self._data[k]
end

local function switchToMock(reason)
	if usingMock then
		return
	end
	usingMock = true
	store = MockStore.new()
	warn("[DataService] Mock 스토어 사용 — " .. (reason or "Studio API 접근 불가"))
end

-- 저장 포맷: { Data = payload, Lock = { Id = 세션ID, T = 갱신시각 } }
local function unwrap(stored)
	if type(stored) ~= "table" then
		return nil, nil
	end
	return stored.Data, stored.Lock
end

-- 회귀가드: 빈/부분 로드가 채워진 기존 저장본을 덮어쓰는 것 차단 — 기준은 Weapons 수·QuestChain.Index, 신규(stored=nil) 미적용
local function invWeaponCount(payload)
	local w = payload and payload.Inventory and payload.Inventory.Weapons
	local n = 0
	if type(w) == "table" then
		for _ in pairs(w) do n += 1 end
	end
	return n
end
local function isDataRegression(stored, incoming)
	if type(stored) ~= "table" then
		return false
	end
	local s = invWeaponCount(stored)
	local ns = invWeaponCount(incoming)
	if s > 0 and ns == 0 then
		return true
	end
	if s >= 2 and ns < s * 0.5 then
		return true
	end
	local sc = (stored.QuestChain and tonumber(stored.QuestChain.Index)) or 1
	local nc = (incoming.QuestChain and tonumber(incoming.QuestChain.Index)) or 1
	if sc >= 3 and nc <= 1 then
		return true
	end
	return false
end

local function isForeignLiveLock(lock, now)
	return lock ~= nil and lock.Id ~= nil and lock.Id ~= SESSION_ID
		and (now - (tonumber(lock.T) or 0)) < LOCK_STEAL_AFTER
end

-- 세션락 원자 획득: 죽은 락은 탈취, 살아있는 타 세션 락은 대기 후 재시도.
-- 타임아웃 시 강제 탈취(락 미보유 세션이 남기는 stale 락 누적 방지). 반환: acquired, raw
local function acquireSessionLock(uid)
	local raw, acquired = nil, false
	local deadline = os.clock() + LOCK_ACQUIRE_TIMEOUT
	local backoff = RETRY_DELAY
	repeat
		local ok, err = pcall(function()
			store:UpdateAsync(uid, function(stored)
				local payload, lock = unwrap(stored)
				if isForeignLiveLock(lock, os.time()) then
					return nil -- 살아있는 타 세션 소유 → 획득 취소(쓰지 않음)
				end
				raw = payload
				acquired = true
				return { Data = payload, Lock = { Id = SESSION_ID, T = os.time() } }
			end)
		end)
		if acquired then
			break
		end
		if ok then
			task.wait(LOCKED_WAIT)
		elseif RunService:IsStudio() then
			switchToMock()
		else
			warn("[DataService] 락 획득 실패 | uid=" .. uid .. " | " .. tostring(err))
			task.wait(backoff)
			backoff = math.min(backoff * 2, BACKOFF_MAX)
		end
	until os.clock() >= deadline

	if not acquired then
		-- 타임아웃 후 강제 탈취(살아있는 타 세션 진행분 유실 가능 — 구 세션은 락 상실 가드로 저장만 차단됨)
		for attempt = 1, RETRY_COUNT do
			local ok = pcall(function()
				store:UpdateAsync(uid, function(stored)
					local payload, lock = unwrap(stored)
					if isForeignLiveLock(lock, os.time()) then
						warn("[DataService] 살아있는 세션 락 강제 탈취 | uid=" .. uid)
					end
					raw = payload
					acquired = true
					return { Data = payload, Lock = { Id = SESSION_ID, T = os.time() } }
				end)
			end)
			if ok and acquired then
				break
			end
			task.wait(RETRY_DELAY * attempt)
		end
	end
	return acquired, raw
end

-- 로드 대기 중 퇴장한 세션의 락 즉시 해제(다음 접속이 STEAL_AFTER를 기다리지 않게)
local function releaseAbandonedLock(uid)
	pcall(function()
		store:UpdateAsync(uid, function(stored)
			local payload, lock = unwrap(stored)
			if lock and lock.Id == SESSION_ID then
				return { Data = payload }
			end
			return nil -- 타 세션 락이면 손대지 않음
		end)
	end)
end

-- 템플릿 위 비파괴 병합. raw 부재 판정은 신규/기존 코호트와 무기 진화 소급을 구분하는 유일한 권위 시점이다.
local function buildProfile(raw)
	local isNewProfile = raw == nil
	local rawEvolution = type(raw) == "table" and raw.WeaponEvolution or nil
	local profile = Util.deepMerge(Util.deepCopy(ProfileTemplate), raw or {})
	local migrationChanged = false
	if profile.Meta.CreatedAt == 0 then
		profile.Meta.CreatedAt = os.time()
		migrationChanged = true
	end

	local evolution = profile.WeaponEvolution
	if evolution and (type(rawEvolution) ~= "table" or rawEvolution.LegacyProfile == nil) then
		-- 기존 저장 데이터만 구 제작 이력 소급 후보가 될 수 있다.
		evolution.LegacyProfile = not isNewProfile
		migrationChanged = true
	end
	if evolution and (type(rawEvolution) ~= "table" or rawEvolution.PolicyExistingProfile == nil) then
		-- 배포 시 이미 새 조건을 달성한 기존 유저만 무연출 소급 대상으로 스냅샷한다.
		evolution.PolicyExistingProfile = not isNewProfile
		migrationChanged = true
	end
	if evolution then
		if type(evolution.RequirementPolicies) ~= "table" then
			evolution.RequirementPolicies = {}
			migrationChanged = true
		end
		if type(evolution.PolicyEligible) ~= "table" then
			evolution.PolicyEligible = {}
			migrationChanged = true
		end
		if type(evolution.PolicyMigrationDone) ~= "table" then
			evolution.PolicyMigrationDone = {}
			migrationChanged = true
		end
		local configRevision = math.max(0, math.floor(tonumber(
			GameConfig.WEAPON_EVOLUTION and GameConfig.WEAPON_EVOLUTION.RequirementPolicyRevision
		) or 0))
		local savedRevision = math.max(0, math.floor(tonumber(evolution.RequirementPolicyRevision) or 0))
		if savedRevision < configRevision then
			for weaponId, policy in pairs(GameConfig.WEAPON_EVOLUTION.RequirementPolicies or {}) do
				evolution.RequirementPolicies[weaponId] = policy
			end
			evolution.RequirementPolicyRevision = configRevision
			migrationChanged = true
		end
		local version = math.max(tonumber(evolution.Version) or 0, 3)
		if evolution.Version ~= version then
			evolution.Version = version
			migrationChanged = true
		end
	end

	if isNewProfile and profile.Funnel then
		profile.Funnel.FTUEV4Eligible = false
		profile.Funnel.FTUEV5Eligible = false
		profile.Funnel.FTUEV6Eligible = false
		profile.Funnel.FTUEV7Eligible = true
		migrationChanged = true
	end
	return profile, migrationChanged
end

local function fireLoaded(player, profile)
	for _, fn in ipairs(loadedCallbacks) do
		task.spawn(fn, player, profile)
	end
end

local function runFlushers(player, profile)
	for _, fn in ipairs(flushers) do
		local ok, err = pcall(fn, player, profile)
		if not ok then
			warn("[DataService] Flusher 실패 | " .. tostring(err))
		end
	end
end

-- 로드 대기자 큐: GetProfile/_load 중복 진입의 폴링 대체 — _load 종결 시 일괄 재개
local waiters = {} -- [uid] = wake 콜백 배열

local function notifyWaiters(uid)
	local list = waiters[uid]
	if not list then
		return
	end
	waiters[uid] = nil
	for _, wake in ipairs(list) do
		pcall(wake) -- 취소된 대기 스레드가 로드 흐름을 깨지 않게 격리
	end
end

-- 현재 스레드를 로드 종결 notify 또는 timeout까지 중단. 재개 후 상태 판정은 호출부 책임
local function waitForLoadSettled(uid, timeout)
	local thread = coroutine.running()
	local resumed = false -- 이중 재개 방지(notify와 task.delay 중 먼저 온 쪽만 유효)
	local function wake()
		if resumed then
			return
		end
		resumed = true
		task.defer(thread)
	end
	local list = waiters[uid]
	if not list then
		list = {}
		waiters[uid] = list
	end
	table.insert(list, wake)
	task.delay(timeout, function()
		if resumed then
			return
		end
		local l = waiters[uid] -- 타임아웃 폴백: notify 부재 시 큐 잔존 누수 방지 위해 자신만 제거
		if l then
			local idx = table.find(l, wake)
			if idx then
				table.remove(l, idx)
			end
			if #l == 0 then
				waiters[uid] = nil
			end
		end
		wake()
	end)
	coroutine.yield()
end

function DataService._load(player)
	local uid = key(player)
	if cache[uid] then
		return cache[uid]
	end
	if loading[uid] then
		waitForLoadSettled(uid, GameConfig.PROFILE_LOAD_TIMEOUT)
		if cache[uid] then
			return cache[uid]
		end
		loading[uid] = nil
	end

	loading[uid] = true
	local acquired, raw = acquireSessionLock(uid)

	if player.Parent ~= Players then
		-- 락 획득 대기 중 퇴장: 캐시 미생성(유령 세션 방지) + 락 해제
		loading[uid] = nil
		notifyWaiters(uid)
		if acquired then
			releaseAbandonedLock(uid)
		end
		return nil
	end

	if not acquired then
		-- 라이브 로드 실패: 캐시/저장 없이 재접속 유도(기존 데이터 보호)
		loading[uid] = nil
		notifyWaiters(uid)
		warn("[DataService] 로드 실패 → kick | player=" .. player.Name)
		task.defer(function()
			if player.Parent then
				player:Kick(Strings.getFor(player, "Kick_LoadFail"))
			end
		end)
		return nil
	end

	if cache[uid] then
		-- 중복 로드 레이스: 먼저 끝난 쪽 캐시 유지(우리 락 쓰기는 동일 SESSION_ID라 무해)
		loading[uid] = nil
		notifyWaiters(uid)
		return cache[uid]
	end

	local profile, migrationChanged = buildProfile(raw)
	newDefault[uid] = (raw == nil) -- 빈 로드 표시(신규 or 일시 read-nil) — 첫 정상 저장 전까지 강제
	cache[uid] = profile
	dirty[uid] = migrationChanged == true
	dirtyGen[uid] = migrationChanged and 1 or 0
	loadOk[uid] = true
	loading[uid] = nil
	notifyWaiters(uid)
	fireLoaded(player, profile)
	return profile
end

-- 저장 본체. releaseLock=true(퇴장/서버 종료)면 락 해제를 겸한다
function DataService._save(player, reason, releaseLock)
	local uid = key(player)
	local profile = cache[uid]
	if not profile then
		return false
	end
	if loadOk[uid] ~= true then
		warn("[DataService] Save 차단(로드 미확인 세션) | player=" .. player.Name .. " | reason=" .. reason)
		return false
	end
	if saving[uid] then
		if releaseLock then
			-- 종료 계열(PlayerRemoving/BindToClose): 진행 중 저장 완료 대기 후 최종 스냅샷 재저장(락 해제 보장)
			local waitUntil = os.clock() + STALE_SAVING_SEC
			while saving[uid] and os.clock() < waitUntil do
				task.wait(0.05)
			end
			saving[uid] = nil
		elseif os.clock() - saving[uid] > STALE_SAVING_SEC then
			saving[uid] = nil
		else
			return false
		end
	end
	saving[uid] = os.clock()

	local genAtSnapshot = dirtyGen[uid] or 0
	profile.Meta.LastSavedAt = os.time()
	profile.Meta.SaveCount = (tonumber(profile.Meta.SaveCount) or 0) + 1
	local snapshot = Util.deepCopy(profile)

	local backoff = RETRY_DELAY
	for attempt = 1, (closing and RETRY_COUNT_CLOSING or RETRY_COUNT) do
		local lostLock = false
		local regressed = false
		local ok, err = pcall(function()
			store:UpdateAsync(uid, function(stored)
				local storedData, lock = unwrap(stored)
				if lock and lock.Id and lock.Id ~= SESSION_ID then
					lostLock = true
					return nil -- 락 탈취당함 → 저장 취소(현 소유 세션 데이터 보호)
				end
				-- 회귀가드: 빈 로드 세션(newDefault)이 채워진 기존 저장본을 덮어쓰려 하면 차단
				if newDefault[uid] and isDataRegression(storedData, snapshot) then
					regressed = true
					return nil
				end
				local wrapper = { Data = snapshot }
				if not releaseLock then
					wrapper.Lock = { Id = SESSION_ID, T = os.time() }
				end
				return wrapper
			end)
		end)
		if ok and lostLock then
			warn("[DataService] Save 중단(락 상실) | player=" .. player.Name .. " | reason=" .. reason)
			saving[uid] = nil
			-- [2026-07-29 감사 C2] 락을 빼앗기면 이 세션은 이후 어떤 저장도 성공하지 못한다 — 경고 없이 계속 플레이하면 그 전부를 잃는다.
			-- loadOk를 내려 저장 시도 자체를 막고(빈 재시도 반복 방지) 즉시 알린 뒤 내보낸다. 퇴장·종료 경로(releaseLock)는 이미 나가는 중이라 kick 제외.
			loadOk[uid] = false
			if not releaseLock then
				task.defer(function()
					if player.Parent then
						player:Kick(Strings.getFor(player, "Kick_SessionTaken"))
					end
				end)
			end
			return false
		end
		if ok and regressed then
			warn("[DataService] Save 차단(회귀가드 — 빈/stale 세션의 기존 데이터 덮어쓰기) | player=" .. player.Name .. " | reason=" .. reason)
			saving[uid] = nil
			return false
		end
		if ok then
			-- 저장 중 새 변경(dirtyGen 증가)이 있으면 dirty 유지 → 다음 오토세이브가 재저장
			if (dirtyGen[uid] or 0) == genAtSnapshot then
				dirty[uid] = false
			end
			newDefault[uid] = nil -- 첫 정상 저장 성공 → 이후 정상 급감(판매 등) 허용
			saving[uid] = nil
			return true
		end
		warn("[DataService] Save 실패 | player=" .. player.Name .. " | attempt=" .. attempt .. " | " .. tostring(err))
		task.wait(backoff)
		backoff = math.min(backoff * 2, BACKOFF_MAX)
	end
	saving[uid] = nil
	return false
end

function DataService._saveAll(reason)
	local players = Players:GetPlayers()
	local done, total = 0, #players
	for _, player in ipairs(players) do
		task.spawn(function()
			DataService.ForceSave(player, reason)
			done += 1
		end)
	end
	local deadline = os.clock() + BIND_TO_CLOSE_WAIT
	while done < total and os.clock() < deadline do
		task.wait(0.05)
	end
end

-- ===== 계약 API =====

-- 계약: 공개 API는 전부 닷 호출(DataService.Fn(...)) — 소비 측(Bootstrap/PlayerService/Analytics)과 통일
function DataService.Init()
	GameConfig = require(ReplicatedStorage.Defs.GameConfig)
	ProfileTemplate = require(ReplicatedStorage.Defs.ProfileTemplate)
	Util = require(ReplicatedStorage.Shared.Util)
	if RunService:IsStudio() and GameConfig.DATA and GameConfig.DATA.StudioUseMock then
		switchToMock("GameConfig.DATA.StudioUseMock (라이브 스토어 보호)")
		return
	end
	-- [2026-07-29 감사 C1] 표준은 Studio=Mock이다. false로 둔 채 잊고 게시하는 것을 막기 위해
	-- 매 부팅마다 크게 경고한다 — 이 상태의 Play는 라이브 프로필을 직접 쓴다.
	if RunService:IsStudio() then
		warn("[DataService] 🔴Studio에서 StudioUseMock=false — 라이브 스토어(" .. tostring(GameConfig.STORE_NAME)
			.. ")에 직접 쓴다. 의도한 것이 아니면 GameConfig.DATA.StudioUseMock을 true로 되돌려라.")
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.STORE_NAME)
	end)
	if ok then
		store = result
	elseif RunService:IsStudio() then
		switchToMock()
	else
		-- 라이브에서 스토어 획득 실패: 로드 경로 재시도가 소진되면 kick으로 이어짐
		warn("[DataService] GetDataStore 실패 | " .. tostring(result))
	end
end

function DataService.Start()
	Players.PlayerAdded:Connect(function(player)
		DataService._load(player)
	end)
	-- Start 이전 접속자 레이스 방어(_load는 멱등)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			DataService._load(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		DataService.ForceSave(player, "PlayerRemoving")
		local uid = key(player)
		-- ForceSave yield 중 재접속했으면 새 세션이 상태를 소유 → 정리 생략
		local rejoined = Players:GetPlayerByUserId(player.UserId)
		if rejoined and rejoined ~= player then
			return
		end
		cache[uid] = nil
		dirty[uid] = nil
		dirtyGen[uid] = nil
		saving[uid] = nil
		loadOk[uid] = nil
		newDefault[uid] = nil
		loading[uid] = nil
		notifyWaiters(uid) -- 로드 전 퇴장 대기자를 폴링 없이 즉시 nil 귀결
	end)

	task.spawn(function()
		while true do
			task.wait(GameConfig.AUTOSAVE_INTERVAL)
			-- [2026-07-29 감사 C4] 종료 중 오토세이브 정지 — BindToClose 전원 저장과 경합하면 saving[uid] 점유로 최종 스냅샷이 밀리고 30초 유예·DataStore 예산까지 나눠 쓴다.
			if closing then
				return
			end
			for _, player in ipairs(Players:GetPlayers()) do
				if dirty[key(player)] == true then
					task.spawn(DataService.ForceSave, player, "AutoSave")
				end
			end
		end
	end)

	game:BindToClose(function()
		closing = true -- [2026-07-29 감사 C4] 오토세이브 정지 + 재시도 축소를 먼저 켜고 저장 시작
		DataService._saveAll("BindToClose")
	end)
end

-- 로드 완료까지 최대 PROFILE_LOAD_TIMEOUT 대기. 실패/퇴장 시 nil
function DataService.GetProfile(player)
	local uid = key(player)
	if cache[uid] then
		return cache[uid]
	end
	if player.Parent ~= Players then
		return nil
	end
	waitForLoadSettled(uid, GameConfig.PROFILE_LOAD_TIMEOUT)
	if player.Parent ~= Players then
		return nil
	end
	return cache[uid]
end

function DataService.IsLoaded(player)
	local uid = key(player)
	return cache[uid] ~= nil and loadOk[uid] == true
end

function DataService.MarkDirty(player, _reason)
	local uid = key(player)
	if cache[uid] then
		dirty[uid] = true
		dirtyGen[uid] = (dirtyGen[uid] or 0) + 1
	end
end

function DataService.ForceSave(player, reason)
	local profile = cache[key(player)]
	if profile then
		runFlushers(player, profile)
	end
	local saveReason = tostring(reason or "ForceSave")
	local releaseLock = (saveReason == "PlayerRemoving" or saveReason == "BindToClose")
	return DataService._save(player, saveReason, releaseLock)
end

function DataService.RegisterFlusher(fn)
	if type(fn) == "function" then
		table.insert(flushers, fn)
	end
end

function DataService.OnLoaded(fn)
	if type(fn) ~= "function" then
		return
	end
	table.insert(loadedCallbacks, fn)
	-- 이미 로드 완료된 플레이어에게 소급 호출
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = cache[key(player)]
		if profile then
			task.spawn(fn, player, profile)
		end
	end
end

return DataService