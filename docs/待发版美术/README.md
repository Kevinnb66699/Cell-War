# 待发版美术

这里放**已经定下来、但还进不了热更**的贴图。

**为什么进不了热更**：补丁包里装的是 `game/` 下的源文件，而 Godot 在导出包里用的是
`.godot/imported/` 下的导入产物（`.ctex` 等），那个目录是 gitignore 掉的 ——
补丁里的原始 `.png` 根本不会被读到。`tools/build_patch.sh` 有一道闸专门拦这种改动，
所以**只要 `game/` 里动了贴图，从那一刻起到下次全量发版为止，每一个补丁都打不出来**。

于是规矩是：贴图先在这儿排队，**下次全量发版时**再拷进 `game/assets/art/` 一起发。

| 文件 | 去处 | 来历 |
| --- | --- | --- |
| `vessel_cancer_2026-09-13.png` | `game/assets/art/vessel_cancer.png` | issue #39，Kevin 附的图（顶面 #9f5868，比现行的 #b04a5a 闷一档） |
