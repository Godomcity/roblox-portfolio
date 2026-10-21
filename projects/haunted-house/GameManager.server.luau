-- 서버스크립트
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local playersReady = {}
local tutorialStarted = false

local drawersFolder = workspace:WaitForChild("Curse"):WaitForChild("kitchen"):WaitForChild("Side_Table_m"):WaitForChild("DrawersFolder")
local keyTemplate = ReplicatedStorage:WaitForChild("BlueKey")
local numberOfKeys = 1

local gameStartEvent = ReplicatedStorage:WaitForChild("GameStartEvent")
local readyEvent = ReplicatedStorage:WaitForChild("ReadyEvent")

local allDrawers = drawersFolder:GetChildren()
local loadedPlayers = {}

local dollPrefab = ReplicatedStorage:WaitForChild("Amy")
local amydo = ReplicatedStorage:WaitForChild("Amydo")
local dogSnack = ReplicatedStorage:WaitForChild("DogSnack")
local purpleKey = ReplicatedStorage:WaitForChild("PurpleKey")
local floorPartsFolder = workspace:WaitForChild("Curse"):WaitForChild("cursehouse2"):WaitForChild("FloorFolder")
local playerDefeatedEvent = ReplicatedStorage:WaitForChild("PlayerDefeatedEvent")

local floorParts = floorPartsFolder:GetChildren()


local soundManager = require(ReplicatedStorage:WaitForChild("SoundManager"))

local itemHeldEvent = ReplicatedStorage:WaitForChild("ItemHeldEvent")
local itemUsedEvent = ReplicatedStorage:WaitForChild("ItemUsedEvent")
local heldItems = {}

-- 거리 검사 관련 변수
local zoneParts = {} -- 각 구역의 파트들을 저장할 테이블. 예: zoneParts["ZoneA"] = {part1, part2}
local availableZones = {} -- 아이템을 생성할 수 있는 남아있는 구역 이름 목록
local count = 0

local readyValue = Instance.new("IntValue")
readyValue.Parent = game.ServerStorage
readyValue.Name = "readyValue"


-- Workspace에 있는 Zone 폴더들을 찾아서 정보를 저장합니다.
for _, item in ipairs(workspace:GetChildren()) do
	-- 이름이 "Zone"으로 시작하는 폴더를 찾습니다.
	if item:IsA("Folder") and item.Name:match("^Zone") then
		local partsInZone = {}
		for _, part in ipairs(item:GetChildren()) do
			if part:IsA("BasePart") then
				table.insert(partsInZone, part)
			end
		end

		-- 파트가 하나라도 있는 유효한 구역만 등록합니다.
		if #partsInZone > 0 then
			zoneParts[item.Name] = partsInZone
			table.insert(availableZones, item.Name)
			print("구역 발견:", item.Name, "(".. #partsInZone .."개의 파트)")
		end
	end
end

local function getRandomPositionInPart(part)
	local size = part.Size
	local position = part.Position
	local randomX = position.X --+ (math.random() - 0.5) * size.X
	local randomZ = position.Z --+ (math.random() - 0.5) * size.Z
	local y = position.Y + size.Y / 2 + 1.3 + 3
	return Vector3.new(randomX, y, randomZ)
end

local purpleKeySpawnParts = workspace:WaitForChild("PurpleKeySpawner"):GetChildren()

local function getRandomValidPositionFromZone()
	
	if #availableZones == 0 then
		warn("생성 가능 구역이 없어 목록을 초기화합니다.")
		for zoneName, _ in pairs(zoneParts) do
			table.insert(availableZones, zoneName)
		end
	end
	
	if #availableZones == 0 then
		warn("일반 아이템을 생성할 구역이 남아있지 않습니다!")
		return nil
	end

	local randomZoneIndex = math.random(1, #availableZones)
	local chosenZoneName = availableZones[randomZoneIndex]
	table.remove(availableZones, randomZoneIndex)

	local partsInChosenZone = zoneParts[chosenZoneName]
	local randomPart = partsInChosenZone[math.random(1, #partsInChosenZone)]

	print(chosenZoneName .. " 구역에 일반 아이템 생성 시도...")
	return getRandomPositionInPart(randomPart)
end


local function spawnDollAtRandomFloor()
	local pos = getRandomValidPositionFromZone()
	if pos then
		local doll = dollPrefab:Clone()
		doll:PivotTo(CFrame.new(pos))
		doll.Parent = workspace
	end
end

local function Randomkey()
	for i = #allDrawers, 2, -1 do
		local j = math.random(1, i)
		allDrawers[i], allDrawers[j] = allDrawers[j], allDrawers[i]
	end

	for i = 1, numberOfKeys do
		local drawer = allDrawers[i]
		if drawer then
			local keyClone = keyTemplate:Clone()
			keyClone.Parent = drawer
			keyClone.Handle.Position = drawer.Position + Vector3.new(-0.5, 0.5, 0)
		end
	end
end

local function RandomAmyItem()
	local pos = getRandomValidPositionFromZone()
	if pos then
		local amydoClone = amydo:Clone()
		amydoClone:PivotTo(CFrame.new(pos))
		amydoClone.Parent = workspace
	end
end

local function RandomGreenPigItem()
	local pos = getRandomValidPositionFromZone()
	if pos then
		local dogSnackClone = dogSnack:Clone()
		dogSnackClone:PivotTo(CFrame.new(pos))
		dogSnackClone.Parent = workspace
	end
end


local function RandomPupleKey()
	if #purpleKeySpawnParts == 0 then
		warn("PurpleKeySpawner 폴더에 스폰 파트가 없습니다!")
		return
	end

	-- 전용 스폰 파트 목록에서 무작위로 파트를 선택
	local randomPart = purpleKeySpawnParts[math.random(1, #purpleKeySpawnParts)]
	local pos = getRandomPositionInPart(randomPart)

	if pos then
		print("PurpleKeySpawner 전용 구역에 보라색 열쇠 생성.")
		local purpleKeyClone = purpleKey:Clone()
		purpleKeyClone:PivotTo(CFrame.new(pos))
		purpleKeyClone.Parent = workspace
	end
end

local function GetPlayerInfo()
	soundManager.PlayBGM()
end

local function startTutorial()
	-- 게임 시작 시 사용 가능한 구역 목록을 다시 채워줍니다.
	availableZones = {}
	for zoneName, _ in pairs(zoneParts) do
		table.insert(availableZones, zoneName)
	end
	print("새 게임 시작. 모든 구역을 다시 사용 가능하도록 설정합니다.")
	
	--RandomPupleKey() 
	-- 총 5개의 아이템이 각기 다른 구역에 생성됩니다.
	spawnDollAtRandomFloor() -- 인형 1
	spawnDollAtRandomFloor() -- 인형 2
	spawnDollAtRandomFloor() -- 인형
	      -- 보라 열쇠
	RandomAmyItem()        -- 아미도
	RandomGreenPigItem()   -- 개껌

	Randomkey() -- 서랍 속 열쇠는 구역과 상관없이 생성
	gameStartEvent:FireAllClients()
	
end

local function onPlayerReady(player)
	table.insert(playersReady, player)

	local currentPlayers = Players:GetPlayers()
	for _, p in ipairs(currentPlayers) do
		if not table.find(playersReady, p) then
			return
		end
	end

	if not tutorialStarted then
		tutorialStarted = true
		startTutorial()
	end
end

local function respawnItem(itemName)
	task.wait(1)

	-- 아이템 재생성 시, 해당 아이템의 이전 위치는 더 이상 고려하지 않아도 되지만,
	-- 현재 시스템은 위치 기록을 초기화하지 않으므로 새 게임이 시작되기 전까지는 계속 누적됩니다.
	-- 이는 의도된 동작일 수 있으므로 그대로 둡니다.

	if itemName == "BlueKey" then
		print("나간 유저가 BlueKey를 소지하여 재생성합니다.")
		Randomkey()
	elseif itemName == "Amydo" then
		print("나간 유저가 Amydo를 소지하여 재생성합니다.")
		RandomAmyItem()
	elseif itemName == "DogSnack" then
		print("나간 유저가 DogSnack을 소지하여 재생성합니다.")
		RandomGreenPigItem()
	elseif itemName == "PurpleKey" then
		print("나간 유저가 PurpleKey를 소지하여 재생성합니다.")
		RandomPupleKey()
	elseif itemName == "Amy" then -- [[ 이 부분을 추가해주세요 ]]
		print("나간 유저가 인형(Amy)을 소지하여 재생성합니다.")
		spawnDollAtRandomFloor() -- 인형을 생성하는 함수 호출
	end
end

local collisionGroupName = "Player"
pcall(function()
	-- RegisterCollisionGroup 사용 (새로운 방식)
	PhysicsService:RegisterCollisionGroup(collisionGroupName)
end)

-- 그룹끼리 충돌 안 하도록 설정
PhysicsService:CollisionGroupSetCollidable(collisionGroupName, collisionGroupName, false)

-- 캐릭터의 모든 파트를 Players 그룹으로 설정
local function setCharacterCollisionGroup(character)
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = collisionGroupName
		end
	end
end

local function dropAndRespawnPlayerItems(player)
	local itemsHeldByPlayer = heldItems[player]

	if itemsHeldByPlayer and #itemsHeldByPlayer > 0 then
		print(player.Name .. "이(가) 소지하고 있던 아이템을 모두 드랍합니다:", table.concat(itemsHeldByPlayer, ", "))
		for _, itemName in ipairs(itemsHeldByPlayer) do
			respawnItem(itemName)
		end
		heldItems[player] = nil -- 처리 후 소지 목록 비우기
	end
end

Players.PlayerAdded:Connect(function(player)
	task.wait(1)
	GetPlayerInfo()
	
	onPlayerReady(player)
	
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("HumanoidRootPart")
		task.wait(0.1)
		setCharacterCollisionGroup(character)
	end)
	
	if player.Character then
		local character = player.Character
		character:WaitForChild("HumanoidRootPart")
		task.wait(0.1)
		setCharacterCollisionGroup(character)
	end
	
end)

--for _, player in ipairs(game.Players:GetPlayers()) do
--	if player.Character then
--		setCharacterCollisionGroup(player.Character)
--	end
--	player.CharacterAdded:Connect(function(character)
--		character:WaitForChild("HumanoidRootPart")
--		task.wait(0.1)
--		setCharacterCollisionGroup(character)
--	end)
--end

itemHeldEvent.Event:Connect(function(player, itemName)
	print(player.Name .. "이(가) " .. itemName .. "을(를) 획득했습니다.")
	if not heldItems[player] then
		heldItems[player] = {}
	end

	-- 플레이어의 아이템 목록에 획득한 아이템을 추가합니다.
	table.insert(heldItems[player], itemName)
end)

itemUsedEvent.Event:Connect(function(player, usedItemName)
	-- 해당 플레이어의 소지품 목록이 있는지 확인
	if heldItems[player] then
		-- 목록을 처음부터 끝까지 순회
		for i = #heldItems[player], 1, -1 do
			-- 현재 보고 있는 아이템 이름이 사용된 아이템 이름과 같다면
			if heldItems[player][i] == usedItemName then
				print(player.Name .. "이(가) " .. usedItemName .. "을(를) 사용했습니다. 소지 목록에서 제거합니다.")
				-- 목록에서 해당 아이템을 제거
				table.remove(heldItems[player], i)
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	for i, p in ipairs(playersReady) do
		if p == player then
			table.remove(playersReady, i)
			break
		end
	end
	
	readyValue.Value = #Players:GetPlayers()
	
	dropAndRespawnPlayerItems(player)
end)

playerDefeatedEvent.Event:Connect(function(player)
	print(player.Name .. "이(가) NPC에게 잡혀 아이템을 모두 드랍합니다.")
	-- 새로 만든 공용 함수를 호출
	dropAndRespawnPlayerItems(player)
end)