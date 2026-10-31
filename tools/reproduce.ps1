param(
 [ValidateSet('check','quick','full','pc','sd')][string]$Mode='check',
 [string]$Python='', [string]$VivadoBin='', [string]$IverilogBin=''
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if (-not $Python) {
 if ($env:EXAMGUARD_PYTHON) {$Python=$env:EXAMGUARD_PYTHON}
 elseif (Test-Path -LiteralPath "$root\.venv\Scripts\python.exe") {$Python="$root\.venv\Scripts\python.exe"}
 elseif (Get-Command python -ErrorAction SilentlyContinue) {$Python=(Get-Command python).Source}
 else {throw '请安装Python 3.12，或使用 -Python 指定python.exe。'}
}
if (-not $VivadoBin) {$VivadoBin=$env:EXAMGUARD_VIVADO_BIN}
if (-not $IverilogBin) {$IverilogBin=$env:EXAMGUARD_IVERILOG_BIN}
if (-not $VivadoBin) {
 $exe=Get-Command vivado.bat -ErrorAction SilentlyContinue
 if ($exe) {$VivadoBin=Split-Path -Parent $exe.Source}
 elseif (Test-Path -LiteralPath 'D:\vivado\vivado2018.3\Vivado\2018.3\bin\vivado.bat') {$VivadoBin='D:\vivado\vivado2018.3\Vivado\2018.3\bin'}
}
if (-not $IverilogBin) {
 $exe=Get-Command iverilog.exe -ErrorAction SilentlyContinue
 if ($exe) {$IverilogBin=Split-Path -Parent $exe.Source}
 elseif (Test-Path -LiteralPath 'C:\iverilog\bin\iverilog.exe') {$IverilogBin='C:\iverilog\bin'}
}
$needSim=$Mode -in @('quick','full')
if ($needSim -and (-not $VivadoBin -or -not $IverilogBin)) {throw '仿真需Vivado2018.3和Icarus。可设置EXAMGUARD_VIVADO_BIN/EXAMGUARD_IVERILOG_BIN，或传入对应参数。'}
$argsList=@('-B','-X','utf8',"$root\tools\reproduce.py")
switch ($Mode) {
 'quick' {$argsList+='--simulate'}
 'full' {$argsList+='--full'}
 'pc' {$argsList+='--pc-tests'}
 'sd' {$argsList+='--prepare-sd'}
}
if ($VivadoBin) {$argsList+=@('--vivado-bin',$VivadoBin)}
if ($IverilogBin) {$argsList+=@('--iverilog-bin',$IverilogBin)}
$env:PIP_CACHE_DIR='D:\examguard_cache\pip'
$env:PYTHONDONTWRITEBYTECODE='1'
Push-Location -LiteralPath $root
try {& $Python @argsList;exit $LASTEXITCODE} finally {Pop-Location}
