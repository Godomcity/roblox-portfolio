# Story RPG: Wolf Awakening

개발 기간: 2026.03 - 2026.08  
팀 규모: 4명  
담당: 서버 전투 판정, 몬스터·필드 보스, 퀘스트·진행 호환, 저장·운영

## 추천 탐색 순서

CombatService, MonsterService, FieldBossService, QuestChainService, DataService, SkillService

## 코드 목록

| 파일 | Studio 경로 | 종류 |
|---|---|---|
| [CombatService.luau](CombatService.luau) | /ServerScriptService/Services/CombatService | ModuleScript |
| [MonsterService.luau](MonsterService.luau) | /ServerScriptService/Services/MonsterService | ModuleScript |
| [FieldBossService.luau](FieldBossService.luau) | /ServerScriptService/Services/FieldBossService | ModuleScript |
| [QuestChainService.luau](QuestChainService.luau) | /ServerScriptService/Services/QuestChainService | ModuleScript |
| [DataService.luau](DataService.luau) | /ServerScriptService/Services/DataService | ModuleScript |
| [Scheduler.luau](Scheduler.luau) | /ServerScriptService/Services/Scheduler | ModuleScript |
| [PlayerDamageService.luau](PlayerDamageService.luau) | /ServerScriptService/Services/PlayerDamageService | ModuleScript |
| [DashService.luau](DashService.luau) | /ServerScriptService/Services/DashService | ModuleScript |
| [SkillService.luau](SkillService.luau) | /ServerScriptService/Services/SkillService | ModuleScript |
| [Net.luau](Net.luau) | /ReplicatedStorage/Net | ModuleScript |
| [Util.luau](Util.luau) | /ReplicatedStorage/Shared/Util | ModuleScript |
| [LevelDefs.luau](LevelDefs.luau) | /ReplicatedStorage/Defs/LevelDefs | ModuleScript |
| [StatDefs.luau](StatDefs.luau) | /ReplicatedStorage/Defs/StatDefs | ModuleScript |
| [QuestChainDefs.luau](QuestChainDefs.luau) | /ReplicatedStorage/Defs/QuestChainDefs | ModuleScript |
| [WolfDifficultyDefs.luau](WolfDifficultyDefs.luau) | /ReplicatedStorage/Defs/WolfDifficultyDefs | ModuleScript |
| [WeaponTypeDefs.luau](WeaponTypeDefs.luau) | /ReplicatedStorage/Defs/WeaponTypeDefs | ModuleScript |
