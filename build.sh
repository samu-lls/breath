#!/usr/bin/env bash
# Gera dist/breath.cmd: um único arquivo com o breath.ps1 embutido.
# O cabeçalho é ao mesmo tempo um bloco de comentário do PowerShell (<# ... #>)
# e o trecho batch que o cmd executa; o cmd copia o próprio arquivo para
# %TEMP%\breath\breath.ps1 (UTF-8 com BOM) e roda com -File.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist

{
    cat <<'EOF'
<# : breath
@echo off
setlocal
set "BREATH_SRC=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d = Join-Path $env:TEMP 'breath'; New-Item -ItemType Directory -Force $d | Out-Null; $p = Join-Path $d 'breath.ps1'; [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($env:BREATH_SRC), (New-Object Text.UTF8Encoding $true)); & powershell -NoProfile -ExecutionPolicy Bypass -STA -File $p %*"
exit /b
#>
EOF
    # remove o BOM do fonte (o cmd não entende BOM na primeira linha)
    sed '1s/^\xEF\xBB\xBF//' breath.ps1
} | sed 's/\r$//; s/$/\r/' > dist/breath.cmd

echo "Gerado: dist/breath.cmd ($(du -h dist/breath.cmd | cut -f1))"
