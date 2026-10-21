--[[
	ShoppingBagService (Server)
	- 구매 완료 후 캐릭터 왼손에 실제 ShoppingBag 모델을 붙여 "임시 보관" 상태를 만든다.
	- DepositPart(예: Floor) 터치 시 인벤토리에 저장하고 Bag를 제거한다.
	- 여러 층 Floor를 동시에 바인딩 가능
	- 사망 / 리스폰 / 퇴장 시 운반 상태를 강제로 정리한다.
]]

local ShoppingBagService = {}

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local AnalyticsService = game:GetService("AnalyticsService")

-- Modules
local Constants = require(ReplicatedStorage.Shared.Constants)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)
local Utils = require(ReplicatedStorage.Shared.Utils)

local DataService
local NotifyService
local EffectService

-- [자산 로드]
local Templates = ReplicatedStorage:WaitForChild("Templates")
local BagTemplate = Templates:WaitForChild("ShoppingBag")

-- Config
local BAG_NAME = "Shopping"
local DEFAULT_COOLDOWN = 0.75
local FALLBACK_OFFSET = CFrame.new(0, -0.35, -0.6) * CFrame.Angles(0, math.rad(90), 0)

-- State
-- [userId] = { Connections = {}, LastAt = 0, IsProcessing = false }
local DepositStateByUserId = {}

-- [userId] = { CharacterAddedConn = RBXScriptConnection?, CharacterRemovingConn = RBXScriptConnection?, DiedConn = RBXScriptConnection? }
local CharacterStateByUserId = {}

--------------------------------------------------------------------------------
-- [HELPER]
--------------------------------------------------------------------------------
local function SetCarrying(player, isCarrying)
	if player and player.Parent then
		-- 1. 운반 상태 업데이트
		player:SetAttribute("IsCarryingItem", isCarrying == true)

		-- 2. 중앙 속도 계산기 호출 (알아서 디버프/버프까지 다 계산해서 갱신해줌!)
		local character = player.Character
		if character then
			local SkillUtil = require(game:GetService("ReplicatedStorage").Shared.SkillUtil)
			SkillUtil.UpdateWalkSpeed(character)
		end
	end
end

local function GetLeftHand(character)
	local hand = character:FindFirstChild("LeftHand")
	if hand and hand:IsA("BasePart") then
		return hand
	end

	local arm = character:FindFirstChild("Left Arm")
	if arm and arm:IsA("BasePart") then
		return arm
	end

	return nil
end

local function GetBag(character)
	return character:FindFirstChild(BAG_NAME)
end

local function ClearBag(character)
	local old = GetBag(character)
	if old then
		old:Destroy()
	end
end

local function HasCapacity(data)
	if type(data) ~= "table" then
		return false
	end

	if type(data.Inventory) ~= "table" then
		return false
	end

	local capacity = Utils.GetStorageCapacity(data)
	if type(capacity) ~= "number" then
		return false
	end

	return #data.Inventory < capacity
end

local function CreateBagInstance()
	local bag = BagTemplate:Clone()
	bag.Name = BAG_NAME

	local bagBasePart = nil

	if bag:IsA("BasePart") then
		bag.CanCollide = false
		bag.Massless   = true
		bag.Anchored   = false
		bagBasePart    = bag
	else
		for _, part in ipairs(bag:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Massless   = true
				part.Anchored   = false
				if not bagBasePart then
					bagBasePart = part
				end
			end
		end
		if not bagBasePart and bag:IsA("Model") then
			bagBasePart = bag.PrimaryPart or bag:FindFirstChildWhichIsA("BasePart", true)
		end
	end

	-- 💡 [수정] 화면을 가리던 ProximityPrompt 생성 코드를 완전히 삭제했습니다!
	-- 클라이언트 GUI 버튼이 이 역할을 대신하게 됩니다.

	return bag
end

local function AttachBagToHand(character, bagInstance)
	local hand = GetLeftHand(character)
	if not hand then
		return false, "NO_HAND"
	end

	local bagAtt = nil

	if bagInstance:IsA("BasePart") then
		bagAtt = bagInstance:FindFirstChildWhichIsA("Attachment")
	else
		for _, desc in ipairs(bagInstance:GetDescendants()) do
			if desc:IsA("Attachment") then
				bagAtt = desc
				break
			end
		end
	end

	if bagAtt then
		local targetCFrame = hand.CFrame * bagAtt.CFrame:Inverse()

		if bagInstance:IsA("Model") then
			bagInstance:PivotTo(targetCFrame)
		else
			bagInstance.CFrame = targetCFrame
		end
	else
		if bagInstance:IsA("Model") then
			bagInstance:PivotTo(hand.CFrame * FALLBACK_OFFSET)
		else
			bagInstance.CFrame = hand.CFrame * FALLBACK_OFFSET
		end
	end

	local bagPartToWeld = bagInstance
	if bagInstance:IsA("Model") then
		bagPartToWeld = bagInstance.PrimaryPart or bagInstance:FindFirstChildWhichIsA("BasePart", true)
	end

	if not bagPartToWeld then
		return false, "NO_PART_IN_BAG"
	end

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = bagPartToWeld
	weld.Parent = bagPartToWeld -- Parent LAST

	return true
end

local function IsCharacterTouch(player, hit)
	local character = player.Character
	if not character then
		return false
	end

	if typeof(hit) ~= "Instance" then
		return false
	end

	if not hit:IsA("BasePart") then
		return false
	end

	if not hit:IsDescendantOf(character) then
		return false
	end

	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return false
	end

	local bag = GetBag(character)
	if bag then
		if hit == bag or hit:IsDescendantOf(bag) then
			return false
		end
	end

	return true
end

local function DisconnectCharacterState(userId)
	local state = CharacterStateByUserId[userId]
	if not state then
		return
	end

	for _, conn in pairs(state) do
		if conn then
			conn:Disconnect()
		end
	end

	CharacterStateByUserId[userId] = nil
end

--------------------------------------------------------------------------------
-- [LIFECYCLE HELPERS]
--------------------------------------------------------------------------------
function ShoppingBagService:ResetCarryState(player, reason)
	if not (player and player.Parent) then
		return
	end

	local character = player.Character
	if character then
		ClearBag(character)
	end

	SetCarrying(player, false)

	if DataService then
		local data = DataService:Get(player)
		if data then
			data.PendingBagItem = nil
		end
		DataService:Set(player, "PendingBagItem", nil)
	end
end

function ShoppingBagService:BindCharacter(player, character)
	if not (player and player.Parent and character) then
		return
	end

	local userId = player.UserId
	DisconnectCharacterState(userId)

	local humanoid = character:FindFirstChildWhichIsA("Humanoid")

	CharacterStateByUserId[userId] = {}

	if humanoid then
		CharacterStateByUserId[userId].DiedConn = humanoid.Died:Connect(function()
			self:ResetCarryState(player, "Died")
		end)
	end
end

function ShoppingBagService:WatchPlayer(player)
	if not (player and player.Parent) then
		return
	end

	local userId = player.UserId
	DisconnectCharacterState(userId)

	CharacterStateByUserId[userId] = {}

	CharacterStateByUserId[userId].CharacterAddedConn = player.CharacterAdded:Connect(function(character)
		self:ResetCarryState(player, "CharacterAdded")
		self:BindCharacter(player, character)
	end)

	CharacterStateByUserId[userId].CharacterRemovingConn = player.CharacterRemoving:Connect(function()
		self:ResetCarryState(player, "CharacterRemoving")
	end)

	if player.Character then
		self:ResetCarryState(player, "WatchPlayerInit")
		self:BindCharacter(player, player.Character)
	end
end

function ShoppingBagService:UnwatchPlayer(player)
	if not player then
		return
	end

	DisconnectCharacterState(player.UserId)
end

--------------------------------------------------------------------------------
-- [PUBLIC] Bag API
--------------------------------------------------------------------------------
function ShoppingBagService:HasBag(player)
	local character = player and player.Character
	if not character then
		return false
	end

	return GetBag(character) ~= nil
end

function ShoppingBagService:GetBagInfo(player)
	local character = player and player.Character
	if not character then
		return nil
	end

	local bag = GetBag(character)
	if not bag then
		return nil
	end

	local itemId = bag:GetAttribute("Id")
	local rarity = bag:GetAttribute("Rarity")

	if typeof(itemId) ~= "string" or itemId == "" then
		return nil
	end

	if typeof(rarity) ~= "string" or rarity == "" then
		return nil
	end

	return {
		Id = itemId,
		Rarity = rarity,
	}
end

function ShoppingBagService:GiveBag(player, itemId, rarity, opts)
	if not player or not player.Parent then
		return false, "NO_PLAYER"
	end

	if typeof(itemId) ~= "string" or itemId == "" then
		return false, "BAD_ITEMID"
	end

	if typeof(rarity) ~= "string" or rarity == "" then
		return false, "BAD_RARITY"
	end

	local character = player.Character
	if not character then
		return false, "NO_CHARACTER"
	end

	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false, "CHARACTER_DEAD"
	end

	if player:GetAttribute("IsCarryingItem") == true then
		local hasRealBag = self:HasBag(player)
		if not hasRealBag then
			self:ResetCarryState(player, "StaleBagState")
		else
			return false, "ALREADY_CARRYING"
		end
	end

	local bagInstance = CreateBagInstance()
	bagInstance:SetAttribute("Id", itemId)
	bagInstance:SetAttribute("Rarity", rarity)
	bagInstance:SetAttribute("AcquiredAt", (opts and opts.AcquiredAt) or os.time())

	local head = character:FindFirstChild("Head")
	if head and EffectService then
		EffectService:PlayPurchaseEffect(head, rarity, itemId)
	end

	local okAttach, reason = AttachBagToHand(character, bagInstance)
	if not okAttach then
		bagInstance:Destroy()
		return false, reason
	end

	bagInstance.Parent = character -- Parent LAST
	SetCarrying(player, true)

	if DataService then
		local data = DataService:Get(player)
		if data then
			data.PendingBagItem = {
				Id = itemId,
				Rarity = rarity,
				AcquiredAt = os.time(),
				Source = (opts and opts.Source) or "Market",
			}
		end
		DataService:Set(player, "PendingBagItem", {
			Id = itemId,
			Rarity = rarity,
			AcquiredAt = os.time(),
			Source = (opts and opts.Source) or "Market",
		})
	end

	return true
end

function ShoppingBagService:Clear(player)
	local character = player and player.Character
	if character then
		ClearBag(character)
	end

	SetCarrying(player, false)

	if DataService then
		local data = DataService:Get(player)
		if data then
			data.PendingBagItem = nil
		end
		DataService:Set(player, "PendingBagItem", nil)
	end
end

--------------------------------------------------------------------------------
-- [PUBLIC] Deposit API
--------------------------------------------------------------------------------
function ShoppingBagService:TryDeposit(player, source)
	if not player or not player.Parent then
		return false, "NO_PLAYER"
	end

	local character = player.Character
	if not character then
		return false, "NO_CHARACTER"
	end

	local bag = GetBag(character)
	if not bag then
		return false, "NO_BAG"
	end

	local itemId = bag:GetAttribute("Id")
	local rarity = bag:GetAttribute("Rarity")

	if typeof(itemId) ~= "string" or itemId == "" then
		return false, "BAD_BAG_DATA"
	end

	if typeof(rarity) ~= "string" or rarity == "" then
		return false, "BAD_BAG_DATA"
	end

	local data = DataService and DataService:Get(player)
	if not data then
		return false, "NO_DATA"
	end

	if not HasCapacity(data) then
		if NotifyService then
			NotifyService:NotifyPlayer(player, Utils.FormatByKey(player, "ERR_BAG_INV_FULL", nil, "인벤토리가 꽉 찼습니다!"), "Error")
		end
		return false, "FULL"
	end

	table.insert(data.Inventory, {
		Id = itemId,
		Rarity = rarity,
		AcquiredAt = os.time(),
		Source = source or "Deposit",
	})

	data.PendingBagItem = nil

	DataService:Set(player, "Inventory", data.Inventory)
	DataService:Set(player, "PendingBagItem", nil)

	if type(data.CollectionLog) ~= "table" then
		data.CollectionLog = {}
	end

	data.CollectionLog[itemId] = true
	DataService:Set(player, "CollectionLog", data.CollectionLog)

	-- 📊 [Analytics] 총 수집한 고유 아이템 개수 계산 및 전송 (여기부터 복사)
	pcall(function()
		local totalCollected = 0
		for _, _ in pairs(data.CollectionLog) do
			totalCollected += 1
		end
		-- 대시보드 표시명: "Total_Items_Collected" (값: 현재 수집한 고유 아이템 총 개수)
		AnalyticsService:LogCustomEvent(player, "Total_Items_Collected", totalCollected)
		--print(string.format("📊 [Analytics] 아이템 수집 갱신: %s | 총 %d개 수집", player.Name, totalCollected))
	end)

	local itemInfo = ItemDatabase.ITEMS[itemId]
	local itemName = itemInfo and itemInfo.Name or itemId

	if NotifyService then
		if rarity == Constants.RARITY.B6 then
			--local globalMsg = Utils.FormatByKey(
			--	nil,
			--	"MSG_GLOBAL_B6_ACQUIRED",
			--	{ player = tostring(player.Name), item = tostring(itemName) },
			--	string.format("🎉 %s님이 [B6] %s 아이템을 획득했습니다!", player.Name, itemName)
			--)
			--NotifyService:BroadcastItem(globalMsg, "Global")
		else
			local msg = Utils.FormatByKey(player, "MSG_ITEM_SAVED", nil, "아이템 보관 완료! 인벤토리에서 확인할 수 있어요.")
			NotifyService:NotifyPlayer(player, msg, "Success")
		end
	end

	local head = character:FindFirstChild("Head")
	if head and EffectService then
		EffectService:PlayDepositEffect(head, rarity, itemId)
	end

	SetCarrying(player, false)
	bag:Destroy()

	return true
end

function ShoppingBagService:UnbindDeposit(player)
	if not player then
		return
	end

	local st = DepositStateByUserId[player.UserId]
	if not st then
		return
	end

	if type(st.Connections) == "table" then
		for _, conn in ipairs(st.Connections) do
			if conn then
				conn:Disconnect()
			end
		end
	end

	DepositStateByUserId[player.UserId] = nil
end

function ShoppingBagService:BindDepositPart(player, depositPart, opts)
	if not player or not player.Parent then
		return false, "NO_PLAYER"
	end

	if not (depositPart and depositPart:IsA("BasePart")) then
		return false, "BAD_PART"
	end

	return self:BindDepositParts(player, { depositPart }, opts)
end

function ShoppingBagService:BindDepositParts(player, depositParts, opts)
	if not player or not player.Parent then
		return false, "NO_PLAYER"
	end

	if type(depositParts) ~= "table" then
		return false, "BAD_PARTS"
	end

	self:UnbindDeposit(player)

	local cooldown = (opts and opts.Cooldown) or DEFAULT_COOLDOWN

	DepositStateByUserId[player.UserId] = {
		Connections = {},
		LastAt = 0,
		IsProcessing = false,
	}

	local st = DepositStateByUserId[player.UserId]

	for _, depositPart in ipairs(depositParts) do
		if depositPart and depositPart:IsA("BasePart") then
			local conn = depositPart.Touched:Connect(function(hit)
				local state = DepositStateByUserId[player.UserId]
				if not state then
					return
				end

				if state.IsProcessing then
					return
				end

				if not IsCharacterTouch(player, hit) then
					return
				end

				-- [버그 수정] PVP 피격으로 가방이 막 드롭된 직후엔 deposit 차단
				-- BagBlastStunned 상태이거나 IsCarryingItem이 false면(이미 드롭됨) 무시
				local character = player.Character
				if character then
					if character:GetAttribute("BagBlastStunned") == true then
						return
					end
					if character:GetAttribute("PaparazziStunned") == true then
						return
					end
					if character:GetAttribute("IsBalloonLifted") == true then
						return
					end
				end
				-- IsCarryingItem이 false면 가방이 이미 손에 없으므로 무시
				if player:GetAttribute("IsCarryingItem") ~= true then
					return
				end

				local now = os.clock()
				if (now - (state.LastAt or 0)) < cooldown then
					return
				end

				state.IsProcessing = true
				state.LastAt = now

				self:TryDeposit(player, "FloorTouched")

				state.IsProcessing = false
			end)

			table.insert(st.Connections, conn)
		end
	end

	if #st.Connections <= 0 then
		DepositStateByUserId[player.UserId] = nil
		return false, "NO_VALID_PARTS"
	end

	return true
end

--------------------------------------------------------------------------------
-- [LIFECYCLE]
--------------------------------------------------------------------------------
function ShoppingBagService:Init()
	DataService = require(ServerScriptService.Services.DataService)
	NotifyService = require(ServerScriptService.Services.NotifyService)
	EffectService = require(ServerScriptService.Services.EffectService)

	for _, player in ipairs(Players:GetPlayers()) do
		self:WatchPlayer(player)
	end

	Players.PlayerAdded:Connect(function(player)
		self:WatchPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:ResetCarryState(player, "PlayerRemoving")
		self:UnbindDeposit(player)
		self:UnwatchPlayer(player)
	end)
end

return ShoppingBagService