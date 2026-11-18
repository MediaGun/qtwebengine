<#
.SYNOPSIS
    Prepares a Windows machine as the self-hosted GitHub Actions runner that builds Qt WebEngine
    ("Build for Windows" in .github/workflows/build.yaml, runner label windows-we-builder).

.DESCRIPTION
    Checks everything the job needs, installs or configures what is missing, and prints a summary.
    Safe to run again: whatever is already in place is left as it is.

    What it checks (see docs/self-hosted-windows-runner.md for the reasons):
      - administrator rights, Windows long paths, RAM, CPU, build drive and free space
      - Chocolatey, Git for Windows (with Git Bash on the machine PATH), PowerShell 7, Strawberry Perl,
        gperf, winflexbison3, Python 3.12 with html5lib
      - Visual Studio 2022 (Build Tools are enough) 17.6+ with the C++ tools and ATL, the Windows SDK
        10.0.26100+ and its Debugging Tools
      - Microsoft Defender exclusions for the build folders (optional, much faster builds)
      - the GitHub Actions runner service (registers one when -RunnerToken is given)

    Node.js, CMake, Ninja, Qt and sccache are not installed here: the job's actions download them.

.PARAMETER CheckOnly
    Only report; change nothing.

.PARAMETER BuildDrive
    Drive letter the job builds on. The workflow uses D:\qtwe\... .

.PARAMETER RunnerToken
    Registration token (repository Settings > Actions > Runners > New self-hosted runner). Only
    needed to register a new runner; without it the script only checks the existing runner service.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-windows-runner.ps1 -CheckOnly

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-windows-runner.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-windows-runner.ps1 -RunnerToken AAAA...
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [ValidatePattern('^[A-Za-z]$')]
    [string]$BuildDrive = 'D',
    [int]$MinFreeGB = 150,
    [int]$MinRamGB = 32,
    [switch]$SkipDefenderExclusions,
    [string]$RunnerUrl = 'https://github.com/MediaGun/qtwebengine',
    [string]$RunnerToken,
    [string]$RunnerName = $env:COMPUTERNAME,
    [string]$RunnerLabels = 'windows-we-builder',
    [string]$RunnerDir
)

# Works in Windows PowerShell 5.1 too: PowerShell 7 may be one of the things to install.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$BuildRoot = "${BuildDrive}:\qtwe"
# Re-registering keeps the runner's current name unless -RunnerName is given.
$script:RunnerNameGiven = $PSBoundParameters.ContainsKey('RunnerName')
# ...and where it is registered (repository or organization) unless -RunnerUrl is given.
$script:RunnerUrlGiven = $PSBoundParameters.ContainsKey('RunnerUrl')
if (-not $RunnerDir) { $RunnerDir = "${BuildDrive}:\actions-runner" }

$VsComponents = @(
    'Microsoft.VisualStudio.Workload.VCTools',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    'Microsoft.VisualStudio.Component.VC.ATL',
    'Microsoft.VisualStudio.Component.Windows11SDK.26100'
)
$MinSdkBuild = 26100
$KitsRoot = "${env:ProgramFiles(x86)}\Windows Kits\10"
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$VsSetup = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"

$script:Results = New-Object System.Collections.Generic.List[object]
$script:RebootNeeded = $false
$script:PathChanged = $false

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }

# Status: OK (was fine), FIXED (changed now), MISSING (CheckOnly), WARN (needs a person), FAILED
function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') {
    $color = @{ OK = 'Green'; FIXED = 'Green'; MISSING = 'Yellow'; WARN = 'Yellow'; FAILED = 'Red' }[$Status]
    Write-Host ("   [{0}] {1} {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
    $script:Results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
}

# Runs $Fix unless -CheckOnly; records FIXED, or FAILED with the error.
function Invoke-Fix([string]$Name, [string]$Missing, [scriptblock]$Fix) {
    if ($CheckOnly) { Add-Result $Name 'MISSING' $Missing; return }
    Write-Host "   $Name`: $Missing -> fixing..."
    try {
        $detail = & $Fix
        Add-Result $Name 'FIXED' ([string]$detail)
    } catch {
        Add-Result $Name 'FAILED' $_.Exception.Message
    }
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Test-Command([string]$Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Runs a native command and returns its stdout. In Windows PowerShell 5.1, stderr output of a native
# command is a terminating error under $ErrorActionPreference = 'Stop', so it is relaxed here.
function Invoke-Quiet([scriptblock]$Command) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>$null } finally { $ErrorActionPreference = $saved }
}

# Case-insensitive index of a folder in a list of PATH entries; -1 if absent.
function Find-PathEntry([string[]]$Entries, [string]$Dir) {
    $want = [Environment]::ExpandEnvironmentVariables($Dir).TrimEnd('\')
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        if ([string]::Equals([Environment]::ExpandEnvironmentVariables($Entries[$i]).TrimEnd('\'), $want, 'OrdinalIgnoreCase')) { return $i }
    }
    -1
}

function Get-MachinePathEntries {
    [Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ }
}

# Adds $Dir to the machine PATH (first when $Prepend), or moves it first if it must be.
function Add-MachinePath([string]$Dir, [switch]$Prepend) {
    $entries = @(Get-MachinePathEntries | Where-Object { (Find-PathEntry @($_) $Dir) -lt 0 })
    if ($Prepend) { $entries = @($Dir) + $entries } else { $entries = $entries + @($Dir) }
    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'Machine')
    $script:PathChanged = $true
    Update-SessionPath
}

function Invoke-Native([string]$Exe, [string[]]$Arguments, [int[]]$OkCodes = @(0)) {
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($OkCodes -notcontains $p.ExitCode) { throw "$Exe exited with code $($p.ExitCode)" }
    if ($p.ExitCode -eq 3010) { $script:RebootNeeded = $true }
    $p.ExitCode
}

function Install-ChocoPackage([string]$Package, [string]$PackageParameters) {
    $chocoArgs = @('install', $Package, '-y', '--no-progress')
    if ($PackageParameters) { $chocoArgs += @('--package-parameters', "`"$PackageParameters`"") }
    Invoke-Native 'choco' $chocoArgs @(0, 1641, 3010) | Out-Null
    Update-SessionPath
}

# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Machine {
    Write-Step 'Machine'
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($os.OSArchitecture -notmatch '64') { Add-Result 'Windows 64-bit' 'FAILED' $os.OSArchitecture }
    else { Add-Result 'Windows' 'OK' "$($os.Caption) $($os.Version)" }

    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    if ($ramGB -lt $MinRamGB) { Add-Result 'RAM' 'WARN' "$ramGB GB; at least $MinRamGB GB recommended (Chromium's links)" }
    else { Add-Result 'RAM' 'OK' "$ramGB GB" }
    Add-Result 'CPU' 'OK' "$($cs.NumberOfLogicalProcessors) logical processors"

    $drive = Get-PSDrive -Name $BuildDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    if (-not $drive) {
        Add-Result "Drive ${BuildDrive}:" 'FAILED' "missing; the workflow builds in ${BuildDrive}:\qtwe (change env paths in build.yaml or pass -BuildDrive)"
        return
    }
    $freeGB = [math]::Round($drive.Free / 1GB)
    if ($freeGB -lt $MinFreeGB) { Add-Result "Free space ${BuildDrive}:" 'WARN' "$freeGB GB; about $MinFreeGB GB needed" }
    else { Add-Result "Free space ${BuildDrive}:" 'OK' "$freeGB GB" }

    if (Test-Path $BuildRoot) { Add-Result "Build folder $BuildRoot" 'OK' }
    else { Invoke-Fix "Build folder $BuildRoot" 'missing' { New-Item -ItemType Directory -Force $BuildRoot | Out-Null } }
}

function Assert-LongPaths {
    Write-Step 'Long paths'
    $key = 'HKLM:\System\CurrentControlSet\Control\FileSystem'
    $value = (Get-ItemProperty $key -Name LongPathsEnabled -ErrorAction SilentlyContinue)
    if ($value -and $value.LongPathsEnabled -eq 1) { Add-Result 'LongPathsEnabled' 'OK' }
    else { Invoke-Fix 'LongPathsEnabled' 'off' { Set-ItemProperty $key -Name LongPathsEnabled -Value 1 -Type DWord } }
}

function Assert-Chocolatey {
    Write-Step 'Chocolatey'
    if (Test-Command 'choco') { Add-Result 'Chocolatey' 'OK' (& choco --version); return }
    Invoke-Fix 'Chocolatey' 'not installed' {
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) | Out-Host
        Update-SessionPath
        if (-not (Test-Command 'choco')) { throw 'choco not on PATH after install' }
        & choco --version
    }
}

# A tool found on PATH, or installed with Chocolatey.
function Assert-ChocoTool([string]$Name, [string]$Command, [string]$Package, [string]$VersionArg = '--version') {
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = (Invoke-Quiet { & $cmd.Source $VersionArg } | Where-Object { "$_".Trim() } | Select-Object -First 1) -as [string]
        Add-Result $Name 'OK' ("$($cmd.Source) $ver".Trim())
        return
    }
    if (-not (Test-Command 'choco')) { Add-Result $Name 'MISSING' 'needs Chocolatey'; return }
    Invoke-Fix $Name 'not found' {
        Install-ChocoPackage $Package
        $c = Get-Command $Command -ErrorAction SilentlyContinue
        if (-not $c) { throw "$Command not on PATH after installing $Package" }
        $c.Source
    }
}

function Get-GitRoot {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        # ...\Git\cmd\git.exe or ...\Git\bin\git.exe or ...\Git\mingw64\bin\git.exe
        $dir = Split-Path $git.Source
        while ($dir -and -not (Test-Path (Join-Path $dir 'bin\bash.exe'))) { $dir = Split-Path $dir }
        if ($dir) { return $dir }
    }
    foreach ($d in @("$env:ProgramFiles\Git", "${env:ProgramFiles(x86)}\Git")) {
        if (Test-Path (Join-Path $d 'bin\bash.exe')) { return $d }
    }
    $null
}

function Assert-Git {
    Write-Step 'Git and Git Bash'
    $gitRoot = Get-GitRoot
    if ($gitRoot) { Add-Result 'Git for Windows' 'OK' $gitRoot }
    elseif (-not (Test-Command 'choco')) { Add-Result 'Git for Windows' 'MISSING' 'needs Chocolatey'; return }
    else {
        Invoke-Fix 'Git for Windows' 'not installed' { Install-ChocoPackage 'git' '/NoShellIntegration'; Get-GitRoot }
        $gitRoot = Get-GitRoot
        if (-not $gitRoot) { return }
    }

    # The job's "shell: bash" steps (jurplel/install-qt-action) look bash up on the PATH of the
    # runner service. It must be Git's bash: C:\Windows\System32\bash.exe is WSL's and would run
    # the steps in Linux.
    $gitBin = Join-Path $gitRoot 'bin'
    $wslBash = Join-Path $env:WINDIR 'System32\bash.exe'
    $entries = @(Get-MachinePathEntries)
    $gitIdx = Find-PathEntry $entries $gitBin
    $sysIdx = Find-PathEntry $entries (Join-Path $env:WINDIR 'System32')
    $needFirst = Test-Path $wslBash
    if ($gitIdx -ge 0 -and (-not $needFirst -or $sysIdx -lt 0 -or $gitIdx -lt $sysIdx)) {
        Add-Result 'Git Bash on machine PATH' 'OK' $gitBin
    } else {
        $why = if ($gitIdx -lt 0) { "$gitBin not on PATH" } else { "$gitBin is after System32 (WSL bash.exe would win)" }
        Invoke-Fix 'Git Bash on machine PATH' $why {
            if ($needFirst) { Add-MachinePath $gitBin -Prepend } else { Add-MachinePath $gitBin }
            $gitBin
        }
    }

    $longpaths = Invoke-Quiet { & git config --system --get core.longpaths }
    if ($longpaths -eq 'true') { Add-Result 'git core.longpaths (system)' 'OK' }
    else { Invoke-Fix 'git core.longpaths (system)' 'not set' { & git config --system core.longpaths true; 'true' } }
}

function Assert-Python {
    Write-Step 'Python'
    $py = $null
    foreach ($candidate in @("$env:SystemDrive\Python312\python.exe", "$env:ProgramFiles\Python312\python.exe")) {
        if (Test-Path $candidate) { $py = $candidate; break }
    }
    if (-not $py -and (Test-Command 'py')) {
        $py = Invoke-Quiet { & py -3.12 -c 'import sys; print(sys.executable)' } | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or -not $py -or -not (Test-Path $py)) { $py = $null }
    }
    if ($py) { Add-Result 'Python 3.12' 'OK' $py }
    elseif (-not (Test-Command 'choco')) { Add-Result 'Python 3.12' 'MISSING' 'needs Chocolatey'; return }
    else {
        Invoke-Fix 'Python 3.12' 'not installed' { Install-ChocoPackage 'python312'; "$env:SystemDrive\Python312\python.exe" }
        $py = "$env:SystemDrive\Python312\python.exe"
        if (-not (Test-Path $py)) { return }
    }

    Invoke-Quiet { & $py -c 'import html5lib' } | Out-Null
    if ($LASTEXITCODE -eq 0) { Add-Result 'html5lib' 'OK' }
    else { Invoke-Fix 'html5lib' 'not installed' { Invoke-Native $py @('-m', 'pip', 'install', '--upgrade', 'html5lib') | Out-Null } }
}

function Get-Vs2022 {
    if (-not (Test-Path $VsWhere)) { return $null }
    # The highest 2022 (17.x) instance; 17.6 has MSVC 14.36, the minimum for Qt WebEngine.
    $json = & $VsWhere -products * -version '[17.0,18.0)' -format json -utf8 | Out-String
    # Assigned first: Windows PowerShell's ConvertFrom-Json emits a JSON array as one object.
    $parsed = $json | ConvertFrom-Json
    $all = @($parsed)
    if ($all.Count -eq 0) { return $null }
    $all | Sort-Object { [version]$_.installationVersion } -Descending | Select-Object -First 1
}

function Test-VsComponents([string]$InstallPath) {
    $required = $VsComponents | Where-Object { $_ -notlike '*Workload*' -and $_ -notlike '*Windows11SDK*' }
    $found = & $VsWhere -products * -version '[17.0,18.0)' -requires $required -property installationPath
    @($found) -contains $InstallPath
}

function Get-SdkBuild {
    $inc = Join-Path $KitsRoot 'Include'
    if (-not (Test-Path $inc)) { return 0 }
    $builds = Get-ChildItem $inc -Directory | Where-Object { $_.Name -match '^10\.0\.(\d+)\.0$' } |
        ForEach-Object { [int]($_.Name -replace '^10\.0\.(\d+)\.0$', '$1') }
    if ($builds) { ($builds | Measure-Object -Maximum).Maximum } else { 0 }
}

function Assert-VisualStudio {
    Write-Step 'Visual Studio 2022 and Windows SDK'
    $vs = Get-Vs2022
    if (-not $vs) {
        if (-not (Test-Command 'choco')) { Add-Result 'Visual Studio 2022' 'MISSING' 'needs Chocolatey'; return }
        Invoke-Fix 'Visual Studio 2022 Build Tools' 'not installed (about 10 GB, takes a while)' {
            $p = ($VsComponents | ForEach-Object { "--add $_" }) -join ' '
            Install-ChocoPackage 'visualstudio2022buildtools' "$p --includeRecommended --passive --norestart"
            $v = Get-Vs2022
            if (-not $v) { throw 'vswhere does not see Visual Studio 2022 after install' }
            "$($v.displayName) $($v.installationVersion)"
        }
        $vs = Get-Vs2022
        if (-not $vs) { return }
    } else {
        Add-Result 'Visual Studio 2022' 'OK' "$($vs.displayName) $($vs.installationVersion) at $($vs.installationPath)"
    }

    if ([version]$vs.installationVersion -lt [version]'17.6') {
        Invoke-Fix 'Visual Studio 2022 >= 17.6' "is $($vs.installationVersion) (MSVC older than 14.36)" {
            Invoke-Native $VsSetup @('update', '--installPath', "`"$($vs.installationPath)`"", '--quiet', '--norestart') @(0, 3010) | Out-Null
            (Get-Vs2022).installationVersion
        }
    }

    $sdk = Get-SdkBuild
    $compsOk = Test-VsComponents $vs.installationPath
    if ($compsOk) { Add-Result 'C++ tools and ATL' 'OK' }
    if ($sdk -ge $MinSdkBuild) { Add-Result 'Windows SDK' 'OK' "10.0.$sdk.0" }
    if (-not $compsOk -or $sdk -lt $MinSdkBuild) {
        $what = @()
        if (-not $compsOk) { $what += 'C++ tools / ATL' }
        if ($sdk -lt $MinSdkBuild) { $what += "Windows SDK 10.0.$MinSdkBuild (have $sdk)" }
        Invoke-Fix 'Visual Studio components' ("missing: " + ($what -join ', ')) {
            $vsArgs = @('modify', '--installPath', "`"$($vs.installationPath)`"")
            foreach ($c in $VsComponents) { $vsArgs += @('--add', $c) }
            $vsArgs += @('--includeRecommended', '--quiet', '--norestart')
            Invoke-Native $VsSetup $vsArgs @(0, 3010) | Out-Null
            if (-not (Test-VsComponents $vs.installationPath)) { throw 'components still missing after modify' }
            "SDK 10.0.$(Get-SdkBuild).0"
        }
    }

    # Chromium's build copies dbghelp.dll and friends from the SDK's Debugging Tools, which the
    # Visual Studio SDK component does not install.
    $cdb = Join-Path $KitsRoot 'Debuggers\x64\cdb.exe'
    if (Test-Path $cdb) { Add-Result 'SDK Debugging Tools' 'OK' (Split-Path $cdb) }
    else {
        Invoke-Fix 'SDK Debugging Tools' 'not installed' {
            $setup = Get-ChildItem "$env:ProgramData\Package Cache" -Recurse -Filter winsdksetup.exe -ErrorAction SilentlyContinue |
                Where-Object { $_.VersionInfo.ProductVersion -match '^\d+\.\d+\.(\d+)' -and [int]$Matches[1] -ge $MinSdkBuild } |
                Sort-Object { $_.VersionInfo.ProductVersion } -Descending | Select-Object -First 1
            if (-not $setup) {
                throw "no cached winsdksetup.exe for SDK $MinSdkBuild+; download the Windows SDK installer from https://developer.microsoft.com/windows/downloads/windows-sdk/ and add the feature 'Debugging Tools for Windows'"
            }
            Invoke-Native $setup.FullName @('/features', 'OptionId.WindowsDesktopDebuggers', '/quiet', '/norestart') @(0, 3010) | Out-Null
            if (-not (Test-Path $cdb)) { throw "$cdb still missing after the SDK installer ran" }
            Split-Path $cdb
        }
    }

    # ilammy/msvc-dev-cmd picks the newest Visual Studio. Visual Studio 2026 (18.x) next to 2022
    # would build with a newer runtime than the app ships.
    if (Test-Path $VsWhere) {
        $newer = & $VsWhere -products * -version '[18.0,' -property displayName
        if ($newer) { Add-Result 'No Visual Studio 2026+' 'WARN' "found: $($newer -join ', '); msvc-dev-cmd would pick it. Uninstall it, or pin vsversion: 2022 in build.yaml" }
        else { Add-Result 'No Visual Studio 2026+' 'OK' }
    }
}

function Assert-Defender {
    Write-Step 'Microsoft Defender exclusions'
    if ($SkipDefenderExclusions) { Add-Result 'Defender exclusions' 'OK' 'skipped (-SkipDefenderExclusions)'; return }
    if (-not (Test-Command 'Get-MpPreference')) { Add-Result 'Defender exclusions' 'OK' 'Defender not present'; return }
    try { $pref = Get-MpPreference } catch { Add-Result 'Defender exclusions' 'OK' 'Defender not running'; return }

    # Scanning every object file roughly doubles Chromium's build time.
    $paths = @($BuildRoot, $RunnerDir)
    $procs = @('cl.exe', 'link.exe', 'lib.exe', 'ninja.exe', 'sccache.exe', 'clang-cl.exe', 'lld-link.exe', 'python.exe', 'node.exe')
    $missingPaths = @($paths | Where-Object { @($pref.ExclusionPath) -notcontains $_ })
    $missingProcs = @($procs | Where-Object { @($pref.ExclusionProcess) -notcontains $_ })
    if ($missingPaths.Count -eq 0 -and $missingProcs.Count -eq 0) { Add-Result 'Defender exclusions' 'OK'; return }
    Invoke-Fix 'Defender exclusions' ("missing: " + (($missingPaths + $missingProcs) -join ', ')) {
        if ($missingPaths.Count) { Add-MpPreference -ExclusionPath $missingPaths }
        if ($missingProcs.Count) { Add-MpPreference -ExclusionProcess $missingProcs }
        'added'
    }
}

# Only the runner configured in $RunnerDir is ours. Other runners on the machine (other
# repositories, signing agents, ...) are listed but never touched.
function Get-RunnerConfig {
    $file = Join-Path $RunnerDir '.runner'
    if (-not (Test-Path $file)) { return $null }
    # The runner writes it with a BOM, which Windows PowerShell's ConvertFrom-Json rejects.
    (Get-Content $file -Raw -Encoding UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
}

function Get-AllRunnerServices { @(Get-CimInstance Win32_Service -Filter "Name LIKE 'actions.runner.%'") }

function Get-OurRunnerService {
    $bin = Join-Path $RunnerDir 'bin\RunnerService.exe'
    Get-AllRunnerServices | Where-Object { $_.PathName -and $_.PathName.Trim('"', ' ') -like "$bin*" } | Select-Object -First 1
}

function Get-OurConsoleRunner {
    $exe = Join-Path $RunnerDir 'bin\Runner.Listener.exe'
    Get-CimInstance Win32_Process -Filter "Name = 'Runner.Listener.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like $exe } | Select-Object -First 1
}

function Test-JobRunning {
    $exe = Join-Path $RunnerDir 'bin\Runner.Worker.exe'
    [bool](Get-CimInstance Win32_Process -Filter "Name = 'Runner.Worker.exe'" | Where-Object { $_.ExecutablePath -like $exe })
}

function Register-Runner {
    if (Test-JobRunning) { throw "a job is running on the runner in $RunnerDir; run again when it has finished" }
    New-Item -ItemType Directory -Force $RunnerDir | Out-Null
    $existing = Get-RunnerConfig
    if (-not $existing) {
        # A failed earlier attempt leaves the old registration in the newest backup folder.
        $last = Get-ChildItem $RunnerDir -Directory -Filter 'config-backup-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($last -and (Test-Path (Join-Path $last.FullName '.runner'))) {
            $existing = (Get-Content (Join-Path $last.FullName '.runner') -Raw -Encoding UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
        }
    }
    $name = $RunnerName
    if ($existing -and -not $script:RunnerNameGiven) { $name = $existing.agentName }
    $url = $RunnerUrl
    if ($existing -and -not $script:RunnerUrlGiven) { $url = $existing.gitHubUrl }
    Write-Host "   registering '$name' at $url (the token must come from that page's Settings > Actions > Runners)"

    # Stop and unregister the old setup in this folder: its service, or its console process.
    $svc = Get-OurRunnerService
    if ($svc) {
        if ($svc.State -ne 'Stopped') { Stop-Service $svc.Name -Force }
        Invoke-Native 'sc.exe' @('delete', $svc.Name) | Out-Null
    }
    $console = Get-OurConsoleRunner
    if ($console) { Stop-Process -Id $console.ProcessId -Force; Start-Sleep 2 }
    $backup = $null
    $configFiles = '.runner', '.credentials', '.credentials_rsaparams', '.service'
    if (Test-Path (Join-Path $RunnerDir '.runner')) {
        # Keep the old registration files; --replace below takes over the runner of the same name on GitHub.
        $backup = Join-Path $RunnerDir ("config-backup-{0:yyyyMMdd-HHmmss}" -f (Get-Date))
        New-Item -ItemType Directory $backup | Out-Null
        foreach ($f in $configFiles) {
            $path = Join-Path $RunnerDir $f
            if (Test-Path $path) { Move-Item $path $backup }
        }
    }

    if (-not (Test-Path (Join-Path $RunnerDir 'config.cmd'))) {
        $release = Invoke-RestMethod 'https://api.github.com/repos/actions/runner/releases/latest' -Headers @{ 'User-Agent' = 'setup-windows-runner' }
        $asset = $release.assets | Where-Object { $_.name -match '^actions-runner-win-x64-[\d.]+\.zip$' } | Select-Object -First 1
        if (-not $asset) { throw 'no actions-runner-win-x64 zip in the latest runner release' }
        $zip = Join-Path $env:TEMP $asset.name
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $RunnerDir -Force
        Remove-Item $zip
    }

    # As LocalSystem: the job's first step sets LongPathsEnabled in HKLM, which needs admin rights.
    Push-Location $RunnerDir
    try {
        & .\config.cmd --unattended --replace --url $url --token $RunnerToken --name $name `
            --labels $RunnerLabels --work _work --runasservice --windowslogonaccount 'NT AUTHORITY\SYSTEM' | Out-Host
        if ($LASTEXITCODE -ne 0) {
            $why = "config.cmd exited with code $LASTEXITCODE"
            if ($backup) {
                # Put the old registration back, so the runner works as before.
                foreach ($f in $configFiles) {
                    $path = Join-Path $backup $f
                    if (Test-Path $path) { Move-Item $path $RunnerDir -Force }
                }
                Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
                $why += '; old registration restored (start run.cmd or its service again)'
            }
            throw "$why. A 404 means the token is not for $url"
        }
    } finally { Pop-Location }
    "$name ($RunnerLabels) at $url, in $RunnerDir as a service"
}

function Assert-Runner {
    Write-Step 'GitHub Actions runner'
    $others = @(Get-AllRunnerServices | Where-Object { -not $_.PathName -or $_.PathName.Trim('"', ' ') -notlike (Join-Path $RunnerDir 'bin\*') })
    if ($others.Count) {
        Add-Result 'Other runners (not touched)' 'OK' (($others | ForEach-Object { "$($_.Name) [$($_.State)]" }) -join ', ')
    }

    if ($RunnerToken) {
        Invoke-Fix 'Runner registration' "registering in $RunnerDir with labels $RunnerLabels" { Register-Runner }
    }

    $config = Get-RunnerConfig
    if (-not $config) {
        Add-Result 'Runner' $(if ($CheckOnly) { 'MISSING' } else { 'WARN' }) "not configured in $RunnerDir; run again with -RunnerToken <token> (repo Settings > Actions > Runners > New self-hosted runner), labels: $RunnerLabels"
        return
    }
    $detail = "$($config.agentName), registered to $($config.gitHubUrl)"
    if ($config.gitHubUrl.TrimEnd('/') -ne $RunnerUrl.TrimEnd('/') -and $RunnerUrl.TrimEnd('/') -notlike "$($config.gitHubUrl.TrimEnd('/'))/*") {
        Add-Result 'Runner' 'WARN' "$detail, not $RunnerUrl"
    } else {
        Add-Result 'Runner' 'OK' $detail
    }
    # The label lives on GitHub, not in local files; check it in Settings > Actions > Runners.

    $svc = Get-OurRunnerService
    $console = Get-OurConsoleRunner
    if (-not $svc) {
        $how = if ($console) { 'runs as a console process (run.cmd), not a service' } else { 'is not running and is not a service' }
        Add-Result 'Runner service' 'WARN' "$($config.agentName) $how; it stops on logout or reboot. Make it a service: run again with -RunnerToken <token> (keeps the name)"
        if ($script:PathChanged -and $console) {
            Add-Result 'Runner restart' 'WARN' 'PATH changed: close run.cmd and start it again from a new window, so the job sees Git Bash'
        }
        return
    }

    $detail = "$($svc.Name): $($svc.State), runs as $($svc.StartName)"
    if ($svc.StartName -match 'NetworkService|NETWORK SERVICE|LocalService') {
        Add-Result 'Runner service account' 'WARN' "$detail; the job's 'Prepare environment' step writes HKLM and needs an admin account: re-register with -RunnerToken (runs as LocalSystem)"
    }
    if ($svc.State -ne 'Running') {
        Invoke-Fix 'Runner service' $detail { Start-Service $svc.Name; 'started' }
        return
    }
    Add-Result 'Runner service' 'OK' $detail

    # A service reads the machine PATH when it starts: restart it so the job sees Git Bash etc.
    if ($script:PathChanged -and -not $CheckOnly) {
        if (Test-JobRunning) {
            Add-Result 'Runner restart' 'WARN' "PATH changed but a job is running; restart $($svc.Name) after it finishes"
        } else {
            Invoke-Fix 'Runner restart' 'PATH changed' { Restart-Service $svc.Name; 'restarted to pick up the new PATH' }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

if (-not (Test-Admin)) {
    Write-Host 'Run this script from an elevated PowerShell (Run as administrator).' -ForegroundColor Red
    exit 1
}

$log = Join-Path $env:TEMP ("setup-windows-runner-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $log | Out-Null
Write-Host ("Qt WebEngine Windows runner setup {0}" -f $(if ($CheckOnly) { '(check only)' } else { '' }))

Assert-Machine
Assert-LongPaths
Assert-Chocolatey
Assert-Git
Write-Step 'Tools'
Assert-ChocoTool 'PowerShell 7' 'pwsh' 'powershell-core'
Assert-ChocoTool 'Perl' 'perl' 'strawberryperl' '-v'
Assert-ChocoTool 'gperf' 'gperf' 'gperf'
Assert-ChocoTool 'bison (winflexbison3)' 'win_bison' 'winflexbison3'
Assert-ChocoTool 'flex (winflexbison3)' 'win_flex' 'winflexbison3'
Assert-Python
Assert-VisualStudio
Assert-Defender
Assert-Runner

Write-Step 'Summary'
$script:Results | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$bad = @($script:Results | Where-Object { $_.Status -in 'FAILED', 'MISSING', 'WARN' })
if ($script:RebootNeeded) { Write-Host 'An installer asked for a reboot: restart the machine before the next build.' -ForegroundColor Yellow }
Write-Host "Log: $log"
Stop-Transcript | Out-Null
if (@($bad | Where-Object { $_.Status -in 'FAILED', 'MISSING' }).Count) { exit 2 }
exit 0
