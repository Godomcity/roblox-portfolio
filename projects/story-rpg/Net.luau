-- Net: 리모트 단일 선언·생성·조회. 확장은 DEFS.Events에 이름만 추가
-- 제약: 서버는 Net.Server() 선행 필수(Bootstrap 경로에서 호출), 클라는 대기 조회
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

Net.DEFS = {
	Events = {
		"SkillFx", -- S->C skill cast relay { casterChar, skillId }
		"SkillAcquired", -- [2026-08-05 스킬8종 §2-7] S→C 스킬 획득 모달 트리거 (skillId, source=boss|derive|retro)
		"StateSync", -- S→C 프로필 스냅샷
		"RequestStateSync", -- C→S 초기 StateSync 재요청(클라이언트 로드 경합 복구)
		"RequestAttack", -- C→S 공격 입력 (타겟 선정·판정은 서버)
		"RequestDash", -- C→S 대쉬 회피 요청(서버 쿨다운·생존 검증 후 짧은 피해 무효)
		"EvadeSuccess", -- S→C 대쉬로 실제 피해를 막았을 때 1회 성공 피드백 { pos? }
		"RequestAllocateStat", -- C→S 스탯 투자 (statId)
		"Notice", -- S→C 알림 토스트 { text }
		"OpenCraftUI", -- S→C 대장간 제작 UI 열기
		"RequestCraft", -- C→S 제작 요청 (kind)
		"CraftResult", -- S→C 제작 결과 { kind, gradeId, bonus, atk, uid }
		"RequestEquip", -- C→S 무기 교체 장착 (uid)
		"BossHpSync", -- S→C 보스 체력·기여도 (0.2s 코얼리싱) { hp, maxHp, myDamage, totalDamage, active, thresholdPct }

		"ToggleSprint", -- C→S 달리기 토글 (서버가 WalkSpeed 권위 설정)
		"MonsterHit", -- S→C 가해자 전용 명중 연출 트리거 { pos, model, crit }
		"ShowDamage", -- S→C 데미지 숫자 { pos, dmg, crit }
		"PlayerSwing", -- S→C 타 플레이어 스윙 릴레이 { char, comboIdx }
		"MonsterDeathFx", -- S→C 전체 브로드쯌스트 사망 연출 { pos, monsterId }
		"BossNoReward", -- S→C 기여도 미달 보상 미지급 통지 { myPct, thresholdPct }
		"LootPickupFx", -- S→C 드랍 수거 연출(수거 플레이어 전용) { itemId, pos }
		"RequestResetStats", -- C→S 스탯 초기화(전액 환급)
		"RequestSetSetting", -- C→S 설정 저장 { key, value } (화이트리스트)
		"RequestRedeemCode", -- C→S 프로모션 코드 { code } — 서버 정규화·1회 지급
		"QuestState", -- S→C 퀘체인 상태 { index, progress, questId, target, count }
		"RequestCompleteStoryIntro", -- C→S 첫 스토리 카드 완료/건너뛰기(프로필 1회 원장)
		"OpenRegionRequestStory", -- S→C 돼지 이야기 의뢰 대화 { index, status, progress, count }
		"RequestRegionRequestAction", -- C→S 돼지 이야기 의뢰 선택 (index, "accept"|"claim")
		"QuestReward", -- S→C 퀘 완료 보상 배너 { questId, exp, gold, items[], nextId, evolution?, growth? }
		"WeaponEvolutionFx", -- S→C 자동 진화 연출 { weaponId, uid, stage, duration, weaponAtk, previousAtk, presentation }
		"PlayerKnockback", -- S→C 플레이어 피격 넉백 { dir, force, lift } — 클라 소유 캐릭이라 클라 적용(연출용·검증 불필요)
		"PlayerCc", -- [2026-07-25] S→C CC 상태 통지 { kind = "slow"|"root", sec } — FxController 머리 위 상태 표시
		"OpenShop", -- S→C 라쿤 프롬프트 → 상점 GUI 열기
		"RequestBuy", -- C→S 구매 { itemId, count } — 화이트리스트·1~99·골드·1s 디바운스
		"RequestSell", -- C→S 판매 { itemId, count } — 화이트리스트·재고·퀘 재료(Quest 버킷) 거부·1s
		"RequestTeleport", -- C→S 포탈 이동 { portalId } — 등록 검증·3s 디바운스·월드2 게이트
		"OpenTeleport", -- S→C 등록된 포탈 재상호작용 → 텔레포트 GUI 보조 진입
		"RequestSetCraftGoal", -- C→S 제작 목표 토글 (tier) — 서버 검증(티어 실재·해금) 후 profile.CraftGoal 설정/해제, HUD CraftGoalCard가 StateSync로 소비
		"BossDefeatFx", -- S→C 보스 사망 컷씬 트리거 { bossId } — 기여자(피해 1 이상) 전용, FieldBossService 사망 정산 지점 발화
		"OpenWolfDifficulty", -- S→C 늑대 제단 선택 창 열기
		"OpenCosmeticWardrobe", -- S→C 두더지 ProximityPrompt 검증 후 의상실 열기
		"WolfDifficultyChanged", -- S→C 서버 늑대 난이도 변경 브로드캐스트
		"ReferralGranted", -- S→C 초대 보상 도착 { count } — 약관상 초대자에게 반드시 알려야 한다
		"OfferDaily", -- S→C 오늘치 일일 보상 수령 가능 통지 — 팝업 시점은 OfferController 규칙
		"RewardGranted", -- S→C 자동 지급 토스트 { kind, coins, stones, potions, label }
		"RequestDeclineOffer", -- C→S 판매 제안 거절 { offerId } — 24시간 침묵을 위해 프로필에 시각 기록
		"OpenStore", -- S→C 상점 열기 { tab? }
		"OfferStarterPack", -- S→C 스타터팩 제안 시점(첫 보스 처치 직후) — 표시 여부는 OfferController 규칙이 결정
		"ReportFirstMove", -- [2026-08-10 계측 v3] C→S 첫 이동 입력 1회 보고(FirstRun 퍼널 step2 — 조이스틱 먹통 등 '조작 불능' 이탈 분해)
		"ReportAnalyticsSignal", -- [2026-08-24 계측 v4] C→S UI/가이드 노출 진단(화이트리스트·서버 검증·레이트 제한, 게임 판정 영향 없음)
		"ReportAnimIssue", -- [2026-08-04] C→S 애니 재생 실패 사유 계측(화이트리스트·서버 스로틀) — 지급/판정 없음
		"ShowCommunity", -- [2026-08-04] S→C 커뮤니티 창 자동 표시(짚찌왕 처치 후 생애 1회) — 원장=Flags.CommunityShown(서버 권위)
		"PortalRegistered", -- S→C 포탈 최초 등록 { portalId } — 배너(NoticeController)+월드 이펙트(PortalFxController)
		"ShowCh2Teaser", -- [2026-08-10] S→C 챕터2 티저 모달(완주 1회·도깨비 문 상호작용) — 원장=Flags.Ch2TeaserSeen(상호작용 경로는 원장 무관)
		"RankBoardReady", -- [2026-08-13] S→C 랭킹 보드 갱신 완료 { boardId } — 요청자에게만(클라 폴링 제거)
	},
	-- RemoteFunction 선언 — 반환값이 필요한 C→S 요청만(남용 금지 — 기본은 Events)
	Functions = {
		"GetRanking", -- [2026-08-13] C→S (boardId) → { ok, boardId, ageSec, pending?, rows={{r,uid,n,v}}, me={r?,v} } — 서버 캐시만 읽는다
		"EnhanceWeapon", -- C→S (uid) → {ok, result=success|fail|drop|break, level, reason?} [2026-07-23 강화]
		"SellWeapon", -- C→S (uid) → {ok, gold, stones, reason?} [2026-07-23 무기 판매]
		"SellBulk", -- [2026-08-10] C→S ({ items={{id,count}}, weapons={uid} }) → {ok, gold, stones, itemKinds, weaponCount, reason?}
		--   상점 판매 탭 다중 선택 일괄 판매. 전수 검증 후 일괄 적용(중간 yield 없음) · 1s 디바운스 공유
		"SkillCast",
		"SkillManage", -- C->S (action, skillId) -> { ok, reason?, level? } -- C->S (slotIndex) -> { ok, reason?, cooldownEndsAt? }
		"RequestUsePotion", -- C→S (kind) → {ok, reason, cooldownEndsAt} — 수량·공용쿨3s·만피·Hidden 거부
		"ClaimDaily", -- C→S () → { ok, day, streak, reward } — 날짜·스트릭 판정은 전부 서버
		"UseAtkBuff", -- C→S () → { ok, untilAt, mul, left } — 초대 보상 버프 발동(사용 시점은 플레이어 선택)
		"EquipTitle", -- [2026-07-25 F5] C→S (titleId | "") → {ok, equipped?, reason?} — 보유 검증 서버 권위
		"ToggleCosmetic", -- C→S (cosmeticId) → { ok, equipped?, reason? } — 두더지 16stud 이내 서버 권위 착탈
		"InspectPlayer", -- [2026-08-04] C→S (targetUserId) → 공개 스냅샷 { Level, Atk, MaxHp, MaxMp, Weapon{WeaponId,Enhance,Atk}, TitleId } — 화이트리스트 복사만(경제 정보 비노출)
		"WolfDifficulty", -- C→S ("get"|"set", difficultyId?) → 서버 Wolf 난이도 상태
	},
}

local FOLDER_NAME = "Remotes"
local folder = nil
local serverReady = false -- 최초 1회 생성/검증 후 true — 이후 Server()는 폴더 즉시 반환
local instanceCache = {} -- 이름→RemoteEvent/RemoteFunction (Parent 유실 시 재조회)

-- 서버: Remotes 폴더와 선언된 RemoteEvent 전부 생성(멱등)
function Net.Server()
	if not RunService:IsServer() then
		error("[Net] Server()는 서버 전용")
	end
	if serverReady then
		return folder
	end
	if not folder then
		folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
	end
	for _, name in ipairs(Net.DEFS.Events) do
		if not folder:FindFirstChild(name) then
			local event = Instance.new("RemoteEvent")
			event.Name = name
			event.Parent = folder
		end
	end
	for _, name in ipairs(Net.DEFS.Functions or {}) do
		if not folder:FindFirstChild(name) then
			local fn = Instance.new("RemoteFunction")
			fn.Name = name
			fn.Parent = folder
		end
	end
	serverReady = true
	return folder
end

-- 클라: 서버 생성 완료까지 대기 후 조회
function Net.Client()
	if not folder then
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	end
	return folder
end

-- RemoteFunction 조회 — Event와 동일 규약(서버 선생성·미선언 에러, 클라 대기 조회)
function Net.Function(name: string): RemoteFunction
	local cached = instanceCache[name]
	if cached and cached.Parent then
		assert(cached:IsA("RemoteFunction"), ("[Net] RemoteFunction 타입 불일치: %s"):format(name))
		return cached
	end
	if RunService:IsServer() then
		Net.Server()
		local fn = folder:FindFirstChild(name)
		if not fn then
			error(("[Net] 미선언 리모트 함수: %s"):format(name))
		end
		assert(fn:IsA("RemoteFunction"), ("[Net] RemoteFunction 타입 불일치: %s"):format(name))
		instanceCache[name] = fn
		return fn
	end
	local fn = Net.Client():WaitForChild(name)
	assert(fn:IsA("RemoteFunction"), ("[Net] RemoteFunction 타입 불일치: %s"):format(name))
	instanceCache[name] = fn
	return fn
end

-- 공용 조회: 양쪽에서 동일 호출 형태로 사용
function Net.Event(name: string): RemoteEvent
	local cached = instanceCache[name]
	if cached and cached.Parent then
		assert(cached:IsA("RemoteEvent"), ("[Net] RemoteEvent 타입 불일치: %s"):format(name))
		return cached
	end
	if RunService:IsServer() then
		Net.Server()
		local event = folder:FindFirstChild(name)
		if not event then
			error(("[Net] 미선언 리모트: %s"):format(name))
		end
		assert(event:IsA("RemoteEvent"), ("[Net] RemoteEvent 타입 불일치: %s"):format(name))
		instanceCache[name] = event
		return event
	end
	local event = Net.Client():WaitForChild(name)
	assert(event:IsA("RemoteEvent"), ("[Net] RemoteEvent 타입 불일치: %s"):format(name))
	instanceCache[name] = event
	return event
end

return Net
