param(
    [string]$DotnetPath = "dotnet",
    [string]$TargetFramework = "net10.0-windows"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot "src\CodexTokenOverlay\CodexTokenOverlay.csproj"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("CodexTokenOverlayTests-" + [Guid]::NewGuid().ToString("N"))
$threadId = "11111111-2222-3333-4444-555555555555"
$sessionDirectory = Join-Path $testRoot "sessions\2026\07\17"
$sessionPath = Join-Path $sessionDirectory ("rollout-2026-07-17T00-00-00-" + $threadId + ".jsonl")
$probePath = Join-Path $testRoot "probe.json"
$threadA = "aaaaaaaa-1111-2222-3333-444444444444"
$threadB = "bbbbbbbb-1111-2222-3333-444444444444"
$threadAPath = Join-Path $sessionDirectory ("rollout-2026-07-17T00-01-00-" + $threadA + ".jsonl")
$threadBPath = Join-Path $sessionDirectory ("rollout-2026-07-17T00-02-00-" + $threadB + ".jsonl")
$switchProbePath = Join-Path $testRoot "thread-switch-probe.json"
$originalCodexHome = $env:CODEX_HOME

try {
    New-Item -ItemType Directory -Path $sessionDirectory -Force | Out-Null

    # Используются только синтетические данные; в тестовый репозиторий не попадёт содержимое реальных сессий Codex.
    $sessionMeta = '{"type":"session_meta","payload":{"originator":"Codex Desktop","source":"vscode"}}'
    $tokenEvent = '{"timestamp":"2026-07-17T00:00:01.123456789Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12345,"input_tokens":10000,"cached_input_tokens":7000,"output_tokens":2345,"reasoning_output_tokens":345},"last_token_usage":{"total_tokens":2300,"input_tokens":2048},"model_context_window":128000}}}'
    [System.IO.File]::WriteAllLines(
        $sessionPath,
        [string[]]@($sessionMeta, $tokenEvent),
        [System.Text.UTF8Encoding]::new($false))

    $threadATokenEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":11111,"input_tokens":10000,"cached_input_tokens":7000,"output_tokens":1111,"reasoning_output_tokens":111},"last_token_usage":{"total_tokens":1200,"input_tokens":1024},"model_context_window":128000}}}'
    $threadBTokenEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":22222,"input_tokens":20000,"cached_input_tokens":14000,"output_tokens":2222,"reasoning_output_tokens":222},"last_token_usage":{"total_tokens":2300,"input_tokens":2048},"model_context_window":128000}}}'
    [System.IO.File]::WriteAllLines(
        $threadAPath,
        [string[]]@($sessionMeta, $threadATokenEvent),
        [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllLines(
        $threadBPath,
        [string[]]@($sessionMeta, $threadBTokenEvent),
        [System.Text.UTF8Encoding]::new($false))

    $threadBWriteUtc = [DateTime]::UtcNow.AddMinutes(-10)
    $threadAWriteUtc = $threadBWriteUtc.AddMinutes(5)
    [System.IO.File]::SetLastWriteTimeUtc($threadBPath, $threadBWriteUtc)
    [System.IO.File]::SetLastWriteTimeUtc($threadAPath, $threadAWriteUtc)
    $threadAWriteTicks = [System.IO.File]::GetLastWriteTimeUtc($threadAPath).Ticks
    $threadBWriteTicks = [System.IO.File]::GetLastWriteTimeUtc($threadBPath).Ticks

    & $DotnetPath build $projectPath -c Release --nologo "-p:TargetFramework=$TargetFramework"
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось собрать проект."
    }

    $applicationDll = Join-Path $repositoryRoot "src\CodexTokenOverlay\bin\Release\$TargetFramework\CodexTokenOverlay.dll"
    $applicationAssembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
    $probeRunnerType = $applicationAssembly.GetType("CodexTokenOverlay.ProbeRunner", $false)
    if ($null -eq $probeRunnerType) {
        throw "Единая точка входа ProbeRunner не найдена."
    }
    $tryRun = $probeRunnerType.GetMethod(
        "TryRun",
        [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static)
    if ($null -eq $tryRun) {
        throw "Точка входа ProbeRunner.TryRun не найдена."
    }
    $normalStartupArguments = [System.Collections.Generic.List[string]]::new()
    $normalStartupInvocation = New-Object object[] 2
    $normalStartupInvocation[0] = $normalStartupArguments
    $normalStartupInvocation[1] = [string](Join-Path $testRoot "sessions")
    $normalStartupResult = $tryRun.Invoke(
        $null,
        $normalStartupInvocation)
    if ($normalStartupResult -ne $false) {
        throw "Обычный запуск интерфейса не должен обрабатываться точкой входа для проверок."
    }

    # Сначала убеждаемся через единую точку входа, что новые параметры обрабатываются проверкой: так при отсутствии реализации не будет запущен интерфейс WinForms.
    $switchProbeArguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @("--thread-switch-probe", $switchProbePath, $threadA, $threadB)) {
        $switchProbeArguments.Add($argument)
    }
    $switchProbeInvocation = New-Object object[] 2
    $switchProbeInvocation[0] = $switchProbeArguments
    $switchProbeInvocation[1] = [string](Join-Path $testRoot "sessions")
    $switchProbeHandled = $tryRun.Invoke($null, $switchProbeInvocation)
    if ($switchProbeHandled -ne $true -or -not (Test-Path -LiteralPath $switchProbePath)) {
        throw "Нет результата проверки переключения потоков."
    }
    Remove-Item -LiteralPath $switchProbePath -Force

    & $DotnetPath $applicationDll --thread-switch-probe $switchProbePath $threadA $threadB --sessions (Join-Path $testRoot "sessions")
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $switchProbePath)) {
        throw "Не удалось выполнить проверку переключения потоков."
    }

    $switchResult = Get-Content -LiteralPath $switchProbePath -Encoding UTF8 -Raw | ConvertFrom-Json
    $switchChecks = @(
        $switchResult.FirstSnapshot.ThreadId -eq $threadA
        $switchResult.FirstSnapshot.TotalTokens -eq 11111
        $switchResult.SecondSnapshot.ThreadId -eq $threadB
        $switchResult.SecondSnapshot.TotalTokens -eq 22222
        $switchResult.SecondVersion -gt $switchResult.FirstVersion
        [System.IO.File]::GetLastWriteTimeUtc($threadAPath).Ticks -eq $threadAWriteTicks
        [System.IO.File]::GetLastWriteTimeUtc($threadBPath).Ticks -eq $threadBWriteTicks
    )
    if ($switchChecks -contains $false) {
        throw "Результат переключения потоков без новых записей не совпадает с ожидаемым."
    }

    & $DotnetPath $applicationDll --probe $probePath --sessions (Join-Path $testRoot "sessions")
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probePath)) {
        throw "Не удалось выполнить проверку журнала."
    }

    $snapshot = Get-Content -LiteralPath $probePath -Encoding UTF8 -Raw | ConvertFrom-Json
    $checks = @(
        $snapshot.ThreadId -eq $threadId
        $snapshot.TotalTokens -eq 12345
        $snapshot.InputTokens -eq 10000
        $snapshot.CachedInputTokens -eq 7000
        $snapshot.OutputTokens -eq 2345
        $snapshot.ReasoningOutputTokens -eq 345
        $snapshot.ContextUsedTokens -eq 2300
        $snapshot.ContextWindowTokens -eq 128000
        $snapshot.HasContextUsage -eq $true
        ([DateTimeOffset]$snapshot.UpdatedAtUtc).UtcDateTime -eq ([DateTimeOffset]'2026-07-17T00:00:01.1234567Z').UtcDateTime
        $snapshot.UncachedInputTokens -eq 3000
    )
    if ($checks -contains $false) {
        throw "Результат разбора не совпадает с синтетическим журналом."
    }

    # Также проверяем автоматическое обнаружение CODEX_HOME: программа не должна требовать установки в определённую папку.
    Remove-Item -LiteralPath $probePath -Force
    $env:CODEX_HOME = $testRoot
    & $DotnetPath $applicationDll --probe $probePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $probePath)) {
        throw "Не удалось проверить автоматическое обнаружение CODEX_HOME."
    }
    $autoDiscoveredSnapshot = Get-Content -LiteralPath $probePath -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($autoDiscoveredSnapshot.ThreadId -ne $threadId -or $autoDiscoveredSnapshot.TotalTokens -ne 12345) {
        throw "Результат автоматического обнаружения CODEX_HOME неверен."
    }

    $unknownUsageEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12400},"last_token_usage":{"input_tokens":2048,"total_tokens":null},"model_context_window":128000}}}'
    $unknownWindowEvent = '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12500},"last_token_usage":{"total_tokens":2400},"model_context_window":null}}}'
    foreach ($case in @(
        @{ Name = 'unknown-usage'; Event = $unknownUsageEvent; Total = 12400; Used = -1; Window = 128000 },
        @{ Name = 'unknown-window'; Event = $unknownWindowEvent; Total = 12500; Used = 2400; Window = 0 }
    )) {
        [System.IO.File]::AppendAllLines($sessionPath, [string[]]@($case.Event))
        $caseProbePath = Join-Path $testRoot "$($case.Name).json"
        & $DotnetPath $applicationDll --probe $caseProbePath $threadId
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $caseProbePath)) {
            throw "Не удалось выполнить проверку при отсутствии данных о контексте: $($case.Name)"
        }
        $caseSnapshot = Get-Content -LiteralPath $caseProbePath -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($caseSnapshot.TotalTokens -ne $case.Total -or $caseSnapshot.HasContextUsage -ne $false -or
            $caseSnapshot.ContextUsedTokens -ne $case.Used -or $caseSnapshot.ContextWindowTokens -ne $case.Window) {
            throw "При отсутствии данных о контексте нужно сохранить последнее итоговое значение и пометить использование контекста как неизвестное: $($case.Name)"
        }
    }

    Write-Host "Проверка разбора журнала пройдена."
}
finally {
    if ($null -eq $originalCodexHome) {
        Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:CODEX_HOME = $originalCodexHome
    }

    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $isInsideTemporaryRoot = $resolvedTestRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)
    $hasExpectedPrefix = (Split-Path -Leaf $resolvedTestRoot).StartsWith("CodexTokenOverlayTests-", [StringComparison]::Ordinal)
    if ($isInsideTemporaryRoot -and $hasExpectedPrefix) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
