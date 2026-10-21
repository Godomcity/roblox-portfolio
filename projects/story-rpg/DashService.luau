-- DashService: 대쉬를 서버 검증 회피로 승격한다.
-- 이동 자체는 반응성을 위해 클라이언트 소유로 유지하고, 피해 무효만 서버가 쿨다운·생존 검증 후 부여한다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local MovementDefs = require(ReplicatedStorage:WaitForChild("Defs"):WaitForChild("MovementDefs"))
local Net = require(ReplicatedStorage:WaitForChild("Net"))
local AnalyticsService = require(script.Parent:WaitForChild("AnalyticsService"))

local DashService = {}

local nextAllowedAt = setmetatable({}, { __mode = "k" })
local firstDashSent = setmetatable({}, { __mode = "k" })

local SHIELD_NAME = "DashEvadeShield"

local function aliveCharacter(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and humanoid and root) or humanoid.Health <= 0 then
		return nil
	end
	return character
end

local function grantEvade(player, inputMode)
	local character = aliveCharacter(player)
	if not character then
		return
	end

	local dashDef = MovementDefs.DASH
	local cooldown = math.max(0.1, tonumber(dashDef.Cooldown) or 0.65)
	local grace = math.clamp(tonumber(dashDef.ServerCooldownGrace) or 0, 0, cooldown * 0.25)
	local now = os.clock()
	if now < (nextAllowedAt[player] or 0) then
		return
	end
	nextAllowedAt[player] = now + cooldown - grace

	-- Humanoid:TakeDamage는 ForceField를 존중한다. 기존 몬스터·보스 피해 경로를
	-- 수십 곳에서 갈아엎지 않고도 동일한 서버 권위 회피 규칙을 적용할 수 있다.
	local stale = character:FindFirstChild(SHIELD_NAME)
	if stale then
		stale:Destroy()
	end
	local shield = Instance.new("ForceField")
	shield.Name = SHIELD_NAME
	shield.Visible = false
	shield.Parent = character

	local evadeSec = math.clamp(tonumber(dashDef.InvulnerableSec) or 0.3, 0.05, cooldown)
	local token = (tonumber(character:GetAttribute("_DashEvadeToken")) or 0) + 1
	character:SetAttribute("_DashEvadeToken", token)
	character:SetAttribute("DashEvading", true)
	character:SetAttribute("DashEvadeEndsAt", Workspace:GetServerTimeNow() + evadeSec)
	task.delay(evadeSec, function()
		if shield.Parent then
			shield:Destroy()
		end
		if character.Parent and character:GetAttribute("_DashEvadeToken") == token then
			character:SetAttribute("DashEvading", false)
			character:SetAttribute("DashEvadeEndsAt", nil)
		end
	end)

	if not firstDashSent[player] then
		firstDashSent[player] = true
		local mode = inputMode == "Touch" and "Touch" or "Keyboard"
		AnalyticsService.CustomCF(player, "FirstDash", 1, "Input - " .. mode)
	end
end

function DashService.Init()
	Net.Event("RequestDash").OnServerEvent:Connect(grantEvade)
	Players.PlayerRemoving:Connect(function(player)
		nextAllowedAt[player] = nil
		firstDashSent[player] = nil
	end)
end

return DashService
