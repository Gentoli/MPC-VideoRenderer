param(
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",
    [switch]$Sign,
    [switch]$NoWait,
    [ValidateSet("VS2019", "VS2022")]
    [string]$Compiler
)

$Title = "MPC Video Renderer"
$Project = "MpcVideoRenderer"
$BuildCfg = $Configuration
$Suffix = if ($BuildCfg -eq "Debug") { "_Debug" } else { "" }
$Wait = -not $NoWait

if ($Sign -and -not (Test-Path "$PSScriptRoot\signinfo.txt")) {
    Write-Host "[WARNING] signinfo.txt not found." -ForegroundColor Yellow
    $Sign = $false
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$params = @("-property", "installationPath", "-requires", "Microsoft.Component.MSBuild")
if ($Compiler -eq "VS2019") {
    $params += @("-version", "[16.0,17.0)")
} elseif ($Compiler -eq "VS2022") {
    $params += @("-version", "[17.0,18.0)")
} else {
    $params += "-latest"
}

$vsPath = & $vswhere $params
if (-not $vsPath) {
    Write-Host "[ERROR] Visual Studio installation not found." -ForegroundColor Red
    exit 1
}

$msBuildPath = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path $msBuildPath)) {
    $msBuildPath = Join-Path $vsPath "MSBuild\15.0\Bin\MSBuild.exe"
}

$LogDir = Join-Path $PSScriptRoot "_bin\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Invoke-Compiling($Platform) {
    $Host.UI.RawUI.WindowTitle = "Compiling $Title - $BuildCfg|$Platform..."
    $sln = Join-Path $PSScriptRoot "$Project.sln"
    $switches = @("/nologo", "/consoleloggerparameters:Verbosity=minimal", "/maxcpucount", "/nodeReuse:true")
    $targets = "/target:Build"
    $config = "/p:Configuration=$BuildCfg"
    $plt = "/p:Platform=$Platform"
    $flp1 = "/flp1:LogFile=$LogDir\errors_$($BuildCfg)_$($Platform).log;errorsonly;Verbosity=diagnostic"
    $flp2 = "/flp2:LogFile=$LogDir\warnings_$($BuildCfg)_$($Platform).log;warningsonly;Verbosity=diagnostic"
    
    & $msBuildPath $sln $switches $targets $config $plt $flp1 $flp2
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] $Project.sln $BuildCfg $Platform - Compilation failed!" -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "[INFO] $Project.sln $BuildCfg $Platform compiled successfully" -ForegroundColor Green
}

Invoke-Compiling "x86"
Invoke-Compiling "x64"

if ($Sign) {
    $files = @(
        Join-Path $PSScriptRoot "_bin\Filter_x86$Suffix\$Project.ax",
        Join-Path $PSScriptRoot "_bin\Filter_x64$Suffix\$Project64.ax"
    )
    & (Join-Path $PSScriptRoot "sign.cmd") $files
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Problem signing files." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "[INFO] Files signed successfully." -ForegroundColor Green
}

function Get-Define($filePath, $name) {
    if (Test-Path $filePath) {
        $line = Select-String -Path $filePath -Pattern "#define\s+$name\s+([^\s/]+)"
        if ($line) { return $line.Matches.Groups[1].Value.Trim('"') }
    }
    return ""
}

$versionH = Join-Path $PSScriptRoot "Include\Version.h"
$revisionH = Join-Path $PSScriptRoot "revision.h"

$VerMajor = Get-Define $versionH "VER_MAJOR"
$VerMinor = Get-Define $versionH "VER_MINOR"
$VerBuild = Get-Define $versionH "VER_BUILD"
$VerRelease = Get-Define $versionH "VER_RELEASE"

$RevDate = Get-Define $revisionH "REV_DATE"
$RevHash = Get-Define $revisionH "REV_HASH"
$RevNum = Get-Define $revisionH "REV_NUM"
$RevBranch = Get-Define $revisionH "REV_BRANCH"

if ($VerRelease -eq "1") {
    $PckgName = "$Project-$VerMajor.$VerMinor.$VerBuild.$RevNum$Suffix"
} else {
    if ($RevBranch -eq "master") {
        $PckgName = "$Project-$VerMajor.$VerMinor.$VerBuild.$RevNum`_git$RevDate-$RevHash$Suffix"
    } else {
        $PckgName = "$Project-$VerMajor.$VerMinor.$VerBuild.$RevNum.$RevBranch`_git$RevDate-$RevHash$Suffix"
    }
}

$sevenZip = "7z.exe"
if (-not (Get-Command $sevenZip -ErrorAction SilentlyContinue)) {
    $regPath = Get-ItemProperty -Path "HKLM:\SOFTWARE\7-Zip" -Name "Path" -ErrorAction SilentlyContinue
    if ($regPath) { $sevenZip = Join-Path $regPath.Path "7z.exe" }
    else {
        $regPath = Get-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\7-Zip" -Name "Path" -ErrorAction SilentlyContinue
        if ($regPath) { $sevenZip = Join-Path $regPath.Path "7z.exe" }
    }
}

if (Get-Command $sevenZip -ErrorAction SilentlyContinue) {
    $zipFile = Join-Path $PSScriptRoot "_bin\$PckgName.zip"
    if (Test-Path $zipFile) { Remove-Item $zipFile }
    
    $Host.UI.RawUI.WindowTitle = "Creating archive $PckgName.zip..."
    $archiveFiles = @(
        "_bin\Filter_x86$Suffix\$Project.ax",
        "_bin\Filter_x64$Suffix\$Project64.ax",
        "distrib\Install_MPCVR_32.cmd",
        "distrib\Install_MPCVR_64.cmd",
        "distrib\Uninstall_MPCVR_32.cmd",
        "distrib\Uninstall_MPCVR_64.cmd",
        "distrib\Reset_Settings.cmd",
        "Readme.md",
        "history.txt",
        "LICENSE.txt"
    )
    
    & $sevenZip a -tzip -mx9 $zipFile $archiveFiles
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[INFO] $PckgName.zip successfully created" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Unable to create $PckgName.zip!" -ForegroundColor Red
        exit 1
    }
}

$Host.UI.RawUI.WindowTitle = "Compiling $Title [FINISHED]"
if ($Wait) {
    Write-Host "Done. Waiting 3 seconds..."
    Start-Sleep -Seconds 3
}
