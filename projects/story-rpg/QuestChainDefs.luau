-- 시스템 퀘스트 체인: 월드1 16개 저장 슬롯(15개 플레이 퀘스트) + 월드2 21단계. 실제 Chain에는 GameConfig.CH2.ReleasedQuestCount까지만 병합한다.
-- 🔴월드2 게이트는 #Chain이 아니라 W1Count를 쓴다(병합 시 #Chain=37로 늘어나므로) — 소비처 4곳 일괄 전환 완료
--   (TeleportController·PlayerService·CodexDefs·LumiDefs).
-- Type→훅: Kill/Boss=CombatService.OnKilled(기여자 크레딧·막타 무관, Target=모델 MonsterId) · UseWeapon=CombatService.OnDamageConfirmed(Target=MonsterId, RequiredWeapon=WeaponId) · Craft=CraftService.OnCrafted(Target=티어 Id)
--   Skill=SkillService.OnBound(Target=스킬 Id) · CraftRegion=CraftService.OnCrafted(Target=WeaponDefs Region, 해당 지역 무기 아무거나 1자루)
--   SellWeapon=ShopService.OnWeaponSold(Target 없음, 1회) · Enhance=CraftService.OnEnhanced(Target 없음, 🔴성공 1회만 — 실패/하락/깨짐 미집계)
--   BuyPotion=ShopService.OnPotionBought(Target 없음, 아무 포션이나 누적 Count개 — 재발화 가능 타입이라 소급 없음)
-- ⚠뒤 3종(CraftRegion/SellWeapon/Enhance)은 이벤트 재발화가 없어 QuestChainService가 보유 상태로 소급 완료한다(베타 유저 재수행 방지)
-- Reward.Items = { {itemId, count, bucket?} } — bucket="Quest"면 QuestMaterials(거래 불가), itemId=SkillFrag는 Inventory.SkillFragments 버킷
-- OnboardStep = 온보딩 퍼널(16스텝) 번호. 생략=비관측. ⚠메인 퀘 퍼널(MainQuestCh1)은 체인 인덱스 1:1이라 필드 불요
-- 표시 오버라이드(선택·UI 3소비처+Craft 해금문 공용): TitleKo=목표문 전체 교체 · TargetKo=대상 표시명 · IconWeapon=아이콘 무기(WeaponDefs.Weapons 키)

-- 16개 저장 슬롯(플레이 퀘스트 15개): 당근 사냥→C1 자동 진화→당근보스→볏짚→**Lv.6 S1 자동 진화**→짚찌왕→판매→강화→진흙
--   →진흙보스→**포션구매**→나무→나무장군→벽돌→벽돌대왕→늑대. Index 2는 구 세이브 호환용 숨은 tombstone이다.
-- 🔴[2026-08-09 밸런스] ①볏짚 진화(W1Q05C)를 짚찌왕 앞으로 스왑(초보가 C1로 보스를 치던 순서 결함 — 시뮬 사망 4.59→2.13)
--   ②W1Q07P(포션 구매 학습) 신설 = Index 11, 이후 전부 +1 밀림. 구세이브 W1Q05C 스탬프는 QuestChainService.reconcileChain이 W1Q05V로 특례 remap(보스 재킬 방지).
-- 바위 사냥·T2~T4 제작·포탈 퀘는 체인에서 제외(자유 콘텐츠로 존치 — 티어 해금은 UnlockQuestIndex, 월드2=체인 완주).
-- ⚠구 세이브가 새 체인 범위 밖이면 clamp로 체인 완주 취급됨(QuestChainService._debugSet 참조).
-- 🔴[2026-07-27 W1Q05C/V/E 삽입] Index 6 이상이 +3 밀림. 구 세이브 복구는 QuestChainService가 2경로:
--   ①QuestId 스탬프 보유 = Id 재해석(영구 안전) ②스탬프 없음(구 12단계) = LEGACY_INDEX_MAP 표. 둘 다 신설 3퀘는 건너뛴다.
-- 🔴Index 참조처(WeaponDefs.UnlockQuestIndex·Tiers) 일괄 갱신 완료: S=4 · M=9 · W=12 · B=14 · X1=17 (2026-08-09 W1Q07P 삽입으로 11 이상 +1).
local QuestChainDefs = {
	Chain = {
		-- [2026-08-24] 기본 보상 Exp 48은 4킬 EXP와 합쳐 첫 완료 순간 레벨업을 보장한다.
		-- [2026-08-26] 제거한 W1Q02 보상 Exp 100을 함께 합산해 현재 148이며, Gold·포션도 같은 원칙으로 보존한다.
		{ Id = "W1Q01", Type = "Kill",  Target = "Carrot",     Count = 4,  Reward = { Exp = 148, Gold = 150, Items = { { "HpS", 3 }, { "MpS", 2 } } } }, -- [2026-08-10] 8→4(사장님 — 온보딩 가속)
		-- 저장/분석 인덱스 호환용 비표시 tombstone. 구 W1Q02 유저에게만 MigrationReward를 지급하고 W1Q03으로 즉시 이동한다.
		{ Id = "W1Q02", Deprecated = true, ResumeId = "W1Q03", MigrationReward = { Exp = 100, Gold = 105, Items = { { "HpS", 2 }, { "MpS", 2 } } } },
		{ Id = "W1Q03", Type = "Boss",  Target = "CarrotBoss", Count = 1,  Reward = { Exp = 140, Gold = 150, Items = { { "HpS", 2 } } }, OnboardStep = 7 },
		{ Id = "W1Q04", Type = "Kill",  Target = "Straw",      Count = 8, Reward = { Exp = 160, Gold = 165, Items = { { "Rope", 3, "Quest" } } }, OnboardStep = 8 },
		{ Id = "W1Q05C", Type = "Evolution", Target = "S1", Count = 1, EvolutionStage = 2, TitleKo = "볏짚 삼갈래창으로 진화하기", TargetKo = "볏짚 삼갈래창", IconWeapon = "S1", Reward = { Exp = 150, Gold = 150, Items = { { "MpS", 2 } } }, OnboardStep = 9 }, -- W1Q04 완료 + Lv.6 달성 즉시 비용 없이 같은 성장 코어 자동 진화
		{ Id = "W1Q05", Type = "Boss",  Target = "StrawBoss",  Count = 1,  Reward = { Exp = 220, Gold = 225, Items = { { "HpM", 2 }, { "MpS", 2 } } }, OnboardStep = 10 },
		{ Id = "W1Q05V", Type = "SellWeapon", SellTarget = "Starter", Count = 1, TitleKo = "쓰지 않는 무기 팔기", TargetKo = "시작 무기 판매", Reward = { Exp = 120, Gold = 90, Items = { { "HpS", 2 } } }, OnboardStep = 11 },
		{ Id = "W1Q05E", Type = "Enhance",     Count = 1, TitleKo = "무기 강화 성공하기", TargetKo = "무기 강화", Reward = { Exp = 150, Gold = 150, Items = { { "HpM", 2 } } }, OnboardStep = 12 },
		{ Id = "W1Q06", Type = "Kill",  Target = "Mud",        Count = 12, Reward = { Exp = 240, Gold = 240, Items = { { "SkillFrag", 3 }, { "MudBall", 3, "Quest" } } } , OnboardStep = 13 },
		{ Id = "W1Q07", Type = "Boss",  Target = "MudBoss",    Count = 1,  Reward = { Exp = 300, Gold = 285, Items = { { "HpM", 2 } } }, OnboardStep = 14 },
		{ Id = "W1Q07P", Type = "BuyPotion", Target = "HpM", Count = 1, TitleKo = "상점에서 중형 체력 포션 1개 사기", TargetKo = "포션 구매", Reward = { Exp = 150, Gold = 150, Items = { { "HpM", 1 } } } }, -- [2026-08-10 사장님] 3개→중형 체력 1개(Target 필터 신설)
		-- [2026-08-24] Count 18→12 + Branch 보상 4→9 (동시 변경 필수 — 따로 바꾸면 안 된다).
		--   MainQuestCh1 실측: Q07P→Q08 통과 73.0% = 챕터1 후반 최대 절벽. 마진 킬당 이탈 1.735%/킬.
		--   재료 결합: 드랍 75% → 18킬=13.5+4=17.5 / 12킬=9.0+4=13.0.
		--   지역 최저가 무기 W1(Branch 18)을 못 만들게 되므로 보상 9로 보정 → 9.0+9=18.0.
		{ Id = "W1Q08", Type = "Kill",  Target = "Wood",       Count = 12, Reward = { Exp = 340, Gold = 450, Items = { { "Branch", 9, "Quest" } } } }, -- [2026-08-20 재밸런스 D4] Gold 300→450
		{ Id = "W1Q09", Type = "Boss",  Target = "WoodBoss",   Count = 1,  Reward = { Exp = 400, Gold = 360, Items = { { "HpM", 2 } } } },
		-- [2026-08-24] Count 18→12 + Stone 보상 4→9 (W1Q08과 동일 근거·동일 재료 보정).
		--   실측: Q09→Q10 통과 81.2% · 마진 킬당 1.151%/킬 → 12킬 시 87.0%.
		{ Id = "W1Q10", Type = "Kill",  Target = "Brick",      Count = 12, Reward = { Exp = 440, Gold = 610, Items = { { "Stone", 9, "Quest" } } } }, -- [2026-08-20 재밸런스 D4] Gold 360→610
		{ Id = "W1Q11", Type = "Boss",  Target = "BrickBoss",  Count = 1,  Reward = { Exp = 520, Gold = 390, Items = { { "HpL", 1 } } }, OnboardStep = 15 },
		{ Id = "W1Q12", Type = "Boss",  Target = "Wolf",       Count = 1,  Reward = { Exp = 800, Gold = 750, Items = { { "HpL", 1 } } }, OnboardStep = 16 },
	},
}

-- 월드1 체인 길이(고정) — 월드2 진입 게이트·퍼널 분기(MainQuestCh2)의 기준값. 🔴W1 퀘 삽입/삭제 시 함께 갱신.
QuestChainDefs.W1Count = 16

-- ===== [2026-08-20 챕터2 확정 수치 v1] 월드2 전체 설계 21단계 (인덱스 17~37) =====
-- 보상 XP 합 12,075 · 골드 합 13,930 = 시뮬 r14 검증값(임의 변경 시 재시뮬).
-- 킬 퀘 대상 = 구역 내 빠름/중간 몹 로테이션(재료 파밍과 자연 중첩).
-- 🔴W2Q04/W2Q09 = 전투 동작 티칭 예약 슬롯(올려치기·공중 연계 / 강공격) — 동작 배선 전까지 소형 Kill로 운영,
--   배선 시 같은 인덱스에서 Type만 교체(인덱스 불변 = 세이브 안전). 보상은 그대로.
-- 진입 게이트 = 체인 자체(완주자만 인덱스 17 도달) · 무기 티어 게이트 = WeaponDefs UnlockQuestIndex(17/22/27/31/37).
QuestChainDefs.ChainW2 = {
	{ Id = "W2Q01", Type = "Kill",  Target = "Wisp",         Count = 16, TitleKo = "길 잃은 파란불을 물리쳐 도깨비 방망이의 소원 기운 추적하기", TargetKo = "길 잃은 파란불", Reward = { Exp = 210, Gold = 280 } },
	{ Id = "W2Q02", Type = "CraftRegion", Target = "GoblinForest", Count = 1, TitleKo = "숲의 마력으로 방망이 흔적을 좇을 무기 만들기", TargetKo = "숲 무기", IconWeapon = "FW8", Reward = { Exp = 245, Gold = 320 } },
	{ Id = "W2Q03", Type = "Kill",  Target = "Bat",          Count = 22, TitleKo = "조각도둑 밤박쥐를 물리쳐 훔쳐 간 흔적 되찾기", TargetKo = "조각도둑 밤박쥐", Reward = { Exp = 315, Gold = 400 } },
	{ Id = "W2Q04", Type = "Kill",  Target = "Mushroom",     Count = 8, TitleKo = "꾸벅 달빛버섯을 깨워 숨어든 소원 기운 거두기", TargetKo = "꾸벅 달빛버섯", Reward = { Exp = 175, Gold = 200 } }, -- 동작 티칭(올려치기·공중 연계) 예약 슬롯
	{ Id = "W2Q05", Type = "Boss",  Target = "ForestKeeper", Count = 1, TitleKo = "이끼갑옷 숲지기를 쓰러뜨려 숲의 첫 봉인 풀기", TargetKo = "이끼갑옷 숲지기", Reward = { Exp = 630, Gold = 700 } },
	{ Id = "W2Q09", Type = "Kill",  Target = "GoblinDrum",   Count = 10, TitleKo = "쿵짝 도깨비북을 멈춰 왕좌로 이어지는 비밀 장단 해독하기", TargetKo = "쿵짝 도깨비북", Reward = { Exp = 210, Gold = 250 } }, -- 동작 티칭(강공격) 예약 슬롯
	{ Id = "W2Q08", Type = "Kill",  Target = "MagicJar",     Count = 24, TitleKo = "덜컹 요술독을 깨워 갇혀 있던 방망이의 기억 꺼내기", TargetKo = "덜컹 요술독", Reward = { Exp = 455, Gold = 560 } },
	{ Id = "W2Q07", Type = "CraftRegion", Target = "GoblinVillage", Count = 1, TitleKo = "마을의 요술 흔적을 깨뜨릴 무기 만들기", TargetKo = "마을 무기", IconWeapon = "VJ8", Reward = { Exp = 315, Gold = 420 } },
	{ Id = "W2Q06", Type = "Kill",  Target = "GoblinBaby",   Count = 18, TitleKo = "까불이 꼬마깨비를 혼내 방망이 소문의 행방 알아내기", TargetKo = "까불이 꼬마깨비", Reward = { Exp = 350, Gold = 450 } },
	{ Id = "W2Q10", Type = "Boss",  Target = "MotherGoblin", Count = 1, TitleKo = "호통 큰 엄마깨비를 쓰러뜨려 마을의 두 번째 봉인 풀기", TargetKo = "호통 큰 엄마깨비", Reward = { Exp = 840, Gold = 900 } },
	{ Id = "W2Q11", Type = "Kill",  Target = "DanceGoblin",  Count = 20, TitleKo = "빙글빙글 춤깨비를 물리쳐 잔치판의 홀림 마법 흐트러뜨리기", TargetKo = "빙글빙글 춤깨비", Reward = { Exp = 490, Gold = 620 } },
	{ Id = "W2Q12", Type = "CraftRegion", Target = "GoblinFeast", Count = 1, TitleKo = "잔치의 취기 마법을 가를 무기 만들기", TargetKo = "잔치 무기", IconWeapon = "JD8", Reward = { Exp = 385, Gold = 500 } },
	{ Id = "W2Q13", Type = "Kill",  Target = "DrinkSpirit",  Count = 26, TitleKo = "술렁 술독정령을 잠재워 취기 속 신전 단서 찾기", TargetKo = "술렁 술독정령", Reward = { Exp = 630, Gold = 780 } },
	{ Id = "W2Q14", Type = "Boss",  Target = "FeastGoblin",  Count = 1, TitleKo = "끝없는 잔치대감을 쓰러뜨려 세 번째 봉인을 풀고 신전길 열기", TargetKo = "끝없는 잔치대감", Reward = { Exp = 1050, Gold = 1150 } },
	{ Id = "W2Q15", Type = "Kill",  Target = "WispMage",     Count = 18, TitleKo = "주문 외는 푸른불을 물리쳐 닫힌 신전길 밝히기", TargetKo = "주문 외는 푸른불", Reward = { Exp = 560, Gold = 700 } },
	{ Id = "W2Q16", Type = "CraftRegion", Target = "GoblinTemple", Count = 1, TitleKo = "신전의 돌 봉인을 깨뜨릴 무기 만들기", TargetKo = "신전 무기", IconWeapon = "TG8", Reward = { Exp = 455, Gold = 600 } },
	{ Id = "W2Q17", Type = "Kill",  Target = "TempleGuard",  Count = 26, TitleKo = "달문 신전수호령의 시험을 넘어 왕좌의 마지막 봉인 열기", TargetKo = "달문 신전수호령", Reward = { Exp = 770, Gold = 950 } },
	{ Id = "W2Q18", Type = "Boss",  Target = "StoneGolem",   Count = 1, TitleKo = "천년 묵은 돌장군을 쓰러뜨려 왕좌의 문 완전히 열기", TargetKo = "천년 묵은 돌장군", Reward = { Exp = 1330, Gold = 1450 } },
	{ Id = "W2Q19", Type = "BuyPotion", Target = "HpL", Count = 2, TitleKo = "왕좌 앞 결전 준비: 대형 체력 포션 2개 사기", TargetKo = "왕좌 앞 결전 준비", Reward = { Exp = 280, Gold = 350 } }, -- 왕 접견 비트 — 왕전 직전 포션 학습(W1Q07P 규약)
	{ Id = "W2Q20", Type = "Boss",  Target = "GoblinKing",   Count = 1, TitleKo = "천둥방망이 도깨비왕을 쓰러뜨려 방망이 세 조각 되찾기", TargetKo = "천둥방망이 도깨비왕", Reward = { Exp = 1820, Gold = 2000, Items = { { "GoblinBatFrag", 2, "Boss" } } } }, -- 확정 드랍 1개+퀘 보상 2개 = 첫 승리 뒤 바로 복원
	{ Id = "W2Q21", Type = "Craft", Target = "K1", Count = 1, TitleKo = "세 조각을 하나로 모아 전설의 도깨비 방망이 복원하기", TargetKo = "전설의 도깨비 방망이", IconWeapon = "K1", Reward = { Exp = 560, Gold = 600 } },
}

-- 챕터2 병합: 오픈 시각 이후 부팅한 서버/Studio에서 공개된 퀘스트까지만 Chain 뒤에 붙인다.
-- 미공개 구역 정의는 ChainW2에 그대로 보존한다. ReleasedQuestCount만 올리면 기존 대기 세이브가 다음 퀘스트부터 재개된다.
local GameConfig = require(script.Parent:WaitForChild("GameConfig"))
local RunService = game:GetService("RunService")
QuestChainDefs.Ch2Merged = GameConfig.IsCh2ContentOn(RunService:IsStudio()) == true

local configuredReleased = tonumber(GameConfig.CH2 and GameConfig.CH2.ReleasedQuestCount) or #QuestChainDefs.ChainW2
configuredReleased = math.clamp(math.floor(configuredReleased), 0, #QuestChainDefs.ChainW2)
QuestChainDefs.ActiveW2Count = QuestChainDefs.Ch2Merged and configuredReleased or 0
QuestChainDefs.WaitingZone = QuestChainDefs.Ch2Merged
	and configuredReleased < #QuestChainDefs.ChainW2
	and tonumber(GameConfig.CH2 and GameConfig.CH2.NextZone)
	or nil
QuestChainDefs.WaitingStamp = QuestChainDefs.WaitingZone and ("WAIT_W2_ZONE%d"):format(QuestChainDefs.WaitingZone) or nil
QuestChainDefs.WaitResumeByStamp = {
	WAIT_W2_ZONE3 = "W2Q11",
	WAIT_W2_ZONE4 = "W2Q15",
	WAIT_W2_ZONE5 = "W2Q19",
}

if QuestChainDefs.Ch2Merged then
	for index = 1, QuestChainDefs.ActiveW2Count do
		table.insert(QuestChainDefs.Chain, QuestChainDefs.ChainW2[index])
	end
end

function QuestChainDefs.IsWaitingIndex(index)
	return QuestChainDefs.WaitingZone ~= nil and tonumber(index) == #QuestChainDefs.Chain + 1
end

return QuestChainDefs
