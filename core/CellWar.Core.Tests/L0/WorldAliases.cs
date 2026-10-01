// 2026-10-01 换内核 P5：cwxworld/3 的记录与装载器上提进产品程序集（CellWar.Core.Worlds），名字去掉了 L0 前缀。
// 靶场这边几十处还叫老名字 —— 用别名接上，测试文件一个字不改。
global using L0World = CellWar.Core.Worlds.WorldSpec;
global using L0Player = CellWar.Core.Worlds.SpecPlayer;
global using L0Tile = CellWar.Core.Worlds.SpecTile;
global using L0Cell = CellWar.Core.Worlds.SpecCell;
global using L0Chemo = CellWar.Core.Worlds.SpecChemo;
global using L0Track = CellWar.Core.Worlds.SpecTrack;
global using L0CancerAlarm = CellWar.Core.Worlds.SpecCancerAlarm;
global using L0Events = CellWar.Core.Worlds.SpecEvents;
global using L0Effect = CellWar.Core.Worlds.SpecEffect;
global using L0Mod = CellWar.Core.Worlds.SpecMod;
global using WorldLoader = CellWar.Core.Worlds.WorldLoader;
global using UnloadableException = CellWar.Core.Worlds.UnloadableException;
