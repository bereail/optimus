# Genera Optimizador-W10.exe (autoextraíble) con IExpress, incluido en Windows.
# Uso: powershell -ExecutionPolicy Bypass -File build.ps1
$root  = $PSScriptRoot
$files = 'Optimizador.ps1', 'Iniciar.bat', 'Revertir.bat', 'LEEME.txt'

$strings = ($files | ForEach-Object -Begin { $i = 0 } -Process { "FILE$i=`"$_`""; $i++ }) -join "`r`n"
$list    = (0..($files.Count - 1) | ForEach-Object { "%FILE$_%=" }) -join "`r`n"

$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$root\Optimizador-W10.exe
FriendlyName=Optimizador Windows 10 - 4GB RAM
AppLaunched=cmd /c Iniciar.bat
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
$strings
[SourceFiles]
SourceFiles0=$root\
[SourceFiles0]
$list
"@

$sedPath = Join-Path $env:TEMP 'optimizador.sed'
[IO.File]::WriteAllText($sedPath, $sed, [Text.Encoding]::ASCII)
Start-Process iexpress.exe -ArgumentList '/N', '/Q', $sedPath -Wait
Remove-Item $sedPath
Get-Item "$root\Optimizador-W10.exe" | Select-Object Name, Length
