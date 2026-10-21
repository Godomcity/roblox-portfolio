--------------------------------------------------------------------------------
-- MannequinFxClient  (LocalScript)
-- 마네킹 스킬 클라이언트 FX 전담
--   · 화면 ColorCorrectionEffect  : 스킬 활성화 중 푸른 색보정
--   · 레인보우 Highlight 루프      : 자신 + 타 플레이어 캐릭터 감시
-- StarterPlayerScripts에 위치 → 항상 실행, 툴 장착 여부 무관
--------------------------------------------------------------------------------
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local Lighting          = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer   = Players.LocalPlayer
local SharedFolder  = ReplicatedStorage:WaitForChild("Shared")
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")

local Constants         = require(SharedFolder:WaitForChild("Constants"))
local RE_MannequinSkill = NetworkFolder:WaitForChild("RE_MannequinSkill")

local CFG = (Constants.PVP and Constants.PVP.MANNEQUIN) or {}

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
local SKILL_ID            = tostring(CFG.SKILL_ID or "Mannequin")
local ACTIVE_ATTRIBUTE    = tostring(CFG.ACTIVE_ATTRIBUTE or "IsMannequinActive")
local HIGHLIGHT_FILL_COLOR = CFG.HIGHLIGHT_FILL_COLOR or Color3.fromRGB(77, 135, 255)

local RAINBOW_ENABLED          = (CFG.RAINBOW_ENABLED ~= false)
local RAINBOW_SPEED            = tonumber(CFG.RAINBOW_SPEED)           or 0.8
local RAINBOW_SATURATION       = tonumber(CFG.RAINBOW_SATURATION)      or 0.75
local RAINBOW_VALUE            = tonumber(CFG.RAINBOW_VALUE)           or 1
local RAINBOW_UPDATE_INTERVAL  = tonumber(CFG.RAINBOW_UPDATE_INTERVAL) or 0.08

local FX_EFFECT_NAME = "MannequinLocalColor"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local localColorEffect = nil
local rainbowTokens    = setmetatable({}, { __mode = "k" }) -- [character] = token

--------------------------------------------------------------------------------
-- 화면 FX — ColorCorrectionEffect
--------------------------------------------------------------------------------

local function CleanupStaleEffects()
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("ColorCorrectionEffect") and child.Name == FX_EFFECT_NAME then
			child:Destroy()
		end
	end
end

local function DestroyLocalFx()
	local effectToDestroy = localColorEffect
	localColorEffect = nil

	if effectToDestroy and effectToDestroy.Parent then
		local tween = TweenService:Create(effectToDestroy, TweenInfo.new(0.15), {
			TintColor  = Color3.fromRGB(255, 255, 255),
			Brightness = 0,
			Saturation = 0,
			Contrast   = 0,
		})
		tween.Completed:Connect(function()
			if effectToDestroy and effectToDestroy.Parent then
				effectToDestroy:Destroy()
			end
		end)
		tween:Play()
	end

	CleanupStaleEffects()
end

local function PlayActivateFx()
	DestroyLocalFx()

	local colorEffect      = Instance.new("ColorCorrectionEffect")
	colorEffect.Name       = FX_EFFECT_NAME
	colorEffect.TintColor  = Color3.fromRGB(255, 255, 255)
	colorEffect.Brightness = 0
	colorEffect.Saturation = 0
	colorEffect.Contrast   = 0
	colorEffect.Parent     = Lighting
	localColorEffect       = colorEffect

	TweenService:Create(colorEffect, TweenInfo.new(0.18), {
		TintColor  = Color3.fromRGB(180, 205, 255),
		Brightness = 0.03,
		Saturation = -0.1,
		Contrast   = 0.08,
	}):Play()
end

local function PlayDeactivateFx()
	DestroyLocalFx()
end

--------------------------------------------------------------------------------
-- 레인보우 Highlight FX
--------------------------------------------------------------------------------

local function StopRainbow(character)
	rainbowTokens[character] = (rainbowTokens[character] or 0) + 1
end

local function StartRainbow(character)
	if not RAINBOW_ENABLED then return end

	local token = (rainbowTokens[character] or 0) + 1
	rainbowTokens[character] = token
	local startAt = os.clock()

	task.spawn(function()
		while true do
			task.wait(RAINBOW_UPDATE_INTERVAL)
			if rainbowTokens[character] ~= token then return end
			if not character.Parent then return end

			if character:GetAttribute(ACTIVE_ATTRIBUTE) ~= true then
				local highlight = character:FindFirstChild("MannequinHighlight")
				if highlight then
					highlight.FillColor = HIGHLIGHT_FILL_COLOR
				end
				return
			end

			local hue   = (os.clock() - startAt) * RAINBOW_SPEED % 1
			local color = Color3.fromHSV(hue, RAINBOW_SATURATION, RAINBOW_VALUE)

			local highlight = character:FindFirstChild("MannequinHighlight")
			if highlight then
				highlight.FillColor = color
			end
		end
	end)
end

local function WatchCharacter(character)
	if character:GetAttribute(ACTIVE_ATTRIBUTE) == true then
		StartRainbow(character)
	end
	character:GetAttributeChangedSignal(ACTIVE_ATTRIBUTE):Connect(function()
		if character:GetAttribute(ACTIVE_ATTRIBUTE) == true then
			StartRainbow(character)
		else
			StopRainbow(character)
		end
	end)
end

local function WatchPlayer(player)
	if player.Character then
		WatchCharacter(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		task.wait(0.1) -- 서버 Highlight 복제 대기
		WatchCharacter(character)
	end)
end

--------------------------------------------------------------------------------
-- 레인보우 감시 초기화 (모든 플레이어)
--------------------------------------------------------------------------------
for _, player in ipairs(Players:GetPlayers()) do
	WatchPlayer(player)
end
Players.PlayerAdded:Connect(WatchPlayer)
Players.PlayerRemoving:Connect(function(player)
	if player.Character then
		rainbowTokens[player.Character] = nil
	end
end)

--------------------------------------------------------------------------------
-- 화면 FX 이벤트 수신 (RE_MannequinSkill)
--------------------------------------------------------------------------------
RE_MannequinSkill.OnClientEvent:Connect(function(action, payload)
	if not payload or payload.SkillId ~= SKILL_ID then return end

	if action == "Activated" then
		PlayActivateFx()
	elseif action == "Ended" then
		PlayDeactivateFx()
	end
end)

-- 리스폰 시 잔여 effect 정리
LocalPlayer.CharacterAdded:Connect(function()
	DestroyLocalFx()
	CleanupStaleEffects()
end)

-- 시작 시 잔여 effect 정리
CleanupStaleEffects()
