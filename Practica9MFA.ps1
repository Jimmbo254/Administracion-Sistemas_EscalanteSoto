# ================================
# CONFIGURACION BASE
# ================================
$dominio = "empresa.local"
$netbios = "EMPRESA"
$pass = ConvertTo-SecureString "P@ssw0rd123" -AsPlainText -Force

# ================================
# MENU
# ================================
function Mostrar-Menu {
    Clear-Host
    Write-Host "===== MENU CONFIGURACION AD ====="
    Write-Host "1. Instalar Active Directory"
    Write-Host "2. Crear Dominio"
    Write-Host "3. Crear OUs y Usuarios"
    Write-Host "4. Configurar FGPP"
    Write-Host "5. Configurar Auditoria"
    Write-Host "6. Script Logs"
    Write-Host "0. Salir"
}

# ================================
# OPCION 1
# ================================
function Instalar-AD {
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
}

# ================================
# OPCION 2
# ================================
function Crear-Dominio {
    Install-ADDSForest `
    -DomainName $dominio `
    -DomainNetbiosName $netbios `
    -SafeModeAdministratorPassword $pass `
    -Force
}

# ================================
# OPCION 3
# ================================
function Crear-Estructura {
    Import-Module ActiveDirectory

    # Crear OUs
    New-ADOrganizationalUnit -Name "Cuates"
    New-ADOrganizationalUnit -Name "NoCuates"

    # Crear usuarios ejemplo
    for ($i=1; $i -le 5; $i++) {
        New-ADUser -Name "cuate$i" `
        -SamAccountName "cuate$i" `
        -AccountPassword $pass `
        -Enabled $true `
        -Path "OU=Cuates,DC=empresa,DC=local"
    }

    for ($i=1; $i -le 5; $i++) {
        New-ADUser -Name "nocuate$i" `
        -SamAccountName "nocuate$i" `
        -AccountPassword $pass `
        -Enabled $true `
        -Path "OU=NoCuates,DC=empresa,DC=local"
    }

    Write-Host "Usuarios creados correctamente"
}

# ================================
# OPCION 4
# ================================
function Configurar-FGPP {
    Import-Module ActiveDirectory

    New-ADFineGrainedPasswordPolicy `
    -Name "AdminsPolicy" `
    -Precedence 1 `
    -MinPasswordLength 12 `
    -ComplexityEnabled $true

    New-ADFineGrainedPasswordPolicy `
    -Name "UsersPolicy" `
    -Precedence 2 `
    -MinPasswordLength 8 `
    -ComplexityEnabled $true

    Write-Host "FGPP configurado"
}

# ================================
# OPCION 5
# ================================
function Configurar-Auditoria {
    auditpol /set /subcategory:"Logon" /success:enable /failure:enable
    Write-Host "Auditoria activada"
}

# ================================
# OPCION 6
# ================================
function Script-Logs {
    $logs = Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4625} -MaxEvents 10
    $logs | Out-File "C:\logs.txt"
    Write-Host "Logs exportados a C:\logs.txt"
}

# ================================
# LOOP
# ================================
do {
    Mostrar-Menu
    $op = Read-Host "Selecciona opcion"

    switch ($op) {
        1 { Instalar-AD }
        2 { Crear-Dominio }
        3 { Crear-Estructura }
        4 { Configurar-FGPP }
        5 { Configurar-Auditoria }
        6 { Script-Logs }
    }

    Pause
} while ($op -ne 0)
