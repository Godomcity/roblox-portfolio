# Catch the Drop! - Win the Runway

개발 기간: 2025.11 - 2026.02  
팀 규모: 4명  
담당: 서버 구매·운반, PvP·상태 제어, 기능별 모듈 분리

## 추천 탐색 순서

GameBootstrapper, ClientBootstrapper, MarketService, ShoppingBagService, LootDropService, Skills, SkillUtil

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
