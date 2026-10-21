local WeaponTypeDefs = {}

WeaponTypeDefs.DEFAULT = "OneHandSword"

-- ConeAngleDeg는 좌우 합산 총각도다. 서버가 소비하는 ConeCos는 반각에서 파생해 한 곳에서만 관리한다.
local function hitProfile(coneAngleDeg, maxTargets, secondaryFalloff)
	return {
		ConeAngleDeg = coneAngleDeg,
		ConeCos = math.cos(math.rad(coneAngleDeg * 0.5)),
		MaxTargets = maxTargets,
		SecondaryFalloff = secondaryFalloff,
	}
end

-- Combat = V2 전투 프로필(쿨다운·사거리·치명률·지상 평타 판정) — V2 켜지면 레거시 Kinds를 대체한다.
-- NormalMonsterControl은 일반 몬스터 지상 평타 피격에만 적용하며, 보스·대시·공중·스킬에는 적용하지 않는다.
-- 🔴수치 변경 시 반드시 무기 Atk 재시뮬 — DPS 곡선 보존 역산 방식(최신: tools/balance_sim_speed_r1.js)
-- [2026-08-20 공속 개편] 오너 지시(애니·타격음 불일치) — 전 타입 쿨다운 -18~19%(서열 유지),
--   전 무기 80종 Atk를 DPS 보존 역산으로 동시 재배분(TTK·매크로 밸런스 불변). 구값: 0.96/0.88/0.62/1.10/0.80/1.00.
WeaponTypeDefs.Types = {
	Trident = {
		DisplayKey = "WeaponType.Trident", NameKo = "삼지창", CraftUnlockLevel = 6, AnimationSet = "Trident", FxProfile = "Pierce", EquipProfile = "Single", LegacyKind = "Sword",
		UI = {
			RoleKey = "AreaControl", RoleKo = "광역·제압",
			DescriptionKo = "넓은 전방을 덮어 다수의 적을 제압하는 광역형 무기입니다.",
			Metrics = { Speed = 2, Range = 4, Area = 5, Mobility = 2, Stagger = 3 },
		},
		Combat = {
			Cooldown = 0.78, Range = 7.3, CritChance = 0.22, AnimationSpeedScale = 0.96,
			HitProfile = hitProfile(145, 4, 0.65),
			NormalMonsterControl = { KnockbackScale = 1.02, StunScale = 1.02 },
		},
	},
	Spear = {
		DisplayKey = "WeaponType.Spear", NameKo = "창", CraftUnlockLevel = 3, AnimationSet = "Spear", FxProfile = "Pierce", EquipProfile = "Single", LegacyKind = "Sword",
		UI = {
			RoleKey = "Pierce", RoleKo = "관통",
			DescriptionKo = "좁은 정면을 길게 찔러 후열까지 관통하는 장거리 무기입니다.",
			Metrics = { Speed = 3, Range = 5, Area = 2, Mobility = 3, Stagger = 2 },
		},
		Combat = {
			Cooldown = 0.72, Range = 8.0, CritChance = 0.12, AnimationSpeedScale = 1.00,
			HitProfile = hitProfile(80, 3, 1.00),
			NormalMonsterControl = { KnockbackScale = 1.04, StunScale = 0.98 },
		},
	},
	DualBlades = {
		DisplayKey = "WeaponType.DualBlades", NameKo = "쌍검", CraftUnlockLevel = 6, AnimationSet = "DualBlades", FxProfile = "DualSlash", EquipProfile = "Dual", LegacyKind = "Sword",
		UI = {
			RoleKey = "RapidPursuit", RoleKo = "연격·추격",
			DescriptionKo = "빠르게 파고들며 두 대상을 연속 압박하는 추격형 무기입니다.",
			Metrics = { Speed = 5, Range = 1, Area = 2, Mobility = 5, Stagger = 1 },
		},
		Combat = {
			Cooldown = 0.50, Range = 4.5, CritChance = 0.18, AnimationSpeedScale = 1.08,
			HitProfile = hitProfile(90, 2, 1.00),
			NormalMonsterControl = { KnockbackScale = 0.94, StunScale = 0.94 },
		},
	},
	HeavyWeapon = {
		DisplayKey = "WeaponType.HeavyWeapon", NameKo = "대형무기", CraftUnlockLevel = 9, AnimationSet = "HeavyWeapon", FxProfile = "Heavy", EquipProfile = "TwoHand", LegacyKind = "Hammer",
		UI = {
			RoleKey = "CrushStagger", RoleKo = "분쇄·경직",
			DescriptionKo = "묵직한 타격으로 적을 밀어내고 오래 경직시키는 분쇄형 무기입니다.",
			Metrics = { Speed = 1, Range = 3, Area = 4, Mobility = 1, Stagger = 5 },
		},
		Combat = {
			Cooldown = 0.90, Range = 5.9, CritChance = 0.25, AnimationSpeedScale = 0.88,
			HitProfile = hitProfile(120, 3, 0.85),
			NormalMonsterControl = { KnockbackScale = 1.10, StunScale = 1.10 },
		},
	},
	OneHandSword = {
		DisplayKey = "WeaponType.OneHandSword", NameKo = "한손검", CraftUnlockLevel = 1, AnimationSet = "OneHandSword", FxProfile = "Slash", EquipProfile = "Single", LegacyKind = "Sword",
		UI = {
			RoleKey = "Balanced", RoleKo = "균형",
			DescriptionKo = "속도와 범위, 기동성을 고르게 갖춘 균형형 무기입니다.",
			Metrics = { Speed = 4, Range = 2, Area = 3, Mobility = 4, Stagger = 2 },
		},
		Combat = {
			Cooldown = 0.65, Range = 5.2, CritChance = 0.15, AnimationSpeedScale = 1.03,
			HitProfile = hitProfile(110, 3, 0.70),
			NormalMonsterControl = { KnockbackScale = 1.00, StunScale = 1.00 },
		},
	},
	TwoHandSword = {
		DisplayKey = "WeaponType.TwoHandSword", NameKo = "양손검", CraftUnlockLevel = 4, AnimationSet = "TwoHandSword", FxProfile = "HeavySlash", EquipProfile = "TwoHand", LegacyKind = "Sword",
		UI = {
			RoleKey = "SweepFinish", RoleKo = "휩쓸기·마무리",
			DescriptionKo = "넓은 범위를 휩쓸고 후속 대상까지 강하게 마무리하는 대검입니다.",
			Metrics = { Speed = 2, Range = 4, Area = 5, Mobility = 3, Stagger = 4 },
		},
		Combat = {
			Cooldown = 0.82, Range = 6.6, CritChance = 0.20, AnimationSpeedScale = 0.92,
			HitProfile = hitProfile(145, 4, 0.75),
			NormalMonsterControl = { KnockbackScale = 1.06, StunScale = 1.07 },
		},
	},
}
WeaponTypeDefs.Order = { "Trident", "Spear", "DualBlades", "HeavyWeapon", "OneHandSword", "TwoHandSword" }
-- 제작술 해금 순서. 전투 타입 표시 순서와 분리해 레벨업 알림·소급 마이그레이션을 결정적으로 유지한다.
WeaponTypeDefs.CraftUnlockOrder = { "OneHandSword", "Spear", "TwoHandSword", "Trident", "DualBlades", "HeavyWeapon" }

WeaponTypeDefs.LegacyByKind = {
	Starter = "OneHandSword",
	Sword = "OneHandSword",
	Hammer = "HeavyWeapon",
}

WeaponTypeDefs.ComboDamage = { 1.00, 1.05, 1.10, 1.20, 1.30 }
WeaponTypeDefs.CritMultiplierByMaxCombo = {
	[3] = 1.40,
	[4] = 1.50,
	[5] = 1.70,
}
WeaponTypeDefs.AirDamage = 1.10
WeaponTypeDefs.DashAttackDistance = 5
WeaponTypeDefs.DashAttackDuration = 0.16

function WeaponTypeDefs.Resolve(weaponType, legacyKind)
	if type(weaponType) == "string" and WeaponTypeDefs.Types[weaponType] then
		return weaponType
	end
	return WeaponTypeDefs.LegacyByKind[legacyKind] or WeaponTypeDefs.DEFAULT
end

function WeaponTypeDefs.CraftUnlockLevel(weaponType, legacyKind)
	local resolved = WeaponTypeDefs.Resolve(weaponType, legacyKind)
	local typeDef = WeaponTypeDefs.Types[resolved]
	return math.max(1, math.floor(tonumber(typeDef and typeDef.CraftUnlockLevel) or 1))
end

function WeaponTypeDefs.IsCraftUnlockEnabled(gameConfig, isStudio)
	local config = gameConfig and gameConfig.WEAPON_TYPE_CRAFT_UNLOCK
	return config ~= nil and (config.Enabled == true or (isStudio and config.StudioPreview == true))
end

-- 저장 원장이 우선이며, 레벨 조건도 즉시 인정한다. 원장은 향후 요구 레벨이 바뀌어도 이미 얻은 제작술을 보존한다.
function WeaponTypeDefs.IsCraftUnlocked(unlocks, weaponType, legacyKind, level, gameConfig, isStudio)
	if not WeaponTypeDefs.IsCraftUnlockEnabled(gameConfig, isStudio) then
		return true
	end
	local resolved = WeaponTypeDefs.Resolve(weaponType, legacyKind)
	if type(unlocks) == "table" and unlocks[resolved] == true then
		return true
	end
	return math.floor(tonumber(level) or 0) >= WeaponTypeDefs.CraftUnlockLevel(resolved)
end

function WeaponTypeDefs.MaxCombo(enhance, enabled)
	if not enabled then
		return 4
	end
	local level = math.clamp(math.floor(tonumber(enhance) or 0), 0, 10)
	if level <= 3 then
		return 3
	elseif level <= 7 then
		return 4
	end
	return 5
end

function WeaponTypeDefs.CritMultiplier(maxCombo)
	return WeaponTypeDefs.CritMultiplierByMaxCombo[maxCombo] or 1.50
end

function WeaponTypeDefs.IsEnabled(gameConfig, isStudio)
	local config = gameConfig and gameConfig.WEAPON_COMBAT_V2
	return config ~= nil and (config.Enabled == true or (isStudio and config.StudioPreview == true))
end

return WeaponTypeDefs
