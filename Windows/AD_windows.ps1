$DOM = "reprobados.com"
$NB = "REPROBADOS"
$CLAVE_SECRETA = ConvertTo-SecureString "Admin1234!" -AsPlainText -Force
$RUTA_CSV = "$PSScriptRoot\usuarios.csv"
$DIRECTORIO_RAIZ = "C:\AlmacenUsuarios"
$NOMBRE_SHARE = "AlmacenUsuarios"

Write-Host ">>> INICIANDO DESPLIEGUE AUTOMATIZADO <<<" -ForegroundColor Cyan

$rolActivo = (Get-WmiObject Win32_ComputerSystem).DomainRole -ge 4
if (-not $rolActivo) {
    Write-Host ">> Instalando roles AD DS y FSRM..." -ForegroundColor Yellow
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
    Install-WindowsFeature -Name FS-Resource-Manager -IncludeManagementTools | Out-Null

    Write-Host ">> Promoviendo a Controlador de Dominio. El servidor se reiniciara pronto..." -ForegroundColor Red
    Import-Module ADDSDeployment
    Install-ADDSForest -DomainName $DOM -DomainNetbiosName $NB -SafeModeAdministratorPassword $CLAVE_SECRETA -InstallDns:$true -Force:$true -NoRebootOnCompletion:$false | Out-Null
    exit
}

Write-Host ">> El equipo ya opera como Controlador de Dominio. Continuando..." -ForegroundColor Green

Import-Module ActiveDirectory
$baseDC = "DC=reprobados,DC=com"

foreach ($unidad in @("Cuates", "NoCuates")) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$unidad'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $unidad -Path $baseDC | Out-Null
    }
    $rutaUO = "OU=$unidad,$baseDC"
    if (-not (Get-ADGroup -Filter "Name -eq '$unidad'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $unidad -GroupScope Global -GroupCategory Security -Path $rutaUO | Out-Null
    }
}

if (Test-Path $RUTA_CSV) {
    if (-not (Test-Path $DIRECTORIO_RAIZ)) {
        New-Item -Path $DIRECTORIO_RAIZ -ItemType Directory | Out-Null
    }

    $shareExiste = Get-SmbShare -Name $NOMBRE_SHARE -ErrorAction SilentlyContinue
    if (-not $shareExiste) {
        New-SmbShare -Name $NOMBRE_SHARE -Path $DIRECTORIO_RAIZ -FullAccess "Everyone" | Out-Null
    }

    $nombreServidor = $env:COMPUTERNAME

    $lista = Import-Csv $RUTA_CSV
    foreach ($registro in $lista) {
        $gn = $registro.Nombres
        $sn = $registro.Apellidos
        $sam = $registro.Logon
        $pass = ConvertTo-SecureString $registro.Clave -AsPlainText -Force

        $destino = $registro.Grupo
        $rutaFinal = "OU=$destino,$baseDC"

        if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
            New-ADUser -Name "$gn $sn" -GivenName $gn -Surname $sn -SamAccountName $sam -UserPrincipalName "$sam@$DOM" -Path $rutaFinal -AccountPassword $pass -Enabled $true -PasswordNeverExpires $true | Out-Null
        }

        Add-ADGroupMember -Identity $destino -Members $sam -ErrorAction SilentlyContinue

        $carpetaPer = "$DIRECTORIO_RAIZ\$sam"
        if (-not (Test-Path $carpetaPer)) {
            New-Item -Path $carpetaPer -ItemType Directory | Out-Null
        }

        $permisos = Get-Acl $carpetaPer
        $permisos.SetAccessRuleProtection($true, $false)

        $sidAdmin = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $pAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule($sidAdmin, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")

        $sidUser = (Get-ADUser -Identity $sam).SID
        $pUser = New-Object System.Security.AccessControl.FileSystemAccessRule($sidUser, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")

        $permisos.AddAccessRule($pAdmin)
        $permisos.AddAccessRule($pUser)
        Set-Acl $carpetaPer $permisos

        $rutaUNC = "\\192.168.56.102\$NOMBRE_SHARE\$sam"
        Set-ADUser -Identity $sam -HomeDirectory $rutaUNC -HomeDrive "Z:"
    }
    Write-Host ">> Carga de usuarios y directorios completada." -ForegroundColor Green
} else {
    Write-Host ">> Archivo CSV no encontrado en $RUTA_CSV. Saltando creacion de usuarios." -ForegroundColor Red
}

function Generar-MatrizBytes([int[]]$Ventana) {
    $vector = New-Object bool[] 168
    foreach ($d in 0..6) {
        foreach ($h in $Ventana) {
            $pos = $d * 24 + $h
            if ($pos -ge 0 -and $pos -lt 168) { $vector[$pos] = $true }
        }
    }
    $binario = New-Object byte[] 21
    for ($k = 0; $k -lt 168; $k++) {
        if ($vector[$k]) {
            $bloque = [int][Math]::Floor($k / 8)
            $desplazamiento = $k % 8
            $binario[$bloque] = [byte]($binario[$bloque] -bor (1 -shl $desplazamiento))
        }
    }
    return ,$binario
}

$rangoA = 15..21
$rangoB = @(22,23,0,1,2,3,4,5,6,7,8)
$matrizA = Generar-MatrizBytes -Ventana $rangoA
$matrizB = Generar-MatrizBytes -Ventana $rangoB

Get-ADUser -Filter * -SearchBase "OU=Cuates,DC=reprobados,DC=com" | ForEach-Object { Set-ADUser -Identity $_.SamAccountName -Replace @{logonHours = $matrizA} }
Get-ADUser -Filter * -SearchBase "OU=NoCuates,DC=reprobados,DC=com" | ForEach-Object { Set-ADUser -Identity $_.SamAccountName -Replace @{logonHours = $matrizB} }

$nombreDirectiva = "Politica_Cierre_Turno"
$objGPO = Get-GPO -Name $nombreDirectiva -ErrorAction SilentlyContinue
if (-not $objGPO) {
    $objGPO = New-GPO -Name $nombreDirectiva
    Start-Sleep -Seconds 6
}

Set-GPRegistryValue -Name $nombreDirectiva -Key "HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -ValueName "ForceLogoffWhenHourExpire" -Type DWord -Value 1 | Out-Null
Set-GPRegistryValue -Name $nombreDirectiva -Key "HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -ValueName "EnableForcedLogOff" -Type DWord -Value 1 | Out-Null

try { New-GPLink -Name $nombreDirectiva -Target "DC=reprobados,DC=com" -ErrorAction Stop | Out-Null } catch {}
Write-Host ">> Politicas de horarios de logon inyectadas." -ForegroundColor Green

Import-Module FileServerResourceManager -ErrorAction SilentlyContinue

if (-not (Get-FsrmQuotaTemplate -Name "Cuota-10MB-Cuates" -ErrorAction SilentlyContinue)) {
    New-FsrmQuotaTemplate -Name "Cuota-10MB-Cuates" -Size 10MB -SoftLimit:$false -Description "Cuota estricta 10MB para Cuates" | Out-Null
}
if (-not (Get-FsrmQuotaTemplate -Name "Cuota-5MB-NoCuates" -ErrorAction SilentlyContinue)) {
    New-FsrmQuotaTemplate -Name "Cuota-5MB-NoCuates" -Size 5MB -SoftLimit:$false -Description "Cuota estricta 5MB para NoCuates" | Out-Null
}

Get-ADUser -Filter * -SearchBase "OU=Cuates,DC=reprobados,DC=com" | ForEach-Object {
    $rutaTarget = "$DIRECTORIO_RAIZ\$($_.SamAccountName)"
    if (Test-Path $rutaTarget) {
        if (-not (Get-FsrmQuota -Path $rutaTarget -ErrorAction SilentlyContinue)) {
            New-FsrmQuota -Path $rutaTarget -Template "Cuota-10MB-Cuates" | Out-Null
        }
    }
}

Get-ADUser -Filter * -SearchBase "OU=NoCuates,DC=reprobados,DC=com" | ForEach-Object {
    $rutaTarget = "$DIRECTORIO_RAIZ\$($_.SamAccountName)"
    if (Test-Path $rutaTarget) {
        if (-not (Get-FsrmQuota -Path $rutaTarget -ErrorAction SilentlyContinue)) {
            New-FsrmQuota -Path $rutaTarget -Template "Cuota-5MB-NoCuates" | Out-Null
        }
    }
}

$etiquetaFiltro = "FiltroRestringido_P8"
if (-not (Get-FsrmFileGroup -Name $etiquetaFiltro -ErrorAction SilentlyContinue)) {
    New-FsrmFileGroup -Name $etiquetaFiltro -IncludePattern @("*.mp3","*.mp4","*.exe","*.msi") | Out-Null
}

Get-ADUser -Filter * -SearchBase "DC=reprobados,DC=com" | ForEach-Object {
    $rutaTarget = "$DIRECTORIO_RAIZ\$($_.SamAccountName)"
    if (Test-Path $rutaTarget) {
        if (-not (Get-FsrmFileScreen -Path $rutaTarget -ErrorAction SilentlyContinue)) {
            New-FsrmFileScreen -Path $rutaTarget -IncludeGroup $etiquetaFiltro -Active:$true | Out-Null
        }
    }
}
Write-Host ">> Cuotas FSRM y bloqueos de extensiones activos." -ForegroundColor Green

$baseLdap = (Get-ADDomain).DistinguishedName
$targetGPO = "Reglas_AppLocker_Hash"

Remove-GPO -Name $targetGPO -ErrorAction SilentlyContinue
$gpoNueva = New-GPO -Name $targetGPO
Start-Sleep -Seconds 5
New-GPLink -Name $targetGPO -Target $baseLdap -ErrorAction SilentlyContinue | Out-Null
$cadenaLdap = "LDAP://CN={$($gpoNueva.Id)},CN=Policies,CN=System,$baseLdap"

# Valores exactos extraidos de tu cliente Windows 10 para Notepad.exe (Authenticode Hash)
$fileHash = "0x0C386FA6ABFDEFFBBEFF5BCE97D461340A23D1981458607BD9E5EEFF4066789A"
$fileLen  = 201216
Write-Host ">> Usando hash y length estaticos verificados para Notepad..." -ForegroundColor Green

$sidNoCuates = (Get-ADGroup "NoCuates").SID.Value

$xmlTodo = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="Salvavidas ProgramFiles" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51" Name="Salvavidas Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="Salvavidas Administradores" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
    <FileHashRule Id="$([guid]::NewGuid().ToString())" Name="Bloquear Notepad NoCuates" Description="" UserOrGroupSid="$sidNoCuates" Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256" Data="$fileHash" SourceFileName="notepad.exe" SourceFileLength="$fileLen" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
  </RuleCollection>
  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    <FilePublisherRule Id="$([guid]::NewGuid().ToString())" Name="Salvavidas Appx Menu Inicio" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="*" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="0.0.0.0" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>
</AppLockerPolicy>
"@

$xmlTodo | Out-File "$env:TEMP\applocker_todo.xml" -Encoding UTF8
Set-AppLockerPolicy -XmlPolicy "$env:TEMP\applocker_todo.xml" -Ldap $cadenaLdap


Set-GPRegistryValue -Name $targetGPO -Key "HKLM\Software\Policies\Microsoft\Windows\SrpV2\Exe" -ValueName "EnforcementMode" -Type DWord -Value 1 | Out-Null
Set-GPRegistryValue -Name $targetGPO -Key "HKLM\Software\Policies\Microsoft\Windows\SrpV2\Appx" -ValueName "EnforcementMode" -Type DWord -Value 1 | Out-Null
Set-GPRegistryValue -Name $targetGPO -Key "HKLM\System\CurrentControlSet\Services\AppIDSvc" -ValueName "Start" -Type DWord -Value 2 | Out-Null

$xmlTask = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <Enabled>true</Enabled>
  </Settings>
  <Actions>
    <Exec>
      <Command>sc.exe</Command>
      <Arguments>start AppIDSvc</Arguments>
    </Exec>
  </Actions>
</Task>
'@

$xmlTask | Out-File "$env:TEMP\task_applocker.xml" -Encoding Unicode
$nombreGPO_encoded = [uri]::EscapeDataString($targetGPO)
Register-ScheduledTask -TaskName "IniciarAppIDSvc" -Xml (Get-Content "$env:TEMP\task_applocker.xml" -Raw) -Force | Out-Null

$guidGPO = $gpoNueva.Id.ToString().ToUpper()
$rutaGPT = "\\reprobados.com\SYSVOL\reprobados.com\Policies\{$guidGPO}\Machine\Preferences\ScheduledTasks"
New-Item -Path $rutaGPT -ItemType Directory -Force | Out-Null

$xmlGPPTask = @"
<?xml version="1.0" encoding="utf-8"?>
<ScheduledTasks clsid="{CC63F200-7309-4ba0-B154-A0CE23105E28}">
  <ImmediateTaskV2 clsid="{9756B581-76EC-4169-9AFC-0CA8D43ADB5F}" name="IniciarAppIDSvc" image="0" changed="2024-01-01 00:00:00" uid="{$(New-Guid)}">
    <Properties action="C" name="IniciarAppIDSvc" runAs="NT AUTHORITY\System" logonType="S4U">
      <Task version="1.2">
        <Triggers>
          <BootTrigger><Enabled>true</Enabled></BootTrigger>
        </Triggers>
        <Principals>
          <Principal id="Author">
            <UserId>S-1-5-18</UserId>
            <RunLevel>HighestAvailable</RunLevel>
          </Principal>
        </Principals>
        <Settings>
          <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
          <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
          <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
          <Enabled>true</Enabled>
        </Settings>
        <Actions>
          <Exec>
            <Command>sc.exe</Command>
            <Arguments>start AppIDSvc</Arguments>
          </Exec>
        </Actions>
      </Task>
    </Properties>
  </ImmediateTaskV2>
</ScheduledTasks>
"@

$xmlGPPTask | Out-File "$rutaGPT\ScheduledTasks.xml" -Encoding UTF8

try { Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue } catch {}
Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
gpupdate /force | Out-Null

Write-Host ">> AppLocker configurado con reglas Hash para Notepad." -ForegroundColor Green
Write-Host ">>> SCRIPT FINALIZADO EXITOSAMENTE <<<" -ForegroundColor Cyan
Write-Host ">> Para unir tu Windows 10 al dominio usa: Add-Computer -DomainName `"reprobados.com`" -Credential (Get-Credential) -Restart -Force" -ForegroundColor Yellow
