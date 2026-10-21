--[[
	[서버 진입점]
	게임 시작 시 Services 폴더의 모듈들을 require하고 Init -> Start 시키는 메인 스크립트입니다.
	서버 시작 시 단 한 번 실행되는 메인 스크립트입니다.
--]]

local ServerScriptService = game:GetService("ServerScriptService")
local ServicesFolder = ServerScriptService:WaitForChild("Services")

local Services = {}

-- 1. 모듈 로드 (Require)
for _, module in ipairs(ServicesFolder:GetChildren()) do
	if module:IsA("ModuleScript") then
		local success, service = pcall(require, module)
		if success then
			Services[module.Name] = service
		else
			warn(" ❌ Failed to load " .. module.Name .. ": " .. service)
		end
	end
end

-- 2. Init (초기화 - 이벤트 연결 등)
for name, service in pairs(Services) do
	if type(service.Init) == "function" then
		task.spawn(function()
			service:Init()
		end)
	end
end

-- 3. Start (실행 - 게임 루프 시작)
-- Init이 모두 끝날 때까지 아주 잠깐 대기 (안정성)
task.wait(1) 

for name, service in pairs(Services) do
	if type(service.Start) == "function" then
		task.spawn(function()
			service:Start()
		end)
	end
end