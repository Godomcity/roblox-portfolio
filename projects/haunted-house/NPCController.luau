-- ReplicatedStorage에 위치한 ModuleScript, 이름: NPCController

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")

-- [추가] 모듈 상단에서 SoundManager를 한번만 불러옵니다.
local soundManager = require(ReplicatedStorage:WaitForChild("SoundManager"))

local NPCController = {}
NPCController.__index = NPCController

function NPCController.new(npc, config)
	local self = setmetatable({}, NPCController)

	self.npc = npc
	self.config = config
	self.hitbox = npc:WaitForChild("Hitbox")
	self.humanoid = npc:WaitForChild("Humanoid")
	self.hrp = npc:WaitForChild("HumanoidRootPart")
	self.animator = self.humanoid:WaitForChild("Animator")

	self.currentState = "Patrol"
	self.target = nil
	self.isChasing = false
	self.lastAttackTime = 0
	self.chaseStartTime = 0

	self.overrideTarget = nil
	self.overrideUntil = 0

	-- [추가] 플레이어를 마지막으로 본 시간을 기록할 변수
	self.lastSeenTimestamp = 0

	self.patrolPoints = {}
	self.currentPatrolIndex = 1

	-- [추가] Path 실행 플래그
	self.isFollowingPath = false

	self.animations = {}
	if self.config.AnimationIds then
		for name, id in pairs(self.config.AnimationIds) do
			local anim = Instance.new("Animation")
			anim.AnimationId = "rbxassetid://" .. id
			self.animations[name] = self.animator:LoadAnimation(anim)
		end
	end

	self:Initialize()
	self:BindHitBox()
	return self
end

function NPCController:Initialize()
	self:LoadPatrolPoints()
	self.visionCone = self:CreateVisionCone()

	RunService.Heartbeat:Connect(function() self:Update() end)
end

function NPCController:BindHitBox()
	
	self.hitbox.Touched:Connect(function(otherPart)

		local character = otherPart.Parent
		if not character then return end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid then return end

		local player = game.Players:GetPlayerFromCharacter(character)
		if not player then return end

		-- 쿨다운 체크 (AttackCooldown 사용)
		if not self.lastHitTime or tick() - self.lastHitTime >= self.config.Stats.AttackCooldown then
			local damage = self.config.Stats.AttackDamage or 1
			-- 체력이 1 이하로 내려가지 않도록 보정
			if humanoid.Health - damage < 1 then
				damage = humanoid.Health - 1
			end

			if damage > 0 then
				humanoid:TakeDamage(damage)
				ReplicatedStorage.PlayerHitEvent:FireClient(player, humanoid)
			end

			-- UniqueBehaviors.OnAttackLanded 실행
			if self.config.UniqueBehaviors and self.config.UniqueBehaviors.OnAttackLanded then
				self.config.UniqueBehaviors.OnAttackLanded(self.npc, player, self)
			end

			self.lastHitTime = tick()
		end
	end)
end

function NPCController:MoveToPoint(targetPosition)
	local path = PathfindingService:CreatePath({
		AgentRadius = 3,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentJumpHeight = 6,
		AgentMaxSlope = 45,
	})

	path:ComputeAsync(self.hrp.Position, targetPosition)

	if path.Status == Enum.PathStatus.Success then
		local waypoints = path:GetWaypoints()

		-- 디버그: 웨이포인트 표시
		--for _, waypoint in ipairs(waypoints) do
		--	local part = Instance.new("Part")
		--	part.Shape = Enum.PartType.Ball
		--	part.Size = Vector3.new(0.5,0.5,0.5)
		--	part.Anchored = true
		--	part.CanCollide = false
		--	part.Color = Color3.fromRGB(0, 170, 255) -- 파란색
		--	part.Position = waypoint.Position
		--	part.Parent = workspace
		--game:GetService("Debris"):AddItem(part, 2)
		--end

		self.isFollowingPath = true
		for _, waypoint in ipairs(waypoints) do
			self.humanoid:MoveTo(waypoint.Position)
			task.wait(0.3) -- 간단 대기 (엄격한 도착 판정 대신)
		end
		self.isFollowingPath = false
	else
		warn("NPC " .. self.npc.Name .. " path failed.")

		-- 디버그: 실패 지점 표시
		--local failPart = Instance.new("Part")
		--failPart.Shape = Enum.PartType.Ball
		--failPart.Size = Vector3.new(0.7,0.7,0.7)
		--failPart.Anchored = true
		--failPart.CanCollide = false
		--failPart.Color = Color3.fromRGB(255, 0, 0) -- 빨간색
		--failPart.Position = targetPosition
		--failPart.Parent = workspace
		--game:GetService("Debris"):AddItem(failPart, 2)
	end
end

-- [수정] 상태 변경을 감지하는 로직 추가
function NPCController:Update()
	if self.isFollowingPath then return end -- ✅ Path 이동 중에는 다른 로직 실행 안함

	local previousState = self.currentState
	local previousTarget = self.target

	if self.npc:GetAttribute("ForcedState") == "Snack" then
		if self.isChasing then self:OnChaseEnd(previousTarget) end
		self:StopAnimation("Walk")
		return
	end

	if self.config.UniqueBehaviors.IsOutOfBounds and self.config.UniqueBehaviors.IsOutOfBounds(self.hrp.Position) then
		if self.isChasing then self:OnChaseEnd(previousTarget) end
		self:ResetToPatrol()
		return
	end

	if self.currentState == "Chase" and tick() - self.chaseStartTime > 4 then
		self.target = nil
		self.lastSeenTimestamp = 0
	end

	local targetInSight = self:FindBestTarget()

	if targetInSight then
		self.target = targetInSight
		self.lastSeenTimestamp = tick()
	end

	local memoryDuration = self.config.Stats.ChaseMemoryDuration or 0
	if self.target and (tick() - self.lastSeenTimestamp < memoryDuration) then
		self.currentState = "Chase"
	else
		self.target = nil
		self.currentState = "Patrol"
	end

	if self.currentState ~= previousState then
		if self.currentState == "Chase" then
			self:OnChaseStart()
		else
			self:OnChaseEnd(previousTarget)
		end
	elseif self.currentState == "Chase" and self.target ~= previousTarget then
		if previousTarget then
			self:OnChaseEnd(previousTarget)
		end
		self:OnChaseStart()
	end

	if self.currentState == "Chase" then
		self:Chase()
	else
		self:Patrol()
	end
end

-- [추가] 추격 시작 시 1회만 호출되는 함수
function NPCController:OnChaseStart()
	self.isChasing = true
	self.chaseStartTime = tick() -- [수정] 추격 시작 시간을 기록합니다.

	if not self.target then return end

	ReplicatedStorage.WarningEvent:FireClient(self.target, true)
	soundManager.Chased()
end

function NPCController:OnChaseEnd(lostTarget)
	self.isChasing = false
	self.humanoid:MoveTo(self.hrp.Position)
	self:StopAnimation("Walk")

	self.currentPatrolIndex = self:FindClosestPatrolPoint()
	if #self.patrolPoints > 0 then
		-- ✅ Pathfinding을 비동기로 실행
		task.spawn(function()
			self:MoveToPoint(self.patrolPoints[self.currentPatrolIndex].Position)
		end)
	end

	if not lostTarget then return end

	-- ✅ 알림은 즉시 끄기
	ReplicatedStorage.WarningEvent:FireClient(lostTarget, false)
	soundManager.StopChased()
end


function NPCController:Chase()
	if not self.target or not self.target.Character then
		self:ResetToPatrol()
		return
	end

	local targetHrp = self.target.Character:FindFirstChild("HumanoidRootPart")
	if not targetHrp then return end

	local distance = (self.hrp.Position - targetHrp.Position).Magnitude

	if distance <= self.config.Stats.AttackRange then
		self:Attack()
	else
		self:PlayAnimation("Walk")
		self.humanoid:MoveTo(targetHrp.Position)
	end
end

-- ... 나머지 함수들은 이전과 동일하게 유지 ...
function NPCController:Patrol()
	if #self.patrolPoints == 0 then
		self:StopAnimation("Walk")
		return
	end

	self:PlayAnimation("Walk")
	local targetPoint = self.patrolPoints[self.currentPatrolIndex]
	self.humanoid:MoveTo(targetPoint.Position)

	if (self.hrp.Position - targetPoint.Position).Magnitude < 3 then
		self.currentPatrolIndex = self.currentPatrolIndex % #self.patrolPoints + 1
	end
end

function NPCController:Attack()
	if tick() - self.lastAttackTime < self.config.Stats.AttackCooldown then return end

	local currentTarget = self.target 
	if not currentTarget or not currentTarget.Character then return end

	local targetHumanoid = currentTarget.Character:FindFirstChildOfClass("Humanoid")
	if not (targetHumanoid and targetHumanoid.Health > 0) then
		return 
	end

	self.lastAttackTime = tick()
	self.chaseStartTime = tick()
	self.humanoid:MoveTo(self.hrp.Position) 

	-- 1. 설정에 공격 애니메이션이 있다면 재생하고, 없으면 그냥 넘어갑니다.
	self:PlayAnimation("Attack")

	-- 3. 공격이 명중하는 순간에 타겟과 거리 등을 다시 한번 확인합니다.
	local stillInTarget = self.target == currentTarget
	if not stillInTarget or not currentTarget.Character then return end

	local distance = (currentTarget.Character.HumanoidRootPart.Position - self.hrp.Position).Magnitude

	if distance <= self.config.Stats.AttackRange then
		-- 4. 모든 조건을 만족하면 그때 데미지를 줍니다.
		if targetHumanoid.Health <= 1 then return end

		local damageToDeal = self.config.Stats.AttackDamage
		if targetHumanoid.Health - damageToDeal < 1 then
			damageToDeal = targetHumanoid.Health - 1
		end

		if damageToDeal > 0 then
			targetHumanoid:TakeDamage(damageToDeal)
		end

		ReplicatedStorage.PlayerHitEvent:FireClient(currentTarget, targetHumanoid)

		if self.config.UniqueBehaviors.OnAttackLanded then
			self.config.UniqueBehaviors.OnAttackLanded(self.npc, currentTarget, self)
		end

		self:OnChaseEnd(currentTarget) -- 방금 공격했던 타겟 정보를 넘겨줍니다.

		self.target = nil

		self.currentState = "Patrol"
	end
end

function NPCController:FindBestTarget()
	local bestTarget = nil
	local minDistance = math.huge

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character and self:IsPlayerInVision(player) then
			local targetHrp = player.Character:FindFirstChild("HumanoidRootPart")
			if targetHrp then
				local distance = (self.hrp.Position - targetHrp.Position).Magnitude
				if distance < minDistance then
					minDistance = distance
					bestTarget = player
				end
			end
		end
	end
	return bestTarget
end

function NPCController:IsPlayerInVision(player)
	local char = player.Character
	if not char then return false end
	local targetHrp = char:FindFirstChild("HumanoidRootPart")
	if not targetHrp then return false end

	local direction = (targetHrp.Position - self.hrp.Position)
	local distance = direction.Magnitude

	if distance > self.config.Stats.VisionDistance then return false end

	local lookVector = self.hrp.CFrame.LookVector
	local angle = math.deg(math.acos(lookVector:Dot(direction.Unit)))

	return angle < self.config.Stats.VisionAngle / 2
end

function NPCController:ResetToPatrol()
	self.currentState = "Patrol"
	self.target = nil
	self.overrideTarget = nil
	self:StopAnimation("Walk")

	-- [추가] 리셋 시에도 현재 움직임을 즉시 멈추도록 합니다.
	self.humanoid:MoveTo(self.hrp.Position)

	if #self.patrolPoints > 0 then
		self.npc:SetPrimaryPartCFrame(CFrame.new(self.patrolPoints[self.currentPatrolIndex].Position))
	end
end

function NPCController:LoadPatrolPoints()
	local patrolConfig = self.config.Patrol
	if not patrolConfig then return end

	local foundPoints = {}
	if patrolConfig.QueryType == "Folder" then
		local folder = workspace:WaitForChild(patrolConfig.Query)
		for _, part in ipairs(folder:GetChildren()) do
			if part:IsA("Part") then table.insert(foundPoints, part) end
		end
		table.sort(foundPoints, function(a, b) return tonumber(a.Name) < tonumber(b.Name) end)
	elseif patrolConfig.QueryType == "Pattern" then
		for _, part in ipairs(workspace:GetChildren()) do
			if part:IsA("Part") and part.Name:match(patrolConfig.Query) then
				table.insert(foundPoints, part)
			end
		end
		table.sort(foundPoints, function(a, b) return tonumber(a.Name:match("%d+")) < tonumber(b.Name:match("%d+")) end)
	end
	self.patrolPoints = foundPoints
end

function NPCController:PlayAnimation(name)
	if self.animations[name] and not self.animations[name].IsPlaying then
		self.animations[name]:Play()
	end
end

function NPCController:StopAnimation(name)
	if self.animations[name] and self.animations[name].IsPlaying then
		self.animations[name]:Stop()
	end
end

function NPCController:CreateVisionCone()
	local conePart = Instance.new("Part")
	conePart.Name = "VisionCone"
	conePart.Size = Vector3.new(0.1, 0.1, 0.1)
	conePart.Anchored = false
	conePart.CanCollide = false
	conePart.CanTouch = false
	conePart.CanQuery = false
	conePart.Transparency = 0.7
	conePart.Color = Color3.fromRGB(255, 255, 0)
	conePart.Parent = self.npc
	local mesh = Instance.new("SpecialMesh", conePart)
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = "rbxassetid://1033714"
	local angle = self.config.Stats.VisionAngle
	local distance = self.config.Stats.VisionDistance
	local width = distance * math.tan(math.rad(angle / 2)) * 2
	mesh.Scale = Vector3.new(width, distance, width)
	local CFrame_Offset = CFrame.new(0, 0, -distance / 2) * CFrame.Angles(math.rad(90), 0, 0)
	conePart.CFrame = self.hrp.CFrame * CFrame_Offset
	local weld = Instance.new("WeldConstraint", conePart)
	weld.Part0 = conePart
	weld.Part1 = self.hrp
	return conePart
end

function NPCController:FindClosestPatrolPoint()
	if #self.patrolPoints == 0 then return self.currentPatrolIndex end

	local closestIndex = 1
	local minDistance = math.huge

	for i, point in ipairs(self.patrolPoints) do
		local distance = (self.hrp.Position - point.Position).Magnitude
		if distance < minDistance then
			minDistance = distance
			closestIndex = i
		end
	end
	return closestIndex
end

return NPCController