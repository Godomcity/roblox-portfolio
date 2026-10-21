local Tool = script.Parent

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--------------------------------------------------------------------------------
-- Shared / Network
--------------------------------------------------------------------------------
local SharedFolder  = ReplicatedStorage:WaitForChild("Shared")
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")

local Constants  = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil  = require(SharedFolder:WaitForChild("SkillUtil"))

local RE_MannequinSkill = NetworkFolder:WaitForChild("RE_MannequinSkill")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local LocalPlayer      = Players.LocalPlayer
local CFG              = (Constants.PVP and Constants.PVP.MANNEQUIN) or {}

local SKILL_ID         = tostring(CFG.SKILL_ID or "Mannequin")
local COOLDOWN         = tonumber(CFG.COOLDOWN) or 18
local ACTIVE_ATTRIBUTE = tostring(CFG.ACTIVE_ATTRIBUTE or "IsMannequinActive")

--------------------------------------------------------------------------------
-- WeaponHotbarController (lazy)
--------------------------------------------------------------------------------
local WeaponHotbarController = nil

task.spawn(function()
	pcall(function()
		local playerScripts = LocalPlayer:WaitForChild("PlayerScripts")
		local controllers   = playerScripts:WaitForChild("Controllers")
		WeaponHotbarController = require(controllers:WaitForChild("WeaponHotbarController"))
	end)
end)

--------------------------------------------------------------------------------
-- Local State
--------------------------------------------------------------------------------
local LOCAL_MIN_INTERVAL = 0.12
local lastClickAt        = 0

--------------------------------------------------------------------------------
-- Cast
--------------------------------------------------------------------------------
local function CanLocalCast()
	local character = LocalPlayer.Character
	local humanoid  = SkillUtil.GetHumanoid(character)
	if not character or not humanoid or not SkillUtil.IsAlive(humanoid) then return false end
	if SkillUtil.IsLocalCharacterStunned() then return false end
	if character:GetAttribute(ACTIVE_ATTRIBUTE) == true then return false end
	return true
end

local function RequestActivate()
	local now = os.clock()
	if now - lastClickAt < LOCAL_MIN_INTERVAL then return end
	lastClickAt = now
	if not CanLocalCast() then return end
	RE_MannequinSkill:FireServer("Activate", SKILL_ID)
end

--------------------------------------------------------------------------------
-- Bind
--------------------------------------------------------------------------------
Tool.Activated:Connect(function()
	RequestActivate()
end)

RE_MannequinSkill.OnClientEvent:Connect(function(action, payload)
	if not payload or payload.SkillId ~= SKILL_ID then return end

	if action == "Activated" then
		if WeaponHotbarController and WeaponHotbarController.StartCooldown then
			WeaponHotbarController:StartCooldown(SKILL_ID, tonumber(payload.Cooldown) or COOLDOWN)
		end
	elseif action == "Rejected" then
		-- 필요하면 여기서 실패 UI 추가
	end
end)