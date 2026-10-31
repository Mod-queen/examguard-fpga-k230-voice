$ErrorActionPreference='Stop'
$taskRoot=Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath "$taskRoot\.venv\Scripts\python.exe")) {
    python -m venv "$taskRoot\.venv"
}
& "$taskRoot\.venv\Scripts\python.exe" -m pip install -r "$taskRoot\requirements.txt"
if ($LASTEXITCODE -ne 0) {throw 'Dependency installation failed'}
& "$taskRoot\.venv\Scripts\python.exe" "$PSScriptRoot\make_mcp_config.py"
if ($LASTEXITCODE -ne 0) {throw 'MCP configuration failed'}
