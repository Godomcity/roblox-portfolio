--[[
	Scheduler
	서버 유일의 상시 Heartbeat 루프 — 주기 작업은 전부 여기 등록(성능 원칙: 루프 단일화).
	제약: 등록 fn은 yield 금지(오래 걸리는 작업은 fn 안에서 task.spawn).
]]

local RunService = game:GetService("RunService")

local Scheduler = {}

-- [name] = { Interval, Fn, Acc }
local jobs = {}
local connection = nil
local registerCount = 0

function Scheduler.Register(name, intervalSec, fn)
	assert(type(name) == "string", "[Scheduler] name은 string")
	assert(type(intervalSec) == "number" and intervalSec > 0, "[Scheduler] intervalSec은 양수")
	assert(type(fn) == "function", "[Scheduler] fn은 function")
	-- [2026-07-29 감사 D3] 위상 분산.
	-- 전부 Acc=0으로 시작하면 주기가 같거나 배수 관계인 잡들이 영구히 같은 프레임에 몰린다.
	-- 현재 12개 중 Regen·FallCheck(둘 다 1초)가 그 예다 — 총 작업량은 같지만 피크가 곱해진다.
	-- 등록 순서에 황금비 오프셋을 줘 분포만 평탄화한다(결정적 — 재현 가능).
	registerCount += 1
	jobs[name] = { Interval = intervalSec, Fn = fn, Acc = intervalSec * ((registerCount * 0.618) % 1) }
end

function Scheduler.Init()
end

function Scheduler.Start()
	if connection then
		return
	end
	connection = RunService.Heartbeat:Connect(function(dt)
		for name, job in pairs(jobs) do
			job.Acc += dt
			if job.Acc >= job.Interval then
				job.Acc -= job.Interval
				if job.Acc >= job.Interval then
					job.Acc = 0 -- 프레임 스파이크 후 몰아치기 방지
				end
				local ok, err = pcall(job.Fn)
				if not ok then
					warn(("[Scheduler] 작업 실패: %s | %s"):format(name, tostring(err)))
				end
			end
		end
	end)
end

return Scheduler
