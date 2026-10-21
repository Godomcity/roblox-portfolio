-- 공용 유틸. 제약: 순수 함수만 (상태·서비스 의존 금지)
local Util = {}

function Util.deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = Util.deepCopy(v)
	end
	return copy
end

-- 비파괴 병합: 새 테이블 반환(인자 미변경).
-- 규칙: 템플릿에 없는 키는 유지, 타입 불일치 시 템플릿 값 우선
function Util.deepMerge(template, data)
	local result = Util.deepCopy(template)
	if type(template) ~= "table" or type(data) ~= "table" then
		return result
	end
	for k, dataValue in pairs(data) do
		local templateValue = template[k]
		if templateValue == nil then
			result[k] = Util.deepCopy(dataValue)
		elseif type(templateValue) == "table" and type(dataValue) == "table" then
			result[k] = Util.deepMerge(templateValue, dataValue)
		elseif type(templateValue) == type(dataValue) then
			result[k] = Util.deepCopy(dataValue)
		end
		-- 타입 불일치: result에 이미 복사된 템플릿 값 유지
	end
	return result
end

-- Weight 필드 기반 가중 선택. 반환: 선택된 항목, 인덱스
function Util.weightedRoll(list, rng)
	local total = 0
	for _, item in ipairs(list) do
		total += item.Weight
	end
	if total <= 0 then
		return nil, nil
	end
	local roll = (if rng then rng:NextNumber() else math.random()) * total
	local acc = 0
	for index, item in ipairs(list) do
		acc += item.Weight
		if roll <= acc then
			return item, index
		end
	end
	return list[#list], #list
end

return Util
