# ssh_windows.ps1 - Servicio SSH windows

. ".\funciones_windows.ps1"

function Revision-SSH {
	Write-Host ""
	Write-Host "=== Verificar Instalacion SSH ==="
	pause
}

Verificar-Administrador

function Menu-SSH {
	Clear-Host
	Write-Host "====== MENU SSH ======" -ForegroundColor Cyan
}