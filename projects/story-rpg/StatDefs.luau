-- 스탯 투자 효과 — 회수(리셋) 불가
local StatDefs = {
	-- STR 없음 — 공격력은 무기 전담
	Order = { "VIT", "MNA", "AGI", "LCK" }, -- [2026-07-25] 단련(TRN) 폐지·마나 공개(순서=스탯창 표시 순)

	-- 포인트당 효과·캅은 LevelDefs·MonsterDefs 수치와 세트로 튜닝됨
	Defs = {
		VIT = { HpPerPoint = 4, NameKo = "체력" }, -- 투자 시 현재 HP도 함께 증가
		-- AGI: 이동속도 + 공격속도. cap50 = 이동 +30% · 공속 -20%(DPS +25%)
		AGI = { SpeedPctPerPoint = 0.006, AtkSpeedPctPerPoint = 0.004, CapPoints = 50, NameKo = "민첩" },
		-- LCK: 드랍확률 + 드랍코인. cap25 = 드랍 +37.5%p · 코인 ×1.63
		LCK = { DropPctPerPoint = 0.015, GoldPctPerPoint = 0.025, CapPoints = 25, NameKo = "행운" },
		-- [2026-07-30 10차 QA] 포인트당 2→3(사장님 지시). 칭 없는 축이라 배율만 올린다 —
		-- 10포인트 투자 기준 총 마나 70 → 95(기본 65 포함).
		MNA = { MpPerPoint = 3, NameKo = "마나" },
	},
}

return StatDefs
