-- Tool 내부의 LocalScript (예: BagBlastController)
local Tool = script.Parent
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local RE_BagSkill = NetworkFolder:WaitForChild("RE_BagSkill")

local SharedFolder = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(SharedFolder:WaitForChild("Constants"))
local SkillUtil = require(SharedFolder:WaitForChild("SkillUtil"))

local CFG = (Constants.PVP and Constants.PVP.BAG_BLAST) or {}
local COOLDOWN_SEC = tonumber(CFG.COOLDOWN) or 5
local DETECT_RANGE = tonumber(CFG.RANGE) or 25
local CONE_ANGLE_DEG = tonumber(CFG.CONE_ANGLE_DEG) or 70
local MAX_Y_DIFF = tonumber(CFG.MAX_Y_DIFF) or 999

local LOCAL_MIN_INTERVAL = 0.12
local lastClickAt = 0
local lastCastAt = -math.huge

local WeaponHotbarController = nil
task.spawn(function()
	pcall(function()
		local ps = LocalPlayer:WaitForChild("PlayerScripts")
		local controllers = ps:WaitForChild("Controllers")
		WeaponHotbarController = require(controllers:WaitForChild("WeaponHotbarController"))
	end)
end)

local function IsEquipped()
	return LocalPlayer.Character and Tool.Parent == LocalPlayer.Character
end

-- 타겟팅 렌더링 로직 (내 화면에만 보이면 되므로 툴에 둠)
local HIGHLIGHT_UPDATE_INTERVAL = 0.10
local lastHlAt = 0
local highlightFolder
local active = {}

local function EnsureHighlightFolder()
	if highlightFolder and highlightFolder.Parent then return highlightFolder end
	highlightFolder = Instance.new("Folder")
	highlightFolder.Name = "BagSkill_Highlights"
	highlightFolder.Parent = workspace.CurrentCamera 
	return highlightFolder
end

local function ClearAllHighlights()
	for _, hl in pairs(active) do
		if hl and hl.Parent then hl:Destroy() end
	end
	table.clear(active)
end

local function SetHighlighted(plr, enabled)
	if not plr or plr == LocalPlayer then return end
	local uid = plr.UserId

	if not enabled then
		if active[uid] then
			if active[uid].Parent then active[uid]:Destroy() end
			active[uid] = nil
		end
		return
	end

	local char = plr.Character
	if not char then return end

	local hl = active[uid]
	if not hl or not hl.Parent then
		hl = Instance.new("Highlight")
		hl.Name = "HL_" .. tostring(uid)
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.FillColor = Color3.fromRGB(255, 150, 200)
		hl.OutlineColor = Color3.fromRGB(255, 200, 230)
		hl.FillTransparency = 0.6
		hl.OutlineTransparency = 0.1
		hl.Parent = EnsureHighlightFolder()
		active[uid] = hl
	end
	hl.Adornee = char
end

local function UpdateHighlights()
	if not IsEquipped() then
		ClearAllHighlights()
		return
	end

	local myRoot = SkillUtil.GetRoot(LocalPlayer.Character)
	if not myRoot then
		ClearAllHighlights()
		return
	end

	local now = os.clock()
	if (now - lastHlAt) < HIGHLIGHT_UPDATE_INTERVAL then return end
	lastHlAt = now

	local inside = {}

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer and plr:GetAttribute("InSafeZone") ~= true then
			local targetChar = plr.Character
			local targetRoot = SkillUtil.GetRoot(targetChar)
			local targetHum = SkillUtil.GetHumanoid(targetChar)

			if targetRoot and SkillUtil.IsAlive(targetHum) and not SkillUtil.IsTargetAlreadyHit(targetChar) then
				if SkillUtil.IsValidFrontTarget(myRoot, targetRoot, DETECT_RANGE, CONE_ANGLE_DEG, MAX_Y_DIFF) then
					inside[plr.UserId] = true
					SetHighlighted(plr, true)
				end
			end
		end
	end

	for uid, hl in pairs(active) do
		if not inside[uid] then
			if hl and hl.Parent then hl:Destroy() end
			active[uid] = nil
		end
	end
end

Tool.Activated:Connect(function()
	local now = os.clock()
	if SkillUtil.IsLocalCharacterStunned() then return end
	if (now - lastClickAt) < LOCAL_MIN_INTERVAL then return end
	lastClickAt = now
	if (now - lastCastAt) < COOLDOWN_SEC then return end
	lastCastAt = now

	if WeaponHotbarController and WeaponHotbarController.StartCooldown then
		WeaponHotbarController:StartCooldown(Tool.Name, COOLDOWN_SEC)
	end
	RE_BagSkill:FireServer()
end)

local conn = RunService.RenderStepped:Connect(UpdateHighlights)
Tool.Unequipped:Connect(ClearAllHighlights)
Tool.AncestryChanged:Connect(function(_, parent)
	if parent == nil then
		if conn then conn:Disconnect() end
		ClearAllHighlights()
		if highlightFolder then highlightFolder:Destroy() end
	end
end)