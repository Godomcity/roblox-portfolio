--------------------------------------------------------------------------------
-- BalloonLiftFxClient
-- 풍선 스킬 피해자 전용 클라이언트 FX
--   · 카메라 스웨이  : 공중에 매달린 느낌의 좌우 흔들림
--   · 스피드라인 GUI : 화면 양옆 하강하는 바람결 → 위로 빨려가는 속도감
-- StarterPlayerScripts에 위치 → 항상 실행, 툴 미장착 상태에서도 정상 동작
--------------------------------------------------------------------------------
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local LocalPlayer   = Players.LocalPlayer
local NetworkFolder = ReplicatedStorage:WaitForChild("Network")
local RE_BalloonLiftFx = NetworkFolder:WaitForChild("RE_BalloonLiftFx")

--------------------------------------------------------------------------------
-- 🎈 카메라 스웨이
--------------------------------------------------------------------------------
local SWAY_AMPLITUDE = 0.018   -- 좌우 흔들림 각도 (라디안)
local SWAY_SPEED     = 1.8     -- 흔들림 주기 (Hz)
local ROLL_AMPLITUDE = 0.006   -- 미세 롤 (매달린 느낌 강화)

local cameraSway = { active = false, connection = nil, startTime = 0, duration = 0 }

local function StartCameraSway(durationSec)
	-- 이미 실행 중이면 시간만 갱신
	cameraSway.active    = true
	cameraSway.startTime = os.clock()
	cameraSway.duration  = durationSec

	if cameraSway.connection then return end  -- 이미 연결된 경우 재사용

	cameraSway.connection = RunService.RenderStepped:Connect(function()
		if not cameraSway.active then
			cameraSway.connection:Disconnect()
			cameraSway.connection = nil
			return
		end

		local elapsed = os.clock() - cameraSway.startTime
		if elapsed > cameraSway.duration + 0.3 then
			cameraSway.active = false
			return
		end

		-- 종료 직전 0.4초 동안 진폭을 0으로 수렴
		local fadeOut = 1.0
		if elapsed > cameraSway.duration - 0.4 then
			fadeOut = math.max(0, (cameraSway.duration - elapsed) / 0.4)
		end

		local t     = elapsed * SWAY_SPEED * math.pi * 2
		local swayX = math.sin(t) * SWAY_AMPLITUDE * fadeOut
		local rollZ = math.sin(t + math.pi * 0.5) * ROLL_AMPLITUDE * fadeOut

		local cam = workspace.CurrentCamera
		if cam then
			cam.CFrame = cam.CFrame * CFrame.Angles(0, swayX, rollZ)
		end
	end)
end

local function StopCameraSway()
	cameraSway.active = false
	-- connection은 다음 RenderStepped에서 자동 해제
end

--------------------------------------------------------------------------------
-- 🌬️ 스피드라인 GUI
--------------------------------------------------------------------------------
local SPEEDLINE_COUNT = 14
local SPEEDLINE_COLOR = Color3.fromRGB(180, 220, 255)
local SPEEDLINE_ALPHA = 0.45

local speedlineGui    = nil
local speedlineTweens = {}

local function DestroySpeedlineGUI()
	for _, tw in ipairs(speedlineTweens) do tw:Cancel() end
	speedlineTweens = {}
	if speedlineGui then
		speedlineGui:Destroy()
		speedlineGui = nil
	end
end

local function CreateSpeedlineGUI(durationSec)
	DestroySpeedlineGUI()

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end

	local gui = Instance.new("ScreenGui")
	gui.Name            = "BalloonLift_SpeedlineGui"
	gui.ResetOnSpawn    = false
	gui.IgnoreGuiInset  = true
	gui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
	gui.Parent          = playerGui
	speedlineGui        = gui

	local sides = {
		{ xBase = 0,    dir =  1 },  -- 왼쪽
		{ xBase = 1,    dir = -1 },  -- 오른쪽
	}

	for _, side in ipairs(sides) do
		for i = 1, SPEEDLINE_COUNT do
			-- 화면 가장자리에서 안쪽으로 분포 (0~13% 폭)
			local xRatio = side.xBase + side.dir * (i / SPEEDLINE_COUNT) * 0.13

			local lineHeightRatio = math.random(15, 38) / 100
			local lineWidthPx     = math.random(1, 3)
			local startY          = math.random(-40, 10) / 100
			local travelDist      = 1.0 + lineHeightRatio

			local speed = 0.55 + math.random() * 0.6
			local delay = math.random() * speed

			local frame = Instance.new("Frame")
			frame.AnchorPoint          = Vector2.new(side.xBase, 0)
			frame.BackgroundColor3     = SPEEDLINE_COLOR
			frame.BackgroundTransparency = 1 - SPEEDLINE_ALPHA
			frame.BorderSizePixel      = 0
			frame.Size                 = UDim2.new(0, lineWidthPx, lineHeightRatio, 0)
			frame.Position             = UDim2.new(xRatio, 0, startY, 0)
			frame.Parent               = gui

			-- 선 양 끝 페이드 (UIGradient)
			local gradient = Instance.new("UIGradient")
			gradient.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0,   1.0),
				NumberSequenceKeypoint.new(0.2, 1 - SPEEDLINE_ALPHA),
				NumberSequenceKeypoint.new(0.5, 1 - SPEEDLINE_ALPHA * 1.2),
				NumberSequenceKeypoint.new(0.8, 1 - SPEEDLINE_ALPHA),
				NumberSequenceKeypoint.new(1,   1.0),
			})
			gradient.Parent = frame

			-- 아래로 흐르는 반복 트윈
			local function runLoop()
				if not speedlineGui or not speedlineGui.Parent then return end
				frame.Position = UDim2.new(xRatio, 0, startY, 0)

				local tween = TweenService:Create(
					frame,
					TweenInfo.new(speed, Enum.EasingStyle.Linear, Enum.EasingDirection.In),
					{ Position = UDim2.new(xRatio, 0, startY + travelDist, 0) }
				)
				table.insert(speedlineTweens, tween)
				tween.Completed:Connect(function(state)
					for idx, tw in ipairs(speedlineTweens) do
						if tw == tween then table.remove(speedlineTweens, idx); break end
					end
					if state == Enum.PlaybackState.Completed and speedlineGui and speedlineGui.Parent then
						runLoop()
					end
				end)
				tween:Play()
			end

			task.delay(delay, runLoop)
		end
	end

	-- 종료 직전 페이드 아웃 후 정리
	task.delay(durationSec - 0.35, function()
		if not speedlineGui or not speedlineGui.Parent then return end
		for _, child in ipairs(speedlineGui:GetChildren()) do
			if child:IsA("Frame") then
				TweenService:Create(child, TweenInfo.new(0.35, Enum.EasingStyle.Quad), {
					BackgroundTransparency = 1
				}):Play()
			end
		end
		task.delay(0.4, function()
			DestroySpeedlineGUI()
		end)
	end)
end

--------------------------------------------------------------------------------
-- 이벤트 수신
--------------------------------------------------------------------------------
RE_BalloonLiftFx.OnClientEvent:Connect(function(action, victimPlayer, durationSec)
	-- 본인이 피해자일 때만 처리
	if victimPlayer ~= LocalPlayer then return end

	if action == "BalloonStart" then
		local dur = tonumber(durationSec) or 5
		StartCameraSway(dur)
		CreateSpeedlineGUI(dur)

	elseif action == "BalloonEnd" then
		StopCameraSway()
		DestroySpeedlineGUI()
	end
end)
