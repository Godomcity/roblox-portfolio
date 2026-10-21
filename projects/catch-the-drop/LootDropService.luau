local LootDropService = {}

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

--------------------------------------------------------------------------------
-- Modules
--------------------------------------------------------------------------------
local Constants = require(ReplicatedStorage.Shared.Constants)
local Utils = require(ReplicatedStorage.Shared.Utils)
local SkillUtil = require(ReplicatedStorage.Shared.SkillUtil)

--------------------------------------------------------------------------------
-- Network (아이템 카드 알림)
--------------------------------------------------------------------------------
local Network       = ReplicatedStorage:WaitForChild("Network")
local RE_ItemNotify = Network:WaitForChild("RE_ItemNotify")
local RE_SelfDrop   = Network:WaitForChild("RE_SelfDrop")

--------------------------------------------------------------------------------
-- Templates (여기서 미리 참조해두고 Clone만)
--------------------------------------------------------------------------------
local Templates = ReplicatedStorage:WaitForChild("Templates")

--------------------------------------------------------------------------------
-- Config (Constants에서만)
--------------------------------------------------------------------------------
local CFG = (Constants.PVP and Constants.PVP.LOOT) or {}
local MANNEQUIN_CFG = (Constants.PVP and Constants.PVP.MANNEQUIN) or {}

local ENABLED = (CFG.ENABLED ~= false)
local DROP_LIFETIME = tonumber(CFG.DROP_LIFETIME) or 10
local PROMPT_DISTANCE = tonumber(CFG.PROMPT_DISTANCE) or 10

local BAG_DROP_TEMPLATE_NAME = tostring(CFG.DROP_TEMPLATE_NAME or "ShoppingBag")
local CART_DROP_TEMPLATE_NAME = tostring(CFG.CART_DROP_TEMPLATE_NAME or "ShoppingCart")

local FLING_ENABLED = (CFG.FLING_ENABLED ~= false)

local FLING_SPEED_MIN = tonumber(CFG.FLING_SPEED_MIN) or 45
local FLING_SPEED_MAX = tonumber(CFG.FLING_SPEED_MAX) or 75
local FLING_UP_MIN = tonumber(CFG.FLING_UP_MIN) or 18
local FLING_UP_MAX = tonumber(CFG.FLING_UP_MAX) or 30

local FLING_SPIN_MIN = tonumber(CFG.FLING_SPIN_MIN) or 3
local FLING_SPIN_MAX = tonumber(CFG.FLING_SPIN_MAX) or 9

local NO_COLLIDE_TIME = tonumber(CFG.NO_COLLIDE_TIME) or 0.20

local MANNEQUIN_INVINCIBLE_ATTRIBUTE = tostring(
	MANNEQUIN_CFG.INVINCIBLE_ATTRIBUTE or "IsMannequinInvincible"
)

--------------------------------------------------------------------------------
-- SafeZone Config
--------------------------------------------------------------------------------
local SAFEZONE_NAME = "SafeZone"
local SAFEZONE_PADDING = tonumber(CFG.SAFEZONE_PADDING) or 5
local SAFEZONE_Y_TOLERANCE = tonumber(CFG.SAFEZONE_Y_TOLERANCE) or 12

--------------------------------------------------------------------------------
-- Lazy deps
--------------------------------------------------------------------------------
local _inited = false
local ShoppingBagService = nil
local ShoppingCartService = nil
local NotifyService = nil

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local dropsFolder = nil
local dropStateByModel = {}
local autoDropTestThreads = {}
local rng = Random.new()

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function EnsureInit()
	if _inited then
		return
	end

	_inited = true

	ShoppingBagService  = require(ServerScriptService.Services:WaitForChild("ShoppingBagService"))
	ShoppingCartService = require(ServerScriptService.Services:WaitForChild("ShoppingCartService"))
	NotifyService       = require(ServerScriptService.Services:WaitForChild("NotifyService"))

	dropsFolder = Workspace:FindFirstChild("LootDrops")
	if not dropsFolder then
		local folder = Instance.new("Folder")
		folder.Name   = "LootDrops"
		folder.Parent = Workspace
		dropsFolder   = folder
	end
end

local function GetChar(player)
	return player and player.Character or nil
end

local function GetHumanoid(character)
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function GetRoot(character)
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function IsAlive(humanoid)
	return humanoid and humanoid.Health > 0
end

local function EnsurePrimaryPart(model)
	if model.PrimaryPart then
		return true
	end

	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			model.PrimaryPart = desc
			return true
		end
	end

	return false
end

local function GetPhysicsPart(inst)
	if not inst then
		return nil
	end

	if inst:IsA("BasePart") then
		return inst
	end

	if inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end

	return nil
end

local function SetAllCanCollide(inst, canCollide)
	if inst:IsA("BasePart") then
		inst.CanCollide = canCollide
		return
	end

	for _, desc in ipairs(inst:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.CanCollide = canCollide
		end
	end
end

local function SetAllAnchored(inst, anchored)
	if inst:IsA("BasePart") then
		inst.Anchored = anchored
		return
	end
	for _, desc in ipairs(inst:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = anchored
		end
	end
end

-- 드롭 생성 위치의 실제 지면 Y좌표를 레이캐스트로 보정
-- extraExclude: 추가로 제외할 인스턴스 배열 (예: 플레이어 character)
local function SnapYToGround(worldPos, extraExclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList = {}
	if dropsFolder then
		table.insert(excludeList, dropsFolder)
	end
	if extraExclude then
		for _, inst in ipairs(extraExclude) do
			table.insert(excludeList, inst)
		end
	end
	params.FilterDescendantsInstances = excludeList
	-- 위치보다 10유닛 위에서 아래로 200유닛 레이캐스트
	local origin = Vector3.new(worldPos.X, worldPos.Y + 10, worldPos.Z)
	local result = workspace:Raycast(origin, Vector3.new(0, -200, 0), params)
	if result then
		return Vector3.new(worldPos.X, result.Position.Y + 0.5, worldPos.Z)
	end
	return worldPos
end

local function SetupDropPhysics(inst)
	if inst:IsA("BasePart") then
		-- [버그1 수정] spawn 직후엔 Anchored=true 유지 → NO_COLLIDE_TIME 후 해제
		inst.Anchored = true
		inst.CanCollide = true
		inst.CanTouch = false
		inst.CanQuery = false
		inst.Massless = false

		pcall(function()
			inst:SetNetworkOwner(nil)
		end)
	else
		for _, desc in ipairs(inst:GetDescendants()) do
			if desc:IsA("BasePart") then
				-- [버그1 수정] spawn 직후엔 Anchored=true 유지 → NO_COLLIDE_TIME 후 해제
				desc.Anchored = true
				desc.CanCollide = true
				desc.CanTouch = false
				desc.CanQuery = false
				desc.Massless = false

				pcall(function()
					desc:SetNetworkOwner(nil)
				end)
			end
		end
	end
end

local function ApplyRandomFling(inst)
	if not FLING_ENABLED then
		return
	end

	local physicsPart = GetPhysicsPart(inst)
	if not physicsPart then
		return
	end

	local angle     = rng:NextNumber(0, math.pi * 2)
	local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local speed     = rng:NextNumber(FLING_SPEED_MIN, FLING_SPEED_MAX)
	local upForce   = rng:NextNumber(FLING_UP_MIN, FLING_UP_MAX)
	local spin      = rng:NextNumber(FLING_SPIN_MIN, FLING_SPIN_MAX)

	local linearVel  = (direction * speed) + Vector3.new(0, upForce, 0)
	local angularVel = Vector3.new(
		rng:NextNumber(-spin, spin),
		rng:NextNumber(-spin, spin),
		rng:NextNumber(-spin, spin)
	)

	-- [버그 수정] Anchored=true 상태에서는 AssemblyLinearVelocity가 무시됨
	-- Anchored 해제 시점에 맞춰 속도를 적용해야 실제로 튕겨나감
	if physicsPart.Anchored then
		task.delay(NO_COLLIDE_TIME + 0.01, function()
			if not (inst and inst.Parent) then return end
			if not physicsPart.Parent then return end
			physicsPart.AssemblyLinearVelocity  = linearVel
			physicsPart.AssemblyAngularVelocity = angularVel
		end)
	else
		physicsPart.AssemblyLinearVelocity  = linearVel
		physicsPart.AssemblyAngularVelocity = angularVel
	end
end

local function MakePrompt(basePart)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = Utils.FormatByKey(nil, "PROMPT_ACTION_PICKUP", nil, "줍기")
	prompt.ObjectText = Utils.FormatByKey(nil, "PROMPT_OBJECT_DROP_ITEM", nil, "드롭 아이템")
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.Parent = basePart
	return prompt
end

local function CleanupDrop(dropInst)
	local state = dropStateByModel[dropInst]
	if not state then
		return
	end

	if state.Conn then
		state.Conn:Disconnect()
		state.Conn = nil
	end

	dropStateByModel[dropInst] = nil
end

local function FindDropTemplate(kind)
	if kind == "Furniture" then
		local cartTemplate = Templates:FindFirstChild(CART_DROP_TEMPLATE_NAME)
		if cartTemplate and (cartTemplate:IsA("Model") or cartTemplate:IsA("BasePart")) then
			return cartTemplate
		end

		local fallbackCart = Templates:FindFirstChild("ShoppingCart")
		if fallbackCart and (fallbackCart:IsA("Model") or fallbackCart:IsA("BasePart")) then
			return fallbackCart
		end

		return nil
	end

	local bagTemplate = Templates:FindFirstChild(BAG_DROP_TEMPLATE_NAME)
	if bagTemplate and (bagTemplate:IsA("Model") or bagTemplate:IsA("BasePart")) then
		return bagTemplate
	end

	local fallbackBag = Templates:FindFirstChild("ShoppingBag")
	if fallbackBag and (fallbackBag:IsA("Model") or fallbackBag:IsA("BasePart")) then
		return fallbackBag
	end

	return nil
end

local function IsPlayerCarryingSomething(player)
	if player:GetAttribute("IsCarryingItem") == true then
		return true
	end

	if ShoppingBagService and ShoppingBagService:HasBag(player) then
		return true
	end

	if ShoppingCartService and ShoppingCartService:HasCart(player) then
		return true
	end

	return false
end

--------------------------------------------------------------------------------
-- SafeZone Helpers
--------------------------------------------------------------------------------
local function GetSafeZoneParts()
	local result = {}

	local plotsFolder = Workspace:FindFirstChild("Tycoon_Plots")
	if not plotsFolder then
		return result
	end

	for _, plot in ipairs(plotsFolder:GetChildren()) do
		if plot:IsA("Folder") or plot:IsA("Model") then
			local safeZone = plot:FindFirstChild(SAFEZONE_NAME)
			if safeZone and safeZone:IsA("BasePart") then
				table.insert(result, safeZone)
			end
		end
	end

	return result
end

local function IsPointInsideSafeZone(safeZone, worldPoint)
	local localPoint = safeZone.CFrame:PointToObjectSpace(worldPoint)
	local halfSize = safeZone.Size * 0.5

	local insideX = math.abs(localPoint.X) <= halfSize.X
	local insideZ = math.abs(localPoint.Z) <= halfSize.Z
	local insideY = math.abs(localPoint.Y) <= (halfSize.Y + SAFEZONE_Y_TOLERANCE)

	return insideX and insideZ and insideY
end

local function GetNearestOutsidePointFromSafeZone(safeZone, worldPoint)
	local localPoint = safeZone.CFrame:PointToObjectSpace(worldPoint)
	local halfSize = safeZone.Size * 0.5

	local targetPosX = halfSize.X + SAFEZONE_PADDING
	local targetNegX = -(halfSize.X + SAFEZONE_PADDING)
	local targetPosZ = halfSize.Z + SAFEZONE_PADDING
	local targetNegZ = -(halfSize.Z + SAFEZONE_PADDING)

	local movePosX = math.abs(targetPosX - localPoint.X)
	local moveNegX = math.abs(localPoint.X - targetNegX)
	local movePosZ = math.abs(targetPosZ - localPoint.Z)
	local moveNegZ = math.abs(localPoint.Z - targetNegZ)

	local bestAxis = "X"
	local bestValue = targetPosX
	local bestDistance = movePosX

	if moveNegX < bestDistance then
		bestAxis = "X"
		bestValue = targetNegX
		bestDistance = moveNegX
	end

	if movePosZ < bestDistance then
		bestAxis = "Z"
		bestValue = targetPosZ
		bestDistance = movePosZ
	end

	if moveNegZ < bestDistance then
		bestAxis = "Z"
		bestValue = targetNegZ
		bestDistance = moveNegZ
	end

	local adjustedLocalPoint
	if bestAxis == "X" then
		adjustedLocalPoint = Vector3.new(bestValue, localPoint.Y, localPoint.Z)
	else
		adjustedLocalPoint = Vector3.new(localPoint.X, localPoint.Y, bestValue)
	end

	return safeZone.CFrame:PointToWorldSpace(adjustedLocalPoint)
end

local function GetSafeDropPosition(worldPoint)
	local safeZones = GetSafeZoneParts()
	local adjustedPoint = worldPoint

	for _, safeZone in ipairs(safeZones) do
		if IsPointInsideSafeZone(safeZone, adjustedPoint) then
			adjustedPoint = GetNearestOutsidePointFromSafeZone(safeZone, adjustedPoint)
		end
	end

	return adjustedPoint
end

--------------------------------------------------------------------------------
-- Drop Spawn
--------------------------------------------------------------------------------
local function SpawnDrop(itemId, rarity, kind, cf, meta)
	EnsureInit()

	if not ENABLED then
		return nil
	end

	local template = FindDropTemplate(kind)
	if not template then
		warn(
			"[LootDropService] Drop template missing. kind=",
			kind,
			"bag=",
			BAG_DROP_TEMPLATE_NAME,
			"cart=",
			CART_DROP_TEMPLATE_NAME
		)
		return nil
	end

	local clone = template:Clone()
	clone.Name = (kind == "Furniture") and "LootDrop_Cart" or "LootDrop"

	clone:SetAttribute("Id", itemId)
	clone:SetAttribute("Rarity", rarity)
	clone:SetAttribute("Kind", kind or "Inventory")
	clone:SetAttribute("DroppedFromUserId", meta and meta.DroppedFromUserId or 0)
	clone:SetAttribute("DroppedByUserId", meta and meta.DroppedByUserId or 0)

	local basePart = nil

	-- [Y 이중보정 방지] 호출자가 이미 SnapYToGround를 수행한 경우 재보정 스킵
	local rawPos = cf.Position
	local groundPos = (meta and meta.SkipGroundSnap) and rawPos or SnapYToGround(rawPos)
	local fixedCf = CFrame.new(groundPos) * (cf - cf.Position)

	if clone:IsA("Model") then
		if not EnsurePrimaryPart(clone) then
			clone:Destroy()
			return nil
		end

		clone:PivotTo(fixedCf)
		basePart = clone.PrimaryPart
	else
		basePart = clone
		basePart.CFrame = fixedCf
	end

	clone.Parent = dropsFolder
	-- SetupDropPhysics는 Anchored=true로 세팅 (바닥 뚫림 방지)
	SetupDropPhysics(clone)

	-- Anchored 해제 + LaunchVelocity 주입을 동일 콜백에서 처리
	-- → Anchored=false와 velocity 적용 사이에 gravity가 끼어드는 타이밍 경합 방지
	if NO_COLLIDE_TIME > 0 then
		task.delay(NO_COLLIDE_TIME, function()
			if clone and clone.Parent then
				SetAllAnchored(clone, false)
				-- 호출자가 발사 방향을 넘긴 경우 즉시 velocity 주입 (delay 없이)
				local lv = meta and meta.LaunchVelocity
				if lv and basePart and basePart.Parent then
					basePart.AssemblyLinearVelocity = lv
				end
			end
		end)
	else
		SetAllAnchored(clone, false)
		local lv = meta and meta.LaunchVelocity
		if lv and basePart and basePart.Parent then
			basePart.AssemblyLinearVelocity = lv
		end
	end

	local prompt = MakePrompt(basePart)

	dropStateByModel[clone] = {
		ItemId = itemId,
		Rarity = rarity,
		Kind = kind or "Inventory",
		Locked = false,
		Conn = nil,
		BasePart = basePart,
	}

	Debris:AddItem(clone, DROP_LIFETIME)

	-- [세이프존 바운스] 드롭 가방이 세이프존 파트에 닿으면 튕겨냄
	-- MeshPart 충돌이 신뢰되지 않을 수 있으므로 Touched 이벤트로 직접 처리
	if basePart then
		local bounceConn
		bounceConn = basePart.Touched:Connect(function(hit)
			-- clone이 이미 소멸됐으면 연결 해제
			if not (clone and clone.Parent) then
				bounceConn:Disconnect()
				return
			end

			-- 닿은 파트가 SafeZone인지 확인
			if hit.Name ~= SAFEZONE_NAME then
				return
			end

			-- 아직 Anchored 상태면 (0.2초 이내) 무시
			if basePart.Anchored then
				return
			end

			-- 세이프존 중심에서 드롭 방향으로 벡터 계산
			local dropPos  = basePart.Position
			local zonePos  = hit.Position
			local bounceDir = (dropPos - zonePos)

			-- Y 성분 제거 후 정규화 (수평 방향으로만 튕김)
			local flatDir = Vector3.new(bounceDir.X, 0, bounceDir.Z)
			if flatDir.Magnitude < 0.1 then
				flatDir = Vector3.new(1, 0, 0) -- 예외처리: 중심과 완전 일치
			end
			flatDir = flatDir.Unit

			-- 현재 속도 크기 유지, 방향만 세이프존 밖으로 반전
			local currentVel = basePart.AssemblyLinearVelocity
			local speed = math.max(currentVel.Magnitude, 20) -- 최소 20 보장

			basePart.AssemblyLinearVelocity = flatDir * speed + Vector3.new(0, math.abs(currentVel.Y) * 0.5 + 8, 0)

			-- 연속 튕김 방지: 0.3초 후 재연결
			bounceConn:Disconnect()
			task.delay(0.3, function()
				if clone and clone.Parent and basePart and basePart.Parent then
					bounceConn = basePart.Touched:Connect(function(h)
						if not (clone and clone.Parent) then bounceConn:Disconnect(); return end
						if h.Name ~= SAFEZONE_NAME then return end
						if basePart.Anchored then return end
						local d = (basePart.Position - h.Position)
						local f = Vector3.new(d.X, 0, d.Z)
						if f.Magnitude < 0.1 then f = Vector3.new(1, 0, 0) end
						f = f.Unit
						local v = basePart.AssemblyLinearVelocity
						local s = math.max(v.Magnitude, 20)
						basePart.AssemblyLinearVelocity = f * s + Vector3.new(0, math.abs(v.Y) * 0.5 + 8, 0)
						bounceConn:Disconnect()
					end)
				end
			end)
		end)
	end

	clone.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			CleanupDrop(clone)
		end
	end)

	local conn
	conn = prompt.Triggered:Connect(function(player)
		if not player or not player.Parent then
			return
		end

		if player:GetAttribute("InSafeZone") == true then
			return
		end

		local state = dropStateByModel[clone]
		if not state or state.Locked then
			return
		end

		local character = GetChar(player)
		local humanoid = GetHumanoid(character)
		local root = GetRoot(character)
		if not character or not root or not IsAlive(humanoid) then
			return
		end

		if state.BasePart and (root.Position - state.BasePart.Position).Magnitude > (PROMPT_DISTANCE + 4) then
			return
		end

		state.Locked = true

		-- PVP 스킬 피격 중에는 줍기 불가 (마네킹 무적 제외)
		if character:GetAttribute("PaparazziStunned") == true
			or character:GetAttribute("IsBalloonLifted") == true
			or character:GetAttribute("BagBlastStunned") == true
			or character:FindFirstChild("BagBlast_Cover") ~= nil then
			state.Locked = false
			return
		end

		if IsPlayerCarryingSomething(player) then
			NotifyService:NotifyPlayer(player, Utils.FormatByKey(player, "ERR_DROP_ALREADY_CARRYING", nil, "이미 다른 아이템을 들고 있습니다!"), "Error")
			state.Locked = false
			return
		end

		local okGive = false

		if state.Kind == "Furniture" then
			okGive = (ShoppingCartService:GiveCart(player, state.ItemId, state.Rarity, {
				Kind = "Furniture",
				Source = "LootDrop",
				AcquiredAt = os.time(),
			}) == true)
		else
			okGive = (ShoppingBagService:GiveBag(player, state.ItemId, state.Rarity, {
				AcquiredAt = os.time(),
			}) == true)
		end

		if okGive == true then
			clone:Destroy()
			return
		end

		state.Locked = false
	end)

	dropStateByModel[clone].Conn = conn
	return clone
end

--------------------------------------------------------------------------------
-- Public API: 자발적 드롭 (플레이어가 직접 내려놓기)
--------------------------------------------------------------------------------
local SELF_DROP_COOLDOWN = 3
local lastSelfDropAt = {}

game:GetService("Players").PlayerRemoving:Connect(function(p)
	lastSelfDropAt[p] = nil
end)

function LootDropService:SelfDropBag(player, lookVector)
	EnsureInit()

	if not ENABLED then return false end
	if not player or not player.Parent then return false end

	if player:GetAttribute("InSafeZone") == true then return false end

	local now = os.clock()
	if (now - (lastSelfDropAt[player] or 0)) < SELF_DROP_COOLDOWN then
		return false
	end

	local character = GetChar(player)
	local humanoid  = GetHumanoid(character)
	local root      = GetRoot(character)
	if not character or not root or not IsAlive(humanoid) then return false end

	local hasBag  = ShoppingBagService:HasBag(player)
	local hasCart = ShoppingCartService:HasCart(player)
	if not hasBag and not hasCart then return false end

	local info = nil
	if hasCart then
		info = ShoppingCartService:GetCartInfo(player)
		if not info then ShoppingCartService:Clear(player); return false end
	else
		info = ShoppingBagService:GetBagInfo(player)
		if not info then ShoppingBagService:Clear(player); return false end
		info.Kind = "Inventory"
	end

	lastSelfDropAt[player] = now

	if hasCart then
		ShoppingCartService:Clear(player)
	else
		ShoppingBagService:Clear(player)
	end

	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude > 0 then
		flatLook = flatLook.Unit
	else
		flatLook = Vector3.new(0, 0, -1)
	end

	local dropOffset = flatLook * 3 + Vector3.new(0, 5, 0)
	local rawPos     = root.Position + dropOffset
	-- [점프 내려놓기 수정] 플레이어 character를 레이캐스트에서 제외해 Y 보정 오류 방지
	local groundSnapped = SnapYToGround(rawPos, { character })
	local safePos    = GetSafeDropPosition(groundSnapped)
	-- LaunchVelocity를 meta에 담아 SpawnDrop으로 위임
	-- → SpawnDrop 내부의 Anchored 해제 콜백과 동일 frame에서 velocity 주입됨 (타이밍 경합 Zero)
	local launchVel = flatLook * 8 + Vector3.new(0, 4, 0)
	local dropInst   = SpawnDrop(info.Id, info.Rarity, info.Kind, CFrame.new(safePos), {
		DroppedFromUserId = player.UserId,
		DroppedByUserId   = player.UserId,
		SkipGroundSnap    = true,   -- SelfDropBag에서 이미 SnapYToGround 완료
		LaunchVelocity    = launchVel,
	})

	return dropInst ~= nil
end

--------------------------------------------------------------------------------
-- Public API: 피격 드롭
--------------------------------------------------------------------------------
function LootDropService:DropCarriedItem(victimPlayer, attackerPlayer)
	EnsureInit()

	if not ENABLED then
		return false
	end

	if not victimPlayer or not victimPlayer.Parent then
		return false
	end

	if victimPlayer:GetAttribute("InSafeZone") == true then
		return false
	end

	local victimCharacter = GetChar(victimPlayer)
	local victimHumanoid = GetHumanoid(victimCharacter)
	local victimRoot = GetRoot(victimCharacter)

	if not victimCharacter or not victimRoot or not IsAlive(victimHumanoid) then
		return false
	end

	if victimCharacter:GetAttribute(MANNEQUIN_INVINCIBLE_ATTRIBUTE) == true then
		return false
	end

	local hasBag = ShoppingBagService:HasBag(victimPlayer)
	local hasCart = ShoppingCartService:HasCart(victimPlayer)

	if not hasBag and not hasCart then
		return false
	end

	local info = nil

	if hasCart then
		info = ShoppingCartService:GetCartInfo(victimPlayer)
		if not info then
			ShoppingCartService:Clear(victimPlayer)
			return false
		end
	else
		info = ShoppingBagService:GetBagInfo(victimPlayer)
		if not info then
			ShoppingBagService:Clear(victimPlayer)
			return false
		end
		info.Kind = "Inventory"
	end

	if hasCart then
		ShoppingCartService:Clear(victimPlayer)
	else
		ShoppingBagService:Clear(victimPlayer)
	end

	local rawStartPos = victimRoot.Position + Vector3.new(0, 3, 0)
	local safeStartPos = GetSafeDropPosition(rawStartPos)
	local spawnCf = CFrame.new(safeStartPos)

	local dropInst = SpawnDrop(info.Id, info.Rarity, info.Kind, spawnCf, {
		DroppedFromUserId = victimPlayer.UserId,
		DroppedByUserId = attackerPlayer and attackerPlayer.UserId or 0,
	})

	if dropInst then
		ApplyRandomFling(dropInst)
	end

	return dropInst ~= nil
end

--------------------------------------------------------------------------------
-- Test API: 10초마다 몸 위에서 강제 드롭 생성
--------------------------------------------------------------------------------
function LootDropService:StartAutoDropTest(player, intervalSec, itemId, rarity, kind)
	EnsureInit()

	if not player or not player.Parent then
		return
	end

	if autoDropTestThreads[player] then
		return
	end

	intervalSec = tonumber(intervalSec) or 10
	itemId = itemId or "TestItem"
	rarity = rarity or "B1"
	kind = kind or "Inventory" -- "Inventory" | "Furniture"

	autoDropTestThreads[player] = true

	task.spawn(function()
		while player and player.Parent and autoDropTestThreads[player] do
			local character = GetChar(player)
			local humanoid = GetHumanoid(character)
			local root = GetRoot(character)

			if character and humanoid and root and IsAlive(humanoid) then
				local rawStartPos = root.Position + Vector3.new(0, 3, 0)
				local safeStartPos = GetSafeDropPosition(rawStartPos)
				local spawnCf = CFrame.new(safeStartPos)

				local dropInst = SpawnDrop(itemId, rarity, kind, spawnCf, {
					DroppedFromUserId = player.UserId,
					DroppedByUserId = 0,
				})

				if dropInst then
					ApplyRandomFling(dropInst)
				end
			end

			task.wait(intervalSec)
		end

		autoDropTestThreads[player] = nil
	end)
end

function LootDropService:StopAutoDropTest(player)
	if not player then
		return
	end

	autoDropTestThreads[player] = nil
end

--------------------------------------------------------------------------------
-- RE_SelfDrop 수신 — 모듈 최상위에서 즉시 연결 (EnsureInit 타이밍 무관)
--------------------------------------------------------------------------------
RE_SelfDrop.OnServerEvent:Connect(function(player, lookVector)
	if typeof(lookVector) ~= "Vector3" then
		lookVector = Vector3.new(0, 0, -1)
	end
	LootDropService:SelfDropBag(player, lookVector)
end)

return LootDropService