local Tool = script.Parent
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer

-- ✅ [경로 변경] 대피소(Network)에 있는 리모트 이벤트 연결
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local RE_Paparazzi = NetworkFolder:WaitForChild("RE_Paparazzi")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local CFG = (Constants.PVP and Constants.PVP.PAPARAZZI) or {}
local COOLDOWN_SEC          = tonumber(CFG.COOLDOWN_SEC)          or 1.25
local RANGE                 = tonumber(CFG.RANGE)                 or 10
local CONE_ANGLE_DEG        = tonumber(CFG.CONE_ANGLE_DEG)        or 80
local MAX_Y_DIFF            = tonumber(CFG.MAX_Y_DIFF)            or 12
local TARGET_FRONT_DOT      = tonumber(CFG.TARGET_FRONT_DOT)      or 0.2
local TARGET_BACK_DOT       = tonumber(CFG.TARGET_BACK_DOT)       or -0.15
local REQUIRE_LINE_OF_SIGHT = (CFG.REQUIRE_LINE_OF_SIGHT ~= false)

local HIGHLIGHT_UPDATE_INTERVAL = 0.08
local nextUseAt       = 0
local LastHighlightAt = 0
local RenderConnection = nil

local HighlightFolder   = nil
local HighlightByUserId = {}

--------------------------------------------------------------------------------
-- WeaponHotbarController (쿨타임 UI 연동)
--------------------------------------------------------------------------------
local WeaponHotbarController = nil
task.spawn(function()
	pcall(function()
		local ps = Player:WaitForChild("PlayerScripts")
		local controllers = ps:WaitForChild("Controllers")
		WeaponHotbarController = require(controllers:WaitForChild("WeaponHotbarController"))
	end)
end)

--------------------------------------------------------------------------------
-- Highlight 관리 (파파라치는 다중 타겟이므로 로컬 배열 사용)
--------------------------------------------------------------------------------
local function ensureHighlightFolder()
	local camera = Workspace.CurrentCamera
	if not camera then return nil end
	if HighlightFolder and HighlightFolder.Parent == camera then return HighlightFolder end
	if HighlightFolder then HighlightFolder:Destroy() end

	HighlightFolder = Instance.new("Folder")
	HighlightFolder.Name = "Paparazzi_Highlights"
	HighlightFolder.Parent = camera
	return HighlightFolder
end

local function clearHighlightForUser(userId)
	local hl = HighlightByUserId[userId]
	if hl then
		if hl.Parent then hl:Destroy() end
		HighlightByUserId[userId] = nil
	end
end

local function clearAllHighlights()
	for userId, _ in pairs(HighlightByUserId) do clearHighlightForUser(userId) end
end

local function setHighlightForPlayer(targetPlayer)
	if not targetPlayer or targetPlayer == Player then return end
	local targetCharacter = targetPlayer.Character
	if not targetCharacter then clearHighlightForUser(targetPlayer.UserId); return end

	local folder = ensureHighlightFolder()
	if not folder then return end

	local hl = HighlightByUserId[targetPlayer.UserId]
	if not hl or not hl.Parent then
		hl = Instance.new("Highlight")
		hl.Name = "Paparazzi_TargetHighlight"
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.FillColor = Color3.fromRGB(255, 150, 200)
		hl.OutlineColor = Color3.fromRGB(255, 200, 230)
		hl.FillTransparency = 0.6
		hl.OutlineTransparency = 0.1
		HighlightByUserId[targetPlayer.UserId] = hl
		hl.Parent = folder
	end
	hl.Adornee = targetCharacter
end

--------------------------------------------------------------------------------
-- Highlight Update (SkillUtil 적용)
--------------------------------------------------------------------------------
local function updateHighlights()
	if not Player.Character or Tool.Parent ~= Player.Character then
		clearAllHighlights()
		return
	end

	local now = os.clock()
	if (now - LastHighlightAt) < HIGHLIGHT_UPDATE_INTERVAL then return end
	LastHighlightAt = now

	local localCharacter = Player.Character
	local localHumanoid = SkillUtil.GetHumanoid(localCharacter)
	local localRoot = SkillUtil.GetRoot(localCharacter)

	if not localRoot or not SkillUtil.IsAlive(localHumanoid) then
		clearAllHighlights()
		return
	end

	local fromPosition = localRoot.Position + Vector3.new(0, 2, 0)
	local visibleUserIds = {}

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= Player and targetPlayer:GetAttribute("InSafeZone") ~= true then
			local targetCharacter = targetPlayer.Character
			local targetRoot = SkillUtil.GetRoot(targetCharacter)
			local targetHum = SkillUtil.GetHumanoid(targetCharacter)

			if targetRoot and SkillUtil.IsAlive(targetHum) and not SkillUtil.IsTargetAlreadyHit(targetCharacter) then
				if SkillUtil.IsValidFrontTarget(localRoot, targetRoot, RANGE, CONE_ANGLE_DEG, MAX_Y_DIFF, TARGET_FRONT_DOT, TARGET_BACK_DOT) then
					local toPosition = targetRoot.Position + Vector3.new(0, 2, 0)
					if not REQUIRE_LINE_OF_SIGHT or SkillUtil.HasLineOfSight(localCharacter, targetCharacter, fromPosition, toPosition) then
						visibleUserIds[targetPlayer.UserId] = true
						setHighlightForPlayer(targetPlayer)
					end
				end
			end
		end
	end

	for userId, _ in pairs(HighlightByUserId) do
		if not visibleUserIds[userId] then clearHighlightForUser(userId) end
	end
end

--------------------------------------------------------------------------------
-- Tool Use
--------------------------------------------------------------------------------
Tool.Activated:Connect(function()
	if os.clock() < nextUseAt then return end
	if not Player.Character or Tool.Parent ~= Player.Character then return end

	if SkillUtil.IsLocalCharacterStunned() then return end

	nextUseAt = os.clock() + COOLDOWN_SEC

	if WeaponHotbarController and WeaponHotbarController.StartCooldown then
		WeaponHotbarController:StartCooldown(Tool.Name, COOLDOWN_SEC)
	end

	RE_Paparazzi:FireServer("Use")
end)

--------------------------------------------------------------------------------
-- Loop / Cleanup
--------------------------------------------------------------------------------
RenderConnection = RunService.RenderStepped:Connect(updateHighlights)

Tool.Equipped:Connect(function()
	LastHighlightAt = 0
	updateHighlights()
end)

Tool.Unequipped:Connect(clearAllHighlights)

Tool.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		if RenderConnection then RenderConnection:Disconnect(); RenderConnection = nil end
		clearAllHighlights()
		if HighlightFolder then HighlightFolder:Destroy(); HighlightFolder = nil end
	end
end)