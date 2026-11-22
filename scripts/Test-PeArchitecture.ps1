param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$Architecture
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$resolvedExecutable = [System.IO.Path]::GetFullPath($ExecutablePath)
if (-not (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf)) {
    throw "Не найден PE-файл для проверки: $resolvedExecutable"
}

$expectedMachine = switch ($Architecture) {
    "x64" { 0x8664 }
    "arm64" { 0xAA64 }
}

$stream = [System.IO.File]::Open(
    $resolvedExecutable,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read)
$reader = [System.IO.BinaryReader]::new($stream)
try {
    if ($reader.ReadUInt16() -ne 0x5A4D) {
        throw "В файле отсутствует заголовок MZ: $resolvedExecutable"
    }

    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    if ($peOffset -lt 0x40 -or $peOffset -gt ($stream.Length - 6)) {
        throw "Недопустимое смещение заголовка PE: $peOffset"
    }

    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) {
        throw "В файле отсутствует заголовок PE: $resolvedExecutable"
    }

    $actualMachine = $reader.ReadUInt16()
    if ($actualMachine -ne $expectedMachine) {
        throw ("Архитектура PE не совпадает: ожидалась {0} (0x{1:X4}), получено 0x{2:X4}: {3}" -f `
            $Architecture,
            $expectedMachine,
            $actualMachine,
            $resolvedExecutable)
    }

    Write-Host ("Проверка архитектуры PE пройдена: {0} (0x{1:X4})" -f $Architecture, $actualMachine)
}
finally {
    $reader.Dispose()
    $stream.Dispose()
}
