-- 필요한 이벤트들을 미리 찾아둡니다.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local exitEvent = ReplicatedStorage:WaitForChild("ExitEvent")
local Camevent = ReplicatedStorage:WaitForChild("Camevent")

-- 버튼과 사운드 매니저
local exitButton = script.Parent.ExitButton
local soundManager = require(ReplicatedStorage.SoundManager)
local SelfieMode = ReplicatedStorage:WaitForChild("SelfieMode")
local setEnabled = require(SelfieMode.Api.setEnabled)
-- 플레이어가 현재 들어가 있는 포탈의 모델을 저장할 변수
local currentPortalModel = nil

-- 서버가 보내주는 Camevent를 수신 대기합니다.
Camevent.OnClientEvent:Connect(function(isEntering, zomin, cam, portalModel)
	if isEntering then
		-- 포탈에 들어왔을 때, 서버가 보내준 포탈 모델 정보를 변수에 저장합니다.
		currentPortalModel = portalModel
	else
		-- 포탈에서 나갔을 때는 변수를 비워줍니다.
		currentPortalModel = nil
	end
end)


-- 나가기 버튼 클릭 이벤트
exitButton.MouseButton1Click:Connect(function()
	-- 저장해둔 포탈 정보가 있을 경우에만 서버로 신호를 보냅니다.
	if currentPortalModel then
		-- 서버로 신호를 보낼 때, 현재 포탈 모델 정보를 함께 전달합니다.
		exitEvent:FireServer(currentPortalModel)

		exitButton.Visible = false
		soundManager.UIClickSound()
		setEnabled(true)
	end
end)


-- 마우스 호버 이벤트 (이 부분은 수정할 필요 없습니다.)
exitButton.MouseEnter:Connect(function()
	soundManager.UIClickSound()
end)