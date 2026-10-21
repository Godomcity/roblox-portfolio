--[[
    - 클라이언트 시작점
    - Controllers 폴더의 모든 모듈을 로드하고 Init -> Start 순서로 실행
    - 리스폰 시 OnCharacterAdded 함수 호출
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- 컨트롤러들이 들어있는 폴더 위치 (StarterPlayerScripts/Controllers)
local PlayerScripts = Players.LocalPlayer:WaitForChild("PlayerScripts")
local ControllersFolder = PlayerScripts:WaitForChild("Controllers")

local loadedControllers = {}

-- 1. 모든 컨트롤러 모듈 Require (로드)
for _, module in ipairs(ControllersFolder:GetChildren()) do
	if module:IsA("ModuleScript") then
		local success, result = pcall(function()
			return require(module)
		end)

		if success then
			loadedControllers[module.Name] = result
		else
			warn("❌ Failed to load " .. module.Name .. ": " .. result)
		end
	end
end

-- 2. Init 실행 (초기화)
for name, controller in pairs(loadedControllers) do
	if type(controller.Init) == "function" then
		task.spawn(function()
			controller:Init()
		end)
	end
end

-- 3. Start 실행 (루프 및 이벤트 리스닝 시작)
for name, controller in pairs(loadedControllers) do
	if type(controller.Start) == "function" then
		task.spawn(function()
			controller:Start()
		end)
	end
end

-- 4. 리스폰 시 OnCharacterAdded 함수 호출
local player = Players.LocalPlayer
player.CharacterAdded:Connect(function(character)
	task.wait(0.5) -- UI가 완전히 로드될 때까지 대기
	
	for name, controller in pairs(loadedControllers) do
		if type(controller.OnCharacterAdded) == "function" then
			task.spawn(function()
				controller:OnCharacterAdded(character)
			end)
		end
	end
end)