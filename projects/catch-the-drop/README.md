# Catch the Drop! - Win the Runway

개발 기간: 2025.11 - 2026.02  
팀 규모: 4명  
담당: 서버 구매·운반, PvP·상태 제어, 기능별 모듈 분리

## 추천 탐색 순서

GameBootstrapper, ClientBootstrapper, MarketService, ShoppingBagService, LootDropService, Skills, SkillUtil

## Studio 의존 구조

Network 통신 객체, Constants·Utils·ItemDatabase, DataService·CurrencyService·InventoryService·TycoonService·FurnitureMarketService 등 생략된 모듈과 레일·부지·입고 지점·쇼핑백·스킬 모델·UI가 필요합니다. 부트스트랩은 구조 예시이며 원본의 전체 서비스를 로드하므로 발췌본만으로 실행할 수 없습니다.

## 코드 목록

| 파일 | Studio 경로 | 종류 |
|---|---|---|
| [GameBootstrapper.server.luau](GameBootstrapper.server.luau) | /ServerScriptService/Core/GameBootstrapper | Script |
| [ClientBootstrapper.client.luau](ClientBootstrapper.client.luau) | /StarterPlayer/StarterPlayerScripts/ClientBootstrapper | LocalScript |
| [MarketService.luau](MarketService.luau) | /ServerScriptService/Services/MarketService | ModuleScript |
| [ShoppingBagService.luau](ShoppingBagService.luau) | /ServerScriptService/Services/ShoppingBagService | ModuleScript |
| [LootDropService.luau](LootDropService.luau) | /ServerScriptService/Services/LootDropService | ModuleScript |
| [SkillUtil.luau](SkillUtil.luau) | /ReplicatedStorage/Shared/SkillUtil | ModuleScript |
| [PaparazziService.server.luau](PaparazziService.server.luau) | /ServerScriptService/Skills/PaparazziService | Script |
| [BalloonLiftService.server.luau](BalloonLiftService.server.luau) | /ServerScriptService/Skills/BalloonLiftService | Script |
| [BagBlastService.server.luau](BagBlastService.server.luau) | /ServerScriptService/Skills/BagBlastService | Script |
| [ReceiptService.server.luau](ReceiptService.server.luau) | /ServerScriptService/Skills/ReceiptService | Script |
| [MannequinService.server.luau](MannequinService.server.luau) | /ServerScriptService/Skills/MannequinService | Script |
| [PaparazziController.client.luau](PaparazziController.client.luau) | /ServerStorage/Skills/PaparazziTool/PaparazziController | LocalScript |
| [MannequinController.client.luau](MannequinController.client.luau) | /ServerStorage/Skills/MannequinTool/MannequinController | LocalScript |
| [BalloonLiftController.client.luau](BalloonLiftController.client.luau) | /ServerStorage/Skills/BalloonLiftTool/BalloonLiftController | LocalScript |
| [ReceiptController.client.luau](ReceiptController.client.luau) | /ServerStorage/Skills/ReceiptTool/ReceiptController | LocalScript |
| [BagBlastController.client.luau](BagBlastController.client.luau) | /ServerStorage/Skills/ShoppingBagTool/BagBlastController | LocalScript |
| [ReceiptFxClient.client.luau](ReceiptFxClient.client.luau) | /StarterPlayer/StarterPlayerScripts/ReceiptFxClient | LocalScript |
| [PaparazziFxClient.client.luau](PaparazziFxClient.client.luau) | /StarterPlayer/StarterPlayerScripts/PaparazziFxClient | LocalScript |
| [BalloonLiftFxClient.client.luau](BalloonLiftFxClient.client.luau) | /StarterPlayer/StarterPlayerScripts/BalloonLiftFxClient | LocalScript |
| [MannequinFxClient.client.luau](MannequinFxClient.client.luau) | /StarterPlayer/StarterPlayerScripts/MannequinFxClient | LocalScript |
| [BagBlastVFXController.luau](BagBlastVFXController.luau) | /StarterPlayer/StarterPlayerScripts/Controllers/BagBlastVFXController | ModuleScript |

## 범위

원본 소스에서 선별한 코드 발췌본입니다. 코드 수정·버그 수정·재설계를 수행하지 않았습니다. 생략된 모듈·모델·UI 때문에 단독 실행할 수 없습니다. Studio 실행 및 Luau 문법·동작 테스트는 수행하지 않았습니다. 주석에 적힌 개선 수치는 별도 검증된 성과가 아닙니다.
