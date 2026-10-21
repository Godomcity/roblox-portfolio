-- PlayerDamageService: 몬스터/보스가 플레이어에게 주는 피해의 단일 서버 관문.
-- 대시 회피 중에는 피해와 부가효과를 함께 차단하고, 대시 1회당 성공 피드백을 한 번만 보낸다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Net"))

local PlayerDamageService = {}

local evadeEvent = Net.Event("EvadeSuccess")

local function signalEvade(character)
	local token = tonumber(character:GetAttribute("_DashEvadeToken")) or 0
	if token <= 0 or character:GetAttribute("_DashEvadeSuccessToken") == token then
		return
	end
	character:SetAttribute("_DashEvadeSuccessToken", token)

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	evadeEvent:FireClient(player, {
		pos = root and root.Position or nil,
	})
end

local function clearExpiredEvolution(character)
	character:SetAttribute("WeaponEvolutionInvulnerable", false)
	character:SetAttribute("WeaponEvolutionEndsAt", 0)
	for _, child in ipairs(character:GetChildren()) do
		if child.Name == "WeaponEvolutionShield" and child:IsA("ForceField") then
			child:Destroy()
		end
	end
end

-- true, reason = 피해와 부가효과를 함께 막아야 하는 상태.
function PlayerDamageService.IsProtected(humanoid)
	if not (humanoid and humanoid:IsA("Humanoid") and humanoid.Parent) or humanoid.Health <= 0 then
		return true, "Invalid"
	end
	local character = humanoid.Parent
	local now = Workspace:GetServerTimeNow()
	local evolutionEndsAt = tonumber(character:GetAttribute("WeaponEvolutionEndsAt")) or 0
	if evolutionEndsAt > now then
		return true, "Evolution"
	end
	if character:GetAttribute("WeaponEvolutionInvulnerable") == true or evolutionEndsAt ~= 0 then
		clearExpiredEvolution(character)
	end
	local evadeEndsAt = tonumber(character:GetAttribute("DashEvadeEndsAt")) or 0
	if character:GetAttribute("DashEvading") == true or evadeEndsAt > now then
		return true, "Dash"
	end
	if character:FindFirstChildOfClass("ForceField") then
		return true, "ForceField"
	end
	return false, nil
end

-- true = 피해가 실제 적용됨(밀치기/속박 등 부가효과 적용 가능)
-- false = 사망/무효 수치/ForceField/대시 회피로 피해가 적용되지 않음
function PlayerDamageService.Apply(humanoid, amount)
	if not (humanoid and humanoid:IsA("Humanoid") and humanoid.Parent) or humanoid.Health <= 0 then
		return false
	end
	amount = tonumber(amount)
	if not amount or amount <= 0 then
		return false
	end
	local protected, reason = PlayerDamageService.IsProtected(humanoid)
	if protected then
		if reason == "Dash" then
			signalEvade(humanoid.Parent)
		end
		return false
	end
	local before = humanoid.Health
	humanoid:TakeDamage(amount)
	return humanoid.Health < before
end

return PlayerDamageService
