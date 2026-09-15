# -*- coding: utf-8 -*-
"""装好 Godot 的「安卓自定义构建」模板，并把我们自己那点改动盖上去。

## 为什么要有这个脚本

热更走的是明文 HTTP（信任靠签名不靠 TLS，理由见 `boot.gd` 文件头和
`tools/android/network_security_config.xml`），而安卓 9 起默认禁明文。
**Godot 4.5 的安卓导出预设里没有任何 cleartext 开关**（在引擎二进制里搜过，
只有 `permissions/custom_permissions` 和 `gradle_build/*`），所以唯一的办法是
开 Gradle 自定义构建、往清单里塞一个 `networkSecurityConfig`。

## 为什么模板不进仓库

`android/build/libs/` 里是预编译的原生库，**光它就 202 MB**（整个模板 58 个文件）。
这种东西进 git 一次就再也拿不出来了。所以：

* `game/android/` 整个进 `.gitignore`
* 仓库里只留**我们自己的那一份改动**（`tools/android/`）和这个脚本
* 换机器 / 升 Godot 之后跑一次这个脚本就还原

代价是「有人忘了跑」——而忘了跑的后果是**静默的**（包照样出，只是收不到补丁）。
所以脚本跑完会把清单里那一行打印出来，`--check` 也能单独核一遍；
真出安卓包之前应当先跑 `--check`。

## 用法（仓库根目录）

    python tools/setup_android_build.py           # 装模板 + 盖改动（已装过就只盖改动）
    python tools/setup_android_build.py --check   # 只核对，不动文件；没弄好退 1
    python tools/setup_android_build.py --force   # 删掉重装（升 Godot 之后用）

装完还要在 `export_presets.cfg` 里把 `gradle_build/use_gradle_build` 改成 `true`。
Gradle 那条路对版本比较挑，要求见 `docs/安卓导出.md`。
"""
import argparse
import io
import os
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ANDROID = os.path.join(ROOT, "game", "android")
BUILD = os.path.join(ANDROID, "build")
MANIFEST = os.path.join(BUILD, "AndroidManifest.xml")
NSC_SRC = os.path.join(HERE, "android", "network_security_config.xml")
NSC_DST = os.path.join(BUILD, "res", "xml", "network_security_config.xml")

GODOT_VERSION = "4.5.stable"
TEMPLATE = os.path.join(
    os.environ.get("APPDATA", ""), "Godot", "export_templates", GODOT_VERSION, "android_source.zip")

## 要加到 <application> 上的那个属性。Godot 每次重装模板都会把清单还原，所以这一步要可重复跑
NSC_ATTR = 'android:networkSecurityConfig="@xml/network_security_config"'
ANCHOR = '    <application\n'


def install_template(force):
    if os.path.isdir(BUILD) and not force:
        return False
    if not os.path.exists(TEMPLATE):
        raise SystemExit("找不到导出模板：%s\n先在 Godot 里装一次 4.5.stable 的导出模板" % TEMPLATE)
    if os.path.isdir(ANDROID):
        shutil.rmtree(ANDROID)
    os.makedirs(BUILD)
    with zipfile.ZipFile(TEMPLATE) as z:
        z.extractall(BUILD)
    ## Godot 靠这两样认「模板装好了」：版本戳 + 让编辑器别把这些文件当资源导入
    io.open(os.path.join(ANDROID, ".build_version"), "w", encoding="utf-8").write(GODOT_VERSION)
    io.open(os.path.join(BUILD, ".gdignore"), "w", encoding="utf-8").write("")
    return True


def apply_overlay(check):
    """返回 (改了没有, 问题列表)。check=True 时只看不改。"""
    bad = []
    if not os.path.isfile(MANIFEST):
        return False, ["没装模板：%s 不存在" % os.path.relpath(MANIFEST, ROOT)]

    changed = False
    want = io.open(NSC_SRC, encoding="utf-8", newline="").read()
    have = io.open(NSC_DST, encoding="utf-8", newline="").read() if os.path.isfile(NSC_DST) else None
    if have != want:
        if check:
            bad.append("%s 缺失或和 tools/android/ 那份不一致" % os.path.relpath(NSC_DST, ROOT))
        else:
            os.makedirs(os.path.dirname(NSC_DST), exist_ok=True)
            io.open(NSC_DST, "w", encoding="utf-8", newline="").write(want)
            changed = True

    raw = io.open(MANIFEST, encoding="utf-8", newline="").read()
    if NSC_ATTR not in raw:
        if check:
            bad.append("AndroidManifest.xml 的 <application> 上没有 networkSecurityConfig —— "
                       "出的包在安卓上收不到热更，而且不会报错")
        else:
            if raw.count(ANCHOR) != 1:
                raise SystemExit("清单里的 <application> 锚点对不上，模板变了？手工看一眼：%s" % MANIFEST)
            raw = raw.replace(ANCHOR, ANCHOR + "        " + NSC_ATTR + "\n")
            io.open(MANIFEST, "w", encoding="utf-8", newline="").write(raw)
            changed = True
    return changed, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只核对、不动文件")
    ap.add_argument("--force", action="store_true", help="删掉重装模板")
    args = ap.parse_args()

    if args.check:
        _, bad = apply_overlay(True)
        for b in bad:
            print("[NG] %s" % b)
        if bad:
            print("fix: python tools/setup_android_build.py")
            return 1
        print("OK: android build template ready (network_security_config in place)")
        return 0

    fresh = install_template(args.force)
    print("template: %s" % ("installed" if fresh else "already present (use --force to reinstall)"))
    changed, _ = apply_overlay(False)
    print("overlay : %s" % ("applied" if changed else "already applied"))
    ## 把真正生效的那一行打出来 —— 忘了跑这个脚本的后果是静默的，所以每次都看一眼
    for line in io.open(MANIFEST, encoding="utf-8"):
        if "networkSecurityConfig" in line:
            print("manifest: %s" % line.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
