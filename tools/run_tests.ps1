# Windows 无头测试入口：断言、GDScript 运行时报错和测试脚本加载失败均视为失败。
# 用法：.\tools\run_tests.ps1 [-Godot <Godot_console.exe 路径>] [-Shards 2]
#
# 分片并行（Kevin 2026-09-05 提的）：套件 1900 项、单进程要 2.5 分钟，而 Godot 无头是单线程。
# 默认开两个进程各跑一半（headless_test.gd 的 `-- --shard=i/n`，每片各自的 user://），
# 各片输出先落到临时文件，跑完按片打印摘要；任一片红、或任一片有运行时报错，整体就算失败。-Shards 1 退回串行。
param(
	[string] $Godot = "D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe",
	[int] $Shards = 2
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $Godot)) {
	throw "找不到 Godot 控制台程序：$Godot"
}
if ($Shards -lt 1) {
	$Shards = 1
}
$game = Join-Path $repo "game"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cellwar-tests-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null

$procs = @()
for ($i = 0; $i -lt $Shards; $i++) {
	$argList = @("--headless", "--path", $game, "--script", "res://tests/headless_test.gd", "--", "--shard=$i/$Shards")
	$procs += Start-Process -FilePath $Godot -ArgumentList $argList -NoNewWindow -PassThru `
		-RedirectStandardOutput (Join-Path $tmp "shard$i.log") -RedirectStandardError (Join-Path $tmp "shard$i.err")
}
foreach ($p in $procs) {
	$p.WaitForExit()
}

$exitCode = 0
$all = @()
for ($i = 0; $i -lt $Shards; $i++) {
	$output = @()
	foreach ($name in @("shard$i.log", "shard$i.err")) {
		$path = Join-Path $tmp $name
		if (Test-Path -LiteralPath $path) {
			$output += @(Get-Content -LiteralPath $path -Encoding UTF8)
		}
	}
	$all += $output
	$summary = $output | Where-Object { $_ -match "FAIL|✔|✘" }
	if ($summary) {
		$summary
	}
	if ($procs[$i].ExitCode -ne 0) {
		$exitCode = 1
	}
}
Remove-Item -Recurse -Force $tmp

$text = $all | Out-String
$runtimeFailures = [regex]::Matches($text, "SCRIPT ERROR|Parse Error|Failed to load script").Count
if ($runtimeFailures -gt 0) {
	Write-Host ""
	Write-Host "✘ 发现 $runtimeFailures 处运行时报错或测试脚本未加载（断言没红，也不能算通过）："
	$all | Where-Object { $_ -match "SCRIPT ERROR|Parse Error|Failed to load script" } | ForEach-Object { $_ }
	exit 1
}
if ($Shards -gt 1) {
	# 通过的片写「（N 项检查」，红的片写「（共 N 项」，两种都算进合计
	$total = 0
	foreach ($m in [regex]::Matches($text, "（(?:共 )?(\d+) 项")) {
		$total += [int] $m.Groups[1].Value
	}
	if ($exitCode -eq 0) {
		Write-Host "✔ $Shards 片合计 $total 项检查全部通过"
	} else {
		Write-Host "✘ $Shards 片里有红（合计 $total 项检查）"
	}
}
exit $exitCode
