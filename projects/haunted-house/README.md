# 흔한남매

개발 기간: 2025.06 - 2025.08  
팀 규모: 4명  
담당: 기획·맵·게임 로직·UI·NPC·퍼즐·연출 연동

## 추천 탐색 순서

TutorialHandler, TutorialManager, NPCController, LeverPuzzleManager, LeverClientController, Potal1

## Studio 의존 구조

NPC 모델·Humanoid·Animator·Hitbox, 문·PrimaryPart, 열쇠·스폰 지점, 레버·ActivePlayer·힌트 Decal, 방향·대화 UI와 RemoteEvent가 필요합니다. ZonePlus·SelfieMode 및 SoundManager는 포함하지 않았습니다. 같은 이름의 OtherDoor가 여러 개이며, 포털 한 개만 예시로 포함했습니다.

## 코드 목록

| 파일 | Studio 경로 | 종류 |
|---|---|---|
| [Potal1.server.luau](Potal1.server.luau) | /Workspace/OtherDoor/EnterPart/Potal1 | Script |
| [ExitScript.client.luau](ExitScript.client.luau) | /StarterGui/ExitGui/ExitScript | LocalScript |
| [TutorialManager.luau](TutorialManager.luau) | /ReplicatedStorage/Modules/TutorialManager | ModuleScript |
| [TutorialHandler.server.luau](TutorialHandler.server.luau) | /ServerScriptService/TutorialHandler | Script |
| [TutotialLocalScript.client.luau](TutotialLocalScript.client.luau) | /StarterGui/TutorialGui/DialogFrame/TutotialLocalScript | LocalScript |
| [NPCController.luau](NPCController.luau) | /ReplicatedStorage/NPCController | ModuleScript |
| [LeverClientController.luau](LeverClientController.luau) | /ReplicatedStorage/LeverClientController | ModuleScript |
| [LeverPuzzleManager.luau](LeverPuzzleManager.luau) | /ServerScriptService/LeverPuzzleManager | ModuleScript |
| [LeverServerScript.server.luau](LeverServerScript.server.luau) | /ServerScriptService/LeverServerScript | Script |
| [LeverLocalScript.client.luau](LeverLocalScript.client.luau) | /StarterPlayer/StarterPlayerScripts/LeverLocalScript | LocalScript |
| [GameManager.server.luau](GameManager.server.luau) | /ServerScriptService/GameManager | Script |

## 범위

원본 소스에서 선별한 코드 발췌본입니다. 코드 수정·버그 수정·재설계를 수행하지 않았습니다. 생략된 모듈·모델·UI 때문에 단독 실행할 수 없습니다. Studio 실행 및 Luau 문법·동작 테스트는 수행하지 않았습니다. 주석에 적힌 개선 수치는 별도 검증된 성과가 아닙니다.
