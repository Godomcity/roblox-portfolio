-- 성장 테이블 — "공격력은 무기가, 생존·쾌적함은 레벨이": BaseAtk 하향(무기 전담).
-- ⚠TEMP: BaseAtk·NextExp 곡선은 임시 — 확정 스펙 도착 시 1:1 교체. Mp는 미공개 마나용.
local LevelDefs = {
	START_LEVEL = 1,
	-- [2026-07-25 P0-1] 레벨업 상한 50→30 + 곡선 ×1.26→×1.22 세트.
	-- 근거: 캡 50은 챕터1 완주로 Lv16(32%)까지밖에 못 가 성장 지표가 멈춰 있었다. 캡30·×1.22면 Lv18(60%).
	-- [QA 2026-08-24 Stage2] cap 30 blocked progression: EXP quests exist but no room to level.
	-- Uncapped to 100. The x1.22 curve now paces growth instead of a hard wall.
	MAX_LEVEL = 100,
	-- 🔴Rows 생성 상한은 레벨업 상한과 반드시 분리한다.
	-- 캡을 내려도 기존 초과 레벨(Lv31+) 유저의 Rows[level]이 살아 있어야 파생치(Hp/Mp/Atk)와
	-- EXP 분모를 그대로 유지할 수 있다. 이 분리가 없으면 clamp가 레벨을 깎거나 nil 인덱싱으로 죽는다.
	ROWS_MAX = 120, -- [QA 2026-08-24] must stay above MAX_LEVEL (see note above)
	POINTS_PER_LEVEL = 3, -- 성장 4축(VIT/MNA/AGI/LCK — StatDefs) 분배

	Rows = {},
}

for level = 1, LevelDefs.ROWS_MAX do
	LevelDefs.Rows[level] = {
		Hp = 100 + 12 * (level - 1),
		-- [2026-07-30 10차 QA] 기본 마나 50→65(사장님 지시).
		-- 근거: 스킬 MP가 열파참 24 · 회오리 30 · 끌어당기기 18 — 50이면 회오리+열파참(54)을
		-- 연속으로 못 썬다. 65면 두 발은 들어간다(실전 최소 단위).
		-- ★레벨업으로는 안 오른다 — PlayerService.computeMaxMp가 Rows[START_LEVEL].Mp만 읽는다(7차 QA 확정).
		-- [2026-08-06 사장님 지시] 65→80. 초반 마나 고갈 완화(버퍼만 증가 — 회복률 불변이라 지속 DPS는 그대로).
		--   근거: 열파참24+끌어당기기18을 쿨마다 쓰면 초당 8.4 필요 vs 회복 4 → 65는 약 15초면 바닥.
		Mp = 80 + 5 * (level - 1),
		Atk = math.round(10 + 1.25 * (level - 1)), -- ⚠TEMP 임시 곡선(무기 몫 84% 원칙 — Lv9=20 역산)
		NextExp = if level < LevelDefs.ROWS_MAX then math.round(60 * 1.22 ^ (level - 1)) else nil,
	}
end

return LevelDefs
