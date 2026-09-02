# Windows 无头测试入口：断言、GDScript 运行时报错和测试脚本加载失败均视为失败。
# 用法：.\tools\run_tests.ps1 [-Godot <Godot_console.exe 路径>]
param(
	[string] $Godot = "D:/Godot/Godot_v4.5-stable_win64.exe/Godot_v4.5-stable_win64_console.exe"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $Godot)) {
	throw "找不到 Godot 控制台程序：$Godot"
}

$output = & $Godot --headless --path (Join-Path $repo "game") --script "res://tests/headless_test.gd" 2>&1
$exitCode = $LASTEXITCODE
$text = $output | Out-String
$summary = $output | Where-Object { $_ -match "FAIL|✔|✘" }
if ($summary) {
	$summary
}

$runtimeFailures = [regex]::Matches($text, "SCRIPT ERROR|Parse Error|Failed to load script").Count
if ($runtimeFailures -gt 0) {
	Write-Host ""
	Write-Host "✘ 发现 $runtimeFailures 处运行时报错或测试脚本未加载（断言没红，也不能算通过）："
	$output | Where-Object { $_ -match "SCRIPT ERROR|Parse Error|Failed to load script" } | ForEach-Object { $_ }
	exit 1
}
exit $exitCode
