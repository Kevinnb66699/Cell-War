using CellWar.Core.Worlds;

namespace CellWar.Core.Tests;

/// <summary>
/// S 阶段第 2 步【血管传送】落地追出的问答，要**先问完**才往下走复活 / 有氧 / 开打 —— GD `round_start` 里是
/// `await _vessel_teleport()` → `await enter_tile(...)`（cw_world.gd:31 / 153），问答挂在传送那一步上。
/// 2026-10-01 之前 C# 的 `PhaseRules.ResumeStart` 传送完不看挂起就直接 `ContinueStart`：有氧先结算、行动回合先开，问答被拖到后面。
/// 局面：免疫带【免疫记忆库】、手牌满 8 张站在血管一端，另一端是癌组织 ⇒ 传送落地净化 → 首次净化免费抽 1 张 → 手牌超限要弃。
/// </summary>
public class TransportAskOrderTests
{
    private static WorldState World()
    {
        var spec = WorldJson.Parse("""
        {
          "radius": 6, "round": 2, "phase": "S", "seat": 0,
          "players": [ { "seat": 0, "faction": "immune" }, { "seat": 1, "faction": "cancer", "cancer_type": "Melanoma" } ],
          "tiles": [ { "at": "-6,0", "state": "cancer" }, { "at": "0,0", "state": "cancer" } ],
          "cells": [
            { "seat": 0, "type": "ImmuneBasic", "at": "6,0", "energy": 300, "equipped": ["免疫记忆库"],
              "hand": ["抗原摄取", "抗原摄取", "抗原摄取", "抗原摄取", "抗原摄取", "抗原摄取", "抗原摄取", "抗原摄取"] },
            { "seat": 1, "type": "Melanoma", "at": "0,0", "energy": 300 }
          ]
        }
        """);
        var s = WorldLoader.Load(spec);
        return s.WithTurn(s.Turn.Copy(startStep: 3));
    }

    [Fact]
    public void 传送落地追出的弃牌先问完_有氧与开打排在后面()
    {
        var rng = new Xoshiro256StarStar(7);
        var s = PhaseRules.ResumeStart(World(), rng);
        var immune = s.Cells.Values.Single(c => c.Faction == Faction.Immune);
        Assert.Equal(new HexPosition(-6, 0, 6), immune.Position);              // 传送过去了
        Assert.Equal(0, s.Turn.PendingDiscardSeat);                             // 抽满了，要弃
        Assert.Equal(Phase.S, s.Turn.Phase);                                    // 还停在 S 阶段：没开打
        var energyBefore = immune.Energy;

        var engine = new BasicRulesEngine();
        var discard = engine.GetAvailableDecisions(s, 0).OfType<DiscardDecision>().First();
        var after = engine.ExecuteDecision(s, discard, rng).NewState;
        Assert.Equal(Phase.PlayerAction, after.Turn.Phase);                     // 弃完才接着走：有氧、开打
        Assert.True(after.Cells[immune.Id].Energy > energyBefore, "有氧呼吸排在弃牌之后结算");
    }
}
