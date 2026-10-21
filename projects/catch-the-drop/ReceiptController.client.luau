--[[
	ReceiptController — Tool LocalScript
	툴 장착 시에만 실행: 타겟 하이라이트 + 발사 입력 처리.
	피격 화면 이펙트는 ReceiptFxClient (StarterPlayerScripts) 에서 담당.
]]

local Tool = script.Parent

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--------------------------------------------------------------------------------
-- Shared / Network
--------------------------------------------------------------------------------
local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")

local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))

local RE_ReceiptSkill = NetworkFolder:WaitForChild("RE_ReceiptSkill")

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local CFG = (Constants.PVP and Constants.PVP.RECEIPT) or {}

local SKILL_ID = tostring(CFG.SKILL_ID or "ReceiptBeam")
local COOLDOWN_SEC = tonumber(CFG.COOLDOWN) or 0.2

local DETECT_RANGE = tonumber(CFG.RAYCAST_RANGE) or tonumber(CFG.RANGE) or 14
local MAX_Y_DIFF = tonumber(CFG.MAX_Y_DIFF) or 20
local HITBOX_WIDTH = tonumber(CFG.HITBOX_WIDTH) or 5
local HITBOX_HEIGHT = tonumber(CFG.HITBOX_HEIGHT) or 5
local ALLOW_NON_PLAYER_TARGETS = (CFG.ALLOW_NON_PLAYER_TARGETS == true)

--------------------------------------------------------------------------------
-- Highlight Config
--------------------------------------------------------------------------------
local TARGET_HIGHLIGHT_COLOR = Color3.fromRGB(255, 150, 200)

--------------------------------------------------------------------------------
-- References
--------------------------------------------------------------------------------
local LocalPlayer = Players.LocalPlayer
local WeaponHotbarController = nil

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local nextFireAt = 0
local isEquipped = false
local renderConnection = nil

--------------------------------------------------------------------------------
-- Controller 참조
--------------------------------------------------------------------------------
task.spawn(function()
	local playerScripts = LocalPlayer:WaitForChild("PlayerScripts")
	local controllers = playerScripts:WaitForChild("Controllers")

	local ok, module = pcall(function()
		return require(controllers:WaitForChild("WeaponHotbarController"))
	end)

	if ok then
		WeaponHotbarController = module
	end
end)

--------------------------------------------------------------------------------
-- Utils
--------------------------------------------------------------------------------
local function GetCharacter()
	return LocalPlayer.Character
end

local function IsAliveAndEquipped()
	local character = GetCharacter()
	if not character then return false end
	if Tool.Parent ~= character then return false end

	local humanoid = SkillUtil.GetHumanoid(character)
	local rootPart = SkillUtil.GetRoot(character)
	if not rootPart or not SkillUtil.IsAlive(humanoid) then return false end

	return true
end

local function CanLocalCast()
	local character = GetCharacter()
	if not character then return false end
	if not IsAliveAndEquipped() then return false end
	if LocalPlayer:GetAttribute("InSafeZone") == true then return false end
	if SkillUtil.IsTargetAlreadyHit(character) then return false end
	if os.clock() < nextFireAt then return false end
	return true
end

local function ShouldUpdateHighlight()
	if not isEquipped then return false end
	if not IsAliveAndEquipped() then return false end
	if LocalPlayer:GetAttribute("InSafeZone") == true then return false end
	local character = GetCharacter()
	if not character then return false end
	if SkillUtil.IsTargetAlreadyHit(character) then return false end
	return true
end

local function UpdateTargetHighlight()
	if not ShouldUpdateHighlight() then
		SkillUtil.ClearHighlight()
		return
	end

	local character = GetCharacter()
	if not character then
		SkillUtil.ClearHighlight()
		return
	end

	local targetCharacter = SkillUtil.ResolveWideBoxCharacterTarget(
		character, Tool,
		DETECT_RANGE, HITBOX_WIDTH, HITBOX_HEIGHT, MAX_Y_DIFF,
		ALLOW_NON_PLAYER_TARGETS
	)

	if targetCharacter then
		SkillUtil.UpdateHighlight(targetCharacter, TARGET_HIGHLIGHT_COLOR)
	else
		SkillUtil.ClearHighlight()
	end
end

local function StartHighlightLoop()
	if renderConnection then return end
	renderConnection = RunService.RenderStepped:Connect(UpdateTargetHighlight)
end

local function StopHighlightLoop()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	SkillUtil.ClearHighlight()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
Tool.Equipped:Connect(function()
	isEquipped = true
	StartHighlightLoop()
end)

Tool.Unequipped:Connect(function()
	isEquipped = false
	StopHighlightLoop()
end)

Tool.Activated:Connect(function()
	if not CanLocalCast() then return end

	nextFireAt = os.clock() + COOLDOWN_SEC
	RE_ReceiptSkill:FireServer(SKILL_ID)

	if WeaponHotbarController and WeaponHotbarController.StartCooldown then
		WeaponHotbarController:StartCooldown(SKILL_ID, COOLDOWN_SEC)
	end
end)

Tool.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		StopHighlightLoop()
	end
end)

LocalPlayer.CharacterAdded:Connect(function()
	isEquipped = false
	StopHighlightLoop()
end)
