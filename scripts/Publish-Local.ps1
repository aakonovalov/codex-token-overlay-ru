param(
    [ValidateSet("win-x64", "win-arm64")]
    [string]$RuntimeIdentifier = "win-x64",
    [ValidateSet("Lite", "Standalone", "Both")]
    [string]$Variant = "Both",
    [string]$DotnetPath = "dotnet"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot "src\CodexTokenOverlay\CodexTokenOverlay.csproj"
$artifactsRoot = Join-Path $repositoryRoot "artifacts"
$runtimeNoticePath = Join-Path $repositoryRoot "packaging\windows\INSTALL-DOTNET-RUNTIME.txt"
$resolvedArtifactsRoot = [System.IO.Path]::GetFullPath($artifactsRoot)

function Remove-ArtifactPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $artifactsPrefix = $resolvedArtifactsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedPath.Equals($resolvedArtifactsRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $resolvedPath.StartsWith($artifactsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Очистка разрешена только внутри каталога artifacts. Получен путь $resolvedPath"
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function New-ReleaseArchive {
    param(
        [Parameter(Mandatory = $true)][string]$PublishDirectory,
        [Parameter(Mandatory = $true)][string]$AssetName,
        [Parameter(Mandatory = $true)][bool]$IsLite
    )

    $stagingDirectory = Join-Path $artifactsRoot $AssetName
    $archivePath = $stagingDirectory + ".zip"
    Remove-ArtifactPath -Path $stagingDirectory
    Remove-ArtifactPath -Path $archivePath
    Remove-ArtifactPath -Path ($archivePath + ".sha256")

    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PublishDirectory "CodexTokenOverlay.exe") -Destination $stagingDirectory
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "README.md") -Destination $stagingDirectory
    Copy-Item -LiteralPath (Join-Path $repositoryRoot "LICENSE") -Destination $stagingDirectory
    if ($IsLite) {
        Copy-Item -LiteralPath $runtimeNoticePath -Destination $stagingDirectory
    }

    Compress-Archive -Path (Join-Path $stagingDirectory "*") -DestinationPath $archivePath -CompressionLevel Optimal
    $archiveHash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    $checksumPath = $archivePath + ".sha256"
    [System.IO.File]::WriteAllText(
        $checksumPath,
        ($archiveHash.Hash.ToLowerInvariant() + "  " + (Split-Path -Leaf $archivePath) + "`n"),
        [System.Text.UTF8Encoding]::new($false))

    $archiveSize = (Get-Item -LiteralPath $archivePath).Length
    Write-Host "Создан архив $archivePath ($archiveSize байт)"
    Write-Host "Создан файл контрольной суммы $checksumPath"
}

New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null

# С версии 0.2.1 автономный архив снова использует имя без суффикса -standalone.
# Удаляем файлы со старым суффиксом, который использовался в предварительных выпусках.
$obsoleteStandaloneBase = Join-Path $artifactsRoot ("CodexTokenOverlay-" + $RuntimeIdentifier + "-standalone")
foreach ($obsoletePath in @(
        $obsoleteStandaloneBase,
        ($obsoleteStandaloneBase + ".zip"),
        ($obsoleteStandaloneBase + ".zip.sha256")
    )) {
    Remove-ArtifactPath -Path $obsoletePath
}

$buildLite = $Variant -in @("Lite", "Both")
$buildStandalone = $Variant -in @("Standalone", "Both")

if ($buildLite) {
    $litePublishDirectory = Join-Path $artifactsRoot ("publish-" + $RuntimeIdentifier + "-lite")
    Remove-ArtifactPath -Path $litePublishDirectory

    & $DotnetPath publish $projectPath -c Release -r $RuntimeIdentifier --self-contained false -o $litePublishDirectory `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=false `
        -p:EnableCompressionInSingleFile=false `
        -p:DebugType=None `
        -p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось собрать версию Lite."
    }

    $liteExecutable = Join-Path $litePublishDirectory "CodexTokenOverlay.exe"
    $liteSize = (Get-Item -LiteralPath $liteExecutable).Length
    if ($liteSize -ge 1MB) {
        throw "Размер Lite EXE должен быть меньше 1 МиБ. Получено $liteSize байт."
    }
    & (Join-Path $PSScriptRoot "Test-PeArchitecture.ps1") `
        -ExecutablePath $liteExecutable `
        -Architecture $RuntimeIdentifier.Substring($RuntimeIdentifier.IndexOf('-') + 1)

    # Запускаем проверку x64 на этой машине. Для Arm64 в CI проверяются сборка и архитектура PE.
    if ($RuntimeIdentifier -eq "win-x64") {
        & (Join-Path $PSScriptRoot "Test-PublishedExecutable.ps1") -ExecutablePath $liteExecutable
    }

    New-ReleaseArchive `
        -PublishDirectory $litePublishDirectory `
        -AssetName ("CodexTokenOverlay-" + $RuntimeIdentifier + "-lite") `
        -IsLite $true
}

if ($buildStandalone) {
    $standalonePublishDirectory = Join-Path $artifactsRoot ("publish-" + $RuntimeIdentifier + "-standalone")
    Remove-ArtifactPath -Path $standalonePublishDirectory

    & $DotnetPath publish $projectPath -c Release -r $RuntimeIdentifier --self-contained true -o $standalonePublishDirectory `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        -p:EnableCompressionInSingleFile=true `
        -p:PublishTrimmed=false `
        -p:DebugType=None `
        -p:DebugSymbols=false
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось собрать автономную версию."
    }

    & (Join-Path $PSScriptRoot "Test-PeArchitecture.ps1") `
        -ExecutablePath (Join-Path $standalonePublishDirectory "CodexTokenOverlay.exe") `
        -Architecture $RuntimeIdentifier.Substring($RuntimeIdentifier.IndexOf('-') + 1)

    if ($RuntimeIdentifier -eq "win-x64") {
        & (Join-Path $PSScriptRoot "Test-PublishedExecutable.ps1") `
            -ExecutablePath (Join-Path $standalonePublishDirectory "CodexTokenOverlay.exe")
    }

    New-ReleaseArchive `
        -PublishDirectory $standalonePublishDirectory `
        -AssetName ("CodexTokenOverlay-" + $RuntimeIdentifier) `
        -IsLite $false
}
