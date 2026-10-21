# Story RPG: Wolf Awakening

개발 기간: 2026.03 - 2026.08  
팀 규모: 4명  
담당: 서버 전투 판정, 몬스터·필드 보스, 퀘스트·진행 호환, 저장·운영

## 추천 탐색 순서

CombatService, MonsterService, FieldBossService, QuestChainService, DataService, SkillService

## Studio 의존 구조

GameConfig·ProfileTemplate·MonsterDefs·WeaponDefs·AVDefs·SkillDefs, PlayerService·AnalyticsService·CraftService·LootService 등 생략된 모듈과 몬스터·보스 모델, 스폰 마커·구역·UI·이펙트가 필요합니다. GameConfig의 운영 주소와 인증 설정은 포함하지 않았습니다. 격리된 테스트 저장소와 Studio 모의 저장 설정을 별도로 구성해야 합니다.

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

## 범위

원본 소스에서 선별한 코드 발췌본입니다. 코드 수정·버그 수정·재설계를 수행하지 않았습니다. 생략된 모듈·모델·UI 때문에 단독 실행할 수 없습니다. Studio 실행 및 Luau 문법·동작 테스트는 수행하지 않았습니다. 주석에 적힌 개선 수치는 별도 검증된 성과가 아닙니다.
