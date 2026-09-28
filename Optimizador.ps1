<#
    Optimizador para Windows 10 con 4 GB de RAM - v2.0

    Uso:
        Iniciar.bat              Menú interactivo
        Iniciar.bat -Auto        Optimización completa sin preguntas
        Iniciar.bat -Revertir    Deshace todos los cambios
        Iniciar.bat -Diagnostico Solo muestra el estado del equipo

    Antes de cambiar cualquier valor se guarda su estado original en
    %ProgramData%\OptimizadorW10\respaldo.json, así "Revertir" deja el
    equipo exactamente como estaba (no con valores genéricos).
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$Revertir,
    [switch]$Diagnostico
)

$ErrorActionPreference = 'Continue'
$DataDir    = Join-Path $env:ProgramData 'OptimizadorW10'
$BackupFile = Join-Path $DataDir 'respaldo.json'
$LogFile    = Join-Path ([Environment]::GetFolderPath('Desktop')) 'optimizador_log.txt'
$HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'

# ------------------------------------------------------------------
#  Permisos de administrador
# ------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $Diagnostico -and -not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Auto)     { $argList += '-Auto' }
    if ($Revertir) { $argList += '-Revertir' }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait
    } catch {
        Write-Host 'Se necesitan permisos de administrador para continuar.' -ForegroundColor Red
        Start-Sleep -Seconds 4
    }
    exit
}

# ------------------------------------------------------------------
#  Interfaz
# ------------------------------------------------------------------
function Write-Title($t) { Write-Host ''; Write-Host " == $t ==" -ForegroundColor Cyan }
function Write-Ok($t)    { Write-Host "   [OK] $t" -ForegroundColor Green }
function Write-Info($t)  { Write-Host "        $t" -ForegroundColor Gray }
function Write-Warn($t)  { Write-Host "   [!]  $t" -ForegroundColor Yellow }

function Confirm-Step {
    param([string]$Question, [bool]$Default = $true)
    if ($Auto) { return $Default }
    $hint = if ($Default) { '[S/n]' } else { '[s/N]' }
    $r = Read-Host "   $Question $hint"
    if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
    return ($r -match '^[sSyY]')
}

function Wait-Key {
    if (-not $Auto) { Write-Host ''; Read-Host '   Presione Enter para continuar' | Out-Null }
}

# ------------------------------------------------------------------
#  Respaldo del estado original
# ------------------------------------------------------------------
function Get-Backup {
    $b = @{
        Fecha             = (Get-Date).ToString('s')
        Registry          = @{}
        Services          = @{}
        Tasks             = @{}
        PowerScheme       = $null
        MemoryCompression = $null
        PagefileAuto      = $null
    }
    if (Test-Path $BackupFile) {
        $j = Get-Content $BackupFile -Raw | ConvertFrom-Json
        foreach ($section in 'Registry', 'Services', 'Tasks') {
            if ($j.$section) {
                foreach ($p in $j.$section.PSObject.Properties) { $b[$section][$p.Name] = $p.Value }
            }
        }
        $b.Fecha             = $j.Fecha
        $b.PowerScheme       = $j.PowerScheme
        $b.MemoryCompression = $j.MemoryCompression
        $b.PagefileAuto      = $j.PagefileAuto
    }
    $b
}

function Save-Backup {
    New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
    $script:Backup | ConvertTo-Json -Depth 6 | Set-Content -Path $BackupFile -Encoding UTF8
}

# Escribe un valor de registro guardando antes el valor original (solo la primera vez)
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    $id = "$Path|$Name"
    if (-not $script:Backup.Registry.ContainsKey($id)) {
        $entry = @{ Path = $Path; Name = $Name; Existed = $false; Value = $null; Kind = $null }
        if (Test-Path $Path) {
            $key = Get-Item -Path $Path
            if ($key.GetValueNames() -contains $Name) {
                $entry.Existed = $true
                $entry.Value   = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
                $entry.Kind    = $key.GetValueKind($Name).ToString()
            }
        }
        $script:Backup.Registry[$id] = $entry
        Save-Backup
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# Cambia el tipo de inicio de un servicio guardando antes el original
function Set-ServiceStart {
    param([string]$Name, [ValidateSet('disabled', 'demand')][string]$Mode)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $key)) { return $false }
    if (-not $script:Backup.Services.ContainsKey($Name)) {
        $p = Get-ItemProperty -Path $key
        $script:Backup.Services[$Name] = @{ Start = [int]$p.Start; Delayed = [int]$p.DelayedAutostart }
        Save-Backup
    }
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    sc.exe config $Name start= $Mode | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Disable-Task {
    param([string]$TaskPath, [string]$TaskName)
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t -or $t.State -eq 'Disabled') { return }
    $script:Backup.Tasks["$TaskPath|$TaskName"] = $true
    Save-Backup
    Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
}

# ------------------------------------------------------------------
#  Información del sistema
# ------------------------------------------------------------------
function Get-DiskType {
    try {
        $disk = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop | Get-Disk
        $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq [string]$disk.Number }
        if ($pd) {
            if ([string]$pd.MediaType -in 'HDD', 'SSD') { return [string]$pd.MediaType }
            if ($pd.SpindleSpeed -eq 0) { return 'SSD' }
        }
    } catch { }
    return 'Desconocido'
}

function Get-PagefileState {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { return 'Automático' }
    if (Get-CimInstance Win32_PageFileSetting) { return 'Personalizado' }
    return 'DESACTIVADO'
}

function Get-SystemInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $mc = $null
    try { $mc = (Get-MMAgent -ErrorAction Stop).MemoryCompression } catch { }
    [pscustomobject]@{
        OS           = $os.Caption
        Build        = [int]$os.BuildNumber
        RamTotalGB   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        RamLibreGB   = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 2)
        DiscoLibreGB = [math]::Round((Get-PSDrive $env:SystemDrive.TrimEnd(':')).Free / 1GB, 1)
        DiscoTotalGB = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").Size / 1GB, 1)
        TipoDisco    = Get-DiskType
        EsPortatil   = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        Paginacion   = Get-PagefileState
        Compresion   = $mc
    }
}

function Show-SystemSummary($i) {
    $tipo = if ($i.EsPortatil) { 'Portátil' } else { 'Escritorio' }
    $comp = if ($null -eq $i.Compresion) { 'desconocido' } elseif ($i.Compresion) { 'activa' } else { 'inactiva' }
    Write-Info "Sistema:   $($i.OS) (build $($i.Build)) - $tipo"
    Write-Info "Memoria:   $($i.RamTotalGB) GB total, $($i.RamLibreGB) GB libres"
    Write-Info "Disco $($env:SystemDrive)  $($i.TipoDisco), $($i.DiscoLibreGB) GB libres de $($i.DiscoTotalGB) GB"
    Write-Info "Paginación: $($i.Paginacion)   |   Compresión de memoria: $comp"
}

# ------------------------------------------------------------------
#  Módulos
# ------------------------------------------------------------------
function New-RestorePoint {
    Write-Title 'Punto de restauración'
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $prev = (Get-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description 'Antes del Optimizador W10' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Ok "Punto de restauración 'Antes del Optimizador W10' creado"
        return $true
    } catch {
        Write-Warn "No se pudo crear el punto de restauración: $($_.Exception.Message)"
        return $false
    } finally {
        if ($null -eq $prev) { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $prev -Type DWord }
    }
}

function Invoke-Cleanup {
    Write-Title 'Limpieza de disco'
    $drive  = $env:SystemDrive.TrimEnd(':')
    $before = (Get-PSDrive $drive).Free
    $limite = (Get-Date).AddDays(-1)

    # Temporales de todos los usuarios; solo lo que tiene más de 24 h para no romper instalaciones en curso
    $carpetas = @($env:TEMP, "$env:SystemRoot\Temp", "$env:SystemRoot\Minidump")
    $carpetas += Get-ChildItem "$env:SystemDrive\Users" -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp'; Join-Path $_.FullName 'AppData\Local\CrashDumps' }
    foreach ($c in ($carpetas | Select-Object -Unique)) {
        if (Test-Path $c) {
            Get-ChildItem -Path $c -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $limite } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Ok 'Archivos temporales eliminados'

    $wuRunning = (Get-Service wuauserv -ErrorAction SilentlyContinue).Status -eq 'Running'
    Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
    if ($wuRunning) { Start-Service bits, wuauserv -ErrorAction SilentlyContinue }
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
    }
    Write-Ok 'Caché de Windows Update y Optimización de distribución eliminada'

    # Liberador de espacio de Windows con categorías seguras preseleccionadas
    $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    $cats = @('Temporary Files', 'Thumbnail Cache', 'Update Cleanup', 'Windows Error Reporting Files',
              'Delivery Optimization Files', 'Temporary Setup Files', 'Old ChkDsk Files', 'Setup Log Files',
              'Downloaded Program Files', 'Internet Cache Files', 'D3D Shader Cache',
              'System error memory dump files', 'System error minidump files', 'Windows Upgrade Log Files')
    if (Test-Path "$env:SystemDrive\Windows.old") {
        Write-Warn 'Existe la carpeta Windows.old (versión anterior de Windows, suele ocupar 10-20 GB).'
        if (Confirm-Step '¿Eliminarla? Ya no podrá volver a la versión anterior de Windows' $false) {
            $cats += 'Previous Installations'
        }
    }
    foreach ($c in $cats) {
        $k = Join-Path $vc $c
        if (Test-Path $k) { Set-ItemProperty $k -Name StateFlags0077 -Value 2 -Type DWord }
    }
    Write-Info 'Ejecutando el Liberador de espacio de Windows (en discos HDD puede tardar 10-30 min)...'
    Start-Process cleanmgr.exe -ArgumentList '/sagerun:77' -Wait
    Get-ChildItem $vc | ForEach-Object { Remove-ItemProperty $_.PSPath -Name StateFlags0077 -ErrorAction SilentlyContinue }
    Write-Ok 'Liberador de espacio completado'

    if (Confirm-Step '¿Vaciar la Papelera de reciclaje?' $false) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Ok 'Papelera vaciada'
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue

    $freed = ((Get-PSDrive $drive).Free - $before) / 1MB
    if ($freed -lt 0) { $freed = 0 }
    Write-Ok ('Espacio liberado: {0:N0} MB' -f $freed)
}

function Optimize-Power($info) {
    Write-Title 'Plan de energía'
    $current = $null
    if ((powercfg /getactivescheme | Out-String) -match '([0-9a-fA-F-]{36})') { $current = $Matches[1] }
    if ($info.EsPortatil) {
        Write-Info 'Es un portátil: "Alto rendimiento" consume más batería y calienta más.'
        if (-not (Confirm-Step '¿Activar "Alto rendimiento" de todos modos?' $false)) {
            Write-Ok 'Se mantiene el plan actual'
            return
        }
    }
    if (-not $script:Backup.PowerScheme) { $script:Backup.PowerScheme = $current; Save-Backup }
    powercfg /setactive $HighPerfGuid 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # En algunas ediciones el plan está oculto: se duplica y se activa la copia
        if ((powercfg /duplicatescheme $HighPerfGuid | Out-String) -match '([0-9a-fA-F-]{36})') {
            powercfg /setactive $Matches[1] | Out-Null
        }
    }
    Write-Ok 'Plan "Alto rendimiento" activado'
}

function Optimize-Interface {
    Write-Title 'Efectos visuales y ajustes de Windows'
    # Efectos visuales en modo rendimiento, manteniendo el suavizado de fuentes para que el texto se lea bien
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
    Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
    Write-Ok 'Efectos visuales en modo rendimiento (se conserva el suavizado de texto)'

    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
    Write-Ok 'Aplicaciones de la Tienda en segundo plano desactivadas'

    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($v in 'SystemPaneSuggestionsEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled',
                   'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
                   'SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled') {
        Set-Reg $cdm $v 0
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Write-Ok 'Sugerencias, anuncios e instalación automática de apps desactivados'

    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Write-Ok 'Grabación de Xbox Game Bar desactivada'

    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
    Write-Ok 'Sin retraso para los programas de inicio'

    if (Test-Path "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") {
        Write-Info 'Microsoft Edge queda cargado en memoria aunque esté cerrado (unos 100-200 MB).'
        Write-Info 'Al desactivarlo, Edge mostrará "administrado por su organización" (es normal).'
        if (Confirm-Step '¿Evitar que Edge quede abierto en segundo plano?' $true) {
            Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
            Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
            Write-Ok 'Edge ya no se precarga en segundo plano'
        }
    }
}

function Optimize-Services {
    Write-Title 'Telemetría y tareas en segundo plano'
    # Solo servicios que realmente arrancan solos; los que ya son "manual" no consumen nada
    foreach ($s in 'DiagTrack', 'dmwappushservice') {
        if (Set-ServiceStart $s 'disabled') { Write-Ok "Servicio $s desactivado" }
    }
    if (Set-ServiceStart 'MapsBroker' 'demand') { Write-Ok 'Servicio MapsBroker en modo manual' }

    # Tareas conocidas por disparar el uso de disco/CPU al 100% (CompatTelRunner, etc.)
    $tasks = @(
        @('\Microsoft\Windows\Application Experience\', 'Microsoft Compatibility Appraiser'),
        @('\Microsoft\Windows\Application Experience\', 'ProgramDataUpdater'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'Consolidator'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\', 'UsbCeip'),
        @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector')
    )
    foreach ($t in $tasks) { Disable-Task $t[0] $t[1] }
    Write-Ok 'Tareas programadas de telemetría desactivadas'
}

function Optimize-Memory {
    Write-Title 'Memoria'
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.AutomaticManagedPagefile -and -not (Get-CimInstance Win32_PageFileSetting)) {
        if ($null -eq $script:Backup.PagefileAuto) { $script:Backup.PagefileAuto = $false; Save-Backup }
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
        Write-Ok 'Archivo de paginación REACTIVADO (estaba apagado; con 4 GB provoca cierres de programas)'
    } else {
        Write-Ok "Archivo de paginación: $(Get-PagefileState) (correcto, no se toca)"
    }
    try {
        $mm = Get-MMAgent -ErrorAction Stop
        if ($mm.MemoryCompression) {
            Write-Ok 'Compresión de memoria ya activa'
        } else {
            if ($null -eq $script:Backup.MemoryCompression) { $script:Backup.MemoryCompression = $false; Save-Backup }
            Enable-MMAgent -MemoryCompression -ErrorAction Stop
            Write-Ok 'Compresión de memoria activada (clave con 4 GB: evita usar el disco como RAM)'
        }
    } catch {
        Write-Warn 'No se pudo consultar la compresión de memoria (necesita el servicio SysMain activo).'
    }
}

function Optimize-Disk($info) {
    Write-Title "Disco $($info.TipoDisco)"
    $tipo = $info.TipoDisco
    if ($tipo -eq 'Desconocido') {
        $tipo = if (Confirm-Step 'No se pudo detectar el tipo de disco. ¿Es un disco mecánico (HDD)?' $false) { 'HDD' } else { 'SSD' }
    }
    if ($tipo -ne 'HDD') {
        Write-Ok 'Disco SSD: no hace falta desactivar la indexación ni SysMain'
        return
    }
    Write-Info 'En discos HDD la indexación de búsqueda es una causa frecuente del "disco al 100%".'
    Write-Info 'Buscar apps en el menú Inicio sigue funcionando; buscar archivos será más lento.'
    if (Confirm-Step '¿Desactivar la indexación de búsqueda (WSearch)?' $true) {
        if (Set-ServiceStart 'WSearch' 'disabled') { Write-Ok 'Indexación de búsqueda desactivada' }
    }
    Write-Info 'SysMain precarga programas y además es NECESARIO para la compresión de memoria.'
    Write-Info 'Con 4 GB conviene dejarlo activo; desactívelo solo si el disco sigue al 100% tras reiniciar.'
    if (Confirm-Step '¿Desactivar SysMain?' $false) {
        if (Set-ServiceStart 'SysMain' 'disabled') { Write-Ok 'SysMain desactivado' }
    }
}

function Show-StartupPrograms {
    Write-Title 'Programas que arrancan con Windows'
    $st = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    if ($st.Count -eq 0) { Write-Info 'No se encontraron.'; return }
    $st | Sort-Object Name -Unique | ForEach-Object { Write-Info "- $($_.Name)" }
    if ($st.Count -gt 6) {
        Write-Warn "Hay $($st.Count) programas en el inicio. Con 4 GB conviene dejar solo el antivirus y lo imprescindible."
    }
    if (Confirm-Step '¿Abrir el Administrador de tareas (pestaña Inicio) para deshabilitar algunos?' $false) {
        Start-Process taskmgr.exe -ArgumentList '/0', '/startup'
    }
}

function Show-Diagnostic {
    $i = Get-SystemInfo
    Write-Title 'Diagnóstico del equipo'
    Show-SystemSummary $i

    Write-Title 'Procesos que más memoria usan'
    # Agrupado por programa: Chrome, por ejemplo, abre muchos procesos
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Count = $_.Count; MB = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB }
    } | Sort-Object MB -Descending | Select-Object -First 10 | ForEach-Object {
        $n = if ($_.Count -gt 1) { "$($_.Name) (x$($_.Count))" } else { $_.Name }
        Write-Info ('{0,-32} {1,7:N0} MB' -f $n, $_.MB)
    }

    Show-StartupPrograms

    Write-Title 'Recomendaciones'
    $n = 0
    if ($i.Paginacion -eq 'DESACTIVADO') { Write-Warn 'El archivo de paginación está apagado: actívelo (la opción 1 lo hace).'; $n++ }
    if ($i.Compresion -eq $false)        { Write-Warn 'La compresión de memoria está apagada (la opción 1 la activa).'; $n++ }
    if ($i.DiscoLibreGB -lt 15)          { Write-Warn "Quedan solo $($i.DiscoLibreGB) GB libres: Windows necesita al menos 15-20 GB."; $n++ }
    if ($i.TipoDisco -eq 'HDD')          { Write-Warn 'Disco HDD: cambiarlo por un SSD es la mejora más grande posible (5-10 veces más rápido).'; $n++ }
    if ($i.RamTotalGB -le 4)             { Write-Warn 'Con 4 GB, ampliar a 8 GB es la segunda mejora más notable.'; $n++ }
    if ($n -eq 0) { Write-Ok 'Sin problemas importantes detectados' }
}

function Invoke-FullOptimization {
    $info = Get-SystemInfo
    Write-Title 'Equipo detectado'
    Show-SystemSummary $info
    if ($info.Build -ge 22000) {
        Write-Warn 'Este equipo tiene Windows 11. El optimizador está pensado para Windows 10.'
        if (-not (Confirm-Step '¿Continuar igualmente?' $false)) { return }
    }
    $ramAntes = $info.RamLibreGB

    if (-not (New-RestorePoint)) {
        Write-Info 'Igualmente se guarda un respaldo propio de cada cambio para poder revertirlo.'
        if (-not (Confirm-Step '¿Continuar?' $true)) { return }
    }
    Invoke-Cleanup
    Optimize-Power $info
    Optimize-Interface
    Optimize-Services
    Optimize-Memory
    Optimize-Disk $info
    Show-StartupPrograms

    $despues = Get-SystemInfo
    Write-Title 'Resultado'
    Write-Ok "Memoria libre: $ramAntes GB -> $($despues.RamLibreGB) GB (mejora más tras reiniciar)"
    Write-Ok "Disco libre:   $($info.DiscoLibreGB) GB -> $($despues.DiscoLibreGB) GB"
    Write-Ok "Registro guardado en: $LogFile"
    Write-Ok 'Para deshacer todo: Revertir.bat (o opción 4 del menú)'
    Write-Host ''
    Write-Warn 'Es necesario REINICIAR para que todos los cambios surtan efecto.'
    if (Confirm-Step '¿Reiniciar ahora?' $false) { Restart-Computer -Force }
}

function Invoke-Revert {
    Write-Title 'Revertir cambios'
    if (-not (Test-Path $BackupFile)) {
        Write-Warn 'No hay cambios para revertir (no se encontró el respaldo).'
        return
    }
    $b = $script:Backup
    Write-Info "Respaldo del $($b.Fecha)"

    foreach ($e in $b.Registry.Values) {
        if ($e.Existed) {
            if (-not (Test-Path $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
            $v = $e.Value
            if ($e.Kind -eq 'Binary')      { $v = [byte[]]@($e.Value) }
            if ($e.Kind -eq 'MultiString') { $v = [string[]]@($e.Value) }
            New-ItemProperty -Path $e.Path -Name $e.Name -Value $v -PropertyType $e.Kind -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
        }
    }
    Write-Ok "Registro restaurado ($($b.Registry.Count) valores)"

    foreach ($name in $b.Services.Keys) {
        $s = $b.Services[$name]
        $mode = switch ([int]$s.Start) {
            2 { if ([int]$s.Delayed -eq 1) { 'delayed-auto' } else { 'auto' } }
            3 { 'demand' }
            4 { 'disabled' }
            default { $null }
        }
        if ($mode) {
            sc.exe config $name start= $mode | Out-Null
            if ($mode -in 'auto', 'delayed-auto') { Start-Service $name -ErrorAction SilentlyContinue }
            Write-Ok "Servicio $name -> $mode"
        }
    }

    foreach ($id in $b.Tasks.Keys) {
        $path, $name = $id -split '\|', 2
        Enable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue | Out-Null
    }
    if ($b.Tasks.Count) { Write-Ok "Tareas programadas reactivadas ($($b.Tasks.Count))" }

    if ($b.PowerScheme) { powercfg /setactive $b.PowerScheme | Out-Null; Write-Ok 'Plan de energía original restaurado' }
    if ($b.MemoryCompression -eq $false) { Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue; Write-Ok 'Compresión de memoria restaurada' }
    if ($b.PagefileAuto -eq $false) {
        Set-CimInstance -InputObject (Get-CimInstance Win32_ComputerSystem) -Property @{ AutomaticManagedPagefile = $false }
        Write-Ok 'Archivo de paginación restaurado'
    }

    Remove-Item $BackupFile -Force
    $script:Backup = Get-Backup
    Write-Host ''
    Write-Warn 'Reinicie el equipo para completar la restauración.'
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-Host '  ====================================================' -ForegroundColor Cyan
        Write-Host '     OPTIMIZADOR WINDOWS 10  -  equipos con 4 GB RAM' -ForegroundColor Cyan
        Write-Host '  ====================================================' -ForegroundColor Cyan
        Show-SystemSummary (Get-SystemInfo)
        if (Test-Path $BackupFile) { Write-Info "(Hay cambios aplicados el $($script:Backup.Fecha) que se pueden revertir)" }
        Write-Host ''
        Write-Host '   [1] Optimización completa (recomendada)'
        Write-Host '   [2] Solo limpieza de disco'
        Write-Host '   [3] Diagnóstico (qué consume memoria, programas de inicio)'
        Write-Host '   [4] Revertir todos los cambios'
        Write-Host '   [0] Salir'
        Write-Host ''
        switch (Read-Host '   Elija una opción') {
            '1' { Invoke-FullOptimization; Wait-Key }
            '2' { Invoke-Cleanup; Wait-Key }
            '3' { Show-Diagnostic; Wait-Key }
            '4' { if (Confirm-Step '¿Seguro que desea revertir todos los cambios?' $false) { Invoke-Revert }; Wait-Key }
            '0' { return }
        }
    }
}

# ------------------------------------------------------------------
#  Inicio
# ------------------------------------------------------------------
$Host.UI.RawUI.WindowTitle = 'Optimizador Windows 10 - 4 GB RAM'
Start-Transcript -Path $LogFile -Append | Out-Null
try {
    $script:Backup = Get-Backup
    if     ($Revertir)    { Invoke-Revert; Wait-Key }
    elseif ($Diagnostico) { Show-Diagnostic }
    elseif ($Auto)        { Invoke-FullOptimization }
    else                  { Show-Menu }
} finally {
    Stop-Transcript | Out-Null
}
