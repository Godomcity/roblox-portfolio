local SkillUtil = {}

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

--------------------------------------------------------------------------------
-- 1. 공통 헬퍼 함수
--------------------------------------------------------------------------------
function SkillUtil.GetHumanoid(character)
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

function SkillUtil.GetRoot(character)
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end

	local upperTorso = character:FindFirstChild("UpperTorso")
	if upperTorso and upperTorso:IsA("BasePart") then
		return upperTorso
	end

	local torso = character:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		return torso
	end

	local primaryPart = character.PrimaryPart
	if primaryPart and primaryPart:IsA("BasePart") then
		return primaryPart
	end

	return nil
end

function SkillUtil.IsAlive(humanoid)
	return humanoid and humanoid.Health > 0
end

function SkillUtil.FindCharacterModelFromDescendant(descendant)
	local current = descendant

	while current and current ~= Workspace do
		if current:IsA("Model") then
			local humanoid = current:FindFirstChildOfClass("Humanoid")
			local root = SkillUtil.GetRoot(current)

			if humanoid and root then
				return current
			end
		end

		current = current.Parent
	end

	return nil
end

--------------------------------------------------------------------------------
-- 2. 통합 무적 및 CC 검사 (서버/클라 공용)
--------------------------------------------------------------------------------
function SkillUtil.IsTargetAlreadyHit(character)
	if not character then
		return false
	end

	local immunityEnd = character:GetAttribute("CCImmunityEndTime") or 0
	if Workspace:GetServerTimeNow() < immunityEnd then
		return true
	end

	if character:GetAttribute("IsMannequinInvincible") == true then
		return true
	end

	if character:GetAttribute("PaparazziStunned") == true then
		return true
	end

	if character:GetAttribute("IsBalloonLifted") == true then
		return true
	end

	if character:GetAttribute("BagBlastStunned") == true then
		return true
	end

	if character:FindFirstChild("BagBlast_Cover") then
		return true
	end

	return false
end

function SkillUtil.IsLocalCharacterStunned()
	local localPlayer = Players.LocalPlayer
	return SkillUtil.IsTargetAlreadyHit(localPlayer.Character)
end

--------------------------------------------------------------------------------
-- 3. 타겟팅 검증 (각도, 거리, 시야)
--------------------------------------------------------------------------------
function SkillUtil.HasLineOfSight(attackerChar, targetChar, fromPos, toPos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {attackerChar, targetChar}
	params.IgnoreWater = true

	local direction = toPos - fromPos
	if direction.Magnitude <= 0.001 then
		return true
	end

	local result = Workspace:Raycast(fromPos, direction, params)
	return not result or result.Instance:IsDescendantOf(targetChar)
end

function SkillUtil.IsValidFrontTarget(attackerRoot, targetRoot, range, maxAngle, maxYDiff, targetFrontDot, targetBackDot)
	local delta = targetRoot.Position - attackerRoot.Position
	if delta.Magnitude > range then
		return false
	end

	if math.abs(delta.Y) > maxYDiff then
		return false
	end

	local flatDelta = Vector3.new(delta.X, 0, delta.Z)
	if flatDelta.Magnitude <= 0.001 then
		return true
	end

	local attackerLook = Vector3.new(attackerRoot.CFrame.LookVector.X, 0, attackerRoot.CFrame.LookVector.Z)
	if attackerLook.Magnitude <= 0.001 then
		return false
	end

	local dirToTarget = flatDelta.Unit
	local attackerDot = attackerLook.Unit:Dot(dirToTarget)
	local minDot = math.cos(math.rad(maxAngle * 0.5))

	if attackerDot < minDot then
		return false
	end

	if targetFrontDot and targetBackDot then
		local targetLook = Vector3.new(targetRoot.CFrame.LookVector.X, 0, targetRoot.CFrame.LookVector.Z)
		if targetLook.Magnitude <= 0.001 then
			return false
		end

		local targetDot = targetLook.Unit:Dot(-dirToTarget)
		if targetDot <= targetBackDot then
			return false
		end

		if targetDot < targetFrontDot then
			return false
		end
	end

	return true
end

function SkillUtil.IsValidRayTarget(attackerRoot, targetRoot, range, maxYDiff)
	if not attackerRoot or not targetRoot then
		return false
	end

	local delta = targetRoot.Position - attackerRoot.Position
	if delta.Magnitude > range then
		return false
	end

	if math.abs(delta.Y) > maxYDiff then
		return false
	end

	return true
end

--------------------------------------------------------------------------------
-- 4. Raycast / Box 공용 함수
--------------------------------------------------------------------------------
function SkillUtil.GetToolHandle(tool)
	if not tool then
		return nil
	end

	local handle = tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		return handle
	end

	return nil
end

function SkillUtil.GetRayOriginFromTool(tool, attackerRoot)
	local handle = SkillUtil.GetToolHandle(tool)
	if not handle then
		return attackerRoot.Position
	end

	local attachment = handle:FindFirstChild("Attachment1")
	if attachment and attachment:IsA("Attachment") then
		return attachment.WorldPosition
	end

	return handle.Position
end

function SkillUtil.GetForwardRayDirection(attackerRoot, range)
	return attackerRoot.CFrame.LookVector * range
end

function SkillUtil.RaycastCharacterTarget(attackerCharacter, tool, origin, direction)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {attackerCharacter, tool}
	params.IgnoreWater = true

	local result = Workspace:Raycast(origin, direction, params)
	if not result then
		return nil, nil
	end

	local hitPart = result.Instance
	if not hitPart then
		return result, nil
	end

	local targetCharacter = SkillUtil.FindCharacterModelFromDescendant(hitPart)
	return result, targetCharacter
end

function SkillUtil.IsCharacterTargetable(targetCharacter, attackerCharacter, allowNonPlayerTargets)
	if not targetCharacter or targetCharacter == attackerCharacter then
		return false
	end

	local humanoid = SkillUtil.GetHumanoid(targetCharacter)
	local rootPart = SkillUtil.GetRoot(targetCharacter)

	if not rootPart or not SkillUtil.IsAlive(humanoid) then
		return false
	end

	if SkillUtil.IsTargetAlreadyHit(targetCharacter) then
		return false
	end

	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	if targetPlayer then
		if targetPlayer:GetAttribute("InSafeZone") == true then
			return false
		end

		return true
	end

	return allowNonPlayerTargets == true
end

function SkillUtil.ResolveSimpleRaycastCharacterTarget(attackerCharacter, tool, range, maxYDiff, allowNonPlayerTargets)
	if not attackerCharacter then
		return nil, nil
	end

	local attackerHumanoid = SkillUtil.GetHumanoid(attackerCharacter)
	local attackerRoot = SkillUtil.GetRoot(attackerCharacter)
	if not attackerRoot or not SkillUtil.IsAlive(attackerHumanoid) then
		return nil, nil
	end

	local rayOrigin = SkillUtil.GetRayOriginFromTool(tool, attackerRoot)
	local rayDirection = SkillUtil.GetForwardRayDirection(attackerRoot, range)

	local result, targetCharacter = SkillUtil.RaycastCharacterTarget(attackerCharacter, tool, rayOrigin, rayDirection)
	if not result or not targetCharacter then
		return result, nil
	end

	if targetCharacter == attackerCharacter then
		return result, nil
	end

	local targetHumanoid = SkillUtil.GetHumanoid(targetCharacter)
	local targetRoot = SkillUtil.GetRoot(targetCharacter)
	if not targetRoot or not SkillUtil.IsAlive(targetHumanoid) then
		return result, nil
	end

	local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)
	if targetPlayer then
		if targetPlayer:GetAttribute("InSafeZone") == true then
			return result, nil
		end
	else
		if allowNonPlayerTargets ~= true then
			return result, nil
		end
	end

	local delta = targetRoot.Position - attackerRoot.Position
	if delta.Magnitude > range then
		return result, nil
	end

	if math.abs(delta.Y) > maxYDiff then
		return result, nil
	end

	return result, targetCharacter
end

function SkillUtil.GetCharactersFromBox(attackerCharacter, tool, boxCFrame, boxSize, allowNonPlayerTargets)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {attackerCharacter, tool}
	overlapParams.MaxParts = 100

	local parts = Workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlapParams)
	local foundCharacters = {}
	local seen = {}

	for _, part in ipairs(parts) do
		local targetCharacter = SkillUtil.FindCharacterModelFromDescendant(part)
		if targetCharacter and not seen[targetCharacter] then
			seen[targetCharacter] = true

			if SkillUtil.IsCharacterTargetable(targetCharacter, attackerCharacter, allowNonPlayerTargets) then
				table.insert(foundCharacters, targetCharacter)
			end
		end
	end

	return foundCharacters
end

function SkillUtil.GetClosestCharacter(attackerRoot, characterList, maxRange, maxYDiff)
	local closestCharacter = nil
	local closestDistance = math.huge

	for _, targetCharacter in ipairs(characterList) do
		local targetRoot = SkillUtil.GetRoot(targetCharacter)
		if targetRoot and SkillUtil.IsValidRayTarget(attackerRoot, targetRoot, maxRange, maxYDiff) then
			local distance = (targetRoot.Position - attackerRoot.Position).Magnitude
			if distance < closestDistance then
				closestDistance = distance
				closestCharacter = targetCharacter
			end
		end
	end

	return closestCharacter
end

function SkillUtil.ResolveWideBoxCharacterTarget(attackerCharacter, tool, range, width, height, maxYDiff, allowNonPlayerTargets)
	if not attackerCharacter then
		return nil
	end

	local attackerHumanoid = SkillUtil.GetHumanoid(attackerCharacter)
	local attackerRoot = SkillUtil.GetRoot(attackerCharacter)
	if not attackerRoot or not SkillUtil.IsAlive(attackerHumanoid) then
		return nil
	end

	local origin = SkillUtil.GetRayOriginFromTool(tool, attackerRoot)
	local forward = attackerRoot.CFrame.LookVector
	local center = origin + (forward * (range * 0.5))

	local boxCFrame = CFrame.lookAt(center, center + forward)
	local boxSize = Vector3.new(width, height, range)

	local characters = SkillUtil.GetCharactersFromBox(
		attackerCharacter,
		tool,
		boxCFrame,
		boxSize,
		allowNonPlayerTargets
	)

	if #characters == 0 then
		return nil
	end

	return SkillUtil.GetClosestCharacter(attackerRoot, characters, range, maxYDiff)
end

--------------------------------------------------------------------------------
-- 4-1. 좌/중/우 확산 박스 판정
--------------------------------------------------------------------------------
function SkillUtil.ResolveSpreadBoxCharacterTargets(attackerCharacter, tool, range, width, height, maxYDiff, allowNonPlayerTargets, angleOffsets)
	if not attackerCharacter then
		return {}
	end

	local attackerHumanoid = SkillUtil.GetHumanoid(attackerCharacter)
	local attackerRoot = SkillUtil.GetRoot(attackerCharacter)
	if not attackerRoot or not SkillUtil.IsAlive(attackerHumanoid) then
		return {}
	end

	local origin = SkillUtil.GetRayOriginFromTool(tool, attackerRoot)
	local results = {}
	local seen = {}

	local flatForward = Vector3.new(attackerRoot.CFrame.LookVector.X, 0, attackerRoot.CFrame.LookVector.Z)
	if flatForward.Magnitude <= 0.001 then
		flatForward = Vector3.new(0, 0, -1)
	else
		flatForward = flatForward.Unit
	end

	local offsets = angleOffsets or {0}
	local upVector = Vector3.yAxis

	for _, angleOffset in ipairs(offsets) do
		local spreadForward = CFrame.fromAxisAngle(upVector, angleOffset):VectorToWorldSpace(flatForward)
		if spreadForward.Magnitude > 0.001 then
			spreadForward = spreadForward.Unit
		else
			spreadForward = flatForward
		end

		local center = origin + (spreadForward * (range * 0.5))
		local boxCFrame = CFrame.lookAt(center, center + spreadForward)
		local boxSize = Vector3.new(width, height, range)

		local characters = SkillUtil.GetCharactersFromBox(
			attackerCharacter,
			tool,
			boxCFrame,
			boxSize,
			allowNonPlayerTargets
		)

		local filteredCharacters = {}

		for _, targetCharacter in ipairs(characters) do
			local targetRoot = SkillUtil.GetRoot(targetCharacter)
			if targetRoot
				and SkillUtil.IsValidRayTarget(attackerRoot, targetRoot, range, maxYDiff)
				and SkillUtil.HasLineOfSight(attackerCharacter, targetCharacter, origin, targetRoot.Position) then
				table.insert(filteredCharacters, targetCharacter)
			end
		end

		local closestCharacter = SkillUtil.GetClosestCharacter(attackerRoot, filteredCharacters, range, maxYDiff)
		if closestCharacter and not seen[closestCharacter] then
			seen[closestCharacter] = true
			table.insert(results, closestCharacter)
		end
	end

	return results
end

--------------------------------------------------------------------------------
-- 5. 하이라이트 관리 (클라이언트 전용)
--------------------------------------------------------------------------------
local TargetHighlight = nil

function SkillUtil.UpdateHighlight(targetChar, color)
	if not RunService:IsClient() then
		return
	end

	if not targetChar then
		if TargetHighlight then
			TargetHighlight.Enabled = false
		end
		return
	end

	if not TargetHighlight then
		local highlight = Instance.new("Highlight")
		highlight.Name = "Skill_TargetHighlight"
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = Workspace.CurrentCamera
		TargetHighlight = highlight
	end

	TargetHighlight.FillColor = color or Color3.fromRGB(255, 150, 200)
	TargetHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
	TargetHighlight.FillTransparency = 0.6
	TargetHighlight.OutlineTransparency = 0.1
	TargetHighlight.Adornee = targetChar
	TargetHighlight.Enabled = true
end

function SkillUtil.ClearHighlight()
	if TargetHighlight then
		TargetHighlight.Enabled = false
	end
end

--------------------------------------------------------------------------------
-- 6. 중앙 속도 계산기
--------------------------------------------------------------------------------
function SkillUtil.UpdateWalkSpeed(character)
	if not character then
		return
	end

	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local player = Players:GetPlayerFromCharacter(character)
	local Constants = require(game:GetService("ReplicatedStorage").Shared.Constants)

	local finalSpeed = Constants.PLAYER.DEFAULT_WALKSPEED

	if player and player:GetAttribute("IsCarryingItem") then
		if character:FindFirstChild("Shopping") then
			finalSpeed = Constants.CARRY.BAG_WALKSPEED
		elseif character:FindFirstChild("ShoppingCart") then
			finalSpeed = Constants.CARRY.CART_WALKSPEED
		else
			player:SetAttribute("IsCarryingItem", false)
		end
	end

	if character:GetAttribute("PaparazziStunned") or character:GetAttribute("IsBalloonLifted") then
		finalSpeed = 0
	end

	if character:GetAttribute("BagBlastStunned") then
		local blastSpeed = Constants.PVP.BAG_BLAST.SLOW_WALKSPEED
		finalSpeed = math.min(finalSpeed, blastSpeed)
	end

	local effects = character:FindFirstChild("PvpEffects")
	if effects and effects:FindFirstChild("ReceiptSlow_Token") then
		local receiptMult = Constants.PVP.RECEIPT.SLOW_MULTIPLIER or 0.2
		finalSpeed *= receiptMult
	end

	if character:GetAttribute("IsMannequinActive") then
		local mannequinMult = Constants.PVP.MANNEQUIN.SPEED_MULTIPLIER or 2
		finalSpeed *= mannequinMult
	end

	humanoid.WalkSpeed = finalSpeed
end

return SkillUtil