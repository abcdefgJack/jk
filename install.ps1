# install.ps1 - one-time setup for jk. Safe to re-run.
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Calendar <deadlines.html>]
param([string]$Calendar)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'jk.psd1') -Force
if ($Calendar) { jk due import $Calendar }
jk setup install
jk doctor
