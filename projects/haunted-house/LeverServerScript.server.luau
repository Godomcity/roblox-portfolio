-- ServerScriptService에 위치한 Script, 이름: LeverServerScript

-- 1. 필요한 서비스와 우리가 만든 모듈을 불러옵니다.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local LeverPuzzleManager = require(script.Parent:WaitForChild("LeverPuzzleManager")) -- 모듈이 같은 위치에 있다고 가정

-- 2. 이 레버 퍼즐에 필요한 모든 부품과 설정을 'config' 테이블 하나에 정리합니다.
local config = {
	-- 리모트 이벤트/함수
	remotes = {
		RequestDrag = ReplicatedStorage.RemoteEvents:WaitForChild("RequestDrag"),
		ReleaseDrag = ReplicatedStorage.RemoteEvents:WaitForChild("ReleaseDrag"),
	},
	-- 각 레버의 정보
	leverConfigs = {
		{ part = Workspace.laver.Lever_G:WaitForChild("Lever_Handle"), remote = ReplicatedStorage.RemoteEvents.SetLeverYPosition1 },
		{ part = Workspace.laver.Lever_G:WaitForChild("Lever_Handle1"), remote = ReplicatedStorage.RemoteEvents.SetLeverYPosition2 },
		{ part = Workspace.laver.Lever_G:WaitForChild("Lever_Handle2"), remote = ReplicatedStorage.RemoteEvents.SetLeverYPosition3 },
		{ part = Workspace.laver.Lever_G:WaitForChild("Lever_Handle3"), remote = ReplicatedStorage.RemoteEvents.SetLeverYPosition4 },
	},
	-- 힌트 데칼 정보
	decalParts = {
		Workspace.Curse.Picture.lever1.DecalPart:WaitForChild("Decal"),
		Workspace.Curse.Picture.lever2.DecalPart:WaitForChild("Decal"),
		Workspace.Curse.Picture.lever3.DecalPart:WaitForChild("Decal"),
		Workspace.Curse.Picture.lever4.DecalPart:WaitForChild("Decal")
	},
	-- 힌트 이미지 ID 정보
	imageIds = {
		[1] = { high = "rbxassetid://128377677008190", middle = "rbxassetid://99492078929662", low = "rbxassetid://77040310051063" },
		[2] = { high = "rbxassetid://128038404196861", middle = "rbxassetid://98302472565483", low = "rbxassetid://115389205136777" },
		[3] = { high = "rbxassetid://71967396233776", middle = "rbxassetid://100970451808885", low = "rbxassetid://118667754135831" },
		[4] = { high = "rbxassetid://94213155301560", middle = "rbxassetid://124099360935699", low = "rbxassetid://109272659828770" }
	},
	-- 보상(레드키) 정보
	redKeySpawner = Workspace:WaitForChild("RedKeySpwaner"),
	redKey = ReplicatedStorage:WaitForChild("RedKey")
}

-- 3. 설정을 넘겨주어 퍼즐 관리자(게임 마스터)를 생성하고 퍼즐을 시작합니다.
LeverPuzzleManager.new(config)