--[[
    MarketService
    - Catch a Drop 런웨이 마네킹 이동 및 상점 기능 관리
    - 쿠폰 자동 적용 제거 → "선택 적용" 구매 플로우
    - 원하는 아이템 강제 스폰 기능 추가
      1) FORCED_MARKET_ITEM_ID 우선
      2) 없으면 FORCED_MARKET_ITEM_NAME 사용
      3) 둘 다 없으면 기존 랜덤
]]

local MarketService = {}
MarketService.AutoSpawnEnabled = true

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

-- Modules
local Constants = require(ReplicatedStorage.Shared.Constants)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)
local Utils = require(ReplicatedStorage.Shared.Utils)
local SkillUtil = require(ReplicatedStorage.Shared.SkillUtil)

-- Lazy Loading Modules (Init에서 로드)
local DataService, DropService, GalaxyTimeService, CurrencyService, ShoppingBagService, NotifyService, StatsService, FurnitureMarketService, InventoryService

-- Variables
local RailFolder = workspace:WaitForChild("CatchADropRail")
local StartPoint = RailFolder:WaitForChild("StartPoint")
local EndPoint = RailFolder:WaitForChild("EndPoint")

-- Templates
local Templates = ReplicatedStorage:WaitForChild("Templates")
local ItemTemplates = Templates:WaitForChild("Items")
local NPC_Template = Templates:WaitForChild("NPC_Model")
local InteriorTemplates = Templates:FindFirstChild("InteriorItems")

local Network = ReplicatedStorage:WaitForChild("Network")

local RE_PromoState = Network:FindFirstChild("RE_PromoState")
local RE_PromoAction = Network:FindFirstChild("RE_PromoAction")
local RF_MarketPurchase = nil

-- Active items: { Instance, Root, ItemId, Rarity, Prompt, SpawnTime, Move, WalkAnimTrack, Conns }
local ActiveNPCs = {}
local LastSpawnTime = 0
local IsRunning = false
local GalaxyStateConn = nil
local OutfitSpawnStreak = 0

local WALK_ANIMATION_ID = "rbxassetid://133731336179664"

--------------------------------------------------------------------------------
-- [강제 스폰 설정]
--------------------------------------------------------------------------------

local FORCED_MARKET_ITEM_ID = nil
local FORCED_MARKET_ITEM_NAME = nil

--------------------------------------------------------------------------------
-- [HELPER] 가격 계산 및 셋업
--------------------------------------------------------------------------------

local function GetDiscountMultiplier()
	if not GalaxyTimeService then
		return 1.0
	end

	local mod = GalaxyTimeService:GetMarketModifier()
	return (mod and mod.DiscountMult) or 1.0
end

local function GetBasePrice(itemId, rarityHint)
	local rarity = rarityHint
	local info = ItemDatabase.ITEMS[itemId]
	if info and info.Rarity then
		rarity = info.Rarity
	end

	local basePrice = Constants.ITEM_PRICES[rarity]
	if not basePrice or basePrice <= 0 then
		return nil
	end

	return math.max(1, math.floor(basePrice))
end

local function GetEventPriceFromBase(basePrice)
	local eventMult = GetDiscountMultiplier()
	local eventPrice = math.max(1, math.floor(basePrice * eventMult))
	return eventPrice, eventMult
end

local function IsEventActive(eventMult)
	eventMult = tonumber(eventMult) or 1.0
	return eventMult < 0.999
end

--------------------------------------------------------------------------------
-- [HELPER] 강제 스폰용 아이템 탐색
--------------------------------------------------------------------------------

local function FindItemIdByName(itemName)
	if typeof(itemName) ~= "string" or itemName == "" then
		return nil
	end

	local matchedIds = {}

	for itemId, info in pairs(ItemDatabase.ITEMS) do
		if info.Name == itemName then
			table.insert(matchedIds, itemId)
		end
	end

	if #matchedIds == 0 then
		return nil
	end

	if #matchedIds == 1 then
		return matchedIds[1]
	end

	table.sort(matchedIds)
	return matchedIds[1]
end

local function GetForcedMarketItemData()
	local targetItemId = nil

	if typeof(FORCED_MARKET_ITEM_ID) == "string" and FORCED_MARKET_ITEM_ID ~= "" then
		targetItemId = FORCED_MARKET_ITEM_ID
	elseif typeof(FORCED_MARKET_ITEM_NAME) == "string" and FORCED_MARKET_ITEM_NAME ~= "" then
		targetItemId = FindItemIdByName(FORCED_MARKET_ITEM_NAME)
	end

	if not targetItemId then
		return nil
	end

	local itemInfo = ItemDatabase.ITEMS[targetItemId]
	if not itemInfo then
		warn("[MarketService] 강제 스폰 대상 아이템을 찾을 수 없음:", targetItemId)
		return nil
	end

	if not itemInfo.Rarity then
		warn("[MarketService] 강제 스폰 대상 아이템에 Rarity가 없음:", targetItemId)
		return nil
	end

	if not ItemDatabase.DROP_LIST[itemInfo.Rarity] then
		warn("[MarketService] 강제 스폰 대상 아이템의 희귀도 DropList가 없음:", targetItemId, itemInfo.Rarity)
		return nil
	end

	return {
		Id = targetItemId,
		Rarity = itemInfo.Rarity,
	}
end

--------------------------------------------------------------------------------
-- [HELPER] NPC 리그 안정화
--------------------------------------------------------------------------------

local function FreezeNPCModel(character)
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
		end
	end
end

local function SetupPhysicsForNPC(character)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid.AutoRotate = false
		humanoid.PlatformStand = false
	end

	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
			d.Anchored = false
		end
	end

	if rootPart then
		rootPart.Anchored = true
	end
end

local function GetFlatLookCFrame(fromPos, toPos)
	local flatDir = Vector3.new(toPos.X - fromPos.X, 0, toPos.Z - fromPos.Z)

	if flatDir.Magnitude < 0.001 then
		flatDir = Vector3.new(0, 0, -1)
	else
		flatDir = flatDir.Unit
	end

	return CFrame.lookAt(fromPos, fromPos + flatDir, Vector3.yAxis)
end

local function ApplyFlatFacing(rootPart, targetPos)
	if not rootPart or not rootPart.Parent then
		return
	end

	rootPart.CFrame = GetFlatLookCFrame(rootPart.Position, targetPos)
end

local function StabilizeNPCPose(rootPart, targetPos, debugName)
	if not rootPart or not rootPart.Parent then
		return
	end

	ApplyFlatFacing(rootPart, targetPos)

	task.spawn(function()
		for _ = 1, 5 do
			task.wait()

			if not rootPart or not rootPart.Parent then
				return
			end

			local lookY = math.abs(rootPart.CFrame.LookVector.Y)
			local upY = rootPart.CFrame.UpVector.Y

			if lookY <= 0.05 and upY >= 0.98 then
				return
			end

			ApplyFlatFacing(rootPart, targetPos)
		end
	end)
end

local function CloneItemAccessory(itemId)
	local template = ItemTemplates:FindFirstChild(itemId, true)
	if template and template:IsA("Accessory") then
		return template:Clone()
	end
	return nil
end

local function RefreshNPCData(npcData)
	local inst = npcData.Instance
	if not inst or not inst.Parent then
		return
	end

	local basePrice = GetBasePrice(npcData.ItemId, npcData.Rarity) or 0
	local eventPrice, eventMult = GetEventPriceFromBase(basePrice)

	inst:SetAttribute("BasePrice", basePrice)
	inst:SetAttribute("Price", eventPrice)
	inst:SetAttribute("EventActive", IsEventActive(eventMult))

	if npcData.Prompt then
		npcData.Prompt.ActionText = Utils.FormatByKey(nil, "MARKET_PROMPT_BUY", nil, "구매")
		npcData.Prompt.ObjectText = ""
		npcData.Prompt:SetAttribute("BasePrice", basePrice)
		npcData.Prompt:SetAttribute("Price", eventPrice)
		npcData.Prompt:SetAttribute("EventActive", IsEventActive(eventMult))
	end
end

local function FindNPCDataByInstance(inst)
	for _, data in ipairs(ActiveNPCs) do
		if data.Instance == inst then
			return data
		end
	end
	return nil
end

local function CleanupNPCData(npcData)
	if npcData.Move then
		npcData.Move:Stop()
		npcData.Move = nil
	end

	if npcData.Conns then
		for _, c in ipairs(npcData.Conns) do
			if c then
				c:Disconnect()
			end
		end
		npcData.Conns = {}
	end
end

--------------------------------------------------------------------------------
-- [MOVE] 레일 이동
--------------------------------------------------------------------------------

local function MoveThroughPath(npcData, speed)
	local inst = npcData.Instance
	local rootPart = npcData.Root
	if not inst or not rootPart then
		return nil
	end

	local startPos = StartPoint.Position + Vector3.new(0, -0.3, 0)
	local targetPos = EndPoint.Position + Vector3.new(0, -0.3, 0)

	local dist = (targetPos - startPos).Magnitude
	if dist <= 0.1 then
		return nil
	end

	local duration = dist / math.max(1, speed)

	local flatDir = Vector3.new(targetPos.X - startPos.X, 0, targetPos.Z - startPos.Z)
	if flatDir.Magnitude < 0.001 then
		flatDir = Vector3.new(0, 0, -1)
	else
		flatDir = flatDir.Unit
	end

	local alpha = Instance.new("NumberValue")
	alpha.Value = 0

	local conn = alpha:GetPropertyChangedSignal("Value"):Connect(function()
		if not inst.Parent or not rootPart.Parent then
			return
		end

		local a = alpha.Value
		local pos = startPos:Lerp(targetPos, a)
		rootPart.CFrame = CFrame.lookAt(pos, pos + flatDir)
	end)

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear)
	local tween = TweenService:Create(alpha, tweenInfo, { Value = 1 })

	local move = {
		Tween = tween,
		Conn = conn,
		Alpha = alpha,
		Stop = function(self)
			if self.Tween then
				self.Tween:Cancel()
			end
			if self.Conn then
				self.Conn:Disconnect()
			end
			if self.Alpha then
				self.Alpha:Destroy()
			end
			self.Tween = nil
			self.Conn = nil
			self.Alpha = nil
		end,
	}

	tween.Completed:Connect(function()
		move:Stop()
		if npcData.WalkAnimTrack then
			npcData.WalkAnimTrack:Stop()
		end
	end)

	if npcData.WalkAnimTrack then
		npcData.WalkAnimTrack:Play()
	end

	tween:Play()
	return move
end

--------------------------------------------------------------------------------
-- [SPAWN] 마네킹 스폰
--------------------------------------------------------------------------------

local function SpawnMarketItem()
	if not IsRunning then
		return
	end

	local itemData = GetForcedMarketItemData() or DropService:GetRandomItem()
	if not itemData or not itemData.Id then
		return false
	end

	if NotifyService and NotifyService.BroadcastItem then
		NotifyService:BroadcastItem(itemData.Id, itemData.Rarity)
	end

	local npcInst = NPC_Template:Clone()
	npcInst.Name = "RunwayMannequin"

	local humanoid = npcInst:FindFirstChildOfClass("Humanoid")
	local root = npcInst:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root then
		npcInst:Destroy()
		return false
	end

	local startPos = StartPoint.Position + Vector3.new(0, -0.3, 0)
	local targetPos = EndPoint.Position + Vector3.new(0, -0.3, 0)
	local startCFrame = GetFlatLookCFrame(startPos, targetPos)

	FreezeNPCModel(npcInst)
	npcInst:PivotTo(startCFrame)
	SetupPhysicsForNPC(npcInst)
	npcInst.Parent = RailFolder

	local accessory = CloneItemAccessory(itemData.Id)
	if accessory then
		accessory.Name = itemData.Id
		humanoid:AddAccessory(accessory)
	end

	-- [neck 조정 제거] task.defer 블록 삭제 — HumanoidRootPart.Anchored = true 상태에서
	-- Neck Motor6D 기본값을 건드리지 않는 것이 더 안정적임 (테스트 결과에 따라 방법 2/3 적용 가능)

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local walkAnim = Instance.new("Animation")
	walkAnim.AnimationId = WALK_ANIMATION_ID
	local walkTrack = animator:LoadAnimation(walkAnim)
	walkAnim:Destroy()

	local incomeMult = Constants.INCOME_RATES.RARITY_BONUS[itemData.Rarity] or 1

	npcInst:SetAttribute("ItemId", itemData.Id)
	npcInst:SetAttribute("Rarity", itemData.Rarity)
	npcInst:SetAttribute("Multiplier", incomeMult)

	local basePrice = GetBasePrice(itemData.Id, itemData.Rarity) or 0
	local eventPrice, eventMult = GetEventPriceFromBase(basePrice)

	npcInst:SetAttribute("BasePrice", basePrice)
	npcInst:SetAttribute("Price", eventPrice)
	npcInst:SetAttribute("EventActive", IsEventActive(eventMult))

	local itemInfo = ItemDatabase.ITEMS[itemData.Id]
	if itemInfo then
		Utils.AddHighlightEffect(npcInst, itemData.Id, itemInfo.Category)
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = ""
	prompt.ObjectText = ""
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = Constants.MARKET.INTERACTION_DISTANCE
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.HoldDuration = 0
	prompt.Parent = root

	local itemName = itemInfo and itemInfo.Name or itemData.Id
	local rarityColor = Constants.RARITY_COLORS[itemData.Rarity] or Color3.new(1, 1, 1)
	local finalIncome = Constants.INCOME_RATES.BASE_PER_MANNEQUIN * incomeMult

	local categoryMap = {
		[Constants.LAYER_CATEGORY.Hat] = Utils.FormatByKey(nil, "MARKET_CATEGORY_HAT", nil, "모자"),
		[Constants.LAYER_CATEGORY.TOP] = Utils.FormatByKey(nil, "MARKET_CATEGORY_TOP", nil, "상의"),
		[Constants.LAYER_CATEGORY.BOTTOM] = Utils.FormatByKey(nil, "MARKET_CATEGORY_BOTTOM", nil, "하의"),
		[Constants.LAYER_CATEGORY.JACKET] = Utils.FormatByKey(nil, "MARKET_CATEGORY_JACKET", nil, "자켓"),
		[Constants.LAYER_CATEGORY.SHOES] = Utils.FormatByKey(nil, "MARKET_CATEGORY_SHOES", nil, "신발"),
		[Constants.LAYER_CATEGORY.ACCESSORY] = Utils.FormatByKey(nil, "MARKET_CATEGORY_ACCESSORY", nil, "악세사리"),
	}
	local categoryName = itemInfo and categoryMap[itemInfo.Category] or Utils.FormatByKey(nil, "MARKET_CATEGORY_ETC", nil, "기타")

	prompt:SetAttribute("ItemName", itemName)
	prompt:SetAttribute("Rarity", itemData.Rarity)
	prompt:SetAttribute("GradeText", tostring(itemData.Rarity))
	prompt:SetAttribute("RarityColor", rarityColor)
	prompt:SetAttribute("Income", finalIncome)
	prompt:SetAttribute("Category", categoryName)
	prompt:SetAttribute("BasePrice", basePrice)
	prompt:SetAttribute("Price", eventPrice)
	prompt:SetAttribute("EventActive", IsEventActive(eventMult))

	StabilizeNPCPose(root, targetPos, itemData.Id)

	local npcData = {
		Instance = npcInst,
		Root = root,
		ItemId = itemData.Id,
		Rarity = itemData.Rarity,
		Prompt = prompt,
		SpawnTime = os.time(),
		Move = nil,
		WalkAnimTrack = walkTrack,
		Conns = {},
		Busy = false,
	}

	RefreshNPCData(npcData)

	table.insert(npcData.Conns, npcInst.AncestryChanged:Connect(function(_, p)
		if not p then
			CleanupNPCData(npcData)
		end
	end))

	table.insert(ActiveNPCs, npcData)

	local speed = Constants.MARKET.NPC_SPEED or 10
	npcData.Move = MoveThroughPath(npcData, speed)

	return true
end

local function SpawnNextMarketEntity()
	local n = (Constants.MARKET and Constants.MARKET.FURNITURE_EVERY_N_OUTFITS) or 10

	if OutfitSpawnStreak >= n then
		local ok = FurnitureMarketService:SpawnFurnitureNPC(function(player, inst)
			MarketService:HandlePromptTriggered(player, inst)
		end)

		if ok then
			OutfitSpawnStreak = 0
		end
		return ok
	end

	local ok = SpawnMarketItem()
	if ok then
		OutfitSpawnStreak += 1
	end
	return ok
end

--------------------------------------------------------------------------------
-- [UPDATE] 마네킹 수명 및 도착 체크
--------------------------------------------------------------------------------

local function UpdateNPCs()
	if not IsRunning then
		return
	end

	for i = #ActiveNPCs, 1, -1 do
		local npcData = ActiveNPCs[i]
		local inst = npcData.Instance
		local root = npcData.Root
		local shouldDestroy = false

		if inst and inst.Parent and root and root.Parent then
			local pos = root.Position
			local distToEnd = (EndPoint.Position - pos).Magnitude
			local lifeTime = os.time() - npcData.SpawnTime

			if distToEnd < 8 or lifeTime > 120 then
				shouldDestroy = true
			end
		else
			shouldDestroy = true
		end

		if shouldDestroy then
			CleanupNPCData(npcData)
			if inst then
				inst:Destroy()
			end
			table.remove(ActiveNPCs, i)
		end
	end
end

--------------------------------------------------------------------------------
-- [ENTRY] Prompt Triggered 처리 (현재 미사용 — RF_MarketPurchase가 진입점)
--------------------------------------------------------------------------------

function MarketService:HandlePromptTriggered(player, inst)
	if not IsRunning then
		return false
	end
	if not player or not player.Parent then
		return false
	end
	if not inst or not inst.Parent then
		return false
	end

	local targetData = FindNPCDataByInstance(inst)
	if not targetData then
		return false
	end
	if targetData.Busy then
		return false
	end

	-- 이 경로는 서버 직접 호출이라 쿠폰 인덱스를 알 수 없으므로 0 처리
	if targetData.Kind == "Furniture" then
		targetData.Busy = true
		local ok = FurnitureMarketService:ProcessPurchase(player, targetData, 0)
		targetData.Busy = false
		return ok
	end


	-- PVP 스킬 피격 중에는 구매 불가 (마네킹 무적 제외)
	local char1 = player.Character
	if char1 and (
		char1:GetAttribute("PaparazziStunned") == true
			or char1:GetAttribute("IsBalloonLifted") == true
			or char1:GetAttribute("BagBlastStunned") == true
			or char1:FindFirstChild("BagBlast_Cover") ~= nil
		) then
		if NotifyService and NotifyService.Warn then
			NotifyService:Warn(player, Utils.FormatByKey(player, "ERR_MARKET_HANDS_FULL", nil, "손이 모자랍니다."), 2.5)
		end
		return false
	end
	if ShoppingBagService and ShoppingBagService.HasBag and ShoppingBagService:HasBag(player) then
		if NotifyService and NotifyService.Warn then
			NotifyService:Warn(player, Utils.FormatByKey(player, "ERR_MARKET_HANDS_FULL", nil, "손이 모자랍니다."), 2.5)
		end
		return false
	end

	return self:ProcessPurchase(player, inst, 0)
end

--------------------------------------------------------------------------------
-- [TRANSACTION] 구매 처리
-- couponIndex: RF_MarketPurchase에서 클라이언트가 전달한 값 (0 = 미사용)
--------------------------------------------------------------------------------

function MarketService:ProcessPurchase(player, inst, couponIndex)
	if not IsRunning then
		return false
	end
	if not player or not player.Parent then
		return false
	end
	if not inst or not inst.Parent then
		return false
	end

	local targetData = FindNPCDataByInstance(inst)
	if not targetData then
		return false
	end
	if targetData.Busy then
		return false
	end
	targetData.Busy = true

	-- ✅ 가구: 클라이언트에서 RF_MarketPurchase로 전달받은 couponIndex를 그대로 사용
	if targetData.Kind == "Furniture" then
		targetData.Busy = false
		return FurnitureMarketService:ProcessPurchase(player, targetData, couponIndex)
	end

	local char = player.Character
	if not char or not char.PrimaryPart then
		targetData.Busy = false
		return false
	end

	local root = targetData.Root
	if not root then
		targetData.Busy = false
		return false
	end

	local dist = (char.PrimaryPart.Position - root.Position).Magnitude
	if dist > (Constants.MARKET.INTERACTION_DISTANCE + 5) then
		targetData.Busy = false
		return false
	end

	local data = DataService:Get(player)
	if not data then
		targetData.Busy = false
		return false
	end

	if targetData.IsTutorial then
		if (data.Coins or 0) < 1 then
			CurrencyService:AddCoins(player, 1, false, "Tutorial_Market_Fund")
		end
	end

	do
		local isFull, cnt, cap = InventoryService:IsFull(player, data)
		if isFull then
			if NotifyService and NotifyService.Warn then
				NotifyService:Warn(player, Utils.FormatByKey(player, "ERR_MARKET_INV_FULL", { cnt = tostring(cnt), cap = tostring(cap) }, string.format("인벤토리가 가득 찼습니다. (%d/%d)", cnt, cap)), 2.5)
			end
			targetData.Busy = false
			return false
		end
	end


	-- PVP 스킬 피격 중에는 구매 불가 (마네킹 무적 제외)
	local char2 = player.Character
	if char2 and (
		char2:GetAttribute("PaparazziStunned") == true
			or char2:GetAttribute("IsBalloonLifted") == true
			or char2:GetAttribute("BagBlastStunned") == true
			or char2:FindFirstChild("BagBlast_Cover") ~= nil
		) then
		if NotifyService and NotifyService.Warn then
			NotifyService:Warn(player, Utils.FormatByKey(player, "ERR_MARKET_HANDS_FULL", nil, "손이 모자랍니다."), 2.5)
		end
		targetData.Busy = false
		return false
	end
	if ShoppingBagService:HasBag(player) then
		if NotifyService and NotifyService.Warn then
			NotifyService:Warn(player, Utils.FormatByKey(player, "ERR_MARKET_HANDS_FULL", nil, "손이 모자랍니다."), 2.5)
		end
		targetData.Busy = false
		return false
	end

	local basePrice = GetBasePrice(targetData.ItemId, targetData.Rarity)
	if not basePrice then
		targetData.Busy = false
		return false
	end

	local eventPrice, eventMult = GetEventPriceFromBase(basePrice)
	local eventActive = IsEventActive(eventMult)

	if targetData.IsTutorial then
		basePrice = 1
		eventPrice = 1
		eventActive = false
	end

	data.PromoCoupons = data.PromoCoupons or {}
	local idx = tonumber(couponIndex) or 0

	local finalPrice = eventPrice
	local usedCoupon = false
	local usedPercent = 0
	local usedIndex = 0

	if eventActive then
		if idx >= 1 and NotifyService and NotifyService.NotifyPlayer then
			NotifyService:NotifyPlayer(player, Utils.FormatByKey(player, "MSG_MARKET_COUPON_SAVED", nil, "이벤트 할인 상품이라 장착된 쿠폰이 소모되지 않았습니다."), "Info")
		end
	else
		if idx >= 1 and idx <= #data.PromoCoupons then
			local pct = tonumber(data.PromoCoupons[idx].Percent) or 0
			if pct < 0 then pct = 0 end
			if pct > 90 then pct = 90 end

			if pct > 0 then
				local couponMult = 1 - (pct / 100)
				finalPrice = math.max(1, math.floor(basePrice * couponMult))
				usedCoupon = true
				usedPercent = pct
				usedIndex = idx
			end
		end
	end

	local beforeCoins = data.Coins or 0
	local isSpendSuccess = false

	if targetData.IsTutorial then
		isSpendSuccess = true
	else
		isSpendSuccess = CurrencyService:SpendCoins(player, finalPrice, false, "Market_Purchase")
	end

	if not isSpendSuccess then
		if NotifyService and NotifyService.NotifyPlayer then
			NotifyService:NotifyPlayer(player, Utils.FormatByKey(player, "ERR_MARKET_NOT_ENOUGH_COINS", nil, "코인이 부족합니다."), "Error")
		end
		targetData.Busy = false
		return false
	end

	local afterCoins = data.Coins or (beforeCoins - finalPrice)
	local purchaseType = "정가 구매"
	if eventActive then
		purchaseType = "이벤트 결제"
	elseif usedCoupon then
		purchaseType = string.format("쿠폰 결제(%d%%)", usedPercent)
	end

	--print(string.format(
	--	"🧾 [결제 영수증] 유저: %s | 타입: %s | 기존 돈: %s 🪙 | 결제 금액: %s 🪙 | 남은 돈: %s 🪙",
	--	player.Name,
	--	purchaseType,
	--	Utils.AbbreviateNumber(beforeCoins),
	--	Utils.AbbreviateNumber(finalPrice),
	--	Utils.AbbreviateNumber(afterCoins)
	--	))

	local ok, reason = ShoppingBagService:GiveBag(player, targetData.ItemId, targetData.Rarity, { PricePaid = finalPrice })
	if not ok then
		CurrencyService:AddCoins(player, finalPrice, false, "Market_Refund")
		targetData.Busy = false
		return false
	end

	if usedCoupon and usedIndex >= 1 and usedIndex <= #data.PromoCoupons then
		table.remove(data.PromoCoupons, usedIndex)

		if type(data.PromoCouponsPct) == "table" and data.PromoCouponsPct[usedIndex] then
			table.remove(data.PromoCouponsPct, usedIndex)
		end

		if RE_PromoState then
			RE_PromoState:FireClient(player, {
				Coupons = data.PromoCoupons,
				Count = #data.PromoCoupons,
				NextPercent = (data.PromoCoupons[1] and data.PromoCoupons[1].Percent) or 0,
			})
		end

		if RE_PromoAction and RE_PromoAction:IsA("RemoteEvent") then
			RE_PromoAction:FireClient(player, "GalaxyStorePromoPopup", {
				Title = Utils.FormatByKey(player, "쿠폰 사용", nil, "쿠폰 사용"),
				Message = Utils.FormatByKey(player, "{percent}% 할인 쿠폰을 사용하여 구매했습니다!", { percent = usedPercent }, string.format("%d%% 할인 쿠폰을 사용하여 구매했습니다!", usedPercent)),
			})
		end
	end

	inst:Destroy()

	if NotifyService and NotifyService.NotifyPlayer then
		NotifyService:NotifyPlayer(player, Utils.FormatByKey(player, "MSG_MARKET_BUY_SUCCESS", nil, "구매 완료! 쇼룸 바닥에 놓아주세요."), "Success")
	end

	if StatsService and StatsService.RecordPurchase then
		StatsService:RecordPurchase(player, targetData.ItemId, 1)
	end

	targetData.Busy = false
	return true
end

--------------------------------------------------------------------------------
-- [LIFECYCLE]
--------------------------------------------------------------------------------

function MarketService:Init()
	DataService = require(ServerScriptService.Services.DataService)
	DropService = require(ServerScriptService.Services.DropService)
	GalaxyTimeService = require(ServerScriptService.Services.GalaxyTimeService)
	CurrencyService = require(ServerScriptService.Services.CurrencyService)
	ShoppingBagService = require(ServerScriptService.Services.ShoppingBagService)
	NotifyService = require(ServerScriptService.Services.NotifyService)
	StatsService = require(ServerScriptService.Services.StatsService)
	FurnitureMarketService = require(ServerScriptService.Services:WaitForChild("FurnitureMarketService"))
	InventoryService = require(ServerScriptService.Services:WaitForChild("InventoryService"))

	RF_MarketPurchase = Network:WaitForChild("RF_MarketPurchase")

	-- ✅ 클라이언트가 PromptTriggered 시 RF_MarketPurchase:InvokeServer(npcModel, couponIndex)로 전달
	-- couponIndex는 클라이언트 로컬 변수에서 읽은 값이므로 서버 GetAttribute 불필요
	RF_MarketPurchase.OnServerInvoke = function(player, inst, couponIndex)
		if typeof(inst) ~= "Instance" then
			return false, Utils.FormatByKey(player, "ERR_MARKET_BAD_REQUEST", nil, "잘못된 요청")
		end

		local idx = tonumber(couponIndex) or 0
		if idx < 0 then
			idx = 0
		end

		--print(string.format("[MarketService] 구매 요청 | 유저: %s | inst: %s | couponIndex: %d", player.Name, inst.Name, idx))

		local ok = self:ProcessPurchase(player, inst, idx)
		local resultMsg = ok and Utils.FormatByKey(player, "MSG_MARKET_BUY_DONE_TEXT", nil, "구매 완료") or Utils.FormatByKey(player, "MSG_MARKET_BUY_FAIL_TEXT", nil, "구매 실패")
		return ok, resultMsg
	end

	FurnitureMarketService:Init({
		RailFolder = RailFolder,
		StartPoint = StartPoint,
		EndPoint = EndPoint,

		InteriorTemplates = InteriorTemplates,
		ActiveNPCs = ActiveNPCs,

		GalaxyTimeService = GalaxyTimeService,
		DataService = DataService,
		CurrencyService = CurrencyService,
		NotifyService = NotifyService,
		StatsService = StatsService,

		MoveThroughPath = MoveThroughPath,
	})
end

function MarketService:Start()
	if IsRunning then
		return
	end
	IsRunning = true

	if GalaxyTimeService and GalaxyTimeService.StateChanged then
		GalaxyStateConn = GalaxyTimeService.StateChanged.Event:Connect(function()
			for _, npc in ipairs(ActiveNPCs) do
				if npc.Kind == "Furniture" then
					FurnitureMarketService:RefreshNPCData(npc)
				else
					RefreshNPCData(npc)
				end
			end
		end)
	end

	task.spawn(function()
		while IsRunning do
			local now = os.time()
			if MarketService.AutoSpawnEnabled and (now - LastSpawnTime >= Constants.MARKET.SPAWN_INTERVAL) then
				local ok = SpawnNextMarketEntity()
				if ok then
					LastSpawnTime = now
				end
			end
			UpdateNPCs()
			task.wait(1)
		end
	end)
end

function MarketService:Stop()
	IsRunning = false
	if GalaxyStateConn then
		GalaxyStateConn:Disconnect()
		GalaxyStateConn = nil
	end
end

function MarketService:SpawnTutorialNPC(itemId)
	local prevId = FORCED_MARKET_ITEM_ID
	FORCED_MARKET_ITEM_ID = itemId

	local ok = SpawnMarketItem()
	FORCED_MARKET_ITEM_ID = prevId

	if ok then
		local npcData = ActiveNPCs[#ActiveNPCs]
		if npcData then
			npcData.IsTutorial = true
			npcData.Instance:SetAttribute("Price", 1)
			npcData.Instance:SetAttribute("EventActive", true)
			if npcData.Prompt then
				npcData.Prompt:SetAttribute("Price", 1)
				npcData.Prompt:SetAttribute("EventActive", true)
			end

			task.delay(2.5, function()
				if npcData.Move then npcData.Move:Stop() end
				if npcData.WalkAnimTrack then npcData.WalkAnimTrack:Stop() end
			end)
		end
	end

	return ok
end

return MarketService