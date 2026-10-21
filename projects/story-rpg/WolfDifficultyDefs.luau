-- WolfDifficultyDefs: 늑대 보스 난이도·애니메이션·코스튬 계약
local WolfDifficultyDefs = {}
WolfDifficultyDefs.Default = "Easy"
WolfDifficultyDefs.Order = { "Easy", "Medium", "Hard", "Insane" }
-- 세이브 호환을 위해 내부 ID는 WolfSeal을 유지하고, 플레이어 노출 명칭만 각성석으로 통일한다.
WolfDifficultyDefs.ItemId = "WolfSeal"
WolfDifficultyDefs.ItemNameKo = "늑대 각성석"
WolfDifficultyDefs.DurationSec = 15 * 60
WolfDifficultyDefs.AnimationFolder = "DifficultyAnimations"
WolfDifficultyDefs.AnimationSlots = {
	{ Id="ClawCombo1", Source="GreatShield M1 - 1", Purpose="연속 발톱 1타", Markers="Swing,Hit,Reset" },
	{ Id="ClawCombo2", Source="GreatShield M1 - 2", Purpose="연속 발톱 2타", Markers="Swing,Hit,Reset" },
	{ Id="ClawCombo3", Source="GreatShield M1 - 3", Purpose="연속 발톱 3타", Markers="Swing,Hit,Reset" },
	{ Id="ClawCombo4", Source="GreatShield M1 - 4", Purpose="연속 발톱 4타", Markers="Swing,Hit,Reset" },
	{ Id="ClawCombo5", Source="GreatShield M1 - 5", Purpose="연속 발톱 5타", Markers="Swing,Hit,Reset" },
	{ Id="FrontDash", Source="FrontDash", Purpose="정면 돌진 이동" },
	{ Id="DashAttack", Source="GreatShield Dash Attack", Purpose="돌진 마무리", Markers="Swing,Hit,Reset" },
	{ Id="SideDashLeft", Source="SideDash_Left", Purpose="좌측 측면 이동" },
	{ Id="SideDashRight", Source="SideDash_Right", Purpose="우측 측면 이동" },
	{ Id="BackDash", Source="BacksDash", Purpose="후방 이탈" },
	{ Id="UpTilt", Source="AegisUpTilt", Purpose="공중 사냥 올려치기", Markers="Swing,Hit,Reset" },
	{ Id="AirAttack", Source="GreatShield Air Attack", Purpose="공중 추격", Markers="Swing,Hit,Reset" },
	{ Id="AirSlam", Source="AegisAirSlam", Purpose="낙하 강타", Markers="Swing,Hit,Reset" },
	{ Id="Landing", Source="Landing Animation", Purpose="착지" },
	{ Id="Flinch", Source="Flinch", Purpose="피격 반응 예약" },
	{ Id="Stagger", Source="GreatShield Parried", Purpose="브레이크 경직 예약" },
	{ Id="RunOverride", Source="GreatShield Run", Purpose="달리기 교체", Markers="FootStep x2" },
	{ Id="WalkOverride", Source="GreatShield Walk", Purpose="걷기 교체", Markers="FootStep x2" },
	{ Id="IdleOverride", Source="GreatShield Idle", Purpose="대기 교체 예약" },
	{ Id="BlockIdleReserved", Source="GreatShield Block Idle", Purpose="방어 기믹 예약" },
	{ Id="ClashingReserved", Source="Clashing", Purpose="무기 충돌 기믹 예약" },
	{ Id="Parry1Reserved", Source="Parry1", Purpose="패링 기믹 예약" },
	{ Id="ShieldHeavy", Source="Shield Heavy", Purpose="광기 핏빛 추격 마무리", Markers="Swing,Hit,Reset" },
	{ Id="ParryInitiateReserved", Source="GreatShield Parry Initiate", Purpose="패링 시작 기믹 예약" },
}
-- [2026-08-25] 모든 각성 난이도에서 네 부위를 독립 롤한다. 모자(아바타 정체성/썸네일 영향 최대)가 최희귀이며 천장은 없다.
WolfDifficultyDefs.CostumeOrder = { "WolfBodySuit", "WolfShoulder", "WolfTail", "WolfHat" }
WolfDifficultyDefs.Modes = {
	Easy = {
		NameKo="쉬움", NameEn="EASY", Color=Color3.fromRGB(104,199,118),
		SummaryKo="기본 패턴 · 광폭화 50%", StatLineKo="공격 기본 · 방어 32 · 속도 기본",
		HpMul=1, PartyHpMul=1, AtkMul=1, DefAdd=0, SpeedMul=1,
		AtkIntervalMul=1, ExpMul=1, CoinMul=1, CooldownMul=1, PatternRest=1.6, PatternRecovery=0.8,
		FrenzyAt=0.50, ComboHits=0, StoneCost=0,
	},
	Medium = {
		NameKo="보통", NameEn="MEDIUM", Color=Color3.fromRGB(245,187,66),
		SummaryKo="3연격 · 측면 사냥 · 4연속 돌진", StatLineKo="공격 +28% · 방어 44 · 속도 +15%",
		HpMul=1.65, PartyHpMul=1.65, AtkMul=1.28, DefAdd=12, SpeedMul=1.15,
		AtkIntervalMul=0.84, ExpMul=1.35, CoinMul=1.30, CooldownMul=0.76, PatternRest=0.75, PatternRecovery=0.55,
		FrenzyAt=0.68, ComboHits=3, ComboCooldown=7.5, StoneCost=5,
		Flank=true, FlankCooldown=10, DashCount=4, ClawWaves=4,
		CostumeDrop={ Parts={ WolfShoulder=0.0008, WolfBodySuit=0.0004, WolfTail=0.0002, WolfHat=0.00005 } },
	},
	Hard = {
		NameKo="어려움", NameEn="HARD", Color=Color3.fromRGB(235,91,82),
		SummaryKo="5연격 · 측면/공중 사냥 · 핏빛 추격", StatLineKo="공격 +65% · 방어 62 · 속도 +38%",
		-- 전투 수치와 패턴은 2026-08-25 이전 Insane을 그대로 승계한다. 입장 비용·코스튬 확률은 Hard 경제를 유지한다.
		HpMul=4.5, PartyHpMul=4.5, AtkMul=1.65, DefAdd=30, SpeedMul=1.38,
		AtkIntervalMul=0.65, ExpMul=2.6, CoinMul=2.40, CooldownMul=0.50, PatternRest=0.25, PatternRecovery=0.18,
		FrenzyAt=0.85, ComboHits=5, ComboCooldown=5.8, StoneCost=15,
		Flank=true, FlankCooldown=6.8, SkyHunt=true, SkyHuntCooldown=9,
		BloodHunt=true, BloodHuntCooldown=14, DashCount=5, ClawWaves=5,
		CostumeDrop={ Parts={ WolfShoulder=0.002, WolfBodySuit=0.001, WolfTail=0.0005, WolfHat=0.00015 } },
	},
	Insane = {
		NameKo="광기", NameEn="INSANE", Color=Color3.fromRGB(182,79,245),
		SummaryKo="유도 공중 사냥 · 6연속 돌진 · 핏빛 장판", StatLineKo="공격 +90% · 방어 68 · 속도 +52%",
		-- HP는 새 Hard보다 20%만 올리고, 공격·기동·패턴 빈도와 전용 기믹을 주 난이도 레버로 쓴다.
		HpMul=5.4, PartyHpMul=5.4, AtkMul=1.90, DefAdd=36, SpeedMul=1.52,
		AtkIntervalMul=0.55, ExpMul=3.3, CoinMul=3.0, CooldownMul=0.40, PatternRest=0.15, PatternRecovery=0.05,
		FrenzyAt=0.90, ComboHits=5, ComboCooldown=4.4, StoneCost=30,
		Flank=true, FlankCooldown=5.0, SkyHunt=true, SkyHuntCooldown=6.8,
		BloodHunt=true, BloodHuntCooldown=9.5, DashCount=6, ClawWaves=6,
		LeapHoming=8, DashScar=true,
		CostumeDrop={ Parts={ WolfShoulder=0.0045, WolfBodySuit=0.0025, WolfTail=0.0012, WolfHat=0.00035 } },
	},
}
local function deepCopy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = deepCopy(child) end
	return copy
end
local function scaleCooldown(config, mul)
	if config and config.Cooldown then config.Cooldown = math.max(0.25, config.Cooldown * mul) end
end
function WolfDifficultyDefs.IsValid(id)
	return type(id) == "string" and WolfDifficultyDefs.Modes[id] ~= nil
end
function WolfDifficultyDefs.Compose(baseDef, id)
	id = WolfDifficultyDefs.IsValid(id) and id or WolfDifficultyDefs.Default
	local mode = WolfDifficultyDefs.Modes[id]
	local result = deepCopy(baseDef)
	result.Hp = math.floor((result.Hp or 1) * mode.HpMul + 0.5)
	result.PartyHpPerExtra = math.floor((result.PartyHpPerExtra or 0) * mode.PartyHpMul + 0.5)
	result.Atk = math.floor((result.Atk or 1) * mode.AtkMul + 0.5)
	result.Def = math.floor((result.Def or 0) + mode.DefAdd + 0.5)
	result.WalkSpeed = (result.WalkSpeed or 10) * mode.SpeedMul
	result.AtkInterval = math.max(0.45, (result.AtkInterval or 2) * mode.AtkIntervalMul)
	result.Exp = math.floor((result.Exp or 0) * mode.ExpMul + 0.5)
	result.CoinRewardMul = mode.CoinMul or 1
	result.PatternRest, result.PatternRecovery, result.DifficultyId = mode.PatternRest, mode.PatternRecovery or 0, id
	scaleCooldown(result.WolfBite, mode.CooldownMul)
	scaleCooldown(result.LeapSlam, mode.CooldownMul)
	scaleCooldown(result.Howl, mode.CooldownMul)
	scaleCooldown(result.ClawWave, mode.CooldownMul)
	scaleCooldown(result.FrenzyDash, mode.CooldownMul)
	if result.Frenzy then
		result.Frenzy.HpFrac = mode.FrenzyAt
		result.Frenzy.HpRatio = mode.FrenzyAt
		local f = {
			Medium={1.16,1.25,0.82}, Hard={1.08,1.12,0.90}, Insane={1.10,1.15,0.85},
		}
		if f[id] then
			result.Frenzy.AtkMul, result.Frenzy.SpeedMul, result.Frenzy.CooldownMul = f[id][1], f[id][2], f[id][3]
		end
	end
	if result.FrenzyDash then
		result.FrenzyDash.DashCount = mode.DashCount or result.FrenzyDash.DashCount
		result.FrenzyDash.DamageMul = ({Easy=1.10,Medium=0.90,Hard=0.65,Insane=0.70})[id]
		result.FrenzyDash.HitFalloff = id == "Insane"
			and {1,0.70,0.50,0.38,0.30,0.24}
			or {1,0.72,0.52,0.40,0.32}
		if id == "Insane" then
			result.FrenzyDash.Windups = {0.65,0.55,0.48,0.42,0.38,0.34}
			result.FrenzyDash.MoveTime, result.FrenzyDash.DashGap = 0.36, 0.18
			if mode.DashScar then
				result.FrenzyDash.ScarSec, result.FrenzyDash.ScarTick = 2.8, 8
				result.FrenzyDash.ScarRadius, result.FrenzyDash.ScarCount = 4.5, 2
			end
		end
	end
	if result.ClawWave then
		result.ClawWave.Waves = mode.ClawWaves or result.ClawWave.Waves
		result.ClawWave.DamageMul = ({Easy=0.70,Medium=0.65,Hard=0.55,Insane=0.62})[id]
		if id == "Insane" then
			result.ClawWave.WaveTime, result.ClawWave.Windup = 0.95, 0.90
		end
	end
	if result.Howl then
		result.Howl.Radius = ({Easy=40,Medium=44,Hard=54,Insane=60})[id]
		result.Howl.DamageMul = ({Easy=0.75,Medium=0.72,Hard=0.62,Insane=0.68})[id]
		if id == "Insane" then
			result.Howl.FearSlow, result.Howl.FearSec = 6, 3.0
		end
	end
	if result.LeapSlam then
		result.LeapSlam.DamageMul = ({Easy=1.20,Medium=1.10,Hard=0.90,Insane=1.00})[id]
		if id == "Insane" then
			result.LeapSlam.Homing, result.LeapSlam.AirTime = mode.LeapHoming or 8, 0.82
		end
		if result.LeapSlam.ShockRing then
			result.LeapSlam.ShockRing.DamageMul = ({Easy=0.60,Medium=0.55,Hard=0.45,Insane=0.50})[id]
		end
	end
	if id == "Insane" and result.WolfBite then
		result.WolfBite.DamageMul, result.WolfBite.Windup, result.WolfBite.LungeDist = 1.05, 0.52, 8
	end
	result.WolfDifficultyPatterns = {
		ComboHits=mode.ComboHits or 0, ComboCooldown=mode.ComboCooldown,
		Flank=mode.Flank == true, FlankCooldown=mode.FlankCooldown,
		SkyHunt=mode.SkyHunt == true, SkyHuntCooldown=mode.SkyHuntCooldown,
		BloodHunt=mode.BloodHunt == true, BloodHuntCooldown=mode.BloodHuntCooldown,
	}
	return result
end
return WolfDifficultyDefs
