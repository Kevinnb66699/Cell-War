# tests/archive —— 搁置的无头脚本（2026-09-11）

套件不跑这里的脚本。它们是随功能下架的预览工具和已修 bug 的复现脚本，留着是为了功能回来时不用重写。
跑法与原来一样：`godot --path game --script res://tests/archive/<脚本>.gd -- …`（预览类不能加 `--headless`，要真渲染）。

- preview_chat.gd · preview_room_chat.gd · preview_replay_bar.gd · preview_replay_panel.gd · preview_settle_link.gd：
  随三个下架开关（`CHAT_ON` / `REPLAY_ON` / `WATCH_ON`，都在 `scripts/ui/match.gd` 顶部）一起搁置；开回来的步骤见
  `docs/临时下架清单.md`，开回来时把对应脚本移回 `tests/preview/` 跑一次看图。
- repro_macro_loop.gd（09-01）· repro_stroma.gd（09-05）：已修 bug 的复现，回归断言已进 `headless_test.gd`。
- demo_revive_block.gd · check_feed_overlap.gd：一次性演示 / 量尺。
- balance_sim.gd · balance_variants.gd：被参数化扫描 `tests/balance_scan.gd` 覆盖。
