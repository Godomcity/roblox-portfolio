--[[
	QuestChainService — 시스템 퀘스트 체인 상태머신. 조건 충족 시 자동 완료·보상·다음 발급.
	저장 = profile.QuestChain { Index, Progress } · 전이 시 즉시 저장(저빈도).
	구독: CombatService.OnKilled(기여자 전원 — Kill/Boss 공용) · CraftService.OnCrafted/OnEnhanced · ShopService.OnWeaponSold/OnPotionBought · PlayerService.OnPortalRegistered.
	공표: 어트리뷰트 QuestIndex/QuestProgress + Net "QuestState"(변경 시)·"QuestReward"(완료 시).
	제약: 수치는 QuestChainDefs에서만. 주기 루프 없음(전부 이벤트 구동). 공개 API 닷 호출.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Defs = ReplicatedStorage:WaitForChild("Defs")
local QuestChainDefs = require(Defs:WaitForChild("QuestChainDefs"))
local ItemDefs = require(Defs:WaitForChild("ItemDefs")) -- 포션 지급 분기 판별
local SkillDefs = require(Defs:WaitForChild("SkillDefs")) -- [2026-07-21 W1Q06S] 조각 보상 버킷 판별
local WeaponDefs = require(Defs:WaitForChild("WeaponDefs")) -- [2026-07-27] CraftRegion 지역 매칭·소급 판정(순수 데이터 모듈 — 순환 없음)
local EnhanceDefs = require(Defs:WaitForChild("EnhanceDefs")) -- UseWeapon의 '기준 무기 이상' 서버 공격력 비교
local GameConfig = require(Defs:WaitForChild("GameConfig")) -- [2026-08-10] 챕터2 티저 게이트
local Net = require(ReplicatedStorage:WaitForChild("Net"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local InventoryUtil = require(Shared:WaitForChild("InventoryUtil"))
local EvolutionRequirements = require(Shared:WaitForChild("EvolutionRequirements"))

local QuestChainService = {}

-- 순환 require 방지: 형제 서비스는 Init 시점에 resolve
local DataService
local PlayerService
local CombatService
local CraftService
local LootService -- Evolution 퀘스트의 재료·골드 수거 직후 조건 재평가 훅
local ShopService -- [2026-07-27 W1Q05V] 무기 판매 훅(OnWeaponSold)
local AnalyticsService -- 퍼널 관측점 발화
local SkillService -- [2026-07-21 W1Q06S] 제본 훅(OnBound)·조각 통지(OnFragmentGranted)
local WeaponEvolutionService -- 자동 진화 지급·소급·연출 페이로드

local CHAIN = QuestChainDefs.Chain
local SAVE_REASON = "QuestChain"
local WAITING_STAMP = QuestChainDefs.WaitingStamp

local function chainIndexById(questId)
	for index, quest in ipairs(CHAIN) do
		if quest.Id == questId then
			return index
		end
	end
	return nil
end

-- 저장/분석 슬롯은 유지하되 플레이에서 Deprecated 퀘스트는 절대 발급하지 않는다.
local function nextPlayableIndex(index)
	local current = math.clamp(math.floor(tonumber(index) or 1), 1, #CHAIN + 1)
	local visited = {}
	while current <= #CHAIN do
		local quest = CHAIN[current]
		if not (quest and quest.Deprecated == true) then
			break
		end
		if visited[current] then
			return #CHAIN + 1
		end
		visited[current] = true
		local resumeIndex = type(quest.ResumeId) == "string" and chainIndexById(quest.ResumeId) or nil
		current = resumeIndex and resumeIndex > current and resumeIndex or (current + 1)
	end
	return math.clamp(current, 1, #CHAIN + 1)
end

local function waitingZoneForIndex(index)
	if type(QuestChainDefs.IsWaitingIndex) == "function" and QuestChainDefs.IsWaitingIndex(index) then
		return QuestChainDefs.WaitingZone
	end
	return nil
end

local function getLoadedProfile(player)
	if not DataService.IsLoaded(player) then
		return nil
	end
	return DataService.GetProfile(player)
end

-- 첫 스토리 카드 원장. 기존 진행 유저(Index>1)는 소급 완료 처리해 팝업으로 방해하지 않는다.
local STORY_INTRO_REASON = "StoryIntroSeen"
local function syncStoryIntroState(player, profile)
	if type(profile.Flags) ~= "table" then
		profile.Flags = {}
	end
	local seen = profile.Flags.StoryIntroSeen == true
	if not seen and (tonumber(profile.QuestChain and profile.QuestChain.Index) or 1) > 1 then
		profile.Flags.StoryIntroSeen = true
		seen = true
		DataService.MarkDirty(player, STORY_INTRO_REASON)
	end
	player:SetAttribute("StoryIntroSeen", seen)
end

local function completeStoryIntro(player, mode)
	local profile = getLoadedProfile(player)
	if not profile then
		return
	end
	if type(profile.Flags) ~= "table" then
		profile.Flags = {}
	end
	if profile.Flags.StoryIntroSeen == true then
		player:SetAttribute("StoryIntroSeen", true)
		return
	end
	profile.Flags.StoryIntroSeen = true
	player:SetAttribute("StoryIntroSeen", true)
	DataService.MarkDirty(player, STORY_INTRO_REASON)
	AnalyticsService.StoryResolved(player, mode == "skip" and "skip" or "complete")
	DataService.ForceSave(player, STORY_INTRO_REASON)
end

local function currentQuest(profile)
	return CHAIN[profile.QuestChain.Index]
end

-- 챕터1 완주 파생 해금. 포탈은 탐험 등록이 원칙이지만 월드2 입구는 목적지 쪽에 있어
-- 자동 지급이 없으면 완주자가 입구를 등록하러 갈 수 없는 순환 잠금이 생긴다.
local WORLD2_PORTAL_ID = "World2"
local function ensureWorld2Portal(player, profile)
	local index = tonumber(profile.QuestChain and profile.QuestChain.Index) or 1
	if index <= (QuestChainDefs.W1Count or #CHAIN) then
		return false
	end
	if type(profile.Portals) ~= "table" then
		profile.Portals = {}
	end
	if profile.Portals[WORLD2_PORTAL_ID] == true then
		return false
	end
	profile.Portals[WORLD2_PORTAL_ID] = true
	DataService.MarkDirty(player, "World2PortalUnlock")
	if PlayerService then
		PlayerService.SyncState(player, { "Portals" })
	end
	return true
end

-- 세이브 호환: Id 기반 재정렬. ①QuestId 보유(2026-07-21 이후) = Id로 Index 재해석(삽입/삭제에 영구 안전)
-- ②QuestId 없음 = 구 12단계 세이브 → LEGACY_INDEX_MAP 표 조회  ③완주 = "DONE" 스탬프 → #CHAIN+1(스탬프는 publish가 기록)
-- 🔴누적 오프셋 시프트 금지 — 삽입이 2회 이상이면(W1Q06S +1, W1Q05C/V/E +3) 단일 오프셋으로 구 번호를 복원할 수 없다.
--   표 = 구 12단계 → 현행 16단계(2026-08-09 순서 스왑+W1Q07P 삽입 반영). 신설 퀘(5·7·8·11)는 건너뛴다(이미 지난 단계를 되돌리지 않는 규약).
local LEGACY_INDEX_MAP = { 1, 2, 3, 4, 6, 9, 10, 12, 13, 14, 15, 16 }
local function reconcileChain(profile)
	local qc = profile.QuestChain
	local skippedDeprecated = nil
	local storedId = qc.QuestId
	-- [2026-08-09 순서 스왑 특례] 구 순서(보스→제작) 세이브가 W1Q05C에 멈췄으면 짚찌왕은 이미 처치한 상태다.
	-- 새 순서(제작→보스)로 그대로 복원하면 제작 직후 보스 퀘가 다시 발급된다(재킬 강요) → 판매 퀘(W1Q05V)로 보낸다.
	-- 이중 판별: ①ChainV<2(패치 전 세이브) ②Codex 킬 원장 StrawBoss≥1 — 새 순서 유저(ChainV=2)는 조기 처치가 있어도 remap 안 한다.
	if storedId == "W1Q05C" and (tonumber(qc.ChainV) or 1) < 2 then
		local kills = profile.Codex and profile.Codex.Kills
		if type(kills) == "table" and (tonumber(kills.StrawBoss) or 0) > 0 then
			storedId = "W1Q05V"
		end
	end
	if type(storedId) == "string" and storedId ~= "" then
		if storedId == "DONE" then
			-- [2026-08-20 챕터2] 구 "DONE" = 월드1 완주 스탬프 — W2 병합 후에는 W2Q01(W1Count+1)부터 이어간다.
			-- 병합 전에는 W1Count+1 = #CHAIN+1이라 종전 동작과 동일.
			qc.Index = QuestChainDefs.W1Count + 1
		elseif storedId == "DONE2" then
			-- 부분 공개 중에는 공개 범위 끝의 대기 상태로 복원되고 publish가 전용 WAIT 스탬프로 교체한다.
			qc.Index = #CHAIN + 1
		elseif string.match(storedId, "^WAIT_W2_ZONE%d+$") then
			-- 다음 구역 공개 후에는 대기 스탬프가 가리키는 첫 퀘스트로 자동 재개한다.
			local resumeId = QuestChainDefs.WaitResumeByStamp and QuestChainDefs.WaitResumeByStamp[storedId]
			qc.Index = (resumeId and chainIndexById(resumeId)) or (#CHAIN + 1)
			qc.Progress = 0
		else
			local matchedIndex = chainIndexById(storedId)
			if matchedIndex then
				qc.Index = matchedIndex
			elseif QuestChainDefs.WaitingZone and string.sub(storedId, 1, 3) == "W2Q" then
				-- 패치 전 이미 미공개 W2 퀘스트를 받은 프로필은 구역2 완료 대기점으로 되돌린다.
				qc.Index = #CHAIN + 1
				qc.Progress = 0
			end
		end
	else
		local idx = tonumber(qc.Index) or 1
		-- [2026-08-20 챕터2] 구 12단계 완주 세이브도 월드1 완주로 복원(W2 병합 시 W2Q01부터)
		qc.Index = LEGACY_INDEX_MAP[idx] or (idx > #LEGACY_INDEX_MAP and QuestChainDefs.W1Count + 1 or 1)
	end
	qc.Index = math.clamp(tonumber(qc.Index) or 1, 1, #CHAIN + 1)
	qc.Progress = math.max(0, tonumber(qc.Progress) or 0)
	local deprecated = CHAIN[qc.Index]
	if deprecated and deprecated.Deprecated == true then
		skippedDeprecated = deprecated
		qc.Index = nextPlayableIndex(qc.Index)
		qc.Progress = 0
	end
	if waitingZoneForIndex(qc.Index) then
		qc.Progress = 0
	end
	return skippedDeprecated
end

-- 진행 공표: 어트리뷰트(상시) + QuestState 리모트(카드/화살표 등 GUI 소비)
local function publish(player, profile)
	syncStoryIntroState(player, profile) -- 첫 퀘스트를 이미 지난 세션도 즉시 소급 완료
	local qc = profile.QuestChain
	local quest = CHAIN[qc.Index]
	local waitingZone = waitingZoneForIndex(qc.Index)
	-- 오픈 전 부팅한 비병합 서버가 이후 들어온 W2 프로필의 forward-version 스탬프를
	-- DONE으로 덮지 않게 보존한다. 새 서버에서는 QuestId로 정확한 W2 인덱스를 복원한다.
	local storedId = qc.QuestId
	local preserveForwardStamp = not QuestChainDefs.Ch2Merged
		and type(storedId) == "string"
		and (storedId == "DONE2" or string.sub(storedId, 1, 3) == "W2Q" or string.sub(storedId, 1, 12) == "WAIT_W2_ZONE")
	if not preserveForwardStamp then
		if quest then
			qc.QuestId = quest.Id
		elseif waitingZone then
			qc.QuestId = WAITING_STAMP
		else
			qc.QuestId = QuestChainDefs.Ch2Merged and "DONE2" or "DONE"
		end
	end
	-- 메인 체인의 제작 퀘스트가 이미 같은 목표와 길안내를 소유하므로 선택형 CraftGoal로 복제하지 않는다.
	-- 이전 버전에서 자동 시드된 동일 목표도 여기서 정리해 메인/제작 카드가 중복 표시되지 않게 한다.
	if quest and (quest.Type == "Craft" or quest.Type == "CraftRegion" or quest.Type == "UseWeapon" or quest.Type == "Evolution")
		and type(quest.IconWeapon) == "string"
		and profile.CraftGoal == quest.IconWeapon then
		profile.CraftGoal = ""
		DataService.MarkDirty(player, "DuplicateMainCraftGoalCleanup")
		if PlayerService then
			PlayerService.SyncState(player, { "CraftGoal" })
		end
	end
	qc.ChainV = 2 -- [2026-08-09] 체인 개편 세대 마커 — W1Q05C 특례 remap을 구세이브로만 한정
	player:SetAttribute("QuestWaitingZone", waitingZone)
	player:SetAttribute("QuestIndex", qc.Index)
	player:SetAttribute("QuestProgress", qc.Progress)
	Net.Event("QuestState"):FireClient(player, {
		index = qc.Index,
		progress = qc.Progress,
		questId = quest and quest.Id or nil,
		target = quest and quest.Target or nil,
		count = quest and quest.Count or 0,
		waitingZone = waitingZone,
	})
end

-- 보상 지급: EXP=PlayerService.AddExp / 골드·아이템=인벤 직접+MarkDirty
-- 재료 bucket="Quest" → QuestMaterials(거래 불가) — InventoryUtil 규약
local function grantReward(player, profile, reward, bundleGrowth)
	if not reward then
		return nil
	end
	local growthResult = nil
	if reward.Exp and reward.Exp > 0 then
		growthResult = PlayerService.AddExp(player, reward.Exp, {
			BundleGrowth = bundleGrowth == true,
			CallerSaves = true,
		})
	end
	if reward.Gold and reward.Gold > 0 then
		local gold = math.floor(reward.Gold) -- [2026-07-25 P0-2] 정수 방어(소수 코인 영구 잔존 차단)
		profile.Inventory.Coins += gold
		-- [2026-07-27 M4] 재화 유입 관측 — 퀘 보상은 초반 코인의 주요 소스(파밍과 비율 비교용)
		AnalyticsService.Economy(player, "Source", "Coins", gold, profile.Inventory.Coins, "Gameplay", nil, "Src - Quest")
	end
	for _, item in ipairs(reward.Items or {}) do
		local itemId, count, bucket = item[1], item[2], item[3]
		if ItemDefs.Potions[itemId] then
			local potions = profile.Inventory.Potions
			potions[itemId] = (potions[itemId] or 0) + count
		elseif SkillDefs.Fragments and SkillDefs.Fragments[itemId] then
			-- [2026-07-21 W1Q06S 보정] 스킬 조각 = SkillFragments 버킷(LootService.grantItem 규약 미러) + 제본/레벨업 가능 통지
			local frags = profile.Inventory.SkillFragments or {}
			profile.Inventory.SkillFragments = frags
			local previousCount = frags[itemId] or 0
			local newCount = previousCount + count
			frags[itemId] = newCount
			task.defer(function()
				if SkillService and type(SkillService.OnFragmentGranted) == "function" then
					pcall(SkillService.OnFragmentGranted, player, itemId, count, previousCount, newCount)
				end
			end)
		else
			InventoryUtil.AddMaterial(profile, itemId, count, bucket)
		end
	end
	DataService.MarkDirty(player, SAVE_REASON)
	return growthResult
end

-- 제거된 퀘스트에 머물던 구 프로필만 해당 보상을 조용히 보전한다.
-- QuestId 전진과 보상은 같은 프로필 스냅샷에 저장되므로 재접속 중복 지급이 생기지 않는다.
local function grantDeprecatedMigrationReward(player, profile, deprecatedQuest)
	local reward = deprecatedQuest and deprecatedQuest.MigrationReward
	if not reward then
		return false
	end
	grantReward(player, profile, reward, true)
	return true
end

-- [2026-08-10 챕터2 티저] 완주(라이브·소급 로그인) 시 1회 모달 트리거 — 원장=Flags.Ch2TeaserSeen.
-- 게시 당일 GameConfig.CH2.TeaserOn=false로 발화 중단(원장은 남아 재발화 없음).
local function fireCh2Teaser(player, profile)
	local ch2 = GameConfig.CH2
	if not (ch2 and ch2.TeaserOn) then
		return
	end
	local flags = profile.Flags
	if type(flags) ~= "table" or flags.Ch2TeaserSeen == true then
		return
	end
	flags.Ch2TeaserSeen = true
	DataService.MarkDirty(player, SAVE_REASON)
	Net.Event("ShowCh2Teaser"):FireClient(player)
end

local checkAutoComplete -- 전방 선언(completeQuest 말미에서 호출 — 정의는 advance 아래)

-- 완료 처리: 보상 → QuestReward 통지 → 다음 발급 → 즉시 저장(체인 전이는 저빈도)
local function completeQuest(player, profile, committedEvolution)
	local quest = currentQuest(profile)
	if not quest then
		return
	end
	local completedIndex = profile.QuestChain.Index -- 퍼널 발화용 — 아래에서 Index가 다음 퀘로 넘어간다
	-- V5 순서 계약: 퀘 완료 확정 → 진화 커밋 → 보상/레벨업을 한 성장 카드로 묶는다.
	AnalyticsService.QuestCompleted(player, quest.Id)
	local evolution = committedEvolution or WeaponEvolutionService.ApplyForCompletedQuest(player, quest.Id)
	local nextIndex = nextPlayableIndex(profile.QuestChain.Index + 1)
	local nextQuest = CHAIN[nextIndex]
	local leadsLevelEvolution = evolution == nil and nextQuest ~= nil
		and EvolutionRequirements.IsLevelOnlyQuest(profile, nextQuest)
	-- 직전 퀘 보상으로 Lv.6이 되는 경우 레벨 팝업을 따로 띄우지 않고 진화 완료 카드에 합친다.
	local bundleGrowth = evolution ~= nil or leadsLevelEvolution
	local growth = grantReward(player, profile, quest.Reward, bundleGrowth)
	profile.QuestChain.Index = nextIndex
	profile.QuestChain.Progress = 0
	ensureWorld2Portal(player, profile) -- 신규 완주자: W1Q12 완료 순간 즉시 해금
	local nextEvolutionStage = leadsLevelEvolution and EvolutionRequirements.StageForQuest(nextQuest) or nil
	local deferForNextEvolution = nextEvolutionStage ~= nil
		and EvolutionRequirements.Status(profile, nextEvolutionStage).AllReady == true
	local waitingZone = waitingZoneForIndex(nextIndex)
	Net.Event("QuestReward"):FireClient(player, {
		questId = quest.Id,
		exp = quest.Reward and quest.Reward.Exp or 0,
		gold = quest.Reward and quest.Reward.Gold or 0,
		items = quest.Reward and quest.Reward.Items or {},
		nextId = nextQuest and nextQuest.Id or nil,
		waitingZone = waitingZone,
		evolution = evolution,
		growth = growth,
		deferForNextEvolution = deferForNextEvolution,
	})
	publish(player, profile)
	-- 보상 경로가 Inventory(골드·아이템)·Profile/Flags(AddExp 레벨업)도 변경 — QuestChain 단독 아님
	PlayerService.SyncState(player, { "QuestChain", "Profile", "Inventory", "Flags", "CraftGoal", "Portals", "WeaponEvolution" })
	-- [계측 v2] 퍼널 2종 발화(단조 백필은 AnalyticsService 책임): ①메인 퀘 = 체인 인덱스 1:1
	--   (Kill 퀘 파밍 구간 이탈은 여기서만 보인다) ②온보딩 = OnboardStep 지정 퀘만
	AnalyticsService.Quest(player, completedIndex, quest.Id)
	if quest.OnboardStep then
		AnalyticsService.Onboard(player, quest.OnboardStep)
	end
	if nextQuest then
		AnalyticsService.QuestStarted(player, nextQuest.Id)
	end
	if completedIndex == (QuestChainDefs.W1Count or #CHAIN) then
		fireCh2Teaser(player, profile) -- 챕터1 완주 경계에서만(병합 후 W2 최종 완료 오발화 방지)
	end
	-- 다음 퀘가 "이미 달성한 상태"면 저장 왕복 전에 즉시 완료해 GUI/레벨 팝업이 컷씬보다 앞서지 않게 한다.
	checkAutoComplete(player, profile)
	DataService.ForceSave(player, SAVE_REASON)
end

-- 진행 1증가 — 목표 도달 시 완료
local function advance(player, profile)
	local quest = currentQuest(profile)
	if not quest then
		return
	end
	local qc = profile.QuestChain
	qc.Progress += 1
	AnalyticsService.QuestProgress(player, quest.Id, qc.Progress)
	if qc.Progress >= (quest.Count or 1) then
		completeQuest(player, profile)
	else
		DataService.MarkDirty(player, SAVE_REASON)
		publish(player, profile)
	end
end

-- ===== [2026-07-27 학습 퀘 3종] 보유 상태 판정 헬퍼 — 라이브 훅과 소급 완료가 같은 규칙을 쓰도록 한곳에 =====
-- 🔴PackOnly(스타터팩 S6)는 제작 이력으로 치지 않는다 — 지급 무기라 "직접 만들어 본다" 목표를 대신하지 못함(팩 구매자 오통과 차단)
local function ownsCraftedInRegion(profile, region)
	for _, rec in pairs(profile.Inventory.Weapons or {}) do
		local wdef = rec.WeaponId and WeaponDefs.Weapons[rec.WeaponId] or nil
		if wdef and wdef.Region == region and not wdef.PackOnly then
			return true
		end
	end
	-- 제작 후 판매/깨짐으로 사라진 경우도 이력으로 인정(CraftedWeapons = 제작 경로 전용 기록)
	for weaponId in pairs(profile.CraftedWeapons or {}) do
		local wdef = WeaponDefs.Weapons[weaponId] -- 구 경로는 모델명을 키로 쓰기도 함 → nil로 자연 배제
		if wdef and wdef.Region == region and not wdef.PackOnly then
			return true
		end
	end
	return false
end

local function hasSoldWeapon(profile)
	-- [2026-07-29 8차 QA] 시작 무기(가상 uid 0) 판매 흔적 인정 — ShopService 시작무기 분기는
	-- SaleStones에 기록하지 않고 StarterSold 플래그만 남긴다(퀘 발급 전 판매자 소급 구제).
	if profile.Inventory and profile.Inventory.StarterSold == true then
		return true
	end
	for _ in pairs(profile.SaleStones or {}) do
		return true -- 판매 원장(2026-07-26 신설)
	end
	-- 원장 이전 세이브: 제작 이력에는 있는데 인벤에 없는 무기 = 판매(또는 강화 깨짐) 흔적
	local owned = {}
	for _, rec in pairs(profile.Inventory.Weapons or {}) do
		if rec.WeaponId then
			owned[rec.WeaponId] = true
		end
	end
	for weaponId in pairs(profile.CraftedWeapons or {}) do
		if not owned[weaponId] and WeaponDefs.Weapons[weaponId] then
			return true
		end
	end
	return false
end

local function hasEnhanced(profile)
	for _, rec in pairs(profile.Inventory.Weapons or {}) do
		if (tonumber(rec.Enhance) or 0) > 0 or (tonumber(rec.EnhStones) or 0) > 0 then
			return true -- EnhStones = 투입 누계라 실패로 레벨이 0이어도 시도 이력이 남는다
		end
	end
	return false
end

-- 소급 완료: 발급 시점(직전 퀘 완료 직후·로드 복원)에 이미 목표 달성이면 즉시 완료.
-- 재발화되지 않는 타입 전용(제본·포탈·제작·판매·강화). 판정은 관대하게(흔적이면 인정) — 신규는 프로필이 비어 오통과 불가.
checkAutoComplete = function(player, profile)
	local quest = currentQuest(profile)
	if not quest then
		return
	end
	local qType, target = quest.Type, quest.Target
	local done = false
	if qType == "Skill" then
		local owned = profile.Skills and profile.Skills.Owned
		done = type(owned) == "table" and owned[target] == true
	elseif qType == "Portal" then
		done = type(profile.Portals) == "table" and profile.Portals[target] == true
	elseif qType == "CraftRegion" then
		done = ownsCraftedInRegion(profile, target)
	elseif qType == "SellWeapon" then
		done = hasSoldWeapon(profile)
	elseif qType == "Enhance" then
		done = hasEnhanced(profile)
	elseif qType == "Evolution" then
		local evolution = WeaponEvolutionService.TryApplyActiveQuest(player, quest.Id)
		if evolution then
			completeQuest(player, profile, evolution)
		end
		return
	end
	if done then
		completeQuest(player, profile)
	end
end

-- [2026-07-21 W1Q06S] 제본 훅 소비자: 현재 퀘가 Skill이고 Target 일치 시 진행(OnKilled/OnCrafted 패턴)
local function onSkillBound(player, skillId)
	local profile = getLoadedProfile(player)
	if not profile then
		return
	end
	local quest = currentQuest(profile)
	if quest and quest.Type == "Skill" and quest.Target == skillId then
		advance(player, profile)
	end
end

-- 킬 크레딧(프로덕션·디버그 공용): 현재 퀘가 Kill/Boss이고 Target 일치 시 진행
local function applyKillCredit(player, monsterId)
	local profile = getLoadedProfile(player)
	if not profile then
		return false
	end
	local quest = currentQuest(profile)
	if not quest or (quest.Type ~= "Kill" and quest.Type ~= "Boss") then
		return false
	end
	if quest.Target ~= monsterId then
		return false
	end
	advance(player, profile)
	return true
end

-- CombatService.OnKilled 소비자 — 자격 판정은 CombatService.buildSettlement가 이미 끝냈다(settlement.eligible)
local function onMonsterKilled(model, contributors, _lastHitter, settlement)
	local monsterId = model:GetAttribute("MonsterId")
	if type(monsterId) ~= "string" or monsterId == "" then
		return
	end
	local eligible = settlement and settlement.eligible
	for userId in pairs(contributors or {}) do
		if not eligible or eligible[userId] then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				applyKillCredit(player, monsterId)
			end
		end
	end
end

local function onWeaponDamageConfirmed(player, monsterId, snapshot)
	local profile = getLoadedProfile(player)
	if not profile or type(snapshot) ~= "table" or snapshot.source ~= "Basic" then
		return
	end
	local quest = currentQuest(profile)
	if not quest or quest.Type ~= "UseWeapon" or quest.Target ~= monsterId then
		return
	end
	local matched = snapshot.weaponId == quest.RequiredWeapon
	if not matched and quest.AllowStrongerWeapon == true then
		local requiredDef = WeaponDefs.Weapons and WeaponDefs.Weapons[quest.RequiredWeapon]
		local usedDef = WeaponDefs.Weapons and WeaponDefs.Weapons[snapshot.weaponId]
		local rec = profile.Inventory and profile.Inventory.Weapons
			and profile.Inventory.Weapons[tostring(snapshot.weaponUid)]
		if requiredDef and usedDef and type(rec) == "table" and rec.WeaponId == snapshot.weaponId then
			local requiredAtk = EnhanceDefs.AtkOf(requiredDef.Atk, 0)
			local usedAtk = EnhanceDefs.AtkOf(usedDef.Atk, rec.Enhance)
			matched = usedAtk >= requiredAtk
		end
	end
	if not matched then
		return
	end
	AnalyticsService.WeaponEvolutionUsed(player, quest.RequiredWeapon, monsterId, snapshot.weaponId)
	advance(player, profile)
end

local function onCrafted(player, tierId)
	local profile = getLoadedProfile(player)
	if not profile then
		return
	end
	local quest = currentQuest(profile)
	if not quest then
		return
	end
	local wdef = WeaponDefs.Weapons and WeaponDefs.Weapons[tierId] or nil
	local matched = false
	if quest.Type == "Craft" then
		-- 매칭: 직접 일치(구 티어/신 weaponId) 또는 Target "T1" = 당근 지역 무기(하위호환)
		matched = quest.Target == tierId
		if not matched and quest.Target == "T1" then
			matched = wdef ~= nil and wdef.Region == "Carrot"
		end
	elseif quest.Type == "CraftRegion" then
		-- [2026-07-27 W1Q05C] 지역 단위 매칭 — 해당 지역 무기라면 어느 것이든 인정(키워드=Region).
		-- 팩 지급분(PackOnly)은 제작 경로를 거치지 않아 여기 도달하지 않지만, 소급 판정과 규칙을 맞춘다.
		matched = wdef ~= nil and wdef.Region == quest.Target and not wdef.PackOnly
	elseif quest.Type == "Evolution" then
		-- 구 버전 제작 연출이 패치 경계에서 끝난 경우도 즉시 자동 진화 조건을 다시 본다.
		checkAutoComplete(player, profile)
		return
	end
	if matched then
		advance(player, profile)
	end
end

-- [2026-07-27 W1Q05V] 무기 판매 훅 소비자 — 어떤 무기든 1회(Target 없음)
local function onWeaponSold(player, _weaponId)
	local profile = getLoadedProfile(player)
	if not profile then
		return
	end
	local quest = currentQuest(profile)
	if quest and quest.Type == "SellWeapon" then
		advance(player, profile)
	end
end

-- [2026-08-09 W1Q07P] 포션 구매 훅 소비자 — 아무 포션이나 구매 수량만큼 진행(1회 구매 다수량 = 반복 advance).
-- 재발화 가능 타입(상점 상시 오픈)이라 checkAutoComplete 소급 없음 — Kill 타입 규약 동일.
local function onPotionBought(player, itemId, count)
	local profile = getLoadedProfile(player)
	if not profile then
		return
	end
	for _ = 1, math.max(1, tonumber(count) or 1) do
		local quest = currentQuest(profile)
		if not quest or quest.Type ~= "BuyPotion" then
			return
		end
		-- [2026-08-10 사장님] Target 지정 퀴(HpM 등)는 해당 포션만 인정 — 미지정(nil)은 종전대로 아무 포션
		if quest.Target ~= nil and quest.Target ~= itemId then
			return
		end
		advance(player, profile)
	end
end

-- [W1Q05E] 강화 훅 소비자 — 🔴성공만 집계(실패·하락·깨짐 미집계). 목표문이 "강화 성공하기"라 표기와 어긋난다.
-- 이 시점 강화석 4개 보유(보스 확정 드랍 당근대장 2 + 짚뭉치왕 2) + +1 성공률 100%라 막힐 위험 없음.
local function onEnhanced(player, result)
	local profile = getLoadedProfile(player)
	if not profile then
		return
	end
	local quest = currentQuest(profile)
	if quest and quest.Type == "Enhance" and result == "success" then
		advance(player, profile)
	end
end

local function onPortalRegistered(player, portalId)
	local profile = getLoadedProfile(player)
	if not profile then
		return
	end
	local quest = currentQuest(profile)
	if quest and quest.Type == "Portal" and quest.Target == portalId then
		advance(player, profile)
	end
end

-- 여러 지급/레벨 콜백이 같은 프레임에 겹쳐도 유저당 직렬 펌프 하나만 진화 판정을 실행한다.
local evolutionRechecks = {}

local function requestEvolutionRecheck(player, reconcilePast)
	local state = evolutionRechecks[player]
	if state then
		state.requested = true
		state.reconcilePast = state.reconcilePast or reconcilePast == true
		return
	end
	state = { requested = true, reconcilePast = reconcilePast == true }
	evolutionRechecks[player] = state
	task.defer(function()
		while state.requested and player.Parent == Players do
			state.requested = false
			local runReconcile = state.reconcilePast
			state.reconcilePast = false
			local ok, err = xpcall(function()
				local profile = getLoadedProfile(player)
				if not profile then
					return
				end
				if runReconcile then
					WeaponEvolutionService.Reconcile(player, profile)
				end
				local quest = currentQuest(profile)
				if quest and quest.Type == "Evolution" then
					checkAutoComplete(player, profile)
				end
			end, debug.traceback)
			if not ok then
				warn("[QuestChain] evolution recheck failed:", err)
			end
		end
		evolutionRechecks[player] = nil
	end)
end

function QuestChainService.GetState(player)
	local profile = getLoadedProfile(player)
	if not profile then
		return nil
	end
	local quest = currentQuest(profile)
	return {
		index = profile.QuestChain.Index,
		progress = profile.QuestChain.Progress,
		questId = quest and quest.Id or nil,
		waitingZone = waitingZoneForIndex(profile.QuestChain.Index),
	}
end

-- Studio 디버그 전용(DebugService 브리지 경유)
function QuestChainService._debugKill(player, monsterId, times)
	if not RunService:IsStudio() then
		return "Studio 전용"
	end
	local applied = 0
	for _ = 1, math.max(1, times or 1) do
		if applyKillCredit(player, monsterId) then
			applied += 1
		end
	end
	return { applied = applied, state = QuestChainService.GetState(player) }
end

function QuestChainService._debugSet(player, index, progress)
	if not RunService:IsStudio() then
		return "Studio 전용"
	end
	local profile = getLoadedProfile(player)
	if not profile then
		return "프로필 미로드"
	end
	local requestedIndex = math.clamp(index or 1, 1, #CHAIN + 1)
	local normalizedIndex = nextPlayableIndex(requestedIndex)
	profile.QuestChain.Index = normalizedIndex
	profile.QuestChain.Progress = normalizedIndex == requestedIndex and math.max(0, progress or 0) or 0
	ensureWorld2Portal(player, profile)
	DataService.MarkDirty(player, SAVE_REASON)
	publish(player, profile)
	PlayerService.SyncState(player, { "QuestChain", "Portals" })
	DataService.ForceSave(player, SAVE_REASON)
	return QuestChainService.GetState(player)
end

-- [2026-07-27] 재로그인 시뮬레이션(Studio 전용) — OnLoaded 경로와 동일 순서로 reconcile→publish→소급 완료.
-- 삽입/마이그레이션 회귀 검증용(실제 재입장 없이 구 세이브 복원을 재현) — 프로덕션 호출자 없음.
function QuestChainService._debugReload(player, clearStamp)
	if not RunService:IsStudio() then
		return "Studio 전용"
	end
	local profile = getLoadedProfile(player)
	if not profile then
		return "프로필 미로드"
	end
	if clearStamp then
		profile.QuestChain.QuestId = nil -- 구 세이브(2026-07-21 이전) 재현 — LEGACY_INDEX_MAP 경로로 보낸다
	end
	local before = profile.QuestChain.Index
	local deprecated = reconcileChain(profile)
	local migratedReward = grantDeprecatedMigrationReward(player, profile, deprecated)
	local afterReconcile = profile.QuestChain.Index
	WeaponEvolutionService.Reconcile(player, profile)
	publish(player, profile)
	checkAutoComplete(player, profile)
	if migratedReward then
		PlayerService.SyncState(player, { "QuestChain", "Profile", "Inventory", "Flags", "WeaponEvolution" })
		DataService.ForceSave(player, "DeprecatedQuestMigration")
	end
	return {
		before = before,
		afterReconcile = afterReconcile,
		afterAutoComplete = profile.QuestChain.Index,
		questId = profile.QuestChain.QuestId,
	}
end

function QuestChainService.Init()
	local servicesFolder = script.Parent
	DataService = require(servicesFolder:WaitForChild("DataService"))
	PlayerService = require(servicesFolder:WaitForChild("PlayerService"))
	CombatService = require(servicesFolder:WaitForChild("CombatService"))
	CraftService = require(servicesFolder:WaitForChild("CraftService"))
	LootService = require(servicesFolder:WaitForChild("LootService"))
	ShopService = require(servicesFolder:WaitForChild("ShopService")) -- [W1Q05V] 순환 없음(Shop은 QuestChain 비참조)
	AnalyticsService = require(servicesFolder:WaitForChild("AnalyticsService"))
	SkillService = require(servicesFolder:WaitForChild("SkillService")) -- [W1Q06S] 순환 없음(Skill은 QuestChain 비참조)
	WeaponEvolutionService = require(servicesFolder:WaitForChild("WeaponEvolutionService"))
end

function QuestChainService.Start()
	CombatService.OnKilled(onMonsterKilled)
	CombatService.OnDamageConfirmed(onWeaponDamageConfirmed)
	CraftService.OnCrafted(onCrafted)
	if LootService and type(LootService.OnItemGranted) == "function" then
		LootService.OnItemGranted(function(player)
			requestEvolutionRecheck(player, false)
		end)
	end
	if ShopService and type(ShopService.OnTransactionSucceeded) == "function" then
		ShopService.OnTransactionSucceeded(function(player)
			requestEvolutionRecheck(player, false)
		end)
	end
	if PlayerService and type(PlayerService.OnLevelChanged) == "function" then
		PlayerService.OnLevelChanged(function(player)
			requestEvolutionRecheck(player, true)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		evolutionRechecks[player] = nil
	end)
	-- [2026-07-27 학습 퀘 3종] 판매·강화 훅 구독(Portal 훅 가드 패턴 — 미구현 서비스에도 부팅 안전)
	if ShopService and type(ShopService.OnWeaponSold) == "function" then
		ShopService.OnWeaponSold(onWeaponSold)
	end
	-- [2026-08-09 W1Q07P] 포션 구매 훅 구독(가드 패턴)
	if ShopService and type(ShopService.OnPotionBought) == "function" then
		ShopService.OnPotionBought(onPotionBought)
	end
	if type(CraftService.OnEnhanced) == "function" then
		CraftService.OnEnhanced(onEnhanced)
	end
	-- 훅이 있으면 자동 구독(없으면 Q16은 대기 상태)
	if type(PlayerService.OnPortalRegistered) == "function" then
		PlayerService.OnPortalRegistered(onPortalRegistered)
	end
	-- [2026-07-21 W1Q06S] 스킬 제본 훅 구독(Portal 훅 가드 패턴)
	if SkillService and type(SkillService.OnBound) == "function" then
		SkillService.OnBound(onSkillBound)
	end
	Net.Event("RequestCompleteStoryIntro").OnServerEvent:Connect(completeStoryIntro)
	DataService.OnLoaded(function(player, profile)
		local deprecated = reconcileChain(profile) -- Id 기반 재정렬 + 제거된 W1Q02 즉시 건너뛰기
		local migratedReward = grantDeprecatedMigrationReward(player, profile, deprecated)
		WeaponEvolutionService.Reconcile(player, profile) -- 조건 달성 구유저 조용한 소급 지급(현재 비Starter 장착 보존)
		ensureWorld2Portal(player, profile) -- 기존 DONE/완주 유저 소급 해금
		syncStoryIntroState(player, profile)
		publish(player, profile)
		local loadedQuest = currentQuest(profile)
		if loadedQuest then
			AnalyticsService.QuestStarted(player, loadedQuest.Id)
		end
		DataService.MarkDirty(player, SAVE_REASON) -- QuestId 스탬프/시프트·파생 포탈 영속화(저장은 디바운스 경로)
		checkAutoComplete(player, profile) -- 제본·포탈·제작·판매·강화 소급 완료(연쇄 재귀)
		if profile.QuestChain.Index > (QuestChainDefs.W1Count or #CHAIN) then
			fireCh2Teaser(player, profile) -- 기존 챕터1 완주 유저 소급 1회
		end
		if migratedReward then
			PlayerService.SyncState(player, { "QuestChain", "Profile", "Inventory", "Flags", "WeaponEvolution" })
			DataService.ForceSave(player, "DeprecatedQuestMigration")
		end
	end)
end

return QuestChainService
