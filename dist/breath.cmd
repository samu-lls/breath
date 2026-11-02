<# : breath
@echo off
setlocal
set "BREATH_SRC=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d = Join-Path $env:TEMP 'breath'; New-Item -ItemType Directory -Force $d | Out-Null; $p = Join-Path $d 'breath.ps1'; [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($env:BREATH_SRC), (New-Object Text.UTF8Encoding $true)); & powershell -NoProfile -ExecutionPolicy Bypass -STA -File $p %*"
exit /b
#>
<#
    Breath — Otimizador para Windows 10 / 11
    Criado por samu-lls
    Interface gráfica (WPF) com backup automático e reversão por tweak.

    Uso:
        powershell -ExecutionPolicy Bypass -File .\breath.ps1
        powershell -ExecutionPolicy Bypass -File .\breath.ps1 -DryRun   # só simula

    Cada tweak guarda o valor original antes de alterar (C:\breath\backup.json),
    então "Reverter" devolve exatamente o estado anterior.
#>
[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Script:Versao   = '1.0.0'
$Script:Pasta    = Join-Path $env:SystemDrive 'breath'
$Script:Backup   = Join-Path $Script:Pasta 'backup.json'
$Script:LogFile  = Join-Path $Script:Pasta 'breath.log'

#region Elevação e STA ---------------------------------------------------------

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta     = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'

if (-not $isAdmin -or -not $isSta) {
    $exe  = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    if ($DryRun) { $argList += '-DryRun' }
    if ($isAdmin) { Start-Process -FilePath $exe -ArgumentList $argList }
    else          { Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs }
    exit
}

if (-not (Test-Path $Script:Pasta)) { New-Item -ItemType Directory -Path $Script:Pasta | Out-Null }

#endregion

#region Detecção do sistema ----------------------------------------------------

$os        = Get-CimInstance Win32_OperatingSystem
$Script:Build  = [int]$os.BuildNumber
$Script:IsWin11 = $Script:Build -ge 22000
$cpu       = Get-CimInstance Win32_Processor | Select-Object -First 1
$gpus      = @(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -like 'PCI\VEN_*' })
$Script:RamGB  = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$Script:HasNvidia = [bool]($gpus | Where-Object { $_.PNPDeviceID -match 'VEN_10DE' })
$Script:HasAmd    = [bool]($gpus | Where-Object { $_.PNPDeviceID -match 'VEN_1002' })
$Script:HasIntel  = [bool]($gpus | Where-Object { $_.PNPDeviceID -match 'VEN_8086' })

$Script:InfoSistema = '{0} (build {1})  •  {2}  •  {3} GB RAM  •  GPU: {4}' -f `
    $os.Caption, $Script:Build, $cpu.Name.Trim(), $Script:RamGB, (($gpus | ForEach-Object Name) -join ', ')

#endregion

#region Caminhos dinâmicos -----------------------------------------------------

$ClassGpu = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$ClassNic = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'

function ConvertTo-PsPath([string]$p) {
    $p -replace '^HKLM\\', 'Registry::HKEY_LOCAL_MACHINE\' `
       -replace '^HKCU\\', 'Registry::HKEY_CURRENT_USER\' `
       -replace '^HKCR\\', 'Registry::HKEY_CLASSES_ROOT\' `
       -replace '^HKU\\',  'Registry::HKEY_USERS\'
}

function Get-SubkeyPaths([string]$classPath, [scriptblock]$filtro) {
    Get-ChildItem -Path (ConvertTo-PsPath $classPath) -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        Where-Object $filtro |
        ForEach-Object { $_.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM' }
}

function Get-GpuPaths([string]$vendorRegex) {
    Get-SubkeyPaths $ClassGpu { "$($_.GetValue('ProviderName')) $($_.GetValue('DriverDesc'))" -match $vendorRegex }
}

function Get-EthernetPaths {
    # Só adaptadores com *SpeedDuplex (Ethernet cabeada)
    Get-SubkeyPaths $ClassNic { $null -ne $_.GetValue('*SpeedDuplex') }
}

function Get-ActiveInterfacePaths {
    Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object {
        "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($_.InterfaceGuid)"
    }
}

function Get-DevicePaths([string[]]$classes, [string]$sufixo) {
    Get-PnpDevice -PresentOnly -Class $classes -ErrorAction SilentlyContinue | ForEach-Object {
        "HKLM\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters$sufixo"
    }
}

#endregion

#region Construtores do catálogo -----------------------------------------------

$Script:Tweaks = New-Object System.Collections.Generic.List[object]

# Tweak
function Tw {
    param($Id, $Cat, $Nome, $Desc, [ValidateSet('Baixo', 'Medio', 'Alto')]$Risco, [bool]$Rec, [object[]]$Acoes, [bool]$Visivel = $true)
    if (-not $Visivel) { return }
    $Script:Tweaks.Add([pscustomobject]@{
        Id = $Id; Cat = $Cat; Nome = $Nome; Desc = $Desc; Risco = $Risco; Rec = $Rec; Acoes = $Acoes; CheckBox = $null; Status = $null
    })
}
# Valor de registro (Value pode ser scriptblock, avaliado na hora)
function Rg($Path, $Name, $Value, $Type = 'DWord', [switch]$SeExistir) {
    @{ T = 'Reg'; Path = $Path; Name = $Name; Value = $Value; Type = $Type; SeExistir = [bool]$SeExistir }
}
# Remove valor de registro
function RgDel($Path, $Name) { @{ T = 'RegDel'; Path = $Path; Name = $Name } }
# Mesmos valores em vários caminhos descobertos na hora
function RgMulti([scriptblock]$Paths, [hashtable]$Valores, $Type = 'DWord') {
    @{ T = 'RegMulti'; Paths = $Paths; Valores = $Valores; Type = $Type }
}
# Tipo de inicialização de serviço: 2 = automático, 3 = manual, 4 = desativado
function Sv($Name, [int]$Start) {
    @{ T = 'Reg'; Path = "HKLM\SYSTEM\CurrentControlSet\Services\$Name"; Name = 'Start'; Value = $Start; Type = 'DWord'; SeExistir = $true; Servico = $Name }
}
# Tarefa agendada a desativar
function Tk($TaskPath) { @{ T = 'Task'; Path = $TaskPath } }
# Comando livre com reversão própria
function Cm([scriptblock]$Aplicar, [scriptblock]$Reverter) { @{ T = 'Cmd'; Aplicar = $Aplicar; Reverter = $Reverter } }

#endregion

#region Catálogo de tweaks -----------------------------------------------------
# Categorias (ordem das abas)
$Script:Categorias = [ordered]@{
    Geral       = 'Geral'
    Energia     = 'Energia'
    Entrada     = 'Teclado e Mouse'
    GPU         = 'GPU'
    CPU         = 'CPU'
    Memoria     = 'Memória'
    Disco       = 'Armazenamento'
    Privacidade = 'Privacidade e Debloat'
    Apps        = 'Apps'
    Rede        = 'Rede'
    Extras      = 'Extras'
}

# ---------------- Geral ----------------
Tw 'geral.timer' Geral 'Timer de plataforma (bcdedit)' `
  'Desativa o dynamic tick e usa o platform tick. Pode reduzir latência de entrada em jogos.' Medio $false @(
    Cm { bcdedit /set disabledynamictick yes | Out-Null; bcdedit /set useplatformtick yes | Out-Null } `
      { bcdedit /deletevalue disabledynamictick | Out-Null; bcdedit /deletevalue useplatformtick | Out-Null }
)
Tw 'geral.prioridade' Geral 'Prioridade para o programa em primeiro plano' `
  'Win32PrioritySeparation = 38 (quantum curto e variável, favorece a janela ativa).' Baixo $true @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
)
Tw 'geral.respostas' Geral 'Encerrar apps travados mais rápido e menus instantâneos' `
  'Reduz tempos de espera ao desligar/fechar apps travados e remove o atraso dos menus.' Baixo $true @(
    Rg 'HKCU\Control Panel\Desktop' 'AutoEndTasks' '1' String
    Rg 'HKCU\Control Panel\Desktop' 'HungAppTimeout' '1000' String
    Rg 'HKCU\Control Panel\Desktop' 'WaitToKillAppTimeout' '2000' String
    Rg 'HKCU\Control Panel\Desktop' 'LowLevelHooksTimeout' '1000' String
    Rg 'HKCU\Control Panel\Desktop' 'MenuShowDelay' '0' String
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control' 'WaitToKillServiceTimeout' '2000' String
)
Tw 'geral.multimidia' Geral 'Responsividade do sistema multimídia' `
  'SystemResponsiveness = 10 e remove o limite de rede do agendador multimídia.' Baixo $true @(
    Rg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10
    Rg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' -1
)
Tw 'geral.notificacoes' Geral 'Desativar notificações' `
  'Desliga notificações toast, sons de notificação e a central de notificações.' Medio $false @(
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings' 'NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK' 0
    Rg 'HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1
)
Tw 'geral.sync' Geral 'Desativar sincronização de configurações' `
  'Para de sincronizar tema, idioma, senhas etc. com a conta Microsoft.' Baixo $false @(
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync' 'SyncPolicy' 5
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\SettingSync' 'DisableSettingSync' 2
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\SettingSync' 'DisableSettingSyncUserOverride' 1
)
Tw 'geral.background' Geral 'Desativar apps em segundo plano' `
  'Impede apps da Store de rodarem em segundo plano.' Baixo $true @(
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2
)
Tw 'geral.reinstalar' Geral 'Impedir reinstalação automática de apps sugeridos' `
  'Bloqueia o Windows de instalar apps patrocinados e sugestões no menu Iniciar.' Baixo $true @(
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
)
Tw 'geral.transparencia' Geral 'Desativar transparência' 'Desliga o efeito de transparência da barra e menus.' Baixo $false @(
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
)
Tw 'geral.feeds' Geral 'Desativar Notícias/Widgets e Linha do Tempo' 'Remove notícias e interesses, widgets e o feed de atividades.' Baixo $true @(
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
)
Tw 'geral.manutencao' Geral 'Desativar manutenção automática' `
  'A manutenção automática roda desfragmentação/verificações quando o PC fica ocioso.' Medio $false @(
    Rg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1
)
Tw 'geral.fse' Geral 'Otimizações de tela cheia (FSO)' 'Ajusta o GameConfigStore para o comportamento padrão de tela cheia otimizada.' Baixo $false @(
    Rg 'HKCU\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 0
    Rg 'HKCU\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 0
    Rg 'HKCU\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 0
)
Tw 'geral.drivers' Geral 'Não baixar drivers pelo Windows Update' `
  'Útil se você instala drivers de GPU manualmente. O Windows não vai mais atualizar drivers sozinho.' Medio $false @(
    Rg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
)
Tw 'geral.gamemode' Geral $(if ($Script:IsWin11) { 'Ativar Modo de Jogo (recomendado no Win 11)' } else { 'Desativar Modo de Jogo (recomendado no Win 10)' }) `
  'Ajustado automaticamente para a sua versão do Windows.' Baixo $true @(
    Rg 'HKCU\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode' ([int]$Script:IsWin11)
    Rg 'HKCU\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' ([int]$Script:IsWin11)
)
Tw 'geral.uac' Geral 'Desativar avisos do UAC' `
  'Administradores não recebem mais confirmação ao elevar. Qualquer programa pode virar admin sem você perceber.' Alto $false @(
    Rg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin' 0
    Rg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'PromptOnSecureDesktop' 0
)

# ---------------- Energia ----------------
Tw 'energia.plano' Energia 'Plano de energia "Breath Desempenho"' `
  'Cria um plano baseado no Desempenho Máximo, sem suspensão e sem estacionamento de núcleos, e o ativa.' Baixo $true @(
    Cm {
        # Desempenho Máximo; se a edição não tiver, usa Alto Desempenho
        $saida = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
        $guid  = [regex]::Match(($saida | Out-String), '[0-9a-fA-F-]{36}').Value
        if (-not $guid) {
            $saida = powercfg -duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null
            $guid  = [regex]::Match(($saida | Out-String), '[0-9a-fA-F-]{36}').Value
        }
        if (-not $guid) { throw 'Não foi possível criar o plano.' }
        powercfg -changename $guid 'Breath Desempenho' 'Plano criado pelo Breath' | Out-Null
        powercfg -setacvalueindex $guid sub_processor CPMINCORES 100 | Out-Null
        powercfg -setacvalueindex $guid sub_sleep standbyidle 0 | Out-Null
        powercfg -setacvalueindex $guid sub_sleep hybridsleep 0 | Out-Null
        powercfg -setacvalueindex $guid 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null  # USB selective suspend
        powercfg -setacvalueindex $guid sub_pciexpress ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null                      # PCIe ASPM
        powercfg -setactive $guid | Out-Null
    } {
        powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null
        powercfg -list | Select-String 'Breath' | ForEach-Object {
            $g = [regex]::Match($_.Line, '[0-9a-fA-F-]{36}').Value
            if ($g) { powercfg -delete $g | Out-Null }
        }
    }
)
Tw 'energia.throttling' Energia 'Desativar Power Throttling' 'Impede o Windows de limitar a CPU de processos em segundo plano.' Baixo $true @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
)
Tw 'energia.hibernacao' Energia 'Desativar hibernação e Inicialização Rápida' `
  'Libera espaço do hiberfil.sys e garante um desligamento completo. Notebooks perdem a hibernação.' Medio $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    Cm { powercfg /h off | Out-Null } { powercfg /h on | Out-Null }
)
Tw 'energia.telemetria' Energia 'Desativar telemetria de energia' 'Desliga o registro de consumo por aplicativo (Energy Estimation / Sleep Study).' Baixo $true @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'EnergyEstimationEnabled' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Power\EnergyEstimation\TaggedEnergy' 'DisableTaggedEnergyLogging' 1
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Power\EnergyEstimation\TaggedEnergy' 'TelemetryMaxApplication' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Power\EnergyEstimation\TaggedEnergy' 'TelemetryMaxTagPerApplication' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'SleepStudyDisabled' 1
)
Tw 'energia.timers' Energia 'Desativar agrupamento de timers (CoalescingTimerInterval)' 'Pode reduzir latência; aumenta um pouco o consumo.' Medio $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager' 'CoalescingTimerInterval' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'CoalescingTimerInterval' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'CoalescingTimerInterval' 0
)
Tw 'energia.modernstandby' Energia 'Desativar Modern Standby' `
  'Volta ao modo de suspensão S3 clássico. Em alguns notebooks a suspensão pode deixar de funcionar.' Alto $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'PlatformAoAcOverride' 0
)
Tw 'energia.disco' Energia 'Desativar economia de energia de discos (HIPM/DIPM/StorPort)' `
  'Evita que SSD/HDD entrem em estado de baixo consumo. Aumenta consumo em notebooks.' Medio $false @(
    RgMulti { Get-DevicePaths @('DiskDrive', 'SCSIAdapter', 'HDC') '\StorPort' } @{ EnableIdlePowerManagement = 0 }
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device' 'EnableHIPM' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device' 'EnableDIPM' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\storahci\Parameters\Device' 'EnableHDDParking' 0
)

# ---------------- Teclado e Mouse ----------------
Tw 'entrada.acessibilidade' Entrada 'Desativar atalhos de Teclas de Aderência/Filtro/Alternância' `
  'Evita o pop-up ao apertar Shift 5 vezes etc.' Baixo $true @(
    Rg 'HKCU\Control Panel\Accessibility\StickyKeys' 'Flags' '506' String
    Rg 'HKCU\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' String
    Rg 'HKCU\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' String
)
Tw 'entrada.aceleracao' Entrada 'Desativar aceleração do mouse' 'Movimento 1:1 (desmarca "Aumentar precisão do ponteiro").' Baixo $true @(
    Rg 'HKCU\Control Panel\Mouse' 'MouseSpeed' '0' String
    Rg 'HKCU\Control Panel\Mouse' 'MouseThreshold1' '0' String
    Rg 'HKCU\Control Panel\Mouse' 'MouseThreshold2' '0' String
    Rg 'HKCU\Control Panel\Mouse' 'MouseSensitivity' '10' String
)
Tw 'entrada.teclado' Entrada 'Repetição de teclas mais rápida' 'Menor atraso e maior velocidade de repetição do teclado.' Baixo $true @(
    Rg 'HKCU\Control Panel\Keyboard' 'KeyboardDelay' '0' String
    Rg 'HKCU\Control Panel\Keyboard' 'KeyboardSpeed' '31' String
)
Tw 'entrada.csrss' Entrada 'Prioridade alta para o csrss (entrada de teclado/mouse)' 'Define prioridade de CPU e E/S alta para o processo que trata a entrada.' Medio $false @(
    Rg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions' 'CpuPriorityClass' 4
    Rg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\csrss.exe\PerfOptions' 'IoPriority' 3
)
Tw 'entrada.fila' Entrada 'Tamanho da fila de dados do mouse/teclado' `
  'Reduz o buffer de entrada (valor escolhido pelo número de núcleos da CPU). Valores baixos demais podem causar travadas no mouse.' Medio $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' 'MouseDataQueueSize' { if ($cpu.NumberOfLogicalProcessors -ge 12) { 30 } elseif ($cpu.NumberOfLogicalProcessors -ge 8) { 50 } else { 80 } }
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\kbdclass\Parameters' 'KeyboardDataQueueSize' { if ($cpu.NumberOfLogicalProcessors -ge 12) { 30 } elseif ($cpu.NumberOfLogicalProcessors -ge 8) { 50 } else { 80 } }
)
Tw 'entrada.usb' Entrada 'Desativar suspensão seletiva USB' 'Evita que portas USB (mouse, headset) entrem em economia de energia.' Baixo $true @(
    RgMulti { Get-DevicePaths @('USB') '' } @{
        AllowIdleIrpInD3 = 0; EnhancedPowerManagementEnabled = 0; SelectiveSuspendEnabled = 0; DeviceSelectiveSuspended = 0; SelectiveSuspendOn = 0
    }
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\USB' 'DisableSelectiveSuspend' 1
)

# ---------------- GPU ----------------
Tw 'gpu.hags' GPU 'Ativar agendamento de GPU acelerado por hardware (HAGS)' 'Requer GPU e driver compatíveis. Precisa reiniciar.' Baixo $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
)
Tw 'gpu.flip' GPU 'Permitir Independent Flip / desativar otimizações de VRR em janela' 'Remove OverlayTestMode do DWM e ajusta DirectXUserGlobalSettings.' Baixo $false @(
    RgDel 'HKLM\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode'
    Rg 'HKCU\SOFTWARE\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' 'VRROptimizeEnable=0;SwapEffectUpgradeEnable=1;' String
)
Tw 'gpu.energia' GPU 'Desativar driver de medição de energia da GPU' 'Desliga o GpuEnergyDrv (só telemetria de consumo).' Baixo $true @(
    Sv 'GpuEnergyDrv' 4
)
Tw 'gpu.nvidia' GPU 'NVIDIA: latência, logs e HDCP' `
  'Desativa logs do driver, HDCP (pode impedir streaming em 4K da Netflix) e força memória contígua.' Medio $false @(
    RgMulti { Get-GpuPaths 'NVIDIA' } @{ PreferSystemMemoryContiguous = 1; RMHdcpKeyglobZero = 1; D3PCLatency = 1; F1TransitionLatency = 1; LOWLATENCY = 1; Node3DLowLatency = 1; RMDeepL1EntryLatencyUsec = 1 }
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm' 'LogWarningEntries' 0 -SeExistir
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm' 'LogPagingEntries' 0 -SeExistir
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm' 'LogEventEntries' 0 -SeExistir
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm' 'LogErrorEntries' 0 -SeExistir
) -Visivel $Script:HasNvidia
Tw 'gpu.nvidiatelemetria' GPU 'NVIDIA: desativar telemetria' 'Desativa tarefas agendadas de telemetria e o opt-in do Painel de Controle NVIDIA.' Baixo $true @(
    Tk '\NvTmRep_CrashReport1_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}'
    Tk '\NvTmRep_CrashReport2_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}'
    Tk '\NvTmRep_CrashReport3_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}'
    Tk '\NvTmRep_CrashReport4_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}'
    Tk '\NvTmMon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}'
    Rg 'HKCU\SOFTWARE\NVIDIA Corporation\NVControlPanel2\Client' 'OptInOrOutPreference' 0
) -Visivel $Script:HasNvidia
Tw 'gpu.amd' GPU 'AMD: desativar economia de energia (ULPS, power gating)' `
  'A GPU deixa de entrar em estados de baixo consumo. Mais temperatura em idle.' Medio $false @(
    RgMulti { Get-GpuPaths 'AMD|ATI|Radeon' } @{ EnableUlps = 0; PP_SclkDeepSleepDisable = 1; DisablePowerGating = 1; EnableAspmL0s = 0; EnableAspmL1 = 0; StutterMode = 0 }
) -Visivel $Script:HasAmd
Tw 'gpu.amdservicos' GPU 'AMD: desativar telemetria e serviços extras' 'Desativa AMD Telemetry, Crash Defender e o log do driver.' Baixo $true @(
    Sv 'AMD Crash Defender Service' 4
    Sv 'AMD Telemetry Service' 4
    Sv 'amdlog' 4
) -Visivel $Script:HasAmd
Tw 'gpu.intel' GPU 'Intel: ajustes do driver gráfico' 'Segmento dedicado de 512 MB e desativa melhorias de overlay.' Medio $false @(
    RgMulti { Get-GpuPaths 'Intel' } @{ Disable_OverlayDSQualityEnhancement = 1; IncreaseFixedSegment = 1; AdaptiveVsyncEnabled = 0 }
    Rg 'HKLM\SOFTWARE\Intel\GMM' 'DedicatedSegmentSize' 512
) -Visivel $Script:HasIntel

# ---------------- CPU ----------------
Tw 'cpu.parking' CPU 'Desativar estacionamento de núcleos (core parking)' 'Mantém todos os núcleos ativos no plano de energia atual.' Medio $false @(
    Cm { powercfg -setacvalueindex scheme_current sub_processor CPMINCORES 100 | Out-Null; powercfg -setactive scheme_current | Out-Null } `
      { powercfg -setacvalueindex scheme_current sub_processor CPMINCORES 5 | Out-Null; powercfg -setactive scheme_current | Out-Null }
)
Tw 'cpu.mitigacoes' CPU 'Desativar mitigações de segurança (CFG, SEHOP, ASLR)' `
  'PERIGOSO: remove proteções contra exploits de memória. Ganho de desempenho pequeno. Não recomendado em PC de uso diário.' Alto $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DisableExceptionChainValidation' 1
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'KernelSEHOPEnabled' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'EnableCfg' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'MoveImages' 0
)
Tw 'cpu.smartscreen' CPU 'Desativar SmartScreen' 'PERIGOSO: o Windows deixa de avisar sobre downloads e sites maliciosos.' Alto $false @(
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
    Rg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off' String
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost' 'EnableWebContentEvaluation' 0
)

# ---------------- Memória ----------------
Tw 'mem.svchost' Memoria "Agrupar processos svchost (ajustado para $($Script:RamGB) GB)" `
  'Define SvcHostSplitThresholdInKB conforme a RAM instalada: menos processos svchost.exe.' Baixo $true @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' ([int]([math]::Min($Script:RamGB * 1MB, [int]::MaxValue)))
)
Tw 'mem.compressao' Memoria 'Desativar compressão de memória' 'Recomendado só com 16 GB ou mais de RAM.' Medio ($Script:RamGB -ge 32) @(
    Cm { Disable-MMAgent -MemoryCompression } { Enable-MMAgent -MemoryCompression }
)
Tw 'mem.paginacao' Memoria 'Manter kernel na RAM (DisablePagingExecutive)' 'Impede que drivers e o kernel sejam paginados para o disco.' Baixo ($Script:RamGB -ge 8) @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1
)
Tw 'mem.sysmain' Memoria 'Desativar SysMain (Superfetch) e Prefetch' `
  'Pode ajudar no Windows 10 com SSD. No Windows 11 o recomendado é manter ligado.' Medio $false @(
    Sv 'SysMain' 4
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 0
    Rg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 0
)

# ---------------- Armazenamento ----------------
Tw 'disco.trim' Disco 'Garantir TRIM ativo e otimizar unidade C:' 'Ativa o TRIM (essencial para SSD) e executa ReTrim/otimização no C:.' Baixo $true @(
    Cm { fsutil behavior set disabledeletenotify 0 | Out-Null; Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue } { }
)
Tw 'disco.ntfs' Disco 'Otimizar NTFS (sem 8.3, sem último acesso)' 'Desativa nomes curtos 8.3 e a atualização da data de último acesso.' Baixo $true @(
    Cm { fsutil behavior set disable8dot3 1 | Out-Null; fsutil behavior set disablelastaccess 1 | Out-Null; fsutil behavior set memoryusage 2 | Out-Null } `
      { fsutil behavior set disable8dot3 2 | Out-Null; fsutil behavior set disablelastaccess 2 | Out-Null; fsutil behavior set memoryusage 1 | Out-Null }
)
Tw 'disco.cache' Disco 'Desativar descarga do cache de gravação' `
  'Mais velocidade de escrita, mas uma queda de energia pode corromper dados. Evite sem nobreak.' Alto $false @(
    RgMulti { Get-DevicePaths @('DiskDrive') '\Disk' } @{ UserWriteCacheSetting = 1; CacheIsPowerProtected = 1 }
)

# ---------------- Privacidade e Debloat ----------------
$tarefasTelemetria = @(
    '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator'
    '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip'
    '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask'
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser'
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater'
    '\Microsoft\Windows\Application Experience\StartupAppTask'
    '\Microsoft\Windows\Autochk\Proxy'
    '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector'
    '\Microsoft\Windows\Feedback\Siuf\DmClient'
    '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
    '\Microsoft\Windows\PI\Sqm-Tasks'
    '\Microsoft\Windows\NetTrace\GatherNetworkInfo'
    '\Microsoft\Windows\Device Information\Device'
    '\Microsoft\Office\OfficeTelemetryAgentFallBack2016'
    '\Microsoft\Office\OfficeTelemetryAgentLogOn2016'
)
Tw 'priv.telemetria' Privacidade 'Desativar telemetria do Windows' `
  'Nível mínimo de dados de diagnóstico, sem ID de publicidade, sem experiências personalizadas e sem tarefas de coleta.' Baixo $true (@(
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Rg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowDeviceNameInTelemetry' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Rg 'HKCU\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
    Rg 'HKCU\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
    Rg 'HKCU\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows' 'CEIPEnable' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'AITEnable' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableUAR' 1
    Rg 'HKLM\SOFTWARE\Microsoft\PolicyManager\default\System\AllowExperimentation' 'value' 0
    Rg 'HKCU\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1
    Sv 'DiagTrack' 4
    Sv 'dmwappushservice' 4
) + ($tarefasTelemetria | ForEach-Object { Tk $_ }))
Tw 'priv.autologgers' Privacidade 'Desativar autologgers de diagnóstico' 'Para sessões de rastreamento ETW de telemetria que rodam desde o boot.' Baixo $true @(
    'AutoLogger-Diagtrack-Listener', 'Diagtrack-Listener', 'DiagLog', 'SQMLogger', 'CloudExperienceHostOobe', 'WiFiSession' | ForEach-Object {
        Rg "HKLM\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$_" 'Start' 0 -SeExistir
    }
)
Tw 'priv.erros' Privacidade 'Desativar Relatório de Erros do Windows' 'Não envia relatórios de falhas para a Microsoft.' Baixo $true @(
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Rg 'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Sv 'WerSvc' 3
)
Tw 'priv.office' Privacidade 'Desativar telemetria do Office' 'Feedback, logs e envio de dados do Office 2016+.' Baixo $true @(
    Rg 'HKCU\Software\Microsoft\Office\Common\ClientTelemetry' 'DisableTelemetry' 1
    Rg 'HKCU\Software\Microsoft\Office\16.0\Common' 'sendcustomerdata' 0
    Rg 'HKCU\Software\Microsoft\Office\16.0\Common\Feedback' 'Enabled' 0
    Rg 'HKCU\Software\Microsoft\Office\16.0\OSM' 'Enablelogging' 0
    Rg 'HKCU\Software\Microsoft\Office\16.0\OSM' 'EnableUpload' 0
)
Tw 'priv.localizacao' Privacidade 'Desativar localização' 'Bloqueia o serviço de localização para todos os apps.' Medio $false @(
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableWindowsLocationProvider' 1
)
Tw 'priv.gamedvr' Privacidade 'Desativar Game DVR / gravação da Xbox Game Bar' 'Desliga a gravação em segundo plano. A Game Bar continua abrindo.' Baixo $true @(
    Rg 'HKCU\System\GameConfigStore' 'GameDVR_Enabled' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 0
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
)
Tw 'priv.xbox' Privacidade 'Desativar serviços Xbox' 'Jogos do Game Pass / Xbox app deixam de funcionar até reverter.' Medio $false @(
    Sv 'XblAuthManager' 4
    Sv 'XblGameSave' 4
    Sv 'XboxGipSvc' 4
    Sv 'XboxNetApiSvc' 4
)
Tw 'priv.bluetooth' Privacidade 'Desativar Bluetooth' 'Desliga os serviços de Bluetooth. Fones e controles sem fio param de funcionar.' Medio $false @(
    Sv 'bthserv' 4
    Sv 'BTAGService' 4
    Sv 'BthAvctpSvc' 4
)
Tw 'priv.impressao' Privacidade 'Desativar impressão e Mapas' 'Desliga o Spooler de impressão e o serviço de mapas offline. Impressoras param de funcionar.' Medio $false @(
    Sv 'Spooler' 4
    Sv 'PrintNotify' 4
    Sv 'MapsBroker' 4
)
Tw 'priv.store' Privacidade 'Desativar Microsoft Store' 'Bloqueia a Store e apps dela. Alguns apps (Xbox, WhatsApp) dependem dela.' Alto $false @(
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\WindowsStore' 'RemoveWindowsStore' 1
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\WindowsStore' 'DisableStoreApps' 1
)
Tw 'priv.entrega' Privacidade 'Desativar Otimização de Entrega (P2P)' 'O Windows Update não compartilha atualizações com outros PCs da internet.' Baixo $true @(
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
)

# ---------------- Apps ----------------
$appsInuteis = @(
    'Microsoft.BingWeather', 'Microsoft.BingNews', 'Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.GetHelp',
    'Microsoft.Getstarted', 'Microsoft.Messaging', 'Microsoft.Microsoft3DViewer', 'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MixedReality.Portal', 'Microsoft.OneConnect', 'Microsoft.People', 'Microsoft.Print3D', 'Microsoft.SkypeApp',
    'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.ZuneVideo', 'microsoft.windowscommunicationsapps',
    'Microsoft.549981C3F5F10', 'Clipchamp.Clipchamp', 'Microsoft.Todos', 'MicrosoftCorporationII.MicrosoftFamily'
)
Tw 'apps.remover' Apps 'Remover apps pré-instalados inúteis' `
  'Remove Clima, Notícias, Dicas, Solitaire, Skype, Pessoas, Mapas, Hub de Feedback, Cortana, Clipchamp, To Do, Família e outros. Câmera, Fotos, Calculadora e Store são mantidos. Para reverter, reinstale pela Store.' Medio $false @(
    Cm {
        foreach ($a in $appsInuteis) {
            Get-AppxPackage -AllUsers -Name $a -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $a | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        }
    } {
        Start-Process 'ms-windows-store:' -ErrorAction SilentlyContinue
        Write-Log '   Apps removidos precisam ser reinstalados pela Microsoft Store (abri a Store para você).'
    }
)
Tw 'apps.copilot' Apps 'Desativar Copilot' 'Desativa o Windows Copilot por política e remove o app.' Baixo $true @(
    Rg 'HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Rg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Cm { Get-AppxPackage -Name 'Microsoft.Copilot' -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue } { }
)

# ---------------- Rede ----------------
Tw 'rede.dns' Rede 'Prioridades de resolução de nomes' 'Ordem DNS/hosts/local/NetBT otimizada para resolver nomes mais rápido.' Baixo $true @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider' 'LocalPriority' 4
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider' 'HostsPriority' 5
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider' 'DnsPriority' 6
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider' 'NetbtPriority' 7
)
Tw 'rede.portas' Rede 'MaxUserPort, TcpTimedWaitDelay e TTL' 'Mais portas efêmeras e liberação mais rápida de conexões fechadas.' Baixo $true @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'MaxUserPort' 65534
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'TcpTimedWaitDelay' 30
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' 'DefaultTTL' 64
)
Tw 'rede.nagle' Rede 'Desativar algoritmo de Nagle (TCPNoDelay)' 'Envia pacotes TCP pequenos imediatamente. Pode reduzir ping em alguns jogos.' Baixo $true @(
    RgMulti { Get-ActiveInterfacePaths } @{ TcpAckFrequency = 1; TCPNoDelay = 1; TcpDelAckTicks = 0 }
)
Tw 'rede.tcp' Rede 'Ajustes globais de TCP' 'Desativa heurísticas de escala de janela e ajusta RTO/retransmissões de SYN.' Medio $false @(
    Cm {
        netsh int tcp set heuristics disabled | Out-Null
        Set-NetTCPSetting -SettingName Internet -ScalingHeuristics Disabled -MaxSynRetransmissions 2 -InitialRto 2000 -MinRto 300 -ErrorAction SilentlyContinue
    } {
        netsh int tcp set heuristics default | Out-Null
        Set-NetTCPSetting -SettingName Internet -ScalingHeuristics Disabled -MaxSynRetransmissions 4 -InitialRto 3000 -MinRto 300 -ErrorAction SilentlyContinue
    }
)
Tw 'rede.sondagem' Rede 'Desativar sondagem de internet (NCSI)' 'O ícone de rede pode mostrar "sem internet" mesmo conectado.' Medio $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet' 'EnableActiveProbing' 0
)
Tw 'rede.nic' Rede 'Desativar economia de energia da placa Ethernet' 'Desliga EEE, Green Ethernet e Wake-on-LAN nos adaptadores cabeados.' Medio $false @(
    RgMulti { Get-EthernetPaths } @{
        '*EEE' = '0'; EEE = '0'; AdvancedEEE = '0'; EnableGreenEthernet = '0'; GigaLite = '0'; PowerSavingMode = '0'
        AutoPowerSaveModeEnabled = '0'; ReduceSpeedOnPowerDown = '0'; '*WakeOnMagicPacket' = '0'; '*WakeOnPattern' = '0'; WakeOnLink = '0'
        '*FlowControl' = '0'; '*InterruptModeration' = '0'
    } String
)
Tw 'rede.offload' Rede 'Desativar offloads da placa de rede (LSO, RSC, checksum)' `
  'Transfere esse trabalho para a CPU. Em placas boas pode PIORAR o desempenho; teste antes.' Alto $false @(
    Cm {
        Disable-NetAdapterLso -Name * -ErrorAction SilentlyContinue
        Disable-NetAdapterChecksumOffload -Name * -ErrorAction SilentlyContinue
        Disable-NetAdapterRsc -Name * -ErrorAction SilentlyContinue
    } {
        Enable-NetAdapterLso -Name * -ErrorAction SilentlyContinue
        Enable-NetAdapterChecksumOffload -Name * -ErrorAction SilentlyContinue
        Enable-NetAdapterRsc -Name * -ErrorAction SilentlyContinue
    }
)
Tw 'rede.ipv4' Rede 'Preferir IPv4 em vez de IPv6' 'Mantém o IPv6 funcionando, mas prioriza IPv4 (forma recomendada pela Microsoft).' Baixo $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 0x20
)
Tw 'rede.ipv6' Rede 'Desativar IPv6 por completo' `
  'A Microsoft NÃO recomenda: pode quebrar Grupo Doméstico, Xbox Live, VPNs e alguns provedores. Prefira a opção acima.' Alto $false @(
    Rg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 0xFF
)

# ---------------- Extras ----------------
Tw 'extras.extensoes' Extras 'Mostrar extensões de arquivos' 'Exibe ".exe", ".pdf" etc. no Explorer (ajuda a identificar arquivos falsos).' Baixo $true @(
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
)
Tw 'extras.escuro' Extras 'Modo escuro' 'Tema escuro para apps e para o sistema.' Baixo $false @(
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
)
Tw 'extras.wallpaper' Extras 'Papel de parede em qualidade máxima' 'Remove a compressão JPEG do papel de parede.' Baixo $true @(
    Rg 'HKCU\Control Panel\Desktop' 'JPEGImportQuality' 100
)
Tw 'extras.bing' Extras 'Remover pesquisa Bing do menu Iniciar' 'A busca do Iniciar procura só no PC.' Baixo $true @(
    Rg 'HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    Rg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
)
Tw 'extras.menuclassico' Extras 'Menu de contexto clássico (Win 11)' 'Volta o menu do botão direito completo, sem "Mostrar mais opções".' Baixo $false @(
    Rg 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' String
) -Visivel $Script:IsWin11

#endregion

#region Motor: backup, aplicar, reverter ---------------------------------------

function Write-Log([string]$msg, [string]$nivel = 'info') {
    $linha = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
    Add-Content -Path $Script:LogFile -Value $linha -Encoding UTF8
    if ($Script:LogBox) {
        $Script:LogBox.AppendText($linha + "`r`n")
        $Script:LogBox.ScrollToEnd()
        $Script:StatusTxt.Text = $msg.Trim()
        $Script:Window.Dispatcher.Invoke([action] {}, 'Background')
    } else {
        Write-Host $linha
    }
}

function Read-BackupStore {
    $store = @{}
    if (Test-Path $Script:Backup) {
        $json = Get-Content $Script:Backup -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $store[$p.Name] = @($p.Value) }
    }
    $store
}

function Save-BackupStore($store) {
    $store | ConvertTo-Json -Depth 6 | Set-Content -Path $Script:Backup -Encoding UTF8
}

function Get-RegState($path, $name) {
    $ps = ConvertTo-PsPath $path
    $estado = @{ T = 'Reg'; Path = $path; Name = $name; Existia = $false; Valor = $null; Tipo = $null; ChaveExistia = (Test-Path $ps) }
    if ($estado.ChaveExistia) {
        $key = Get-Item -Path $ps
        if ($name -eq '(default)') { $name = '' }
        if ($key.GetValueNames() -contains $name) {
            $estado.Existia = $true
            $estado.Valor   = $key.GetValue($name, $null, 'DoNotExpandEnvironmentNames')
            $estado.Tipo    = $key.GetValueKind($name).ToString()
        }
    }
    $estado
}

function Set-RegValue($path, $name, $value, $type) {
    $ps = ConvertTo-PsPath $path
    if (-not (Test-Path $ps)) { New-Item -Path $ps -Force | Out-Null }
    if ($type -eq 'Binary' -and $value -isnot [byte[]]) { $value = [byte[]]$value }
    New-ItemProperty -Path $ps -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

function Restore-RegState($e) {
    $ps = ConvertTo-PsPath $e.Path
    if ($e.Existia) {
        $v = $e.Valor
        if ($e.Tipo -eq 'Binary') { $v = [byte[]]@($v) }
        if ($e.Tipo -eq 'MultiString') { $v = [string[]]@($v) }
        Set-RegValue $e.Path $e.Name $v $e.Tipo
    } elseif (Test-Path $ps) {
        Remove-ItemProperty -Path $ps -Name $e.Name -ErrorAction SilentlyContinue
        # Remove a chave se ela foi criada pelo Breath e ficou vazia
        if (-not $e.ChaveExistia) {
            $k = Get-Item $ps -ErrorAction SilentlyContinue
            if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item $ps -ErrorAction SilentlyContinue }
        }
    }
}

# Expande RegMulti e avalia valores dinâmicos em uma lista simples de ações
function Expand-Acoes($tweak) {
    $i = 0
    foreach ($a in $tweak.Acoes) {
        switch ($a.T) {
            'RegMulti' {
                $paths = @(& $a.Paths)
                if ($paths.Count -eq 0) { Write-Log "   (nenhum dispositivo encontrado para '$($tweak.Nome)')" }
                foreach ($p in $paths) {
                    foreach ($n in $a.Valores.Keys) {
                        @{ T = 'Reg'; Path = $p; Name = $n; Value = $a.Valores[$n]; Type = $a.Type; SeExistir = $false; Indice = $i }
                    }
                }
            }
            'Reg' {
                $c = $a.Clone(); $c.Indice = $i
                if ($c.Value -is [scriptblock]) { $c.Value = & $c.Value }
                $c
            }
            default { $c = $a.Clone(); $c.Indice = $i; $c }
        }
        $i++
    }
}

function Invoke-Tweak($tweak, $store) {
    $jaTemBackup = $store.ContainsKey($tweak.Id)
    $estados = New-Object System.Collections.Generic.List[object]
    foreach ($a in (Expand-Acoes $tweak)) {
        try {
            switch ($a.T) {
                'Reg' {
                    if ($a.SeExistir -and -not (Test-Path (ConvertTo-PsPath $a.Path))) { continue }
                    $estados.Add((Get-RegState $a.Path $a.Name))
                    if ($DryRun) { Write-Log "   [simulação] $($a.Path) \ $($a.Name) = $($a.Value)"; continue }
                    Set-RegValue $a.Path $a.Name $a.Value $a.Type
                    if ($a.Servico -and $a.Value -eq 4) { Stop-Service -Name $a.Servico -Force -ErrorAction SilentlyContinue }
                }
                'RegDel' {
                    $estados.Add((Get-RegState $a.Path $a.Name))
                    if ($DryRun) { Write-Log "   [simulação] remover $($a.Path) \ $($a.Name)"; continue }
                    Remove-ItemProperty -Path (ConvertTo-PsPath $a.Path) -Name $a.Name -ErrorAction SilentlyContinue
                }
                'Task' {
                    $nomeTarefa = Split-Path $a.Path -Leaf
                    $pastaTarefa = (Split-Path $a.Path -Parent).TrimEnd('\') + '\'
                    $tarefa = Get-ScheduledTask -TaskPath $pastaTarefa -TaskName $nomeTarefa -ErrorAction SilentlyContinue
                    if (-not $tarefa) { continue }
                    $estados.Add(@{ T = 'Task'; Path = $a.Path; Ativa = ($tarefa.State -ne 'Disabled') })
                    if ($DryRun) { Write-Log "   [simulação] desativar tarefa $($a.Path)"; continue }
                    $tarefa | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
                }
                'Cmd' {
                    $estados.Add(@{ T = 'Cmd'; Indice = $a.Indice })
                    if ($DryRun) { Write-Log "   [simulação] comando: $($a.Aplicar.ToString().Trim().Split("`n")[0])"; continue }
                    & $a.Aplicar
                }
            }
        } catch {
            Write-Log "   ! $($a.Path) $($a.Name): $($_.Exception.Message)" 'erro'
        }
    }
    # Mantém sempre o backup mais antigo (o estado original de verdade)
    if (-not $jaTemBackup -and -not $DryRun) {
        $store[$tweak.Id] = $estados.ToArray()
        Save-BackupStore $store
    }
}

function Undo-Tweak($tweak, $store) {
    if (-not $store.ContainsKey($tweak.Id)) { Write-Log "   (sem backup, nada a reverter)"; return }
    $estados = @($store[$tweak.Id])
    [array]::Reverse($estados)
    foreach ($e in $estados) {
        try {
            switch ($e.T) {
                'Reg' {
                    if ($DryRun) { Write-Log "   [simulação] restaurar $($e.Path) \ $($e.Name)"; continue }
                    Restore-RegState $e
                }
                'Task' {
                    if ($DryRun -or -not $e.Ativa) { continue }
                    $nome = Split-Path $e.Path -Leaf; $pasta = (Split-Path $e.Path -Parent).TrimEnd('\') + '\'
                    Enable-ScheduledTask -TaskPath $pasta -TaskName $nome -ErrorAction SilentlyContinue | Out-Null
                }
                'Cmd' {
                    if ($DryRun) { Write-Log "   [simulação] comando de reversão"; continue }
                    $acao = $tweak.Acoes[[int]$e.Indice]
                    if ($acao.Reverter) { & $acao.Reverter }
                }
            }
        } catch {
            Write-Log "   ! $($_.Exception.Message)" 'erro'
        }
    }
    if (-not $DryRun) {
        $store.Remove($tweak.Id)
        Save-BackupStore $store
    }
}

function New-PontoRestauracao {
    Write-Log 'Criando ponto de restauração...'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # O Windows limita a 1 ponto a cada 24h; liberamos temporariamente
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $antes = (Get-ItemProperty $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
        Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
        Checkpoint-Computer -Description "Breath $(Get-Date -Format 'dd/MM/yyyy HH:mm')" -RestorePointType MODIFY_SETTINGS
        if ($null -eq $antes) { Remove-ItemProperty $k -Name SystemRestorePointCreationFrequency } else { Set-ItemProperty $k -Name SystemRestorePointCreationFrequency -Value $antes }
        Write-Log 'Ponto de restauração criado.'
        return $true
    } catch {
        Write-Log "Falha ao criar ponto de restauração: $($_.Exception.Message)" 'erro'
        return $false
    }
}

#endregion

#region Interface (WPF) --------------------------------------------------------

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, Microsoft.VisualBasic

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Breath — por samu-lls" Width="980" Height="680" MinWidth="760" MinHeight="500"
        WindowStartupLocation="CenterScreen" Background="#111114" Foreground="#E6E6EA"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#C9C9D1"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Link" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0"/>
      <Setter Property="Foreground" Value="#6E6E7A"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" Padding="12,8" Margin="0,1" CornerRadius="6" Background="Transparent">
              <TextBlock x:Name="t" Text="{Binding}" Foreground="#7E7E8A"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Foreground" Value="#C9C9D1"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#1C1C22"/>
                <Setter TargetName="t" Property="Foreground" Value="#F2F2F5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="200"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Barra lateral -->
    <DockPanel Grid.Column="0" Background="#0C0C0F">
      <StackPanel DockPanel.Dock="Top" Margin="22,24,22,20">
        <TextBlock Text="Breath" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="TxtVersao" Foreground="#55555F" FontSize="11" Margin="0,2,0,0"/>
        <TextBlock x:Name="TxtDryRun" Text="simulação" Foreground="#E0A84D" FontSize="11" Margin="0,6,0,0" Visibility="Collapsed"/>
        <TextBlock Text="PONTO DE RESTAURAÇÃO" Foreground="#55555F" FontSize="10" Margin="0,22,0,6"/>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="6"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Button x:Name="BtnCriarPonto" Grid.Column="0" Margin="0" Padding="0,7" FontSize="12" Content="Criar"
                  Background="#24242C" Foreground="#E6E6EA" ToolTip="Criar ponto de restauração agora"/>
          <Button x:Name="BtnRestaurar" Grid.Column="2" Margin="0" Padding="0,7" FontSize="12" Content="Restaurar"
                  Background="#24242C" Foreground="#E6E6EA" ToolTip="Voltar o PC para um ponto de restauração anterior"/>
        </Grid>
      </StackPanel>
      <StackPanel DockPanel.Dock="Bottom" Margin="22,0,22,20">
        <Button x:Name="BtnFerramentas" Style="{StaticResource Link}" Content="Ferramentas" HorizontalAlignment="Left"/>
        <TextBlock x:Name="TxtInfo" Foreground="#45454E" FontSize="10" TextWrapping="Wrap" Margin="0,10,0,0"/>
        <TextBlock Text="por samu-lls" Foreground="#3A3A42" FontSize="10" Margin="0,8,0,0"/>
      </StackPanel>
      <ListBox x:Name="Nav" Margin="10,0" Background="Transparent" BorderThickness="0"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
    </DockPanel>

    <!-- Conteúdo -->
    <Grid Grid.Column="1" Margin="36,28,32,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <TextBlock x:Name="TxtTitulo" Grid.Row="0" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,16"/>
      <ScrollViewer x:Name="Lista" Grid.Row="1" VerticalScrollBarVisibility="Auto"/>

      <TextBox x:Name="Log" Grid.Row="2" Height="140" Margin="0,12,0,0" Visibility="Collapsed" IsReadOnly="True"
               Background="#0C0C0F" Foreground="#8C8C98" BorderThickness="0" Padding="8"
               FontFamily="Consolas" FontSize="11" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>

      <DockPanel Grid.Row="3" Margin="0,14,0,0" LastChildFill="True">
        <Button x:Name="BtnAplicar" DockPanel.Dock="Right" Content="Aplicar" Background="#E6E6EA" Foreground="#111114" FontWeight="SemiBold" Padding="20,7"/>
        <Button x:Name="BtnReverter" DockPanel.Dock="Right" Content="Reverter"/>
        <Button x:Name="BtnRecomendados" DockPanel.Dock="Right" Content="Recomendados"/>
        <Button x:Name="BtnLog" DockPanel.Dock="Left" Style="{StaticResource Link}" Content="log" Margin="0,0,12,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="TxtStatus" Foreground="#55555F" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
    </Grid>
  </Grid>
</Window>
"@

$Script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'TxtVersao', 'TxtDryRun', 'TxtInfo', 'TxtTitulo', 'TxtStatus', 'Nav', 'Lista', 'Log', 'BtnLog', 'BtnFerramentas', 'BtnAplicar', 'BtnReverter', 'BtnRecomendados', 'BtnCriarPonto', 'BtnRestaurar') {
    $ui[$n] = $Script:Window.FindName($n)
}
$Script:LogBox    = $ui.Log
$Script:StatusTxt = $ui.TxtStatus

$ui.TxtVersao.Text = "v$Script:Versao"
$ui.TxtInfo.Text   = $Script:InfoSistema
if ($DryRun) { $ui.TxtDryRun.Visibility = 'Visible' }

$conv  = New-Object Windows.Media.BrushConverter
$cores = @{ Medio = '#D9A441'; Alto = '#E5606E' }

function Update-Status($store) {
    foreach ($t in $Script:Tweaks) {
        $t.Status.Visibility = if ($store.ContainsKey($t.Id)) { 'Visible' } else { 'Collapsed' }
    }
}

# Uma lista por categoria; a barra lateral troca qual está visível
$Script:Paineis = [ordered]@{}
foreach ($cat in $Script:Categorias.Keys) {
    $lista = @($Script:Tweaks | Where-Object Cat -eq $cat)
    if ($lista.Count -eq 0) { continue }

    $painel = New-Object Windows.Controls.StackPanel

    foreach ($t in $lista) {
        $linha = New-Object Windows.Controls.Border
        $linha.BorderBrush = $conv.ConvertFromString('#1E1E24')
        $linha.BorderThickness = '0,0,0,1'
        $linha.Padding = '0,11'

        $grid = New-Object Windows.Controls.Grid
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '*'
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
        $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1)

        $cb = New-Object Windows.Controls.CheckBox
        $cb.VerticalContentAlignment = 'Top'

        $texto = New-Object Windows.Controls.StackPanel
        $texto.Margin = '6,-1,0,0'

        $topo = New-Object Windows.Controls.StackPanel
        $topo.Orientation = 'Horizontal'
        $nome = New-Object Windows.Controls.TextBlock
        $nome.Text = $t.Nome
        $nome.Foreground = $conv.ConvertFromString('#E6E6EA')
        $topo.Children.Add($nome) | Out-Null
        if ($cores.ContainsKey($t.Risco)) {
            $ponto = New-Object Windows.Shapes.Ellipse
            $ponto.Width = 6; $ponto.Height = 6
            $ponto.Margin = '8,0,0,0'
            $ponto.VerticalAlignment = 'Center'
            $ponto.Fill = $conv.ConvertFromString($cores[$t.Risco])
            $ponto.ToolTip = if ($t.Risco -eq 'Alto') { 'Alto risco' } else { 'Risco médio' }
            $topo.Children.Add($ponto) | Out-Null
        }

        $desc = New-Object Windows.Controls.TextBlock
        $desc.Text = $t.Desc
        $desc.TextWrapping = 'Wrap'
        $desc.FontSize = 12
        $desc.Margin = '0,3,0,0'
        $desc.Foreground = $conv.ConvertFromString($(if ($t.Risco -eq 'Alto') { '#B0646E' } else { '#6E6E7A' }))

        $texto.Children.Add($topo) | Out-Null
        $texto.Children.Add($desc) | Out-Null
        $cb.Content = $texto
        [Windows.Controls.Grid]::SetColumn($cb, 0)
        $grid.Children.Add($cb) | Out-Null

        $st = New-Object Windows.Controls.TextBlock
        $st.Text = 'aplicado'
        $st.FontSize = 11
        $st.Margin = '16,1,0,0'
        $st.Foreground = $conv.ConvertFromString('#5E9E7A')
        $st.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetColumn($st, 1)
        $grid.Children.Add($st) | Out-Null

        $linha.Child = $grid
        $painel.Children.Add($linha) | Out-Null

        $t.CheckBox = $cb
        $t.Status = $st
    }

    $Script:Paineis[$Script:Categorias[$cat]] = $painel
    $ui.Nav.Items.Add($Script:Categorias[$cat]) | Out-Null
}

$ui.Nav.Add_SelectionChanged({
    $nome = [string]$ui.Nav.SelectedItem
    $ui.TxtTitulo.Text = $nome
    $ui.Lista.Content  = $Script:Paineis[$nome]
    $ui.Lista.ScrollToTop()
})
$ui.Nav.SelectedIndex = 0

$ui.BtnLog.Add_Click({
    $ui.Log.Visibility = if ($ui.Log.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
})

function Get-Selecionados { @($Script:Tweaks | Where-Object { $_.CheckBox.IsChecked }) }

function Set-Ocupado([bool]$b) {
    foreach ($n in 'BtnAplicar', 'BtnReverter', 'BtnRecomendados', 'BtnFerramentas', 'BtnCriarPonto', 'BtnRestaurar', 'Nav') { $ui[$n].IsEnabled = -not $b }
    $Script:Window.Cursor = if ($b) { [Windows.Input.Cursors]::Wait } else { $null }
}

function Show-Pergunta($texto, $titulo = 'Breath') {
    [Windows.MessageBox]::Show($Script:Window, $texto, $titulo, 'YesNo', 'Question') -eq 'Yes'
}

$ui.BtnRecomendados.Add_Click({ foreach ($t in $Script:Tweaks) { $t.CheckBox.IsChecked = $t.Rec } })

$ui.BtnAplicar.Add_Click({
    $sel = Get-Selecionados
    if ($sel.Count -eq 0) { [Windows.MessageBox]::Show($Script:Window, 'Nenhum tweak selecionado.', 'Breath') | Out-Null; return }

    $altos = @($sel | Where-Object Risco -eq 'Alto')
    if ($altos.Count -gt 0) {
        $lista = ($altos | ForEach-Object { "• $($_.Nome)" }) -join "`n"
        if (-not (Show-Pergunta "Você selecionou tweaks de ALTO RISCO:`n`n$lista`n`nTem certeza que quer continuar?" 'Atenção')) { return }
    }
    if (-not $DryRun -and (Show-Pergunta "Aplicar $($sel.Count) tweak(s).`n`nCriar um ponto de restauração antes? (recomendado)")) {
        New-PontoRestauracao | Out-Null
    }

    Set-Ocupado $true
    $store = Read-BackupStore
    $n = 0
    foreach ($t in $sel) {
        $n++
        Write-Log "[$n/$($sel.Count)] Aplicando: $($t.Nome)"
        Invoke-Tweak $t $store
    }
    Update-Status $store
    Set-Ocupado $false
    Write-Log 'Concluído. Reinicie o PC para que todas as alterações tenham efeito.'
    [Windows.MessageBox]::Show($Script:Window, 'Pronto! Reinicie o PC para que todas as alterações tenham efeito.', 'Breath') | Out-Null
})

$ui.BtnReverter.Add_Click({
    $sel = Get-Selecionados
    if ($sel.Count -eq 0) { [Windows.MessageBox]::Show($Script:Window, 'Marque os tweaks que quer reverter.', 'Breath') | Out-Null; return }
    if (-not (Show-Pergunta "Reverter $($sel.Count) tweak(s) para o estado original?")) { return }
    Set-Ocupado $true
    $store = Read-BackupStore
    foreach ($t in $sel) {
        Write-Log "Revertendo: $($t.Nome)"
        Undo-Tweak $t $store
    }
    Update-Status $store
    Set-Ocupado $false
    Write-Log 'Reversão concluída. Reinicie o PC.'
})

# Menu de ferramentas avulsas (sem reversão — são ações pontuais)
$menu = New-Object Windows.Controls.ContextMenu
function Add-Ferramenta($texto, [scriptblock]$acao) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = $texto
    $item.Add_Click($acao)
    $menu.Items.Add($item) | Out-Null
}
$ui.BtnCriarPonto.Add_Click({ Set-Ocupado $true; New-PontoRestauracao | Out-Null; Set-Ocupado $false })
$ui.BtnRestaurar.Add_Click({ Start-Process rstrui.exe })

Add-Ferramenta 'Desmarcar tudo' { foreach ($t in $Script:Tweaks) { $t.CheckBox.IsChecked = $false } }
$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
Add-Ferramenta 'Limpeza de Disco do Windows' { Start-Process cleanmgr.exe }
Add-Ferramenta 'Limpar arquivos temporários' {
    Set-Ocupado $true
    foreach ($p in @($env:TEMP, "$env:SystemRoot\Temp")) {
        Write-Log "Limpando $p"
        if (-not $DryRun) { Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Log 'Temporários limpos (arquivos em uso foram ignorados).'
    Set-Ocupado $false
}
Add-Ferramenta 'Remover dispositivos desconectados (fantasmas)' {
    if (-not (Show-Pergunta 'Remove do Gerenciador de Dispositivos todos os dispositivos com status desconhecido. Continuar?')) { return }
    Set-Ocupado $true
    Get-PnpDevice | Where-Object Status -eq 'Unknown' | ForEach-Object {
        Write-Log "Removendo $($_.FriendlyName)"
        if (-not $DryRun) { pnputil /remove-device $_.InstanceId | Out-Null }
    }
    Set-Ocupado $false
}
Add-Ferramenta 'Prioridade de rede (QoS) para um jogo...' {
    $exe = [Microsoft.VisualBasic.Interaction]::InputBox('Nome do executável do jogo (ex.: cs2.exe):', 'Breath — QoS', '')
    if (-not $exe) { return }
    if ($exe -notmatch '^[\w\-. ]+\.exe$') { [Windows.MessageBox]::Show($Script:Window, 'Informe um nome terminado em .exe', 'Breath') | Out-Null; return }
    $k = "HKLM\SOFTWARE\Policies\Microsoft\Windows\QoS\breath $exe"
    Write-Log "Criando política QoS (DSCP 46) para $exe"
    if (-not $DryRun) {
        Set-RegValue 'HKLM\SYSTEM\CurrentControlSet\Services\Psched' 'Start' 1 DWord
        $valores = [ordered]@{ 'Version' = '1.0'; 'Application Name' = $exe; 'Protocol' = '*'; 'Local Port' = '*'; 'Local IP' = '*'
            'Local IP Prefix Length' = '*'; 'Remote Port' = '*'; 'Remote IP' = '*'; 'Remote IP Prefix Length' = '*'; 'DSCP Value' = '46'; 'Throttle Rate' = '-1' }
        foreach ($n in $valores.Keys) { Set-RegValue $k $n $valores[$n] String }
    }
    Write-Log 'Política criada. Para remover: apague a chave em HKLM\SOFTWARE\Policies\Microsoft\Windows\QoS.'
}
Add-Ferramenta 'Apps que iniciam com o Windows' { Start-Process 'ms-settings:startupapps' }
Add-Ferramenta 'Abrir pasta de backup/log' { Start-Process explorer.exe $Script:Pasta }
$ui.BtnFerramentas.ContextMenu = $menu
$ui.BtnFerramentas.Add_Click({ $menu.PlacementTarget = $ui.BtnFerramentas; $menu.IsOpen = $true })

Update-Status (Read-BackupStore)
Write-Log "Breath v$Script:Versao iniciado. $($Script:Tweaks.Count) tweaks disponíveis para este PC."
if ($DryRun) { Write-Log 'MODO SIMULAÇÃO: nada será alterado no sistema.' }

$Script:Window.ShowDialog() | Out-Null

#endregion
