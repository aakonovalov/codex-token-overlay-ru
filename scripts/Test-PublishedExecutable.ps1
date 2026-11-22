param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$resolvedExecutable = [System.IO.Path]::GetFullPath($ExecutablePath)
if (-not (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf)) {
    throw "Не найден опубликованный исполняемый файл для проверки: $resolvedExecutable"
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("CodexTokenOverlayPublishedTests-" + [Guid]::NewGuid().ToString("N"))
$threadId = "11111111-2222-3333-4444-555555555555"
$sessionDirectory = Join-Path $testRoot "sessions\2026\07\18"
$sessionPath = Join-Path $sessionDirectory ("rollout-2026-07-18T00-00-00-" + $threadId + ".jsonl")
$probePath = Join-Path $testRoot "probe.json"
$process = $null

try {
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null

    # Используется только синтетический журнал, чтобы проверить запуск опубликованного EXE и разбор всех показателей.
    $sessionMeta = '{"type":"session_meta","payload":{"originator":"Codex Desktop","source":"vscode"}}'
    $tokenEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12345,"input_tokens":10000,"cached_input_tokens":7000,"output_tokens":2345,"reasoning_output_tokens":345},"last_token_usage":{"total_tokens":2300,"input_tokens":2048},"model_context_window":128000}}}'
    [System.IO.File]::WriteAllLines(
        $sessionPath,
        [string[]]@($sessionMeta, $tokenEvent),
        [System.Text.UTF8Encoding]::new($false))

    $argumentString = '--probe "{0}" --sessions "{1}"' -f `
        $probePath.Replace('"', '\"'), `
        (Join-Path $testRoot "sessions").Replace('"', '\"')
    $process = Start-Process `
        -FilePath $resolvedExecutable `
        -ArgumentList $argumentString `
        -WindowStyle Hidden `
        -PassThru

    # Проверка должна завершиться за несколько секунд; при превышении лимита завершаем только процесс, запущенный этим скриптом.
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        $process.WaitForExit()
        throw "Проверка опубликованной программы не завершилась за 30 секунд."
    }

    $exitCode = $process.ExitCode
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
        throw "Не удалось выполнить проверку опубликованной программы. Код завершения: $exitCode"
    }

    $snapshot = Get-Content -LiteralPath $probePath -Encoding UTF8 -Raw | ConvertFrom-Json
    $checks = @(
        $snapshot.ThreadId -eq $threadId
        $snapshot.TotalTokens -eq 12345
        $snapshot.InputTokens -eq 10000
        $snapshot.CachedInputTokens -eq 7000
        $snapshot.UncachedInputTokens -eq 3000
        $snapshot.OutputTokens -eq 2345
        $snapshot.ReasoningOutputTokens -eq 345
        $snapshot.ContextUsedTokens -eq 2300
        $snapshot.ContextWindowTokens -eq 128000
    )
    if ($checks -contains $false) {
        throw "Результат разбора опубликованной программы не совпадает с синтетическим журналом."
    }

    Write-Host "Проверка опубликованной программы пройдена: $resolvedExecutable"
}
finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
        }
        catch {
            # Процесс мог завершиться во время проверки его состояния; в этом случае достаточно продолжить очистку тестовой папки.
        }
        finally {
            $process.Dispose()
        }
    }

    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $isInsideTemporaryRoot = $resolvedTestRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)
    $hasExpectedPrefix = (Split-Path -Leaf $resolvedTestRoot).StartsWith(
        "CodexTokenOverlayPublishedTests-",
        [StringComparison]::Ordinal)
    if ($isInsideTemporaryRoot -and $hasExpectedPrefix) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
