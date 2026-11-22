param(
    [ValidateSet('Settings', 'Presentation', 'Layout', 'Interaction', 'Window', 'Form', 'Attachment', 'Theme', 'All')]
    [string]$Area = 'All',
    [string]$DotnetPath = 'dotnet',
    [string]$TargetFramework = 'net10.0-windows'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$implementedAreas = @('Settings', 'Presentation', 'Layout', 'Interaction', 'Window', 'Form', 'Attachment', 'Theme')
$areas = if ($Area -eq 'All') { $implementedAreas } else { @($Area) }

$unsupportedAreas = $areas | Where-Object { $_ -notin $implementedAreas }
if ($unsupportedAreas.Count -gt 0) {
    throw "Тестирование не поддерживается для областей: $($unsupportedAreas -join ', ')"
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repositoryRoot 'src\CodexTokenOverlay\CodexTokenOverlay.csproj'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'CodexTokenOverlayLogicTests-' + [Guid]::NewGuid().ToString('N'))
$applicationDll = Join-Path $repositoryRoot "src\CodexTokenOverlay\bin\Release\$TargetFramework\CodexTokenOverlay.dll"

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Rect {
    param(
        [object]$Actual,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [string]$Message
    )

    $actualText = if ($null -eq $Actual) {
        '<null>'
    }
    else {
        "$($Actual.X),$($Actual.Y),$($Actual.Width),$($Actual.Height)"
    }
    $expectedText = "$X,$Y,$Width,$Height"
    Assert-Condition ($actualText -eq $expectedText) "$Message expected=$expectedText actual=$actualText"
}

function Assert-LayoutEqual {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    $actualText = $Actual | ConvertTo-Json -Compress -Depth 8
    $expectedText = $Expected | ConvertTo-Json -Compress -Depth 8
    Assert-Condition ($actualText -eq $expectedText) "$Message expected=$expectedText actual=$actualText"
}

function Get-MethodCallTokens {
    param([System.Reflection.MethodBase]$Method)

    $opcodeLookup = @{}
    foreach ($field in [System.Reflection.Emit.OpCodes].GetFields([System.Reflection.BindingFlags]'Public, Static')) {
        $opcode = $field.GetValue($null)
        $value = [int]$opcode.Value
        if ($value -lt 0) { $value += 65536 }
        $opcodeLookup[$value] = $opcode
    }

    $body = $Method.GetMethodBody()
    if ($null -eq $body) { return @() }
    $bytes = $body.GetILAsByteArray()
    $offset = 0
    $tokens = @()
    while ($offset -lt $bytes.Length) {
        $first = [int]$bytes[$offset]
        $offset++
        $value = if ($first -eq 0xFE) {
            $second = [int]$bytes[$offset]
            $offset++
            0xFE00 -bor $second
        }
        else {
            $first
        }
        $opcode = $opcodeLookup[$value]
        if ($null -eq $opcode) { throw "Неизвестный код операции IL: $value" }
        $operandStart = $offset
        $operandLength = switch ($opcode.OperandType.ToString()) {
            'InlineNone' { 0 }
            'ShortInlineBrTarget' { 1 }
            'ShortInlineI' { 1 }
            'ShortInlineVar' { 1 }
            'InlineVar' { 2 }
            'InlineI' { 4 }
            'InlineBrTarget' { 4 }
            'InlineField' { 4 }
            'InlineMethod' { 4 }
            'InlineSig' { 4 }
            'InlineString' { 4 }
            'InlineTok' { 4 }
            'InlineType' { 4 }
            'ShortInlineR' { 4 }
            'InlineI8' { 8 }
            'InlineR' { 8 }
            'InlineSwitch' { 4 + (4 * [BitConverter]::ToInt32($bytes, $offset)) }
            default { throw "Неподдерживаемый операнд IL: $($opcode.OperandType)" }
        }
        if ($opcode.OperandType.ToString() -eq 'InlineMethod') {
            $tokens += [BitConverter]::ToInt32($bytes, $operandStart)
        }
        $offset += $operandLength
    }
    return $tokens
}

function Test-MethodCallChain {
    param(
        [System.Reflection.MethodInfo]$Caller,
        [System.Reflection.MethodInfo[]]$Callees,
        [int]$MaximumSpan = 4
    )

    $calls = @(
        foreach ($token in @(Get-MethodCallTokens $Caller)) {
            $Caller.Module.ResolveMethod($token)
        }
    )
    for ($start = 0; $start -lt $calls.Count; $start++) {
        if ($calls[$start].Module -ne $Callees[0].Module -or
            $calls[$start].MetadataToken -ne $Callees[0].MetadataToken) {
            continue
        }

        $callIndex = $start + 1
        for ($calleeIndex = 1; $calleeIndex -lt $Callees.Count; $calleeIndex++) {
            while ($callIndex -lt $calls.Count -and
                ($calls[$callIndex].Module -ne $Callees[$calleeIndex].Module -or
                 $calls[$callIndex].MetadataToken -ne $Callees[$calleeIndex].MetadataToken)) {
                $callIndex++
            }
            if ($callIndex -ge $calls.Count -or $callIndex - $start -gt $MaximumSpan) {
                break
            }
            $callIndex++
        }
        if ($calleeIndex -eq $Callees.Count -and $callIndex - 1 - $start -le $MaximumSpan) {
            return $true
        }
    }
    return $false
}

function Get-ProbeCase {
    param(
        [object]$Response,
        [string]$Name
    )

    $case = @($Response.Cases | Where-Object { $_.Name -eq $Name })
    if ($case.Count -ne 1) {
        throw "Проверка настроек должна вернуть один результат для сценария: $Name"
    }

    return $case[0]
}

function Copy-WindowCandidate {
    param(
        [hashtable]$Candidate,
        [hashtable]$Overrides
    )

    $copy = @{}
    foreach ($entry in $Candidate.GetEnumerator()) {
        $copy[$entry.Key] = $entry.Value
    }
    foreach ($entry in $Overrides.GetEnumerator()) {
        $copy[$entry.Key] = $entry.Value
    }
    return $copy
}

function Assert-InteractionTrace {
    param(
        [object]$Case,
        [object[]]$Expected
    )

    $actual = @($Case.Events)
    Assert-Condition ($actual.Count -eq $Expected.Count) "У сценария $($Case.Name) неверное число переходов состояния."
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        $actualEvent = $actual[$index]
        $expectedEvent = $Expected[$index]
        Assert-Condition ($actualEvent.State -eq $expectedEvent.State) "Неверное состояние на шаге $index сценария $($Case.Name)."
        Assert-Condition ($actualEvent.ShouldPollOutsideClicks -eq $expectedEvent.Polling) "Статус опроса шага $index случая взаимодействия $($Case.Name) неверен."
        Assert-Condition ($actualEvent.IsWaitingForOpeningClickRelease -eq $expectedEvent.WaitingForRelease) "На этапе $index интерактивного случая $($Case.Name) состояние открытия щелчком мыши является неправильным."
        Assert-Condition ($actualEvent.StateChanged -eq $expectedEvent.StateChanged) "Неверный признак изменения состояния на шаге $index сценария $($Case.Name)."
    }
}

function Invoke-JsonProbe {
    param(
        [string]$Mode,
        [object[]]$Cases
    )

    $requestPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-request.json")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-output.json")
    $request = @{ Cases = $Cases } | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $requestPath,
        $request,
        [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $argumentString = '"{0}" {1} "{2}" "{3}"' -f `
            $applicationDll.Replace('"', '\"'), `
            $Mode, `
            $outputPath.Replace('"', '\"'), `
            $requestPath.Replace('"', '\"')
        $probeProcess = Start-Process `
            -FilePath $DotnetPath `
            -ArgumentList $argumentString `
            -WindowStyle Hidden `
            -PassThru

        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw "Проверка установки не выдала результаты в течение 10 секунд: $Mode"
        }

        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw "Не удалось выполнить проверку установки: $Mode"
        }

        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

function Invoke-WindowDpiAwarenessReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-window-dpi-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-window-dpi-output.json")
    $probeScript = @'
param(
    [string]$ApplicationDll,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
$probeRunner = $assembly.GetType('CodexTokenOverlay.ProbeRunner', $true)
$bindingFlags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Static
$prepare = $probeRunner.GetMethod('PrepareWindowProbeDpiAwareness', $bindingFlags)
$dpiMode = if ($null -eq $prepare) {
    '<method-missing>'
}
else {
    $null = $prepare.Invoke($null, $null)
    $application = [Type]::GetType('System.Windows.Forms.Application, System.Windows.Forms', $true)
    $application.GetProperty('HighDpiMode').GetValue($null).ToString()
}

$json = @{ DpiMode = $dpiMode } | ConvertTo-Json
[System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText(
        $probeScriptPath,
        $probeScript,
        [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $argumentString `
            -WindowStyle Hidden `
            -PassThru

        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw 'Проверка отражения определения DPI окна не завершилась в течение 10 секунд.'
        }

        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'Не удалось выполнить проверку отражения определения DPI окна.'
        }

        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

function Invoke-KnownTargetRefreshReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-known-target-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-known-target-output.json")
    $probeScript = @'
param(
    [string]$ApplicationDll,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
$locatorType = $assembly.GetType('CodexTokenOverlay.CodexWindowLocator', $true)
$candidateType = $assembly.GetType('CodexTokenOverlay.WindowCandidateFacts', $true)
$rectType = $assembly.GetType('CodexTokenOverlay.IntRect', $true)
$selectionType = $assembly.GetType('CodexTokenOverlay.CodexWindowCandidateSelection', $true)
$bindingFlags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Static
$method = $locatorType.GetMethod('TrySelectKnownCodexTarget', $bindingFlags)
$readMethod = $locatorType.GetMethod('IsCandidateReadValid', $bindingFlags)
$identityMethod = $locatorType.GetMethod('IsKnownTargetIdentityValid', $bindingFlags)
if ($null -eq $method) {
    throw 'TrySelectKnownCodexTarget is unsupported.'
}
if ($null -eq $readMethod) {
    throw 'IsCandidateReadValid is unsupported.'
}
if ($null -eq $identityMethod) {
    throw 'IsKnownTargetIdentityValid is unsupported.'
}

function New-Rect([int]$X, [int]$Y, [int]$Width, [int]$Height) {
    return [System.Activator]::CreateInstance($rectType, @($X, $Y, $Width, $Height))
}

function New-Candidate(
    [long]$Handle,
    [uint32]$ProcessId,
    [long]$Style,
    [object]$Bounds,
    [string]$ClassName = 'Chrome_WidgetWin_1') {
    return [System.Activator]::CreateInstance($candidateType, @(
        [IntPtr]::new($Handle),
        $ProcessId,
        $true,
        $true,
        $false,
        [IntPtr]::Zero,
        $Style,
        $Bounds,
        $ClassName))
}

function Invoke-Selection([long]$PreviousHost, [uint32]$ProcessId, [object[]]$Candidates) {
    $listType = [System.Collections.Generic.List``1].MakeGenericType($candidateType)
    $list = [System.Activator]::CreateInstance($listType)
    foreach ($candidate in $Candidates) {
        $list.Add($candidate)
    }
    $arguments = @([IntPtr]::new($PreviousHost), $ProcessId, $list, $null)
    $success = [bool]$method.Invoke($null, $arguments)
    $selection = if ($success) { $arguments[3] } else { $null }
    return [pscustomobject]@{
        Success = $success
        HostHandle = if ($null -eq $selection) { $null } else { $selection.Host.Handle.ToInt64() }
        HostBounds = if ($null -eq $selection) { $null } else { $selection.Host.Bounds }
    }
}

$normalStyle = 0x240100L
$toolStyle = 0x2800A8L
$movedHost = New-Candidate 100 10 $normalStyle (New-Rect 40 60 1500 1000)
$movedTool = New-Candidate 200 10 $toolStyle (New-Rect 1320 410 410 400)
$otherProcessHost = New-Candidate 100 11 $normalStyle (New-Rect 80 90 1500 1000)

$result = @{
    RefreshWhileOverlayForeground = Invoke-Selection 100 10 @($movedHost, $movedTool)
    RejectProcessChange = Invoke-Selection 100 10 @($otherProcessHost)
    DestroyedHostFailsClosed = Invoke-Selection 100 10 @($movedTool)
    ClassReadFailureAccepted = [bool]$readMethod.Invoke($null, @(0, 1L, 0))
    StyleReadFailureAccepted = [bool]$readMethod.Invoke($null, @(20, 0L, 1400))
    ZeroStyleWithoutErrorAccepted = [bool]$readMethod.Invoke($null, @(20, 0L, 0))
    SameConfirmedIdentityAccepted = [bool]$identityMethod.Invoke($null, @(100L, [uint32]10, 100L, [uint32]10))
    ReusedHandleDifferentProcessAccepted = [bool]$identityMethod.Invoke($null, @(100L, [uint32]10, 100L, [uint32]11))
    DifferentHostSameProcessAccepted = [bool]$identityMethod.Invoke($null, @(100L, [uint32]10, 101L, [uint32]10))
}
[System.IO.File]::WriteAllText(
    $OutputPath,
    ($result | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText(
        $probeScriptPath,
        $probeScript,
        [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $argumentString `
            -WindowStyle Hidden `
            -PassThru

        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw 'Проверка обновления известного окна Codex не завершилась за 10 секунд.'
        }
        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'Ошибка при проверке обновления известного окна Codex.'
        }
        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

function Invoke-HostSurfaceContractReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-host-surface-contract-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-host-surface-contract-output.json")
    $probeScript = @'
param([string]$ApplicationDll, [string]$OutputPath)

$ErrorActionPreference = 'Stop'
$result = @{
    Error = $null
    SelectionProperties = @()
    TargetProperties = @()
    LayoutRequestProperties = @()
    DiagnosticProperties = @()
    HasKnownHostMethod = $false
    IgnoredOverlayThenHost = $null
    ToolBeforeHost = $null
    OtherAppBeforeHost = $null
    EmptyAfterIgnoredOverlay = $null
    VisibleInvalidBeforeHostIsKnownHost = $null
    RecoveredAfterCompleteReadsIsKnownHost = $null
    InactiveInvalidBeforeHostIsKnownHost = $null
    DestroyedDuringReadBeforeHostIsKnownHost = $null
    OwnShadowBeforeHostIsKnownHost = $null
    ForeignShadowBeforeHostIsKnownHost = $null
    CodexNonHostBeforeHostIsKnownHost = $null
    OwnUnreadableBeforeHostIsKnownHost = $null
    ForeignUnreadableBeforeHostIsKnownHost = $null
    DestroyedForeignBeforeHostIsKnownHost = $null
    ZeroIgnoredProcessDoesNotSkip = $null
    ExplicitHandleStillSkippedWithZeroProcess = $null
    HasCurrentProcessWrapper = $false
}
try {
    $assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
    $locatorType = $assembly.GetType('CodexTokenOverlay.CodexWindowLocator', $false)
    $selectionType = $assembly.GetType('CodexTokenOverlay.CodexWindowCandidateSelection', $false)
    $targetType = $assembly.GetType('CodexTokenOverlay.CodexWindowTarget', $false)
    $layoutRequestType = $assembly.GetType('CodexTokenOverlay.OverlayLayoutRequest', $false)
    $candidateType = $assembly.GetType('CodexTokenOverlay.WindowSurfaceCandidate', $false)
    $rectType = $assembly.GetType('CodexTokenOverlay.IntRect', $false)
    $bindingFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Static'

    if ($null -ne $selectionType) { $result.SelectionProperties = @($selectionType.GetProperties().Name | Sort-Object) }
    if ($null -ne $targetType) { $result.TargetProperties = @($targetType.GetProperties().Name | Sort-Object) }
    if ($null -ne $layoutRequestType) { $result.LayoutRequestProperties = @($layoutRequestType.GetProperties().Name | Sort-Object) }
    if ($null -ne $locatorType) {
        $result.HasKnownHostMethod = $null -ne $locatorType.GetMethod('IsPointOnKnownHost', $bindingFlags)
        $diagnosticMethod = $locatorType.GetMethod('GetForegroundWindowProbe', $bindingFlags)
        if ($null -ne $diagnosticMethod) {
            $diagnostic = $diagnosticMethod.Invoke($null, @())
            $result.DiagnosticProperties = @($diagnostic.PSObject.Properties.Name | Sort-Object)
        }
    }

    $selectionMethod = if ($null -eq $locatorType) { $null } else { $locatorType.GetMethod('SelectUnderlyingWindowAtPoint', $bindingFlags) }
    $knownHostSelectionMethod = if ($null -eq $locatorType) { $null } else { $locatorType.GetMethod('IsUnderlyingWindowKnownHost', $bindingFlags) }
    $currentProcessKnownHostMethod = if ($null -eq $locatorType) {
        $null
    } else {
        $locatorType.GetMethod('IsUnderlyingWindowKnownHostForCurrentProcess', $bindingFlags)
    }
    $result.HasCurrentProcessWrapper = $null -ne $currentProcessKnownHostMethod
    $unreadableCandidateMethod = if ($null -eq $locatorType) { $null } else { $locatorType.GetMethod('CreateUnreadableSurfaceCandidate', $bindingFlags) }
    $boundsReadProperty = if ($null -eq $candidateType) { $null } else { $candidateType.GetProperty('BoundsReadSucceeded') }
    if ($null -ne $selectionMethod -and $null -ne $candidateType -and $null -ne $rectType) {
        function New-Rect([int]$X, [int]$Y, [int]$Width, [int]$Height) {
            [System.Activator]::CreateInstance($rectType, @($X, $Y, $Width, $Height))
        }
        function New-Surface([long]$Handle, [uint32]$ProcessId, [bool]$IsVisible, [bool]$IsMinimized, [object]$Bounds, [bool]$BoundsReadSucceeded = $true) {
            $candidate = [System.Activator]::CreateInstance($candidateType, @($Handle, $ProcessId, $IsVisible, $IsMinimized, $Bounds))
            if ($null -ne $boundsReadProperty) {
                $boundsReadProperty.SetValue($candidate, $BoundsReadSucceeded)
            }
            $candidate
        }
        function Invoke-SurfaceSelection(
            [object[]]$Candidates,
            [uint32]$IgnoredProcessId) {
            $listType = [System.Collections.Generic.List``1].MakeGenericType($candidateType)
            $list = [System.Activator]::CreateInstance($listType)
            foreach ($candidate in $Candidates) { $list.Add($candidate) }
            $ignored = [System.Collections.Generic.HashSet[long]]::new()
            $null = $ignored.Add(900L)
            $selectionMethod.Invoke($null, @(
                $list,
                [Drawing.Point]::new(50, 50),
                $ignored,
                $IgnoredProcessId))
        }

        $fullBounds = New-Rect 0 0 500 400
        $overlay = New-Surface 900 40 $true $false $fullBounds
        $hostSurface = New-Surface 100 10 $true $false $fullBounds
        $tool = New-Surface 200 10 $true $false $fullBounds
        $otherApp = New-Surface 300 30 $true $false $fullBounds
        $result.IgnoredOverlayThenHost = Invoke-SurfaceSelection -Candidates @($overlay, $hostSurface) -IgnoredProcessId ([uint32]0)
        $result.ToolBeforeHost = Invoke-SurfaceSelection -Candidates @($overlay, $tool, $hostSurface) -IgnoredProcessId ([uint32]0)
        $result.OtherAppBeforeHost = Invoke-SurfaceSelection -Candidates @($overlay, $otherApp, $hostSurface) -IgnoredProcessId ([uint32]0)
        $result.EmptyAfterIgnoredOverlay = Invoke-SurfaceSelection -Candidates @($overlay) -IgnoredProcessId ([uint32]0)

        if ($null -ne $knownHostSelectionMethod -and $null -ne $boundsReadProperty) {
            function Invoke-KnownHostSelection(
                [object[]]$Candidates,
                [uint32]$IgnoredProcessId) {
                $listType = [System.Collections.Generic.List``1].MakeGenericType($candidateType)
                $list = [System.Activator]::CreateInstance($listType)
                foreach ($candidate in $Candidates) { $list.Add($candidate) }
                $ignored = [System.Collections.Generic.HashSet[long]]::new()
                $null = $ignored.Add(900L)
                [bool]$knownHostSelectionMethod.Invoke($null, @(
                    $list,
                    [Drawing.Point]::new(50, 50),
                    $ignored,
                    100L,
                    [uint32]10,
                    $IgnoredProcessId))
            }

            function Invoke-CurrentProcessKnownHostSelection([object[]]$Candidates) {
                $listType = [System.Collections.Generic.List``1].MakeGenericType($candidateType)
                $list = [System.Activator]::CreateInstance($listType)
                foreach ($candidate in $Candidates) { $list.Add($candidate) }
                $ignored = [System.Collections.Generic.HashSet[long]]::new()
                $null = $ignored.Add(900L)
                [bool]$currentProcessKnownHostMethod.Invoke($null, @(
                    $list,
                    [Drawing.Point]::new(50, 50),
                    $ignored,
                    100L,
                    [uint32]10))
            }

            $invalidBlocker = New-Surface 250 25 $true $false (New-Rect 0 0 0 0) $false
            $recoveredBlocker = New-Surface 250 25 $true $false (New-Rect 600 0 500 400) $true
            $invisibleInvalid = New-Surface 260 26 $false $false (New-Rect 0 0 0 0) $false
            $minimizedInvalid = New-Surface 270 27 $true $true (New-Rect 0 0 0 0) $false
            $ignoredInvalid = New-Surface 900 40 $true $false (New-Rect 0 0 0 0) $false
            $overlayProcessId = [uint32]40
            $ownShadow = New-Surface 901 $overlayProcessId $true $false $fullBounds
            $foreignShadow = New-Surface 901 41 $true $false $fullBounds
            $codexNonHost = New-Surface 200 10 $true $false $fullBounds
            $ownUnreadable = New-Surface 902 $overlayProcessId $true $false (New-Rect 0 0 0 0) $false
            $foreignUnreadable = New-Surface 903 41 $true $false (New-Rect 0 0 0 0) $false
            $zeroPidBlocker = New-Surface 904 ([uint32]0) $true $false $fullBounds
            $runtimeOverlayProcessId = [uint32]$PID
            $runtimeOverlay = New-Surface 900 $runtimeOverlayProcessId $true $false $fullBounds
            $runtimeOwnShadow = New-Surface 901 $runtimeOverlayProcessId $true $false $fullBounds

            $result.VisibleInvalidBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $invalidBlocker, $hostSurface) -IgnoredProcessId ([uint32]0)
            $result.RecoveredAfterCompleteReadsIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $recoveredBlocker, $hostSurface) -IgnoredProcessId ([uint32]0)
            $result.InactiveInvalidBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($ignoredInvalid, $invisibleInvalid, $minimizedInvalid, $hostSurface) -IgnoredProcessId ([uint32]0)
            $result.OwnShadowBeforeHostIsKnownHost = Invoke-CurrentProcessKnownHostSelection -Candidates @($runtimeOverlay, $runtimeOwnShadow, $hostSurface)
            $result.ForeignShadowBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $foreignShadow, $hostSurface) -IgnoredProcessId $overlayProcessId
            $result.CodexNonHostBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $codexNonHost, $hostSurface) -IgnoredProcessId $overlayProcessId
            $result.OwnUnreadableBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $ownUnreadable, $hostSurface) -IgnoredProcessId $overlayProcessId
            $result.ForeignUnreadableBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $foreignUnreadable, $hostSurface) -IgnoredProcessId $overlayProcessId
            $result.ZeroIgnoredProcessDoesNotSkip = Invoke-KnownHostSelection -Candidates @($zeroPidBlocker, $hostSurface) -IgnoredProcessId ([uint32]0)
            $result.ExplicitHandleStillSkippedWithZeroProcess = Invoke-KnownHostSelection -Candidates @($overlay, $hostSurface) -IgnoredProcessId ([uint32]0)
            if ($null -ne $unreadableCandidateMethod) {
                $destroyedDuringRead = $unreadableCandidateMethod.Invoke($null, @(
                    280L,
                    [uint32]41,
                    $false,
                    $false,
                    $false))
                $result.DestroyedDuringReadBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $destroyedDuringRead, $hostSurface) -IgnoredProcessId ([uint32]0)
                $result.DestroyedForeignBeforeHostIsKnownHost = Invoke-KnownHostSelection -Candidates @($overlay, $destroyedDuringRead, $hostSurface) -IgnoredProcessId $overlayProcessId
            }
        }
    }
}
catch {
    $result.Error = $_.Exception.ToString()
}
[System.IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText($probeScriptPath, $probeScript, [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process -FilePath $powershellPath -ArgumentList $argumentString -WindowStyle Hidden -PassThru
        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw 'Проверка области главного окна не завершилась за 10 секунд.'
        }
        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'Ошибка при проверке области главного окна.'
        }
        Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally { $probeProcess.Dispose() }
        }
    }
}

function Invoke-ManualCoordinatorReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-manual-coordinator-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-manual-coordinator-output.json")
    $probeScript = @'
param(
    [string]$ApplicationDll,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
$coordinatorType = $assembly.GetType('CodexTokenOverlay.ManualAttachmentCoordinator', $true)
$snapshotType = $assembly.GetType('CodexTokenOverlay.ManualPlacementSnapshot', $true)
$targetsType = $assembly.GetType('CodexTokenOverlay.AttachmentTargetBounds', $true)
$displayType = $assembly.GetType('CodexTokenOverlay.CollapsedDisplayMode', $true)
$gestureType = $assembly.GetType('CodexTokenOverlay.OverlayEditGestureKind', $true)
$previewPolicyType = $assembly.GetType('CodexTokenOverlay.OverlayEditPreviewLayoutPolicy', $false)
$eventArgsType = $assembly.GetType('CodexTokenOverlay.OverlayEditPreviewEventArgs', $true)
$contextType = $assembly.GetType('CodexTokenOverlay.OverlayContext', $true)
$moveDispatcherType = $assembly.GetType('CodexTokenOverlay.OverlayEditMoveDispatcher', $false)
$staticFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Static'
$instanceFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Instance'
$moveDispatcherMethod = if ($null -eq $moveDispatcherType) {
    $null
} else {
    $moveDispatcherType.GetMethod('Dispatch', $staticFlags)
}
$jsonOptions = [System.Text.Json.JsonSerializerOptions]::new()
$jsonOptions.PropertyNameCaseInsensitive = $true

function Convert-Model([string]$Json, [Type]$Type) {
    return [System.Text.Json.JsonSerializer]::Deserialize($Json, $Type, $jsonOptions)
}

$opcodeLookup = @{}
foreach ($field in [System.Reflection.Emit.OpCodes].GetFields([System.Reflection.BindingFlags]'Public, Static')) {
    $opcode = $field.GetValue($null)
    $value = [int]$opcode.Value
    if ($value -lt 0) { $value += 65536 }
    $opcodeLookup[$value] = $opcode
}

function Get-MethodInstructions([System.Reflection.MethodInfo]$Method) {
    if ($null -eq $Method -or $null -eq $Method.GetMethodBody()) {
        return
    }

    $bytes = $Method.GetMethodBody().GetILAsByteArray()
    $offset = 0
    while ($offset -lt $bytes.Length) {
        $instructionOffset = $offset
        $first = [int]$bytes[$offset]
        $offset++
        $value = if ($first -eq 0xFE) {
            if ($offset -ge $bytes.Length) { throw "Invalid IL at offset $instructionOffset." }
            $second = [int]$bytes[$offset]
            $offset++
            0xFE00 -bor $second
        } else {
            $first
        }
        $opcode = $opcodeLookup[$value]
        if ($null -eq $opcode) { throw "Unknown IL opcode at offset $instructionOffset." }

        $operandStart = $offset
        $operandLength = switch ($opcode.OperandType.ToString()) {
            'InlineNone' { 0 }
            'ShortInlineBrTarget' { 1 }
            'ShortInlineI' { 1 }
            'ShortInlineVar' { 1 }
            'InlineVar' { 2 }
            'InlineI' { 4 }
            'InlineBrTarget' { 4 }
            'InlineField' { 4 }
            'InlineMethod' { 4 }
            'InlineSig' { 4 }
            'InlineString' { 4 }
            'InlineTok' { 4 }
            'InlineType' { 4 }
            'ShortInlineR' { 4 }
            'InlineI8' { 8 }
            'InlineR' { 8 }
            'InlineSwitch' {
                if ($offset + 4 -gt $bytes.Length) { throw "Invalid switch IL at offset $instructionOffset." }
                4 + (4 * [BitConverter]::ToInt32($bytes, $offset))
            }
            default { throw "Unsupported IL operand $($opcode.OperandType) at offset $instructionOffset." }
        }
        if ($operandStart + $operandLength -gt $bytes.Length) {
            throw "Truncated IL operand at offset $instructionOffset."
        }

        $token = if ($opcode.OperandType.ToString() -eq 'InlineMethod') {
            [BitConverter]::ToInt32($bytes, $operandStart)
        } else {
            $null
        }
        [pscustomobject]@{
            Offset = $instructionOffset
            OpCode = $opcode.Name
            MethodToken = $token
        }
        $offset += $operandLength
    }
}

function Test-MethodCalls([System.Reflection.MethodInfo]$Caller, [System.Reflection.MethodInfo]$Callee) {
    if ($null -eq $Caller -or $null -eq $Callee) {
        return $false
    }

    foreach ($instruction in @(Get-MethodInstructions $Caller)) {
        if ($null -ne $instruction.MethodToken -and $instruction.MethodToken -eq $Callee.MetadataToken) {
            return $true
        }
    }
    return $false
}

function Get-HandlerDispatcherWiring(
    [System.Reflection.MethodInfo]$Handler,
    [System.Reflection.MethodInfo]$Dispatcher,
    [System.Reflection.MethodInfo]$NativeResolver) {
    $wiring = [ordered]@{
        UsesDispatcher = $false
        ResolverCallsNative = $false
        ResolverMethodToken = $null
        IsCompletionFlag = $null
    }
    if ($null -eq $Handler -or $null -eq $Dispatcher -or $null -eq $NativeResolver) {
        return [pscustomobject]$wiring
    }

    $instructions = @(Get-MethodInstructions $Handler)
    $dispatchIndex = -1
    for ($index = 0; $index -lt $instructions.Count; $index++) {
        if ($instructions[$index].MethodToken -eq $Dispatcher.MetadataToken) {
            $dispatchIndex = $index
            break
        }
    }
    if ($dispatchIndex -lt 0) {
        return [pscustomobject]$wiring
    }

    $wiring.UsesDispatcher = $true
    if ($dispatchIndex -gt 0) {
        $wiring.IsCompletionFlag = switch ($instructions[$dispatchIndex - 1].OpCode) {
            'ldc.i4.0' { $false }
            'ldc.i4.1' { $true }
            default { $null }
        }
    }

    for ($index = $dispatchIndex - 1; $index -ge 0; $index--) {
        $instruction = $instructions[$index]
        if ($instruction.OpCode -ne 'ldftn' -or $null -eq $instruction.MethodToken) {
            continue
        }

        $resolverMethod = $Handler.Module.ResolveMethod($instruction.MethodToken)
        if ($resolverMethod -is [System.Reflection.MethodInfo]) {
            $wiring.ResolverMethodToken = $resolverMethod.MetadataToken
            $wiring.ResolverCallsNative = Test-MethodCalls $resolverMethod $NativeResolver
        }
        break
    }
    return [pscustomobject]$wiring
}

$targets = Convert-Model '{"MainHandle":100,"MainBounds":{"X":100,"Y":200,"Width":800,"Height":600},"WorkingArea":{"X":0,"Y":0,"Width":1920,"Height":1080},"Dpi":96}' $targetsType
$mainOriginal = Convert-Model '{"Enabled":true,"MainAttachment":{"ReferencePoint":2,"OffsetXDip":-112,"OffsetYDip":24},"ScalePercent":100}' $snapshotType
$disabledOriginal = Convert-Model '{"Enabled":false,"MainAttachment":{"ReferencePoint":4,"OffsetXDip":-15,"OffsetYDip":7},"ScalePercent":91}' $snapshotType

$saveCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$saveEvents = @(
    $saveCoordinator.BeginEdit($mainOriginal, $targets)
    $saveCoordinator.CompleteMove($targets, [Drawing.Point]::new(850, 750), [Drawing.Point]::new(840, 740), $true)
    $saveCoordinator.PreviewResize($targets, [Drawing.Point]::new(750, 700), 73, [Enum]::ToObject($displayType, 0))
    $saveCoordinator.Commit()
)

$cancelCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$cancelEvents = @(
    $cancelCoordinator.BeginEdit($disabledOriginal, $targets)
    $cancelCoordinator.CompleteMove($targets, [Drawing.Point]::new(750, 350), [Drawing.Point]::new(750, 350), $true)
    $cancelCoordinator.Cancel()
)

$blankCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$blankEvents = @(
    $blankCoordinator.BeginEdit($mainOriginal, $targets)
    $blankCoordinator.CompleteMove($targets, [Drawing.Point]::new(850, 750), [Drawing.Point]::new(840, 740), $true)
    $blankCoordinator.CompleteMove($targets, [Drawing.Point]::new(870, 230), [Drawing.Point]::new(50, 50), $false)
)

$movePreviewCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$null = $movePreviewCoordinator.BeginEdit($mainOriginal, $targets)
$null = $movePreviewCoordinator.CompleteMove($targets, [Drawing.Point]::new(850, 750), [Drawing.Point]::new(840, 740), $true)
$movePreviewCoordinator.BeginGesturePreview()
$validMovePreview = $movePreviewCoordinator.PreviewMove(
    $targets,
    [Drawing.Point]::new(870, 230),
    [Drawing.Point]::new(700, 650),
    $true)
$draftBeforeInvalidPreview = $validMovePreview.Draft | ConvertTo-Json -Compress -Depth 8
$invalidMovePreview = $movePreviewCoordinator.PreviewMove(
    $targets,
    [Drawing.Point]::new(870, 230),
    [Drawing.Point]::new(50, 50),
    $false)
$previewLayoutMethod = if ($null -eq $previewPolicyType) {
    $null
} else {
    $previewPolicyType.GetMethod(
        'ShouldApplyLayout',
        [System.Reflection.BindingFlags]'Public, NonPublic, Static')
}
$validPreviewAppliesLayout = if ($null -eq $previewLayoutMethod) {
    $null
} else {
    [bool]$previewLayoutMethod.Invoke($null, @(
        [Enum]::ToObject($gestureType, 0),
        $validMovePreview))
}
$invalidPreviewAppliesLayout = if ($null -eq $previewLayoutMethod) {
    $null
} else {
    [bool]$previewLayoutMethod.Invoke($null, @(
        [Enum]::ToObject($gestureType, 0),
        $invalidMovePreview))
}

$refreshCoordinator = [System.Activator]::CreateInstance($coordinatorType)
$null = $refreshCoordinator.BeginEdit($mainOriginal, $targets)
$refreshBeforeGesture = @{
    Apply = $refreshCoordinator.ShouldApplyStaticDraft
    Highlight = $refreshCoordinator.ShouldShowStaticHighlight
}
$refreshCoordinator.BeginGesturePreview()
$refreshDuringGesture = @{
    Apply = $refreshCoordinator.ShouldApplyStaticDraft
    Highlight = $refreshCoordinator.ShouldShowStaticHighlight
}
$refreshCoordinator.EndGesturePreview()
$refreshAfterGesture = @{
    Apply = $refreshCoordinator.ShouldApplyStaticDraft
    Highlight = $refreshCoordinator.ShouldShowStaticHighlight
}
$null = $refreshCoordinator.CompleteMove(
    $targets,
    [Drawing.Point]::new(50, 50),
    [Drawing.Point]::new(50, 50),
    $false)
$refreshAfterInvalidMove = @{
    Apply = $refreshCoordinator.ShouldApplyStaticDraft
    Highlight = $refreshCoordinator.ShouldShowStaticHighlight
}

$previewHandler = $contextType.GetMethod('HandleEditPreviewChanged', $instanceFlags)
$completionHandler = $contextType.GetMethod('HandleEditGestureCompleted', $instanceFlags)
$nativeResolverMethod = $contextType.GetMethod('IsCursorOnKnownHost', $instanceFlags)
$previewHandlerWiring = Get-HandlerDispatcherWiring $previewHandler $moveDispatcherMethod $nativeResolverMethod
$completionHandlerWiring = Get-HandlerDispatcherWiring $completionHandler $moveDispatcherMethod $nativeResolverMethod
$previewDispatch = $null
$completionDispatchFalse = $null
$completionDispatchTrue = $null
$falseResolverPoints = [System.Collections.Generic.List[Drawing.Point]]::new()
$trueResolverPoints = [System.Collections.Generic.List[Drawing.Point]]::new()
if ($null -ne $moveDispatcherMethod) {
    $falseResolver = [Func[Drawing.Point,bool]] {
        param([Drawing.Point]$point)
        $falseResolverPoints.Add($point)
        return $false
    }
    $trueResolver = [Func[Drawing.Point,bool]] {
        param([Drawing.Point]$point)
        $trueResolverPoints.Add($point)
        return $true
    }
    $moveEvent = [System.Activator]::CreateInstance($eventArgsType, @(
        [Enum]::ToObject($gestureType, 0),
        [Drawing.Point]::new(150, 250),
        [Drawing.Point]::new(0, 0),
        100))

    $previewDispatchCoordinator = [System.Activator]::CreateInstance($coordinatorType)
    $null = $previewDispatchCoordinator.BeginEdit($mainOriginal, $targets)
    $previewDispatchCoordinator.BeginGesturePreview()
    $previewDispatch = $moveDispatcherMethod.Invoke($null, @(
        $previewDispatchCoordinator,
        $targets,
        $moveEvent,
        [Drawing.Point]::new(160, 260),
        $falseResolver,
        $false))

    $completionFalseCoordinator = [System.Activator]::CreateInstance($coordinatorType)
    $null = $completionFalseCoordinator.BeginEdit($mainOriginal, $targets)
    $completionDispatchFalse = $moveDispatcherMethod.Invoke($null, @(
        $completionFalseCoordinator,
        $targets,
        $moveEvent,
        [Drawing.Point]::new(160, 260),
        $falseResolver,
        $true))

    $completionTrueCoordinator = [System.Activator]::CreateInstance($coordinatorType)
    $null = $completionTrueCoordinator.BeginEdit($mainOriginal, $targets)
    $completionDispatchTrue = $moveDispatcherMethod.Invoke($null, @(
        $completionTrueCoordinator,
        $targets,
        $moveEvent,
        [Drawing.Point]::new(160, 260),
        $trueResolver,
        $true))
}

$result = @{
    SaveMainBottomRightAndResize = $saveEvents
    CancelRestoresDisabledOriginal = $cancelEvents
    BlankMoveKeepsLastValidDraft = $blankEvents
    ValidMovePreview = $validMovePreview
    InvalidMovePreview = $invalidMovePreview
    DraftBeforeInvalidPreview = $draftBeforeInvalidPreview
    GesturePreviewStillActive = $movePreviewCoordinator.IsEditing
    HasPreviewLayoutPolicy = $null -ne $previewLayoutMethod
    ValidPreviewAppliesLayout = $validPreviewAppliesLayout
    InvalidPreviewAppliesLayout = $invalidPreviewAppliesLayout
    RefreshBeforeGesture = $refreshBeforeGesture
    RefreshDuringGesture = $refreshDuringGesture
    RefreshAfterGesture = $refreshAfterGesture
    RefreshAfterInvalidMove = $refreshAfterInvalidMove
    HasMoveDispatcher = $null -ne $moveDispatcherMethod
    PreviewHandlerUsesDispatcher = $previewHandlerWiring.UsesDispatcher
    CompletionHandlerUsesDispatcher = $completionHandlerWiring.UsesDispatcher
    PreviewResolverCallsNative = $previewHandlerWiring.ResolverCallsNative
    CompletionResolverCallsNative = $completionHandlerWiring.ResolverCallsNative
    PreviewResolverMethodToken = $previewHandlerWiring.ResolverMethodToken
    CompletionResolverMethodToken = $completionHandlerWiring.ResolverMethodToken
    PreviewIsCompletionFlag = $previewHandlerWiring.IsCompletionFlag
    CompletionIsCompletionFlag = $completionHandlerWiring.IsCompletionFlag
    PreviewDispatch = $previewDispatch
    CompletionDispatchFalse = $completionDispatchFalse
    CompletionDispatchTrue = $completionDispatchTrue
    FalseResolverCallCount = $falseResolverPoints.Count
    TrueResolverCallCount = $trueResolverPoints.Count
    FalseResolverPoints = $falseResolverPoints
    TrueResolverPoints = $trueResolverPoints
}
[System.IO.File]::WriteAllText(
    $OutputPath,
    ($result | ConvertTo-Json -Depth 12),
    [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText(
        $probeScriptPath,
        $probeScript,
        [System.Text.UTF8Encoding]::new($false))

    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $argumentString `
            -WindowStyle Hidden `
            -PassThru
        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw 'Проверка ручной привязки окна не завершилась за 10 секунд.'
        }
        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'Ошибка при проверке ручной привязки окна.'
        }
        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

function Invoke-AnchorStateReflectionProbe {
    $probeScriptPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-anchor-state-probe.ps1")
    $outputPath = Join-Path $testRoot ("$([Guid]::NewGuid().ToString('N'))-anchor-state-output.json")
    $probeScript = @'
param([string]$ApplicationDll, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
$assembly = [System.Reflection.Assembly]::LoadFrom($ApplicationDll)
$type = $assembly.GetType('CodexTokenOverlay.OverlayAnchorTargetState', $true)
$interactionType = $assembly.GetType('CodexTokenOverlay.OverlayInteractionState', $true)
$referenceType = $assembly.GetType('CodexTokenOverlay.AttachmentReferencePoint', $true)
$method = @($type.GetMethods() | Where-Object {
    $_.Name -eq 'ObserveAndCollapse' -and $_.GetParameters().Count -eq 3
})[0]

function Test-Collapse(
    [long]$FirstHost,
    [int]$FirstReference,
    [long]$SecondHost,
    [int]$SecondReference) {
    if ($null -eq $method) {
        return $false
    }
    $state = [System.Activator]::CreateInstance($type)
    $interaction = [System.Activator]::CreateInstance($interactionType)
    $null = $interaction.OnCapsuleMouseUp()
    $null = $method.Invoke($state, @(
        $FirstHost,
        [Enum]::ToObject($referenceType, $FirstReference),
        $interaction))
    return [bool]$method.Invoke($state, @(
        $SecondHost,
        [Enum]::ToObject($referenceType, $SecondReference),
        $interaction))
}

$result = @{
    HasMainOnlyObserveMethod = $null -ne $method
    BoundsOnlyMovementStaysExpanded = Test-Collapse 100 2 100 2
    HostHandleChangeCollapses = Test-Collapse 100 2 101 2
    ReferencePointChangeCollapses = Test-Collapse 100 2 100 7
}
[System.IO.File]::WriteAllText(
    $OutputPath,
    ($result | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false))
'@
    [System.IO.File]::WriteAllText($probeScriptPath, $probeScript, [System.Text.UTF8Encoding]::new($false))
    $probeProcess = $null
    try {
        $powershellPath = (Get-Process -Id $PID).Path
        $argumentString = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ApplicationDll "{1}" -OutputPath "{2}"' -f `
            $probeScriptPath.Replace('"', '\"'), `
            $applicationDll.Replace('"', '\"'), `
            $outputPath.Replace('"', '\"')
        $probeProcess = Start-Process -FilePath $powershellPath -ArgumentList $argumentString -WindowStyle Hidden -PassThru
        if (-not $probeProcess.WaitForExit(10000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
            throw 'Проверка идентификатора окна привязки не завершилась за 10 секунд.'
        }
        if ($probeProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'Ошибка при проверке идентификатора окна привязки.'
        }
        return Get-Content -LiteralPath $outputPath -Encoding UTF8 -Raw | ConvertFrom-Json
    }
    finally {
        if ($null -ne $probeProcess) {
            try {
                if (-not $probeProcess.HasExited) {
                    $probeProcess.Kill()
                    $probeProcess.WaitForExit()
                }
            }
            finally {
                $probeProcess.Dispose()
            }
        }
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    & $DotnetPath build $projectPath -c Release --nologo "-p:TargetFramework=$TargetFramework"
    if ($LASTEXITCODE -ne 0) {
        throw 'Не удалось собрать проект.'
    }

    if ($areas -contains 'Theme') {
        $assembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
        $kindType = $assembly.GetType('CodexTokenOverlay.OverlayThemeKind', $false)
        $sourceType = $assembly.GetType('CodexTokenOverlay.WindowsOverlayThemeSource', $false)
        $paletteType = $assembly.GetType('CodexTokenOverlay.OverlayThemePalette', $false)
        Assert-Condition `
            ($null -ne $kindType -and $null -ne $sourceType -and $null -ne $paletteType) `
            'Должны существовать контракты перечисления тем, палитры и разрешения значений Windows.'

        $staticFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Static'
        $resolveKind = $sourceType.GetMethod('ResolveKind', $staticFlags)
        $readKind = $sourceType.GetMethod('ReadKind', $staticFlags)
        $paletteFor = $paletteType.GetMethod('For', $staticFlags)
        Assert-Condition `
            ($null -ne $resolveKind -and $null -ne $readKind -and $null -ne $paletteFor) `
            'Должна быть доступна чисто логическая запись темы.'

        function Invoke-ResolveThemeKind([object]$Value) {
            $arguments = [object[]]::new(1)
            $arguments[0] = $Value
            return $resolveKind.Invoke($null, $arguments).ToString()
        }

        Assert-Condition ((Invoke-ResolveThemeKind 0) -eq 'Dark') 'При AppsUseLightTheme=0 ожидается тёмная тема.'
        Assert-Condition ((Invoke-ResolveThemeKind 1) -eq 'Light') 'При AppsUseLightTheme=1 ожидается светлая тема.'
        Assert-Condition ((Invoke-ResolveThemeKind 2) -eq 'Light') 'При ненулевом DWORD ожидается светлая тема.'
        Assert-Condition ((Invoke-ResolveThemeKind $null) -eq 'Dark') 'Отсутствующий параметр реестра необходимо откатить до темного.'
        Assert-Condition ((Invoke-ResolveThemeKind '1') -eq 'Dark') 'Нечисловые значения реестра должны вернуться к Dark.'

        $throwingRead = [Func[object]] {
            throw [UnauthorizedAccessException]::new('denied')
        }
        $readArguments = [object[]]::new(1)
        $readArguments[0] = $throwingRead
        $fallbackKind = $readKind.Invoke($null, $readArguments).ToString()
        Assert-Condition ($fallbackKind -eq 'Dark') 'Исключение чтения реестра необходимо вернуть в Dark.'

        $darkKind = [Enum]::Parse($kindType, 'Dark')
        $lightKind = [Enum]::Parse($kindType, 'Light')
        $dark = $paletteFor.Invoke($null, @($darkKind))
        $light = $paletteFor.Invoke($null, @($lightKind))
        $propertyNames = @(
            'Background', 'Label', 'Value', 'Accent', 'Border', 'Divider',
            'ProgressTrack', 'ProgressStart', 'ProgressEnd', 'TargetHighlight')
        $expectedDark = @(
            [Drawing.Color]::FromArgb(36, 38, 45),
            [Drawing.Color]::FromArgb(157, 161, 170),
            [Drawing.Color]::FromArgb(245, 245, 247),
            [Drawing.Color]::FromArgb(185, 174, 255),
            [Drawing.Color]::FromArgb(36, 255, 255, 255),
            [Drawing.Color]::FromArgb(80, 84, 93),
            [Drawing.Color]::FromArgb(70, 74, 83),
            [Drawing.Color]::FromArgb(142, 126, 255),
            [Drawing.Color]::FromArgb(181, 169, 255),
            [Drawing.Color]::FromArgb(142, 126, 255))
        $expectedLight = @(
            [Drawing.Color]::FromArgb(244, 244, 246),
            [Drawing.Color]::FromArgb(92, 96, 105),
            [Drawing.Color]::FromArgb(28, 29, 33),
            [Drawing.Color]::FromArgb(91, 72, 190),
            [Drawing.Color]::FromArgb(32, 0, 0, 0),
            [Drawing.Color]::FromArgb(208, 210, 216),
            [Drawing.Color]::FromArgb(221, 222, 227),
            [Drawing.Color]::FromArgb(111, 91, 218),
            [Drawing.Color]::FromArgb(150, 132, 232),
            [Drawing.Color]::FromArgb(111, 91, 218))
        for ($index = 0; $index -lt $propertyNames.Count; $index++) {
            $property = $propertyNames[$index]
            $darkArgb = $dark.$property.ToArgb()
            $lightArgb = $light.$property.ToArgb()
            Assert-Condition ($darkArgb -eq $expectedDark[$index].ToArgb()) "Неправильный темный цвет $property. фактическое=$darkArgb"
            Assert-Condition ($lightArgb -eq $expectedLight[$index].ToArgb()) "Цвет освещения $property неправильный. фактическое=$lightArgb"
            Assert-Condition ($dark.$property -ne [Drawing.Color]::Fuchsia) "В тёмной теме цвет $property совпал с ключевым цветом прозрачности."
            Assert-Condition ($light.$property -ne [Drawing.Color]::Fuchsia) "В светлой теме цвет $property совпал с ключевым цветом прозрачности."
        }
        Assert-Condition ($dark.Background -ne $light.Background) 'Светлый и темный фоны должны быть разными.'
        Assert-Condition ($dark.Value -ne $light.Value) 'Числовые цвета светлого и темного цвета должны различаться.'

        $sourceContract = $assembly.GetType('CodexTokenOverlay.IOverlayThemeSource', $false)
        $bindingType = $assembly.GetType('CodexTokenOverlay.OverlayThemeBinding', $false)
        Assert-Condition `
            ($null -ne $sourceContract -and $null -ne $bindingType) `
            'Должен существовать исходный код темы и контракт привязки пользовательского интерфейса.'

        $themeResponse = Invoke-JsonProbe '--theme-probe' @()
        $theme = Get-ProbeCase $themeResponse 'theme-lifecycle'
        Assert-Condition $theme.Supported 'При проверке жизненного цикла темы необходимо использовать реальный источник/привязку.'
        Assert-Condition $theme.SourceInitialDark 'В источниках тем Windows изначально должен быть применен Dark.'
        Assert-Condition $theme.SourceChangedOnce 'Об изменении типа темы необходимо уведомлять ровно один раз.'
        Assert-Condition $theme.SourceSameKindIgnored 'Дублирование уведомлений одного и того же типа темы не допускается.'
        Assert-Condition $theme.SourceUnsubscribedOnce 'При выпуске источника темы Windows необходимо отменить подписку на статическую подписку ровно один раз.'
        Assert-Condition $theme.SourceDisposeIdempotent 'Повторные выпуски исходных кодов тем Windows должны быть идемпотентными.'
        Assert-Condition $theme.SourcePostDisposeIgnored 'События темы Windows после выпуска необходимо игнорировать.'
        Assert-Condition $theme.BindingInitialDark 'Привязки должны быть изначально применены к Dark в потоке пользовательского интерфейса.'
        Assert-Condition $theme.BindingBackgroundLightOnUiThread 'Обновления фоновой темы должны применять Light к потоку пользовательского интерфейса.'
        Assert-Condition $theme.BindingSameKindIgnored 'Привязки должны объединять повторяющиеся события для одной темы.'
        Assert-Condition $theme.BindingQueuedCallbackCancelledOnDispose 'Обратные вызовы пользовательского интерфейса в очереди должны быть признаны недействительными после выпуска.'
        Assert-Condition $theme.BindingUnsubscribedBeforeSourceDispose 'Привязка должна сначала освободить событие, а затем освободить источник темы.'
        Assert-Condition $theme.FormsSupported 'Обе формы должны поддерживать ApplyTheme.'
        Assert-Condition $theme.FormsInitialDark 'К двум скрытым формам изначально должен быть применен Dark.'
        Assert-Condition $theme.FormsBackgroundLightOnUiThread 'Изменения фона должны применять Light к обеим формам в потоке пользовательского интерфейса.'
        Assert-Condition $theme.FormsStateUnchanged 'Изменения темы не должны изменять границы, макет, отображаемые данные, статус редактирования или видимость.'
        Assert-Condition $theme.FormsSameKindIgnored 'Одно и то же событие темы не должно генерировать второй переход состояния рисования формы.'
        Assert-Condition $theme.FormsSurviveTokenHandleRecreation 'Изменения фоновой темы до и после перестроения дескриптора состояния редактирования по-прежнему должны применяться.'
        Assert-Condition $theme.FormsPostDisposeIgnored 'События темы после освобождения привязки не должны менять форму.'
        Assert-Condition $theme.NoBackgroundException 'События фоновой темы, обработка конкуренции и выпуск не должны исключать исключений.'

        $instanceFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Instance'
        $contextType = $assembly.GetType('CodexTokenOverlay.OverlayContext', $true)
        $themeBindingField = $contextType.GetField('_themeBinding', $instanceFlags)
        $contextThemeApply = $contextType.GetMethod('ApplyTheme', $instanceFlags)
        Assert-Condition `
            ($null -ne $themeBindingField -and $themeBindingField.FieldType -eq $bindingType -and $null -ne $contextThemeApply) `
            'OverlayContext должен содержать уникальную привязку темы и обеспечивать обратные вызовы приложения двойной формы.'

        $formApplyTheme = $assembly.GetType('CodexTokenOverlay.TokenStripForm', $true).GetMethod('ApplyTheme', $instanceFlags)
        $highlightApplyTheme = $assembly.GetType('CodexTokenOverlay.AttachmentTargetHighlightForm', $true).GetMethod('ApplyTheme', $instanceFlags)
        Assert-Condition `
            (Test-MethodCallChain $contextThemeApply @($formApplyTheme, $highlightApplyTheme) 6) `
            'Обратный вызов темы OverlayContext должен применять одну и ту же цветовую палитру к основной форме и выделенной форме.'

        $contextConstructor = @($contextType.GetConstructors($instanceFlags) | Where-Object {
            $_.GetParameters().Count -eq 2
        })[0]
        $constructorCalls = @(
            foreach ($token in @(Get-MethodCallTokens $contextConstructor)) {
                $contextConstructor.Module.ResolveMethod($token)
            })
        $handleGetterIndex = -1
        $bindingConstructorIndex = -1
        for ($index = 0; $index -lt $constructorCalls.Count; $index++) {
            $call = $constructorCalls[$index]
            if ($call.DeclaringType.FullName -eq 'System.Windows.Forms.Control' -and $call.Name -eq 'get_Handle') {
                $handleGetterIndex = $index
            }
            if ($call.DeclaringType -eq $bindingType -and $call.Name -eq '.ctor') {
                $bindingConstructorIndex = $index
                break
            }
        }
        Assert-Condition `
            ($handleGetterIndex -ge 0 -and $bindingConstructorIndex -gt $handleGetterIndex) `
            'OverlayContext должен сначала создать стабильный дескриптор диспетчера выделения, а затем создать привязку темы.'

        $contextDispose = $contextType.GetMethod('DisposeThemeAndForms', $instanceFlags)
        $disposeCalls = @(
            foreach ($token in @(Get-MethodCallTokens $contextDispose)) {
                $contextDispose.Module.ResolveMethod($token)
            })
        $themeDisposeIndex = -1
        $formDisposeIndexes = @()
        for ($index = 0; $index -lt $disposeCalls.Count; $index++) {
            $call = $disposeCalls[$index]
            if ($call.DeclaringType -eq $bindingType -and $call.Name -eq 'Dispose') { $themeDisposeIndex = $index }
            if ($call.DeclaringType.FullName -eq 'System.ComponentModel.Component' -and $call.Name -eq 'Dispose') {
                $formDisposeIndexes += $index
            }
        }
        Assert-Condition `
            ($themeDisposeIndex -ge 0 -and $formDisposeIndexes.Count -eq 2 -and @($formDisposeIndexes | Where-Object { $_ -gt $themeDisposeIndex }).Count -eq 2) `
            'OverlayContext должен освободить привязку темы перед обеими формами.'
    }

    if ($areas -contains 'Attachment') {
        $target = @{ X = 100; Y = 200; Width = 800; Height = 600 }
        $mainBounds = @{ X = 100; Y = 200; Width = 800; Height = 600 }
        $workingArea = @{ X = 0; Y = 0; Width = 1920; Height = 1080 }
        $assembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
        foreach ($contractName in @(
            'CodexTokenOverlay.ManualPlacementSnapshot',
            'CodexTokenOverlay.AttachmentTargetBounds',
            'CodexTokenOverlay.AttachmentTargetHit')) {
            $contract = $assembly.GetType($contractName, $true)
            foreach ($propertyName in @(
                'AttachmentTargetKind', 'ActiveTarget')) {
                Assert-Condition ($null -eq $contract.GetProperty($propertyName)) `
                    "$contractName $propertyName не должен публиковаться."
            }
        }
        Assert-Condition ($null -eq $assembly.GetType('CodexTokenOverlay.AttachmentTargetKind', $false)) `
            'Контракт главного окна не должен сохранять тип AttachmentTargetKind.'
        $response = Invoke-JsonProbe '--attachment-probe' @(
            @{ Name = 'reference-points'; Operation = 'ReferencePoints'; Target = $target; Dpi = 96 },
            @{ Name = 'center-tie'; Operation = 'SelectReferencePoint'; Target = $target; Center = @{ X = 500; Y = 500 } },
            @{ Name = 'near-top-right'; Operation = 'SelectReferencePoint'; Target = $target; Center = @{ X = 870; Y = 230 } },
            @{ Name = 'dpi-capture-roundtrip'; Operation = 'CaptureResolve'; Target = $target; Center = @{ X = 855; Y = 245 }; Dpi = 144 },
            @{
                Name = 'target-hit-testing'
                Operation = 'SelectTargets'
                Targets = @{
                    MainHandle = 100
                    MainBounds = $mainBounds
                    WorkingArea = $workingArea
                    Dpi = 96
                }
                Points = @(
                    @{ X = 870; Y = 230 },
                    @{ X = 870; Y = 230 },
                    @{ X = 50; Y = 50 }
                )
                HostSurfaceHits = @($true, $false, $false)
            },
            @{
                Name = 'scale-calculation'
                Operation = 'CalculateScales'
                Cases = @(
                    @{ StartWidth = 196; StartHeight = 34; StartScale = 100; DeltaX = -80; DeltaY = -20 },
                    @{ StartWidth = 196; StartHeight = 34; StartScale = 100; DeltaX = 59; DeltaY = 10 },
                    @{ StartWidth = 0; StartHeight = 34; StartScale = 73; DeltaX = 20; DeltaY = 20 },
                    @{ StartWidth = 196; StartHeight = -1; StartScale = 999; DeltaX = 20; DeltaY = 20 }
                )
            },
            @{
                Name = 'edit-state'
                Operation = 'EditState'
                CommitOriginal = @{
                    Enabled = $true
                    MainAttachment = @{ ReferencePoint = 2; OffsetXDip = -112; OffsetYDip = 24 }
                    ScalePercent = 100
                }
                CommitAttachment = @{ ReferencePoint = 2; OffsetXDip = -30; OffsetYDip = 40 }
                CommitScale = 73
                CancelOriginal = @{
                    Enabled = $false
                    MainAttachment = @{ ReferencePoint = 4; OffsetXDip = -15; OffsetYDip = 7 }
                    ScalePercent = 91
                }
                CancelAttachment = @{ ReferencePoint = 0; OffsetXDip = 10; OffsetYDip = 20 }
                CancelScale = 120
            }
        )

        $referencePoints = @(Get-ProbeCase $response 'reference-points').Points
        $expectedReferencePoints = @(
            @{ Kind = 0; X = 100; Y = 200 },
            @{ Kind = 1; X = 500; Y = 200 },
            @{ Kind = 2; X = 900; Y = 200 },
            @{ Kind = 3; X = 100; Y = 500 },
            @{ Kind = 4; X = 900; Y = 500 },
            @{ Kind = 5; X = 100; Y = 800 },
            @{ Kind = 6; X = 500; Y = 800 },
            @{ Kind = 7; X = 900; Y = 800 }
        )
        Assert-Condition ($referencePoints.Count -eq $expectedReferencePoints.Count) 'Ручная привязка должна выявить ровно восемь контрольных точек.'
        for ($index = 0; $index -lt $expectedReferencePoints.Count; $index++) {
            $actual = $referencePoints[$index]
            $expected = $expectedReferencePoints[$index]
            Assert-Condition `
                ($actual.Kind -eq $expected.Kind -and $actual.Point.X -eq $expected.X -and $actual.Point.Y -eq $expected.Y) `
                "Неверная контрольная точка ручной привязки $indexth."
        }
        $referenceCase = Get-ProbeCase $response 'reference-points'
        Assert-Condition $referenceCase.RejectsEmptyTarget 'API чистой привязки должен отклонять пустые целевые прямоугольники.'
        Assert-Condition $referenceCase.RejectsZeroDpi 'API привязки должен отклонять нулевой DPI.'

        Assert-Condition ((Get-ProbeCase $response 'center-tie').ReferencePoint -eq 1) 'Центральная связь должна выбирать TopCenter в порядке перечисления.'
        Assert-Condition ((Get-ProbeCase $response 'near-top-right').ReferencePoint -eq 2) 'Необходимо выбрать TopRight в правом верхнем углу.'

        $roundtrip = Get-ProbeCase $response 'dpi-capture-roundtrip'
        Assert-Condition ($roundtrip.Attachment.ReferencePoint -eq 2) 'Для захвата с разрешением 144 DPI необходимо выбрать TopRight.'
        Assert-Condition ([Math]::Abs($roundtrip.Attachment.OffsetXDip - (-30)) -lt 0.000001) 'Смещение X захвата 144 DPI должно быть -30 DIP.'
        Assert-Condition ([Math]::Abs($roundtrip.Attachment.OffsetYDip - 30) -lt 0.000001) 'Смещение по оси Y при захвате 144 DPI должно составлять 30 DIP.'
        Assert-Condition ($roundtrip.ResolvedCenter.X -eq 855 -and $roundtrip.ResolvedCenter.Y -eq 245) 'Захват с разрешением 144 DPI должен без потерь анализироваться обратно в исходный центр.'

        $hits = @(Get-ProbeCase $response 'target-hit-testing').Hits
        Assert-Condition ($hits.Count -eq 3) 'Проверка попадания в цель должна вернуть три результата.'
        Assert-Condition ($hits[0].Handle -eq 100 -and $hits[0].Bounds.X -eq 100 -and $hits[0].Bounds.Y -eq 200) 'Обращение к поверхности главного окна должно захватывать главное окно.'
        Assert-Condition ($null -eq $hits[1]) 'Захват невозможен даже внутри прямоугольника главного окна, если hostSurfaceHit=false.'
        Assert-Condition ($null -eq $hits[2]) 'Нерелевантные позиции не должны попадать ни на одну цель привязки.'

        $scales = @(Get-ProbeCase $response 'scale-calculation').Scales
        Assert-Condition (($scales -join ',') -eq '60,130,73,130') 'Расчеты масштабирования должны производиться на 60–130 границах и возвращаться к очищенному начальному масштабу при недопустимом начальном размере.'

        $edit = Get-ProbeCase $response 'edit-state'
        Assert-Condition $edit.ThrowsBeforeBegin 'Статус редактирования должен отклонять применение/фиксацию/отмену до начала.'
        Assert-Condition (-not $edit.ActiveAfterCommit) 'Статус редактирования должен быть деактивирован после фиксации.'
        Assert-Condition ($edit.Committed.Enabled -and $edit.Committed.ScalePercent -eq 73) 'Commit должен возвращать текущий масштаб уклона.'
        Assert-Condition ($edit.Committed.MainAttachment.ReferencePoint -eq 2 -and $edit.Committed.MainAttachment.OffsetXDip -eq -30 -and $edit.Committed.MainAttachment.OffsetYDip -eq 40) 'Commit должен возвращать вложение черновика главного окна.'
        Assert-Condition (-not $edit.ActiveAfterCancel) 'После отмены статус редактирования должен быть деактивирован.'
        $cancelledJson = $edit.Cancelled | ConvertTo-Json -Compress -Depth 8
        $cancelOriginalJson = $edit.CancelOriginal | ConvertTo-Json -Compress -Depth 8
        Assert-Condition ($cancelledJson -eq $cancelOriginalJson) 'Отмена Исходный неизменяемый снимок должен быть полностью восстановлен.'

        $coordinator = Invoke-ManualCoordinatorReflectionProbe

        $dispatcherBehaviorIsNativeSeamDriven = `
            ($coordinator.FalseResolverCallCount -eq 2) -and `
            ($coordinator.TrueResolverCallCount -eq 1) -and `
            (-not $coordinator.PreviewDispatch.CanSave) -and `
            ($null -eq $coordinator.PreviewDispatch.HighlightBounds) -and `
            (-not $coordinator.CompletionDispatchFalse.CanSave) -and `
            ($null -eq $coordinator.CompletionDispatchFalse.HighlightBounds) -and `
            $coordinator.CompletionDispatchTrue.CanSave -and `
            ($null -ne $coordinator.CompletionDispatchTrue.HighlightBounds) -and `
            ($coordinator.FalseResolverPoints[0].X -eq 150) -and `
            ($coordinator.FalseResolverPoints[0].Y -eq 250) -and `
            ($coordinator.TrueResolverPoints[0].X -eq 150) -and `
            ($coordinator.TrueResolverPoints[0].Y -eq 250)
        Assert-Condition `
            ($coordinator.HasMoveDispatcher -and $coordinator.PreviewHandlerUsesDispatcher -and $coordinator.CompletionHandlerUsesDispatcher -and $dispatcherBehaviorIsNativeSeamDriven) `
            "Оба обработчика перемещения должны вызывать общий диспетчер. Для предпросмотра ожидается false, для завершения — true. actual=$($coordinator | ConvertTo-Json -Compress -Depth 12)"
        Assert-Condition `
            ($coordinator.PreviewResolverCallsNative -and $coordinator.CompletionResolverCallsNative -and ($coordinator.PreviewIsCompletionFlag -eq $false) -and ($coordinator.CompletionIsCompletionFlag -eq $true)) `
            "Оба обработчика должны вызывать IsCursorOnKnownHost. Флаг завершения должен быть false для предпросмотра и true для завершения. actual=$($coordinator | ConvertTo-Json -Compress -Depth 12)"

        $saveEvents = @($coordinator.SaveMainBottomRightAndResize)
        $saved = $saveEvents[3]
        Assert-Condition (-not $saved.IsEditing) 'После сохранения координатор должен выйти из состояния редактирования.'
        Assert-Condition ($saved.Draft.Enabled -and $saved.Draft.ScalePercent -eq 73) 'При сохранении необходимо включить настройку главного окна вручную и сохранить масштаб 73%.'
        Assert-Condition ($saved.Draft.MainAttachment.ReferencePoint -eq 7) 'Опорную точку BottomRight необходимо сохранить после перемещения нижнего правого угла и масштабирования.'
        $resize = $saveEvents[2]
        Assert-Condition $resize.ShouldCollapse 'Чтобы войти в предварительный просмотр в масштабе, вы должны запросить сохранение его в свернутом виде.'
        Assert-Condition ($resize.ResolvedCenter.X -eq 834 -and $resize.ResolvedCenter.Y -eq 712) 'Масштабирование 73% должно определять центр новой капсулы из фиксированного верхнего левого угла.'

        $cancelEvents = @($coordinator.CancelRestoresDisabledOriginal)
        $cancelled = $cancelEvents[2].Draft
        Assert-Condition (-not $cancelEvents[2].IsEditing -and -not $cancelled.Enabled) 'При отмене необходимо выйти из редактирования и восстановить исходный отключенный флаг.'
        Assert-Condition ($cancelled.ScalePercent -eq 91) 'Отмена должна восстановить исходное масштабирование.'
        Assert-Condition ($cancelled.MainAttachment.ReferencePoint -eq 4 -and $cancelled.MainAttachment.OffsetXDip -eq -15 -and $cancelled.MainAttachment.OffsetYDip -eq 7) 'Отмена должна полностью восстановить вложение в главном окне.'

        $blankEvents = @($coordinator.BlankMoveKeepsLastValidDraft)
        Assert-Condition (-not $blankEvents[2].CanSave) 'Нерелевантные пустые позиции должны привести к невозможности сохранения текущего жеста.'
        Assert-Condition (($blankEvents[1].Draft | ConvertTo-Json -Compress -Depth 8) -eq ($blankEvents[2].Draft | ConvertTo-Json -Compress -Depth 8)) 'Ненужное пустое пространство не должно закрывать последний действительный черновик.'
        Assert-Condition ($blankEvents[2].ResolvedCenter.X -eq 840 -and $blankEvents[2].ResolvedCenter.Y -eq 740) 'Завершение недопустимого перемещения должно немедленно вернуться к последнему допустимому центру уклона вместо сохранения положения свободного перетаскивания на рабочем столе.'

        $validMovePreview = $coordinator.ValidMovePreview
        Assert-Condition ($validMovePreview.CanSave -and $validMovePreview.ResolvedCenter.X -eq 700 -and $validMovePreview.ResolvedCenter.Y -eq 650) 'При предварительном просмотре действительных перемещений по-прежнему должно использоваться свободное центрирование при перетаскивании.'
        Assert-Rect $validMovePreview.HighlightBounds 100 200 800 600 'При правильном предварительном просмотре перемещения должно отображаться целевое кольцо главного окна.'
        $invalidMovePreview = $coordinator.InvalidMovePreview
        Assert-Condition $invalidMovePreview.IsEditing 'Недопустимый предварительный просмотр перемещения не должен заканчивать состояние редактирования жеста.'
        Assert-Condition (-not $invalidMovePreview.CanSave) 'Предварительный просмотр перемещения с параметром hostSurfaceHit=false должен быть немедленно отменен.'
        Assert-Condition ($null -eq $invalidMovePreview.HighlightBounds) 'Предварительный просмотр перемещения с параметром hostSurfaceHit=false не должен сохранять целевое кольцо.'
        Assert-Condition (($invalidMovePreview.Draft | ConvertTo-Json -Compress -Depth 8) -eq $coordinator.DraftBeforeInvalidPreview) 'Предварительный просмотр «Недопустимый ход» не должен перезаписывать последний действительный черновик.'
        Assert-Condition ($invalidMovePreview.ResolvedCenter.X -eq 840 -and $invalidMovePreview.ResolvedCenter.Y -eq 740) 'Предварительный просмотр недопустимого перемещения должен синхронно возвращаться к последнему допустимому центру драфта.'
        Assert-Condition $coordinator.GesturePreviewStillActive 'Недопустимый предварительный просмотр перемещения не должен заканчивать предварительный просмотр жеста действия.'
        Assert-Condition $coordinator.HasPreviewLayoutPolicy 'Контекст должен предоставлять видимый шов решения макета предварительного просмотра перемещения.'
        Assert-Condition (-not $coordinator.ValidPreviewAppliesLayout) 'Действительные предварительные просмотры Move должны оставаться бесплатными, а макеты нельзя применять.'
        Assert-Condition $coordinator.InvalidPreviewAppliesLayout 'Предварительный просмотр недопустимого перемещения должен применять последний допустимый макет в том же событии.'

        Assert-Condition ($coordinator.RefreshBeforeGesture.Apply -and $coordinator.RefreshBeforeGesture.Highlight) 'Черновики статического редактирования изначально должны разрешать отслеживание меток и отображать действительные целевые кольца.'
        Assert-Condition (-not $coordinator.RefreshDuringGesture.Apply -and -not $coordinator.RefreshDuringGesture.Highlight) 'Галочка не должна перезаписывать предварительный просмотр или восстанавливать кольцо во время активного предварительного просмотра перемещения/изменения размера.'
        Assert-Condition ($coordinator.RefreshAfterGesture.Apply -and $coordinator.RefreshAfterGesture.Highlight) 'Действительные черновики должны возобновлять статическое окно после завершения жеста.'
        Assert-Condition ($coordinator.RefreshAfterInvalidMove.Apply -and -not $coordinator.RefreshAfterInvalidMove.Highlight) 'Если CanSave=false, Tick может восстановить положение уклона, но не может восстановить целевое кольцо.'
    }

    if ($areas -contains 'Settings') {
        $missingSettingsPath = Join-Path $testRoot 'missing\settings.json'
        $emptySettingsPath = Join-Path $testRoot 'empty\settings.json'
        $migratedSettingsPath = Join-Path $testRoot 'migrated\settings.json'
        $manualPlacementSettingsPath = Join-Path $testRoot 'manual-placement\settings.json'
        $response = Invoke-JsonProbe '--settings-probe' @(
            @{
                Name = 'migrate-real-old-settings'
                Operation = 'Parse'
                Json = '{"AnchorMode":2,"VisibleFields":511}'
            },
            @{
                Name = 'keep-current-old-anchor'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"AnchorMode":2,"VisibleFields":511,"CollapsedPrimaryField":1,"CollapsedSecondaryField":64}'
            },
            @{
                Name = 'existing-version-one-keeps-traditional-mode'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"AnchorMode":2,"VisibleFields":127,"CollapsedPrimaryField":1,"CollapsedSecondaryField":64}'
            },
            @{
                Name = 'swap-duplicate-slot'
                Operation = 'Select'
                Json = '{"SettingsVersion":1,"AnchorMode":3,"VisibleFields":511,"CollapsedPrimaryField":1,"CollapsedSecondaryField":64}'
                Slot = 'Primary'
                Field = 64
            },
            @{
                Name = 'repair-unknown-values'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"AnchorMode":99,"VisibleFields":1073741824,"CollapsedPrimaryField":3,"CollapsedSecondaryField":3}'
            },
            @{
                Name = 'missing-settings-file'
                Operation = 'Load'
                SettingsPath = $missingSettingsPath
            },
            @{
                Name = 'empty-settings-file'
                Operation = 'Load'
                Json = ''
                SettingsPath = $emptySettingsPath
            },
            @{
                Name = 'load-legacy-settings-and-persist'
                Operation = 'Load'
                Json = '{"AnchorMode":2,"VisibleFields":511}'
                SettingsPath = $migratedSettingsPath
            },
            @{
                Name = 'reload-migrated-settings'
                Operation = 'Load'
                SettingsPath = $migratedSettingsPath
            },
            @{
                Name = 'visible-none-becomes-total'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"VisibleFields":0}'
            },
            @{
                Name = 'visible-known-bits-survive'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"VisibleFields":1073741952}'
            },
            @{
                Name = 'existing-visible-fields-preserved'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"VisibleFields":127}'
            },
            @{
                Name = 'duplicate-valid-slots-remain-distinct'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"CollapsedPrimaryField":64,"CollapsedSecondaryField":64}'
            },
            @{
                Name = 'save-reload-isolated-settings'
                Operation = 'SaveReload'
                Json = '{"SettingsVersion":1,"AnchorMode":2,"VisibleFields":511,"CollapsedPrimaryField":64,"CollapsedSecondaryField":1}'
                SettingsPath = $migratedSettingsPath
            },
            @{
                Name = 'manual-placement-roundtrip'
                Operation = 'SaveReload'
                SettingsPath = $manualPlacementSettingsPath
                Json = '{"SettingsVersion":1,"AnchorMode":2,"VisibleFields":127,"CollapsedPrimaryField":1,"CollapsedSecondaryField":64,"ManualPlacementEnabled":true,"MainAttachment":{"ReferencePoint":2,"OffsetXDip":-112.5,"OffsetYDip":24.25},"OverlayScalePercent":73}'
            },
            @{
                Name = 'invalid-manual-placement-sanitized'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{"ReferencePoint":99,"OffsetXDip":1e99,"OffsetYDip":-1e99},"OverlayScalePercent":999}'
            },
            @{
                Name = 'empty-main-attachment-sanitized'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{}}'
            },
            @{
                Name = 'incomplete-main-missing-reference-point'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{"OffsetXDip":3.5,"OffsetYDip":22.75}}'
            },
            @{
                Name = 'incomplete-main-missing-offset-x'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{"ReferencePoint":6,"OffsetYDip":22.75}}'
            },
            @{
                Name = 'incomplete-main-missing-offset-y'
                Operation = 'Parse'
                Json = '{"SettingsVersion":1,"ManualPlacementEnabled":true,"MainAttachment":{"ReferencePoint":6,"OffsetXDip":3.5}}'
            },
            @{
                Name = 'invalid-json-defaults'
                Operation = 'Parse'
                Json = '{not json}'
            }
        )

        $migrated = Get-ProbeCase $response 'migrate-real-old-settings'
        Assert-Condition ($migrated.Settings.SettingsVersion -eq 1) 'Старые настройки не переносятся в версию 1.'
        Assert-Condition ($migrated.Settings.AnchorMode -eq 3) 'Старые настройки не переносятся в верхний правый угол строки заголовка после миграции.'
        Assert-Condition ($migrated.Settings.VisibleFields -eq 511) 'Видимые поля не сохраняются после переноса старых настроек.'
        Assert-Condition ($migrated.Settings.CollapsedPrimaryField -eq 1) 'После переноса старых настроек левый индикатор отображается неправильно.'
        Assert-Condition ($migrated.Settings.CollapsedSecondaryField -eq 1024) 'После переноса старых настроек индикатор справа отображается неправильно.'
        Assert-Condition ($migrated.MustPersist -eq $true) 'Старые настройки должны быть сохранены сразу после миграции.'

        $currentOldAnchor = Get-ProbeCase $response 'keep-current-old-anchor'
        Assert-Condition ($currentOldAnchor.Settings.AnchorMode -eq 2) 'Текущая версия неправильно перезаписывает старый режим привязки, выбранный пользователем.'
        Assert-Condition ($currentOldAnchor.MustPersist -eq $false) 'Настройки текущей версии не должны вызывать запись миграции.'

        $traditionalMode = Get-ProbeCase $response 'existing-version-one-keeps-traditional-mode'
        Assert-Condition ($traditionalMode.Settings.AnchorMode -eq 2) 'Настройки версии 1 неправильно переопределяют устаревший режим привязки.'
        Assert-Condition ($traditionalMode.Settings.ManualPlacementEnabled -eq $false) 'В настройках версии 1 отсутствуют поля, добавленные вручную, и они должны оставаться в устаревшем режиме.'
        Assert-Condition ($traditionalMode.Settings.MainAttachment.ReferencePoint -eq 2) 'В настройках версии 1 отсутствуют поля, размещенные вручную, по умолчанию должна быть установлена верхняя правая контрольная точка главного окна.'
        Assert-Condition ($traditionalMode.Settings.MainAttachment.OffsetXDip -eq -366) 'В настройках версии 1 отсутствуют поля, размещенные вручную, по умолчанию должно быть установлено безопасное горизонтальное смещение главного окна.'
        Assert-Condition ($traditionalMode.Settings.MainAttachment.OffsetYDip -eq 24) 'В версии 1 отсутствует настройка полей, размещаемых вручную, по умолчанию должно быть установлено вертикальное смещение главного окна.'
        Assert-Condition ($traditionalMode.Settings.OverlayScalePercent -eq 100) 'В настройках версии 1 отсутствуют поля, размещенные вручную, по умолчанию должно быть установлено 100% масштабирование.'

        $swapped = Get-ProbeCase $response 'swap-duplicate-slot'
        Assert-Condition ($swapped.Settings.CollapsedPrimaryField -eq 64) 'Левая сторона не обновляется, когда правый индикатор выбран в качестве левого индикатора.'
        Assert-Condition ($swapped.Settings.CollapsedSecondaryField -eq 1) 'Исходный левый указатель не меняется при повторном выборе.'

        $repaired = Get-ProbeCase $response 'repair-unknown-values'
        Assert-Condition ($repaired.Settings.AnchorMode -eq 3) 'Неизвестный режим привязки не возвращается в правый верхний угол строки заголовка.'
        Assert-Condition ($repaired.Settings.VisibleFields -eq 1) 'Все неизвестные видимые поля не возвращаются в общий токен.'
        Assert-Condition ($repaired.Settings.CollapsedPrimaryField -eq 1) 'Недопустимый индикатор слева не возвращается к общему токену.'
        Assert-Condition ($repaired.Settings.CollapsedSecondaryField -eq 64) 'Неверный правый индикатор не возвращается к процентному значению контекста.'

        $missing = Get-ProbeCase $response 'missing-settings-file'
        Assert-Condition ($missing.Settings.SettingsVersion -eq 1) 'Значение по умолчанию текущей версии не используется, если файл настроек отсутствует.'
        Assert-Condition ($missing.Settings.AnchorMode -eq 3) 'Режим привязки по умолчанию неверен, если файл настроек отсутствует.'
        Assert-Condition ($missing.Settings.CollapsedPrimaryField -eq 1) 'Левый индикатор по умолчанию работает неправильно, если файл настроек отсутствует.'
        Assert-Condition ($missing.Settings.CollapsedSecondaryField -eq 1024) 'Правый индикатор по умолчанию работает неправильно, если файл настроек отсутствует.'
        Assert-Condition ($missing.Settings.ManualPlacementEnabled -eq $true) 'При отсутствии файла настроек необходимо включить размещение вручную по умолчанию.'
        Assert-Condition ($missing.Settings.MainAttachment.ReferencePoint -eq 2) 'Базовая точка главного окна по умолчанию неверна, если файл настроек отсутствует.'
        Assert-Condition ($missing.Settings.MainAttachment.OffsetXDip -eq -366 -and $missing.Settings.MainAttachment.OffsetYDip -eq 24) 'Смещение главного окна по умолчанию неверно, если файл настроек отсутствует.'
        $defaultWindowRight = 900
        $defaultCaptionButtonLeft = 730
        $defaultCaptionSafetyGap = 8
        $defaultManualCapsuleWidth = 232
        $defaultManualCapsuleRight = $defaultWindowRight +
            [int]$missing.Settings.MainAttachment.OffsetXDip +
            $defaultManualCapsuleWidth -
            [int]($defaultManualCapsuleWidth / 2)
        Assert-Condition ($defaultManualCapsuleRight -le ($defaultCaptionButtonLeft - $defaultCaptionSafetyGap)) `
            "По умолчанию верхняя правая позиция вручную закрывает кнопку строки заголовка: капсулаRight=$defaultManualCapsuleRight SafeRight=$($defaultCaptionButtonLeft - $defaultCaptionSafetyGap)."
        $maximumManualCapsuleWidth = 302
        $maximumManualCapsuleRight = $defaultWindowRight +
            [int]$missing.Settings.MainAttachment.OffsetXDip +
            $maximumManualCapsuleWidth -
            [int]($defaultManualCapsuleWidth / 2)
        Assert-Condition ($maximumManualCapsuleRight -le ($defaultCaptionButtonLeft - $defaultCaptionSafetyGap)) `
            "Верхнее правое положение по умолчанию, установленное вручную, закрывает кнопку строки заголовка при масштабе 130 %: капсулаRight=$maximumManualCapsuleRight SafeRight=$($defaultCaptionButtonLeft - $defaultCaptionSafetyGap)."
        Assert-Condition ($missing.Settings.OverlayScalePercent -eq 100) 'Неправильное масштабирование по умолчанию при отсутствии файла настроек.'
        Assert-Condition (-not (Test-Path -LiteralPath $missingSettingsPath)) 'Отсутствие файла настроек не должно вызывать запись.'

        $empty = Get-ProbeCase $response 'empty-settings-file'
        Assert-Condition ($empty.Settings.ManualPlacementEnabled -eq $true) 'Если файл настроек пуст, необходимо использовать размещение вручную по умолчанию.'
        Assert-Condition ($empty.Settings.MainAttachment.ReferencePoint -eq 2) 'Контрольная точка главного окна по умолчанию неверна, если файл настроек пуст.'
        Assert-Condition ($empty.Settings.MainAttachment.OffsetXDip -eq -366 -and $empty.Settings.MainAttachment.OffsetYDip -eq 24) 'Смещение главного окна по умолчанию неверно, если файл настроек пуст.'
        Assert-Condition ($empty.Settings.OverlayScalePercent -eq 100) 'Масштабирование по умолчанию неверно, если файл настроек пуст.'

        $loadedLegacy = Get-ProbeCase $response 'load-legacy-settings-and-persist'
        Assert-Condition ($loadedLegacy.Settings.AnchorMode -eq 3) 'Старый файл настроек не переносится в правый верхний угол строки заголовка после загрузки.'
        Assert-Condition ($loadedLegacy.MustPersist -eq $true) 'Старые файлы настроек необходимо переносить сразу после первой загрузки.'
        Assert-Condition ($loadedLegacy.Settings.ManualPlacementEnabled -eq $false) 'Традиционный режим необходимо поддерживать при загрузке и переносе старой версии без настроек версии.'
        Assert-Condition (Test-Path -LiteralPath $migratedSettingsPath -PathType Leaf) 'Старый файл настроек не сохраняется сразу после миграции.'

        $reloadedMigration = Get-ProbeCase $response 'reload-migrated-settings'
        Assert-Condition ($reloadedMigration.Settings.AnchorMode -eq 3) 'Перенесенные настройки были перезаписаны из-за ошибок после перезагрузки.'
        Assert-Condition ($reloadedMigration.MustPersist -eq $false) 'Перенесенные настройки не следует переносить повторно при перезагрузке.'
        Assert-Condition ($reloadedMigration.Settings.ManualPlacementEnabled -eq $false) 'Старая версия без настроек версии должна оставаться в устаревшем режиме после обратной записи и перезагрузки.'

        $visibleNone = Get-ProbeCase $response 'visible-none-becomes-total'
        Assert-Condition ($visibleNone.Settings.VisibleFields -eq 1) 'VisibleFields=None не возвращается к общему токену.'

        $knownBits = Get-ProbeCase $response 'visible-known-bits-survive'
        Assert-Condition ($knownBits.Settings.VisibleFields -eq 128) 'Видимое поле не удаляет неизвестные биты и не сохраняет известные биты.'

        $cacheHitRate = 512
        Assert-Condition (($missing.Settings.VisibleFields -band $cacheHitRate) -ne 0) `
            'В новых настройках по умолчанию должен отображаться коэффициент попадания в кэш.'

        $existing = Get-ProbeCase $response 'existing-visible-fields-preserved'
        Assert-Condition ($existing.Settings.VisibleFields -eq 127) `
            'Существующие поля VisibleField не должны автоматически добавляться к частоте попаданий в кэш.'

        $duplicateSlots = Get-ProbeCase $response 'duplicate-valid-slots-remain-distinct'
        Assert-Condition ($duplicateSlots.Settings.CollapsedPrimaryField -eq 64) 'Индикатор допустимого дублирования неправильно переопределяет выбор слева.'
        Assert-Condition ($duplicateSlots.Settings.CollapsedSecondaryField -eq 1) 'Индикатор эффективного повтора не возвращается к безопасному значению, отличному от левого.'

        $saveReload = Get-ProbeCase $response 'save-reload-isolated-settings'
        Assert-Condition ($saveReload.Settings.SettingsVersion -eq 1) 'Версия настройки неверна после сохранения и перезагрузки.'
        Assert-Condition ($saveReload.Settings.AnchorMode -eq 2) 'Режим привязки, переключенный пользователем, не сохраняется после сохранения и перезагрузки.'
        Assert-Condition ($saveReload.Settings.VisibleFields -eq 511) 'Видимые поля не сохраняются после сохранения и перезагрузки.'
        Assert-Condition ($saveReload.Settings.CollapsedPrimaryField -eq 64) 'Левый индикатор не сохраняется после сохранения и перезагрузки.'
        Assert-Condition ($saveReload.Settings.CollapsedSecondaryField -eq 1) 'Индикатор справа не сохраняется после сохранения и перезагрузки.'
        Assert-Condition ($saveReload.MustPersist -eq $false) 'Сохраненные настройки текущей версии не следует переносить повторно.'
        Assert-Condition (Test-Path -LiteralPath $migratedSettingsPath -PathType Leaf) 'При сохранении перезагрузки не записывается указанный путь временных настроек.'

        $manualPlacement = Get-ProbeCase $response 'manual-placement-roundtrip'
        Assert-Condition ($manualPlacement.Settings.ManualPlacementEnabled -eq $true) 'Переключатель ручного размещения не сохраняется после сохранения и перезагрузки.'
        Assert-Condition ($manualPlacement.Settings.MainAttachment.ReferencePoint -eq 2) 'Опорная точка главного окна не сохраняется после сохранения и перезагрузки.'
        Assert-Condition ($manualPlacement.Settings.MainAttachment.OffsetXDip -eq -112.5 -and $manualPlacement.Settings.MainAttachment.OffsetYDip -eq 24.25) 'Десятичное смещение главного окна не сохраняется после сохранения и перезагрузки.'
        Assert-Condition ($manualPlacement.Settings.OverlayScalePercent -eq 73) 'Масштаб не сохраняется после сохранения и перезагрузки.'
        Assert-Condition (Test-Path -LiteralPath $manualPlacementSettingsPath -PathType Leaf) 'При размещении вручную не записывается указанный путь временных настроек.'
        Assert-Condition ($manualPlacementSettingsPath.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase)) 'Путь к настройкам размещения вручную должен находиться во временном корневом каталоге теста.'
        $manualPlacementSavedJson = Get-Content -LiteralPath $manualPlacementSettingsPath -Encoding UTF8 -Raw | ConvertFrom-Json
        Assert-Condition ($manualPlacementSavedJson.MainAttachment.ReferencePoint -eq 2) 'При сохранении JSON не записывается контрольная точка главного окна.'
        Assert-Condition ($manualPlacementSavedJson.MainAttachment.OffsetXDip -eq -112.5 -and $manualPlacementSavedJson.MainAttachment.OffsetYDip -eq 24.25) 'При сохранении JSON не записывается десятичное смещение главного окна.'

        $invalidManualPlacement = Get-ProbeCase $response 'invalid-manual-placement-sanitized'
        Assert-Condition ($invalidManualPlacement.Settings.ManualPlacementEnabled -eq $true) 'Недопустимое размещение вручную не должно отключать включенный ручной режим.'
        Assert-Condition ($invalidManualPlacement.Settings.MainAttachment.ReferencePoint -eq 2) 'Недопустимое расположение главного окна должно вернуться к исходной точке по умолчанию.'
        Assert-Condition ($invalidManualPlacement.Settings.MainAttachment.OffsetXDip -eq -366 -and $invalidManualPlacement.Settings.MainAttachment.OffsetYDip -eq 24) 'Недопустимое расположение главного окна должно вернуться к смещению по умолчанию.'
        Assert-Condition ($invalidManualPlacement.Settings.OverlayScalePercent -eq 130) 'Ручное масштабирование за пределами диапазона должно быть зафиксировано на уровне 130 %.'

        $emptyAttachments = Get-ProbeCase $response 'empty-main-attachment-sanitized'
        Assert-Condition ($emptyAttachments.Settings.MainAttachment.ReferencePoint -eq 2) 'Размещенные объекты в пустом главном окне должны вернуться к контрольной точке по умолчанию.'
        Assert-Condition ($emptyAttachments.Settings.MainAttachment.OffsetXDip -eq -366 -and $emptyAttachments.Settings.MainAttachment.OffsetYDip -eq 24) 'Размещенные объекты в пустом главном окне должны вернуться к смещению по умолчанию.'

        foreach ($name in @(
            'incomplete-main-missing-reference-point',
            'incomplete-main-missing-offset-x',
            'incomplete-main-missing-offset-y')) {
            $incompleteMain = Get-ProbeCase $response $name
            Assert-Condition ($incompleteMain.Settings.MainAttachment.ReferencePoint -eq 2) "$name Контрольная точка главного окна должна быть возвращена к значению по умолчанию."
            Assert-Condition ($incompleteMain.Settings.MainAttachment.OffsetXDip -eq -366 -and $incompleteMain.Settings.MainAttachment.OffsetYDip -eq 24) "$name Смещение главного окна должно быть возвращено к значению по умолчанию."
        }

        $invalidJson = Get-ProbeCase $response 'invalid-json-defaults'
        Assert-Condition ($invalidJson.Settings.SettingsVersion -eq 1) 'Поврежденный JSON не возвращается к текущей версии по умолчанию.'
        Assert-Condition ($invalidJson.Settings.AnchorMode -eq 3) 'Поврежденный JSON не возвращается в режим привязки по умолчанию.'
        Assert-Condition ($invalidJson.Settings.CollapsedPrimaryField -eq 1) 'Неработающий JSON не возвращается к левому индикатору по умолчанию.'
        Assert-Condition ($invalidJson.Settings.CollapsedSecondaryField -eq 1024) 'Неверный JSON не возвращается к правильному индикатору по умолчанию.'
    }

    if ($areas -contains 'Presentation') {
        $snapshot = @{
            ThreadId = '11111111-2222-3333-4444-555555555555'
            LogPath = 'C:\\tmp\\codex-session.jsonl'
            TotalTokens = 128400
            InputTokens = 82100
            CachedInputTokens = 31400
            OutputTokens = 12600
            ReasoningOutputTokens = 6500
            ContextUsedTokens = 62000
            ContextWindowTokens = 200000
            UpdatedAtUtc = '2026-08-11T00:00:00Z'
        }
        $zeroSnapshot = @{
            ThreadId = '00000000-0000-0000-0000-000000000000'
            LogPath = 'C:\\tmp\\zero-session.jsonl'
            TotalTokens = 0
            InputTokens = 0
            CachedInputTokens = 0
            OutputTokens = 0
            ReasoningOutputTokens = 0
            ContextUsedTokens = 0
            ContextWindowTokens = 0
            UpdatedAtUtc = '2026-08-11T00:00:00Z'
        }
        $fieldExpectations = @(
            @{ Name = 'total'; Field = 1; CompactLabel = 'Всего'; ExpandedLabel = 'Всего токенов'; Value = '128.4k' },
            @{ Name = 'input'; Field = 2; CompactLabel = 'Вход'; ExpandedLabel = 'Входные токены'; Value = '82.1k' },
            @{ Name = 'output'; Field = 4; CompactLabel = 'Выход'; ExpandedLabel = 'Выходные токены'; Value = '12.6k' },
            @{ Name = 'cache-hit'; Field = 8; CompactLabel = 'Кэш'; ExpandedLabel = 'Токены из кэша'; Value = '31.4k' },
            @{ Name = 'cache-miss'; Field = 16; CompactLabel = 'Вне кэша'; ExpandedLabel = 'Токены вне кэша'; Value = '50.7k' },
            @{ Name = 'context'; Field = 32; CompactLabel = 'Контекст'; ExpandedLabel = 'Занято контекста'; Value = '62.0k / 200.0k' },
            @{ Name = 'context-percent'; Field = 64; CompactLabel = 'Контекст'; ExpandedLabel = 'Заполнено (%)'; Value = '31%' },
            @{ Name = 'context-remaining'; Field = 1024; CompactLabel = 'Ост.'; ExpandedLabel = 'Свободный контекст'; Value = "69$([System.Globalization.CultureInfo]::CurrentCulture.NumberFormat.NumberDecimalSeparator)0%" },
            @{ Name = 'reasoning'; Field = 128; CompactLabel = 'Рассужд.'; ExpandedLabel = 'Токены рассуждения'; Value = '6.5k' },
            @{ Name = 'thread'; Field = 256; CompactLabel = 'Чат'; ExpandedLabel = 'Чат'; Value = '1111…555555' },
            @{ Name = 'cache-hit-rate'; Field = 512; CompactLabel = 'Кэш %'; ExpandedLabel = 'Доля токенов из кэша'; Value = '38%' }
        )
        $originalCulture = [System.Globalization.CultureInfo]::CurrentCulture
        try {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            Assert-Condition ([System.Globalization.CultureInfo]::CurrentCulture.NumberFormat.NumberDecimalSeparator -eq ',') 'Региональный охват не включает десятичные культуры без точек.'
            $assembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
            $presentationBuilder = $assembly.GetType('CodexTokenOverlay.OverlayPresentationBuilder', $true)
            $formatTokenCount = $presentationBuilder.GetMethod(
                'FormatTokenCount',
                [System.Reflection.BindingFlags]'Public, Static')
            Assert-Condition ($null -ne $formatTokenCount) 'FormatTokenCount не найден.'
            $localizedLargeValue = $formatTokenCount.Invoke($null, [object[]]@([long]128400))
            $localizedMillionValue = $formatTokenCount.Invoke($null, [object[]]@([long]1200000))
            $localizedSmallValue = $formatTokenCount.Invoke($null, [object[]]@([long]999))
            Assert-Condition ($localizedLargeValue -eq '128.4k') 'Формат тысячного уровня в десятичных культурах без точек должен оставаться неизменным.'
            Assert-Condition ($localizedMillionValue -eq '1.20M') 'Формат миллиона должен оставаться неизменным в десятичных культурах без точек.'
            Assert-Condition ($localizedSmallValue -eq '999') 'Формат целых чисел в десятичных культурах, отличных от точки, должен оставаться неизменным.'
        }
        finally {
            [System.Globalization.CultureInfo]::CurrentCulture = $originalCulture
        }
        $contextBelowZeroSnapshot = @{} + $snapshot
        $contextBelowZeroSnapshot.ContextUsedTokens = -1
        $contextZeroSnapshot = @{} + $snapshot
        $contextZeroSnapshot.ContextUsedTokens = 0
        $contextHundredSnapshot = @{} + $snapshot
        $contextHundredSnapshot.ContextUsedTokens = 200000
        $contextAboveHundredSnapshot = @{} + $snapshot
        $contextAboveHundredSnapshot.ContextUsedTokens = 200001
        $cacheHitZeroSnapshot = @{} + $snapshot
        $cacheHitZeroSnapshot.InputTokens = 0
        $cacheHitZeroSnapshot.CachedInputTokens = 0
        $cacheHitNoneSnapshot = @{} + $snapshot
        $cacheHitNoneSnapshot.InputTokens = 100
        $cacheHitNoneSnapshot.CachedInputTokens = 0
        $cacheHitNegativeSnapshot = @{} + $snapshot
        $cacheHitNegativeSnapshot.InputTokens = 100
        $cacheHitNegativeSnapshot.CachedInputTokens = -1
        $cacheHitAboveHundredSnapshot = @{} + $snapshot
        $cacheHitAboveHundredSnapshot.InputTokens = 100
        $cacheHitAboveHundredSnapshot.CachedInputTokens = 200
        $cacheHitMaximumSnapshot = @{} + $snapshot
        $cacheHitMaximumSnapshot.InputTokens = [long]::MaxValue
        $cacheHitMaximumSnapshot.CachedInputTokens = [long]::MaxValue
        $presentationCases = @(
            @{
                Name = 'primary-secondary'
                Operation = 'Create'
                Snapshot = $snapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'valid-zero'
                Operation = 'Create'
                Snapshot = $zeroSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'waiting'
                Operation = 'Waiting'
                StatusText = 'Ожидание данных сеанса.'
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'context-below-zero'
                Operation = 'Create'
                Snapshot = $contextBelowZeroSnapshot
                PrimaryField = 64
                SecondaryField = 1
                VisibleFields = 1023
            },
            @{
                Name = 'context-zero'
                Operation = 'Create'
                Snapshot = $contextZeroSnapshot
                PrimaryField = 64
                SecondaryField = 1
                VisibleFields = 1023
            },
            @{
                Name = 'context-hundred'
                Operation = 'Create'
                Snapshot = $contextHundredSnapshot
                PrimaryField = 64
                SecondaryField = 1
                VisibleFields = 1023
            },
            @{
                Name = 'context-above-hundred'
                Operation = 'Create'
                Snapshot = $contextAboveHundredSnapshot
                PrimaryField = 64
                SecondaryField = 1
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-zero'
                Operation = 'Create'
                Snapshot = $cacheHitZeroSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-none'
                Operation = 'Create'
                Snapshot = $cacheHitNoneSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-negative'
                Operation = 'Create'
                Snapshot = $cacheHitNegativeSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-above-hundred'
                Operation = 'Create'
                Snapshot = $cacheHitAboveHundredSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            },
            @{
                Name = 'cache-hit-maximum'
                Operation = 'Create'
                Snapshot = $cacheHitMaximumSnapshot
                PrimaryField = 1
                SecondaryField = 64
                VisibleFields = 1023
            }
        )
        foreach ($expectedField in $fieldExpectations) {
            $presentationCases += @{
                Name = "field-$($expectedField.Name)"
                Operation = 'Create'
                Snapshot = $snapshot
                PrimaryField = if ($expectedField.Field -eq 512) { 1 } else { $expectedField.Field }
                SecondaryField = if ($expectedField.Field -eq 64) { 1 } else { 64 }
                VisibleFields = 1023
            }
        }

        $response = Invoke-JsonProbe '--presentation-probe' $presentationCases
        $selected = (Get-ProbeCase $response 'primary-secondary').Presentation
        Assert-Condition ($selected.Primary.CompactLabel -eq 'Всего') 'Подпись компактного основного показателя неверна.'
        Assert-Condition ($selected.Primary.ExpandedLabel -eq 'Всего токенов') 'Неверная подпись основного показателя в раскрытой панели.'
        Assert-Condition ($selected.Primary.Value -eq '128.4k') 'Неверный формат значения основного индикатора.'
        Assert-Condition ($selected.Secondary.CompactLabel -eq 'Контекст') 'Подпись компактного вторичного показателя неверна.'
        Assert-Condition ($selected.Secondary.ExpandedLabel -eq 'Заполнено (%)') 'Подпись развернутого вторичного показателя неверна.'
        Assert-Condition ($selected.Secondary.Value -eq '31%') 'Неверный формат значения вторичного индикатора.'
        Assert-Condition ($selected.ContextPercent -eq 31) 'Неверное процентное значение контекста.'
        Assert-Condition ($selected.ShowContextProgress -eq $true) 'Прогресс должен отображаться, когда виден процент контекста.'
        Assert-Condition (@($selected.ExpandedRows | Where-Object { $_.Field -eq 1 -or $_.Field -eq 64 }).Count -eq 0) 'Развернутая строка дублирует индикатор свертывания.'
        $contextRow = @($selected.ExpandedRows | Where-Object { $_.Field -eq 32 })
        Assert-Condition ($contextRow.Count -eq 1 -and $contextRow[0].Value -eq '62.0k / 200.0k') 'Неверный формат контекстной строки.'
        Assert-Condition (@($selected.ExpandedRows | ForEach-Object Field) -join ',' -eq '2,4,8,512,16,32,128,256') 'Неправильный порядок расширенных строк или дедупликации.'

        $zero = (Get-ProbeCase $response 'valid-zero').Presentation
        Assert-Condition ($zero.Primary.Value -eq '0' -and $zero.Primary.HasValue -eq $true) 'Допустимое нулевое значение должно отображаться как 0.'
        Assert-Condition ($zero.Secondary.Value -eq '—' -and $zero.Secondary.HasValue -eq $false) 'Нулевая занятость не может отображаться, если контекстное окно неизвестно.'

        $waiting = (Get-ProbeCase $response 'waiting').Presentation
        Assert-Condition ($waiting.StatusText -eq 'Ожидание данных сеанса.') 'Неправильный текст состояния ожидания.'
        Assert-Condition ($waiting.ShowContextProgress -eq $false) 'В состоянии ожидания не должно отображаться прогресс контекста.'
        $waitingMetrics = @($waiting.Primary; $waiting.Secondary; $waiting.ExpandedRows)
        Assert-Condition (@($waitingMetrics | Where-Object { $_.Value -ne '—' -or $_.HasValue }).Count -eq 0) 'Индикатор состояния ожидания должен быть пустым заполнителем.'
        $waitingCacheHitRate = @($waiting.ExpandedRows | Where-Object { $_.Field -eq 512 })
        Assert-Condition ($waitingCacheHitRate.Count -eq 1 -and $waitingCacheHitRate[0].Value -eq '—' -and -not $waitingCacheHitRate[0].HasValue) 'доля токенов из кэша ожидания должна быть пустым заполнителем.'

        foreach ($expectedField in $fieldExpectations) {
            $presentation = (Get-ProbeCase $response "field-$($expectedField.Name)").Presentation
            $metric = if ($expectedField.Field -eq 512) {
                @($presentation.ExpandedRows | Where-Object { $_.Field -eq 512 })
            }
            else {
                @($presentation.Primary)
            }
            Assert-Condition ($metric.Count -eq 1) "Поле $($expectedField.Name) не отображается в результатах отображения."
            Assert-Condition ($metric[0].CompactLabel -eq $expectedField.CompactLabel) "Неверная компактная подпись поля $($expectedField.Name)."
            Assert-Condition ($metric[0].ExpandedLabel -eq $expectedField.ExpandedLabel) "Неверная подпись поля $($expectedField.Name) в раскрытой панели."
            Assert-Condition ($metric[0].Value -eq $expectedField.Value) "Неверный формат значения поля $($expectedField.Name): ожидается=$($expectedField.Value), получено=$($metric[0].Value)."
            Assert-Condition ($metric[0].HasValue -eq $true) "Поле $($expectedField.Name) должно иметь значение."
        }

        foreach ($contextCase in @('context-below-zero', 'context-zero', 'context-hundred', 'context-above-hundred')) {
            $presentation = Get-ProbeCase $response $contextCase | Select-Object -ExpandProperty Presentation
            if ($contextCase -eq 'context-below-zero') {
                Assert-Condition ($presentation.Primary.Value -eq '—' -and -not $presentation.Primary.HasValue) 'Неизвестный контекст должен отображать тире.'
                Assert-Condition (-not $presentation.ShowContextProgress) 'Неизвестный контекст не должен отображать прогресс.'
                continue
            }
            $expectedPercent = switch ($contextCase) {
                'context-zero' { 0 }
                'context-hundred' { 100 }
                'context-above-hundred' { 100 }
            }
            Assert-Condition ($presentation.ContextPercent -eq $expectedPercent) "Прогресс контекста $contextCase не ограничен значениями 0–100."
            Assert-Condition ($presentation.Primary.Value -eq "$expectedPercent%") "Значение контекстного отображения для $contextCase не ограничено диапазоном 0–100%."
        }

        foreach ($cacheHitCase in @(
            @{ Name = 'cache-hit-zero'; Value = '0%' },
            @{ Name = 'cache-hit-none'; Value = '0%' },
            @{ Name = 'cache-hit-negative'; Value = '0%' },
            @{ Name = 'cache-hit-above-hundred'; Value = '100%' },
            @{ Name = 'cache-hit-maximum'; Value = '100%' })) {
            $presentation = Get-ProbeCase $response $cacheHitCase.Name | Select-Object -ExpandProperty Presentation
            $cacheHitRate = @($presentation.ExpandedRows | Where-Object { $_.Field -eq 512 })
            Assert-Condition ($cacheHitRate.Count -eq 1 -and $cacheHitRate[0].Value -eq $cacheHitCase.Value) "Неверная частота попаданий в кэш для $($cacheHitCase.Name)."
            Assert-Condition ($cacheHitRate[0].HasValue -eq $true) "Частота попадания в кэш $($cacheHitCase.Name) должна иметь значение."
        }

        $snapshotType = $assembly.GetType('CodexTokenOverlay.TokenSnapshot', $true)
        $displayFieldType = $assembly.GetType('CodexTokenOverlay.DisplayField', $true)
        $presentationBuilder = $assembly.GetType('CodexTokenOverlay.OverlayPresentationBuilder', $true)
        $createPresentation = $presentationBuilder.GetMethod(
            'Create',
            [System.Reflection.BindingFlags]'Public, Static')
        Assert-Condition ($null -ne $createPresentation) 'OverlayPresentationBuilder.Create не найден.'
        $reflectionSnapshot = [System.Activator]::CreateInstance($snapshotType, @(
            $snapshot.ThreadId,
            $snapshot.LogPath,
            [long]$snapshot.TotalTokens,
            [long]$snapshot.InputTokens,
            [long]$snapshot.CachedInputTokens,
            [long]$snapshot.OutputTokens,
            [long]$snapshot.ReasoningOutputTokens,
            [long]$snapshot.ContextUsedTokens,
            [long]$snapshot.ContextWindowTokens,
            [DateTime]::Parse(
                $snapshot.UpdatedAtUtc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)))
        $cacheHitRateField = [Enum]::ToObject($displayFieldType, 512)
        $totalField = [Enum]::ToObject($displayFieldType, 1)
        $visibleFields = [Enum]::ToObject($displayFieldType, 1023)

        $cacheHitRatePrimary = $createPresentation.Invoke(
            $null,
            [object[]]@($reflectionSnapshot, $cacheHitRateField, $totalField, $visibleFields))
        Assert-Condition ($cacheHitRatePrimary.Primary.Field -eq 512) 'Поле, в котором в качестве основного индикатора используется частота попаданий в кэш, неверно.'
        Assert-Condition ($cacheHitRatePrimary.Primary.CompactLabel -eq 'Кэш %') 'Основная подпись для доли попаданий в кэш неверна.'
        Assert-Condition ($cacheHitRatePrimary.Primary.ExpandedLabel -eq 'Доля токенов из кэша') 'Неверная подпись доли токенов из кэша для основного показателя в раскрытой панели.'
        Assert-Condition ($cacheHitRatePrimary.Primary.Value -eq '38%' -and $cacheHitRatePrimary.Primary.HasValue -eq $true) 'Неверное значение или HasValue частоты попаданий в кэш в качестве основного показателя.'
        Assert-Condition ($cacheHitRatePrimary.Secondary.Field -eq 1) 'Если в качестве основного индикатора используется частота попаданий в кэш, другой индикатор является неверным.'
        Assert-Condition (@($cacheHitRatePrimary.ExpandedRows | Where-Object { $_.Field -eq 512 -or $_.Field -eq 1 }).Count -eq 0) 'Если в качестве основного индикатора используется частота попаданий в кэш, развернутая строка не должна повторять ни один из свернутых индикаторов.'

        $cacheHitRateSecondary = $createPresentation.Invoke(
            $null,
            [object[]]@($reflectionSnapshot, $totalField, $cacheHitRateField, $visibleFields))
        Assert-Condition ($cacheHitRateSecondary.Secondary.Field -eq 512) 'Поле, в котором в качестве вторичного индикатора используется частота попаданий в кэш, неверно.'
        Assert-Condition ($cacheHitRateSecondary.Secondary.CompactLabel -eq 'Кэш %') 'Вторичная подпись для доли попаданий в кэш неверна.'
        Assert-Condition ($cacheHitRateSecondary.Secondary.ExpandedLabel -eq 'Доля токенов из кэша') 'Неверная подпись доли токенов из кэша для дополнительного показателя в раскрытой панели.'
        Assert-Condition ($cacheHitRateSecondary.Secondary.Value -eq '38%' -and $cacheHitRateSecondary.Secondary.HasValue -eq $true) 'Значение или HasValue частоты попаданий в кэш в качестве вторичного показателя неверно.'
        Assert-Condition ($cacheHitRateSecondary.Primary.Field -eq 1) 'Если в качестве вторичного показателя используется коэффициент попадания в кэш, другой показатель является неверным.'
        Assert-Condition (@($cacheHitRateSecondary.ExpandedRows | Where-Object { $_.Field -eq 512 -or $_.Field -eq 1 }).Count -eq 0) 'Если в качестве вторичного индикатора используется частота попаданий в кэш, развернутая строка не должна повторять ни один из свернутых индикаторов.'

        $allMetrics = @($selected.Primary; $selected.Secondary; $selected.ExpandedRows; $waiting.Primary; $waiting.Secondary; $waiting.ExpandedRows)
        Assert-Condition (@($allMetrics | Where-Object { $_.CompactLabel -match "[\r\n]" -or $_.ExpandedLabel -match "[\r\n]" -or $_.Value -match "[\r\n]" }).Count -eq 0) 'Поля отображения не могут содержать CR/LF.'
    }

    if ($areas -contains 'Layout') {
        $baseWindow = @{
            Handle = 4294967296
            WindowBounds = @{ X = 0; Y = 0; Width = 1200; Height = 800 }
            ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1200; Height = 800 }
            CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 46 }
            WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 1040 }
            Dpi = 96
            ChromeMetrics = @{
                CaptionButtonWidth = 50
                CaptionButtonHeight = 46
                FrameWidth = 4
                FrameHeight = 4
                PaddedBorderWidth = 2
            }
        }
        $primaryWindow = @{} + $baseWindow
        $primaryWindow.WindowBounds = @{ X = 0; Y = 0; Width = 468; Height = 800 }
        $primaryWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 468; Height = 800 }
        $primaryWindow.CaptionButtonBounds = @{ X = 318; Y = 0; Width = 150; Height = 46 }

        $narrowPrimaryWindow = @{} + $baseWindow
        $narrowPrimaryWindow.CaptionButtonBounds = @{ X = 283; Y = 0; Width = 150; Height = 46 }
        $narrowPrimaryWindow.WindowBounds = @{ X = 0; Y = 0; Width = 433; Height = 800 }
        $narrowPrimaryWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 433; Height = 800 }

        $hiddenWindow = @{} + $primaryWindow
        $hiddenWindow.CaptionButtonBounds = @{ X = 237; Y = 0; Width = 150; Height = 46 }
        $hiddenWindow.WindowBounds = @{ X = 0; Y = 0; Width = 387; Height = 800 }
        $hiddenWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 387; Height = 800 }

        $negativeWindow = @{} + $baseWindow
        $negativeWindow.WindowBounds = @{ X = -1600; Y = 100; Width = 1200; Height = 800 }
        $negativeWindow.ExtendedFrameBounds = @{ X = -1600; Y = 100; Width = 1200; Height = 800 }
        $negativeWindow.CaptionButtonBounds = @{ X = -550; Y = 100; Width = 150; Height = 46 }
        $negativeWindow.WorkingArea = @{ X = -1920; Y = 0; Width = 1920; Height = 1040 }

        $clippedWindow = @{} + $baseWindow
        $clippedWindow.WindowBounds = @{ X = -8; Y = -8; Width = 1936; Height = 1056 }
        $clippedWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1920; Height = 1040 }
        $clippedWindow.CaptionButtonBounds = @{ X = 1770; Y = 0; Width = 150; Height = 46 }
        $clippedWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 1040 }
        $partiallyOffscreenWindow = @{} + $baseWindow
        $partiallyOffscreenWindow.WindowBounds = @{ X = -400; Y = 100; Width = 1200; Height = 800 }
        $partiallyOffscreenWindow.ExtendedFrameBounds = @{ X = -400; Y = 100; Width = 1200; Height = 800 }
        $partiallyOffscreenWindow.CaptionButtonBounds = @{ X = 650; Y = 100; Width = 150; Height = 46 }

        $caption34Window = @{} + $baseWindow
        $caption34Window.CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 34 }
        $caption32Window = @{} + $baseWindow
        $caption32Window.CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 32 }
        $caption20Window = @{} + $baseWindow
        $caption20Window.CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 20 }
        $caption19Window = @{} + $baseWindow
        $caption19Window.CaptionButtonBounds = @{ X = 1050; Y = 0; Width = 150; Height = 19 }

        $fallbackWindow = @{} + $baseWindow
        $fallbackWindow.CaptionButtonBounds = $null
        $clippedFallbackWindow = @{} + $fallbackWindow
        $clippedFallbackWindow.WindowBounds = @{ X = 0; Y = -8; Width = 1200; Height = 808 }
        $clippedFallbackWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1200; Height = 800 }
        $clippedFallbackWindow.ChromeMetrics = @{
            CaptionButtonWidth = 50
            CaptionButtonHeight = 30
            FrameWidth = 4
            FrameHeight = 4
            PaddedBorderWidth = 2
        }
        $invalidFallbackWindow = @{} + $fallbackWindow
        $invalidFallbackWindow.CaptionButtonBounds = @{ X = 4000; Y = 4000; Width = 150; Height = 46 }
        $invalidFallbackWindow.ChromeMetrics = @{
            CaptionButtonWidth = 0
            CaptionButtonHeight = 0
            FrameWidth = -1
            FrameHeight = -1
            PaddedBorderWidth = -1
        }
        $dpi192FallbackWindow = @{
            Handle = 1920
            WindowBounds = @{ X = 0; Y = 0; Width = 2400; Height = 1600 }
            ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 2400; Height = 1600 }
            CaptionButtonBounds = $null
            WorkingArea = @{ X = 0; Y = 0; Width = 3840; Height = 2080 }
            Dpi = 192
            ChromeMetrics = @{ CaptionButtonWidth = 100; CaptionButtonHeight = 92; FrameWidth = 8; FrameHeight = 8; PaddedBorderWidth = 4 }
        }

        $dpi0Window = @{} + $baseWindow
        $dpi0Window.Dpi = 0

        $manualDpi192Window = @{} + $baseWindow
        $manualDpi192Window.Dpi = 192

        $compressedWindow = @{} + $baseWindow
        $compressedWindow.WindowBounds = @{ X = 0; Y = 0; Width = 1200; Height = 400 }
        $compressedWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1200; Height = 400 }
        $compressedWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 400 }
        $tooShortWindow = @{} + $compressedWindow
        $tooShortWindow.WindowBounds = @{ X = 0; Y = 0; Width = 1200; Height = 350 }
        $tooShortWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1200; Height = 350 }
        $tooShortWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 350 }

        $autoRightWindow = @{} + $baseWindow
        $autoRightWindow.WindowBounds = @{ X = 200; Y = 100; Width = 800; Height = 600 }
        $autoRightWindow.ExtendedFrameBounds = @{ X = 200; Y = 100; Width = 800; Height = 600 }
        $autoRightWindow.CaptionButtonBounds = $null
        $autoLeftWindow = @{} + $autoRightWindow
        $autoLeftWindow.WindowBounds = @{ X = 920; Y = 100; Width = 800; Height = 600 }
        $autoLeftWindow.ExtendedFrameBounds = @{ X = 920; Y = 100; Width = 800; Height = 600 }
        $autoInsideWindow = @{} + $autoRightWindow
        $autoInsideWindow.WindowBounds = @{ X = 60; Y = 100; Width = 1800; Height = 800 }
        $autoInsideWindow.ExtendedFrameBounds = @{ X = 60; Y = 100; Width = 1800; Height = 800 }
        $autoUpWindow = @{} + $autoRightWindow
        $autoUpWindow.WindowBounds = @{ X = 200; Y = 400; Width = 800; Height = 600 }
        $autoUpWindow.ExtendedFrameBounds = @{ X = 200; Y = 400; Width = 800; Height = 600 }
        $autoCompressedDownWindow = @{} + $autoRightWindow
        $autoCompressedDownWindow.WindowBounds = @{ X = 200; Y = 100; Width = 800; Height = 214 }
        $autoCompressedDownWindow.ExtendedFrameBounds = @{ X = 200; Y = 100; Width = 800; Height = 214 }
        $autoCompressedDownWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 470 }
        $autoInsideUpWindow = @{} + $autoInsideWindow
        $autoInsideUpWindow.WindowBounds = @{ X = 60; Y = 400; Width = 1800; Height = 300 }
        $autoInsideUpWindow.ExtendedFrameBounds = @{ X = 60; Y = 400; Width = 1800; Height = 300 }
        $autoInsideUpWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 700 }

        $manualNoExpansionWindow = @{} + $baseWindow
        $manualNoExpansionWindow.WorkingArea = @{ X = 0; Y = 0; Width = 1920; Height = 170 }

        $manualCaptionCollisionWindow = @{} + $baseWindow
        $manualCaptionCollisionWindow.WindowBounds = @{ X = 0; Y = 0; Width = 500; Height = 800 }
        $manualCaptionCollisionWindow.ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 500; Height = 800 }
        $manualCaptionCollisionWindow.CaptionButtonBounds = @{ X = 350; Y = 0; Width = 150; Height = 46 }

        $layoutCases = @(
            @{
                Name = 'caption-relative-to-negative-screen'
                Operation = 'ConvertCaptionBounds'
                WindowBounds = @{ X = -1600; Y = 20; Width = 1600; Height = 900 }
                RelativeBounds = @{ X = 1390; Y = 0; Width = 210; Height = 48 }
            },
            @{ Name = 'exact-collapsed'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'exact-expanded'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ClientPoints = @(@{ X = 20; Y = 20 }, @{ X = 100; Y = 20 }, @{ X = 20; Y = 80 }); ScreenPoints = @(@{ X = 762; Y = 26 }, @{ X = 842; Y = 26 }, @{ X = 762; Y = 86 }) },
            @{ Name = 'explicit-default-no-manual'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = $null; ScalePercent = 100 },
            @{ Name = 'manual-collapsed-60'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 60 },
            @{ Name = 'manual-collapsed-100'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 100 },
            @{ Name = 'manual-collapsed-130'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 130 },
            @{ Name = 'manual-collapsed-192-60'; HostWindow = $manualDpi192Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 60 },
            @{ Name = 'manual-scale-low-sanitized'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 20 },
            @{ Name = 'manual-scale-high-sanitized'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 999 },
            @{ Name = 'manual-expanded-60'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 60 },
            @{ Name = 'manual-expanded-100'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 100 },
            @{ Name = 'manual-expanded-130'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 300 }; ScalePercent = 130 },
            @{ Name = 'manual-direction-60-down'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 800 }; ScalePercent = 60 },
            @{ Name = 'manual-direction-130-up'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 800 }; ScalePercent = 130 },
            @{ Name = 'manual-outside-work-area'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 2500; Y = 1500 }; ScalePercent = 100 },
            @{ Name = 'manual-no-expansion-does-not-fall-back'; HostWindow = $manualNoExpansionWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 1000; Y = 85 }; ScalePercent = 100 },
            @{ Name = 'manual-titlebar-cannot-expand-over-caption-buttons'; HostWindow = $manualCaptionCollisionWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ManualCapsuleCenter = @{ X = 185; Y = 24 }; ScalePercent = 130 },
            @{ Name = 'hidden-scale-sanitized'; HostWindow = $hiddenWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 999 },
            @{ Name = 'legacy-system-offsets-at-scale-60'; HostWindow = $baseWindow; AnchorMode = 1; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 60 },
            @{ Name = 'primary-only'; HostWindow = $primaryWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'primary-can-expand'; HostWindow = $primaryWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'narrow-primary-115'; HostWindow = $narrowPrimaryWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'hidden-for-width'; HostWindow = $hiddenWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi-120'; HostWindow = @{ Handle = 120; WindowBounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 }; ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 }; CaptionButtonBounds = @{ X = 1313; Y = 0; Width = 187; Height = 58 }; WorkingArea = @{ X = 0; Y = 0; Width = 2400; Height = 1300 }; Dpi = 120; ChromeMetrics = @{ CaptionButtonWidth = 63; CaptionButtonHeight = 58; FrameWidth = 5; FrameHeight = 5; PaddedBorderWidth = 3 } }; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi-144'; HostWindow = @{ Handle = 144; WindowBounds = @{ X = 0; Y = 0; Width = 1800; Height = 1200 }; ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 1800; Height = 1200 }; CaptionButtonBounds = @{ X = 1575; Y = 0; Width = 225; Height = 69 }; WorkingArea = @{ X = 0; Y = 0; Width = 2880; Height = 1560 }; Dpi = 144; ChromeMetrics = @{ CaptionButtonWidth = 75; CaptionButtonHeight = 69; FrameWidth = 6; FrameHeight = 6; PaddedBorderWidth = 3 } }; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi-192'; HostWindow = @{ Handle = 192; WindowBounds = @{ X = 0; Y = 0; Width = 2400; Height = 1600 }; ExtendedFrameBounds = @{ X = 0; Y = 0; Width = 2400; Height = 1600 }; CaptionButtonBounds = @{ X = 2100; Y = 0; Width = 300; Height = 92 }; WorkingArea = @{ X = 0; Y = 0; Width = 3840; Height = 2080 }; Dpi = 192; ChromeMetrics = @{ CaptionButtonWidth = 100; CaptionButtonHeight = 92; FrameWidth = 8; FrameHeight = 8; PaddedBorderWidth = 4 } }; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'negative-display'; HostWindow = $negativeWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'clipped-maximized'; HostWindow = $clippedWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'partially-offscreen'; HostWindow = $partiallyOffscreenWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'title-fit-caption-34'; HostWindow = $caption34Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-caption-32'; HostWindow = $caption32Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-caption-20'; HostWindow = $caption20Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-caption-19-hidden'; HostWindow = $caption19Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-caption-46'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-primary-150'; HostWindow = $primaryWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'title-fit-scale-low'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 20 },
            @{ Name = 'title-fit-scale-high'; HostWindow = $baseWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 999 },
            @{ Name = 'title-fit-expanded-caption-34'; HostWindow = $caption34Window; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true; ScalePercent = 130 },
            @{ Name = 'fallback-caption'; HostWindow = $fallbackWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'fallback-caption-clipped'; HostWindow = $clippedFallbackWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'fallback-caption-192'; HostWindow = $dpi192FallbackWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'invalid-fallback'; HostWindow = $invalidFallbackWindow; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi0-title'; HostWindow = $dpi0Window; AnchorMode = 3; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi0-auto'; HostWindow = $dpi0Window; AnchorMode = 0; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi0-inside-top'; HostWindow = $dpi0Window; AnchorMode = 1; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'dpi0-inside-bottom'; HostWindow = $dpi0Window; AnchorMode = 2; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'inside-top-expanded'; HostWindow = $baseWindow; AnchorMode = 1; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'inside-bottom-expanded'; HostWindow = $baseWindow; AnchorMode = 2; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'compressed-rows'; HostWindow = $compressedWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 8; ShowContextProgress = $true },
            @{ Name = 'insufficient-height'; HostWindow = $tooShortWindow; AnchorMode = 3; RequestExpanded = $true; ExpandedRowCount = 8; ShowContextProgress = $true },
            @{ Name = 'auto-right'; HostWindow = $autoRightWindow; AnchorMode = 0; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-left'; HostWindow = $autoLeftWindow; AnchorMode = 0; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-inside'; HostWindow = $autoInsideWindow; AnchorMode = 0; RequestExpanded = $false; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-down'; HostWindow = $autoRightWindow; AnchorMode = 0; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-up'; HostWindow = $autoUpWindow; AnchorMode = 0; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-compressed-down'; HostWindow = $autoCompressedDownWindow; AnchorMode = 0; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true },
            @{ Name = 'auto-inside-up'; HostWindow = $autoInsideUpWindow; AnchorMode = 0; RequestExpanded = $true; ExpandedRowCount = 4; ShowContextProgress = $true }
        )

        $response = Invoke-JsonProbe '--layout-probe' $layoutCases
        $layoutContract = Invoke-HostSurfaceContractReflectionProbe
        $removedLayoutProperty = 'Preferred' + 'P' + 'etBounds'
        Assert-Condition `
            (-not (@($layoutContract.LayoutRequestProperties) -contains $removedLayoutProperty)) `
            "OverlayLayoutRequest не должен содержать удалённое свойство прямоугольника привязки. actual=$(@($layoutContract.LayoutRequestProperties) -join ',')"
        Assert-Rect (Get-ProbeCase $response 'caption-relative-to-negative-screen').ScreenBounds -210 20 210 48 'Относительные координаты кнопки заголовка не преобразуются в координаты экрана, основанные на верхнем левом углу исходного окна.'
        $collapsed = (Get-ProbeCase $response 'exact-collapsed').Layout
        Assert-Condition ((Get-ProbeCase $response 'exact-collapsed').Handle -eq 4294967296) 'Пробник макета не обрабатывает дескриптор окна туда и обратно в течение длительного времени.'
        Assert-Condition ($collapsed.State -eq 0) 'Точный статус случая коллапса неверен.'
        Assert-Condition ($collapsed.CollapsedDisplay -eq 0) 'В случае точного свертывания не отображаются двойные поля.'
        Assert-Condition ((@($collapsed.WindowBounds.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'Height,Width,X,Y') 'Прямоугольник пробного макета должен сериализовать только X/Y/Ширину/Высоту.'
        Assert-Rect $collapsed.WindowBounds 778 6 264 34 'Ширина двойного поля строки заголовка при 100% масштабе должна быть 264 DIP.'
        Assert-Rect $collapsed.CapsuleBounds 0 0 264 34 'Ширина клиентской области капсулы строки заголовка при 100% масштабе должна быть 264 DIP.'
        Assert-Rect $collapsed.PanelBounds 0 0 0 0 'Панель точного свертывания должна быть пустой.'

        $expandedCase = Get-ProbeCase $response 'exact-expanded'
        $expanded = $expandedCase.Layout
        Assert-Condition ($expanded.State -eq 1) 'Точный статус расширения неверен.'
        Assert-Condition ($expanded.ExpansionDirection -eq 0) 'Направление расширения строки заголовка должно быть вниз.'
        Assert-Condition ($expanded.Dpi -eq 96) 'Неверное разрешение макета.'
        Assert-Condition ($expanded.ExpandedRowHeight -eq 30) 'Неправильная высота строки обычного расширения.'
        Assert-Rect $expanded.WindowBounds 742 6 300 282 'Неправильный точный прямоугольник окна расширения.'
        Assert-Rect $expanded.CapsuleBounds 36 0 264 34 'Расширенные капсулы должны быть выровнены по правому краю расширенного окна.'
        Assert-Rect $expanded.PanelBounds 0 40 300 242 'Геометрия панели не должна меняться.'
        Assert-Condition (-not $expandedCase.ContainsClientPoints[0]) 'Полая область размером 30×40 в верхнем левом углу не должна быть интерактивной.'
        Assert-Condition ($expandedCase.ContainsClientPoints[1]) 'Точки капсулы должны быть сосредоточены на взаимодействии.'
        Assert-Condition ($expandedCase.ContainsClientPoints[2]) 'Точки панели должны быть сосредоточены на интерактивном объединении.'
        Assert-Condition (-not $expandedCase.ContainsScreenPoints[0]) 'Полая область координат экрана не должна быть интерактивной.'
        Assert-Condition ($expandedCase.ContainsScreenPoints[1]) 'Точки капсулы координат на экране должны быть интерактивными.'
        Assert-Condition ($expandedCase.ContainsScreenPoints[2]) 'Точки панели координат на экране должны быть интерактивными.'

        Assert-Condition ($collapsed.ScalePercent -eq 100 -and $expanded.ScalePercent -eq 100) 'Масштабирование по умолчанию должно оставаться на уровне 100 % в свернутых и развернутых результатах.'
        Assert-LayoutEqual `
            (Get-ProbeCase $response 'explicit-default-no-manual').Layout `
            $collapsed `
            'ManualCapsuleCenter=null и ScalePercent=100 должны оставлять неизменной геометрию старой основной надписи.'

        foreach ($manualCollapsedCase in @(
            @{ Name = 'manual-collapsed-60'; X = 931; Y = 290; Width = 139; Height = 20; Scale = 60 },
            @{ Name = 'manual-collapsed-100'; X = 884; Y = 283; Width = 232; Height = 34; Scale = 100 },
            @{ Name = 'manual-collapsed-130'; X = 849; Y = 278; Width = 302; Height = 44; Scale = 130 },
            @{ Name = 'manual-collapsed-192-60'; X = 861; Y = 280; Width = 278; Height = 41; Scale = 60 },
            @{ Name = 'manual-scale-low-sanitized'; X = 931; Y = 290; Width = 139; Height = 20; Scale = 60 },
            @{ Name = 'manual-scale-high-sanitized'; X = 849; Y = 278; Width = 302; Height = 44; Scale = 130 }
        )) {
            $manualCollapsed = (Get-ProbeCase $response $manualCollapsedCase.Name).Layout
            Assert-Condition ($manualCollapsed.State -eq 0 -and $manualCollapsed.CollapsedDisplay -eq 0) "$($manualCollapsedCase.Name) должен сохранять макет ручного свертывания двойных полей."
            Assert-Condition ($manualCollapsed.ScalePercent -eq $manualCollapsedCase.Scale) "Весы, возвращенные $($manualCollapsedCase.Name), не были очищены должным образом."
            Assert-Rect $manualCollapsed.WindowBounds $manualCollapsedCase.X $manualCollapsedCase.Y $manualCollapsedCase.Width $manualCollapsedCase.Height "$($manualCollapsedCase.Name) Неправильный прямоугольник с ручным втягиванием центра."
            Assert-Rect $manualCollapsed.CapsuleBounds 0 0 $manualCollapsedCase.Width $manualCollapsedCase.Height "$($manualCollapsedCase.Name) Неверная клиентская область капсулы вручную."
        }
        Assert-Condition ((Get-ProbeCase $response 'manual-collapsed-100').Layout.CapsuleBounds.Width -eq 232) 'Нельзя изменять ширину двойного поля ручной привязки.'

        foreach ($manualExpandedCase in @(
            @{ Name = 'manual-expanded-60'; X = 890; Y = 290; Width = 180; Height = 169; CapsuleX = 41; CapsuleY = 0; CapsuleWidth = 139; CapsuleHeight = 20; PanelY = 24; PanelHeight = 145; RowHeight = 18; Scale = 60 },
            @{ Name = 'manual-expanded-100'; X = 816; Y = 283; Width = 300; Height = 282; CapsuleX = 68; CapsuleY = 0; CapsuleWidth = 232; CapsuleHeight = 34; PanelY = 40; PanelHeight = 242; RowHeight = 30; Scale = 100 },
            @{ Name = 'manual-expanded-130'; X = 761; Y = 278; Width = 390; Height = 367; CapsuleX = 88; CapsuleY = 0; CapsuleWidth = 302; CapsuleHeight = 44; PanelY = 52; PanelHeight = 315; RowHeight = 39; Scale = 130 }
        )) {
            $manualExpanded = (Get-ProbeCase $response $manualExpandedCase.Name).Layout
            Assert-Condition ($manualExpanded.State -eq 1 -and $manualExpanded.ExpansionDirection -eq 0) "$($manualExpandedCase.Name) необходимо раскрыть вниз."
            Assert-Condition ($manualExpanded.ScalePercent -eq $manualExpandedCase.Scale) "$($manualExpandedCase.Name) возвращает неправильное масштабирование."
            Assert-Condition ($manualExpanded.ExpandedRowHeight -eq $manualExpandedCase.RowHeight) "$($manualExpandedCase.Name) Высота строки не масштабируется пользователем."
            Assert-Rect $manualExpanded.WindowBounds $manualExpandedCase.X $manualExpandedCase.Y $manualExpandedCase.Width $manualExpandedCase.Height "$($manualExpandedCase.Name) Неправильный прямоугольник развернутого окна."
            Assert-Rect $manualExpanded.CapsuleBounds $manualExpandedCase.CapsuleX $manualExpandedCase.CapsuleY $manualExpandedCase.CapsuleWidth $manualExpandedCase.CapsuleHeight "$($manualExpandedCase.Name) Неправильный прямоугольник капсулы."
            Assert-Rect $manualExpanded.PanelBounds 0 $manualExpandedCase.PanelY $manualExpandedCase.Width $manualExpandedCase.PanelHeight "$($manualExpandedCase.Name) Размер панели не масштабируется пользователем."
        }

        Assert-Condition ((Get-ProbeCase $response 'manual-direction-60-down').Layout.ExpansionDirection -eq 0) '60% Макет вручную должен расширяться вниз на доступную высоту после масштабирования.'
        Assert-Condition ((Get-ProbeCase $response 'manual-direction-130-up').Layout.ExpansionDirection -eq 1) '130% Макет вручную должен расширяться вверх на доступную высоту после масштабирования.'

        $manualOutside = (Get-ProbeCase $response 'manual-outside-work-area').Layout
        Assert-Condition ($manualOutside.State -eq 1 -and $manualOutside.ExpansionDirection -eq 1) 'Центр ручного управления за пределами рабочей зоны должен переместиться вверх после минимального перемещения.'
        Assert-Rect $manualOutside.WindowBounds 1620 758 300 282 'Полное окно ручного центра за пределами рабочей зоны должно быть прикреплено к рабочей зоне.'
        Assert-Rect $manualOutside.CapsuleBounds 68 248 232 34 'Неправильный перевод капсулы ручного центра за пределы рабочей зоны.'
        Assert-Rect $manualOutside.PanelBounds 0 0 300 242 'Панель ручного центра за пределами рабочей зоны должна оставаться неповрежденной.'

        $manualNoExpansion = (Get-ProbeCase $response 'manual-no-expansion-does-not-fall-back').Layout
        Assert-Condition ($manualNoExpansion.State -eq 0) 'Макет вручную должен оставаться свернутым, если его нельзя развернуть вверх или вниз.'
        Assert-Rect $manualNoExpansion.WindowBounds 884 68 232 34 'Традиционную точку привязки нельзя удалить, если при расширении вручную нет места.'

        $manualCaptionCollision = (Get-ProbeCase $response 'manual-titlebar-cannot-expand-over-caption-buttons').Layout
        Assert-Condition ($manualCaptionCollision.State -eq 0) 'Капсула с ручным управлением в строке заголовка должна оставаться втянутой, если она не может безопасно разместить расширенную панель.'
        Assert-Rect $manualCaptionCollision.WindowBounds 34 2 302 44 'Ручной макет строки заголовка нельзя переместить в область кнопки заголовка для расширенных панелей.'

        Assert-Condition ((Get-ProbeCase $response 'hidden-scale-sanitized').Layout.ScalePercent -eq 130) 'Скрытые результаты также должны содержать очищенное отшелушивание.'

        $legacyScaled = (Get-ProbeCase $response 'legacy-system-offsets-at-scale-60').Layout
        Assert-Rect $legacyScaled.WindowBounds 1043 56 139 20 'Устаревшие смещения привязки должны масштабироваться только по системному DPI, размеры капсул используют пользовательский масштаб.'

        $primary = (Get-ProbeCase $response 'primary-only').Layout
        Assert-Condition ($primary.State -eq 0 -and $primary.CollapsedDisplay -eq 1) 'Доступную ширину 150 DIP необходимо уменьшить до одного поля.'
        Assert-Rect $primary.WindowBounds 182 6 128 34 'Ширина свернутого отдельного поля должна составлять 128 DIP.'
        $primaryExpanded = (Get-ProbeCase $response 'primary-can-expand').Layout
        Assert-Condition ($primaryExpanded.State -eq 1 -and $primaryExpanded.CollapsedDisplay -eq 1) 'PrimaryOnly не должен препятствовать полному расширению панели.'
        Assert-Rect $primaryExpanded.PanelBounds 0 40 300 242 'PrimaryТолько расширенные панели должны сохранять свою полную ширину.'

        $narrowPrimary = (Get-ProbeCase $response 'narrow-primary-115').Layout
        Assert-Condition ($narrowPrimary.State -eq 0) 'Доступная ширина 115 пикселей должна оставаться свернутой и не может быть ошибочно расценена как недостаточное пространство.'
        Assert-Condition ($narrowPrimary.ScalePercent -eq 90) 'Необходимо выбрать доступную ширину 115 пикселей с максимальным масштабом 90%.'
        Assert-Condition ($narrowPrimary.CollapsedDisplay -eq 1) 'Доступную ширину в 115 пикселей необходимо уменьшить до одного поля.'
        Assert-Condition ($narrowPrimary.CapsuleBounds.Width -eq 115) 'Капсула доступной ширины 115 пикселей должна занимать все 115 пикселей.'
        Assert-Rect $narrowPrimary.WindowBounds 160 7 115 31 'Прямоугольник с одним полем размером 115 пикселей является неправильным при 90 % доступной ширины.'

        $hiddenWidth = (Get-ProbeCase $response 'hidden-for-width').Layout
        Assert-Condition ($hiddenWidth.State -eq 2) 'Свободное пространство размером менее 60 % ширины одного поля должно быть скрыто.'
        Assert-Rect $hiddenWidth.WindowBounds 0 0 0 0 'Прямоугольник окна должен быть пустым, если его ширина недостаточна.'
        Assert-Rect $hiddenWidth.CapsuleBounds 0 0 0 0 'Прямоугольник капсулы должен быть пустым, если его ширина недостаточна.'
        Assert-Rect $hiddenWidth.PanelBounds 0 0 0 0 'Прямоугольник панели должен быть пустым, если ширина недостаточна.'

        foreach ($dpiCase in @(
            @{ Name = 'dpi-120'; Dpi = 120; CapsuleWidth = 330; CapsuleHeight = 43; PanelWidth = 375; PanelHeight = 305; RowHeight = 38 },
            @{ Name = 'dpi-144'; Dpi = 144; CapsuleWidth = 396; CapsuleHeight = 51; PanelWidth = 450; PanelHeight = 363; RowHeight = 45 },
            @{ Name = 'dpi-192'; Dpi = 192; CapsuleWidth = 528; CapsuleHeight = 68; PanelWidth = 600; PanelHeight = 484; RowHeight = 60 }
        )) {
            $layout = (Get-ProbeCase $response $dpiCase.Name).Layout
            Assert-Condition ($layout.Dpi -eq $dpiCase.Dpi) "$($dpiCase.Name) возвращает неверный DPI."
            Assert-Condition ($layout.CapsuleBounds.Width -eq $dpiCase.CapsuleWidth -and $layout.CapsuleBounds.Height -eq $dpiCase.CapsuleHeight) "Капсула $($dpiCase.Name) не масштабировалась ровно один раз."
            Assert-Condition ($layout.PanelBounds.Width -eq $dpiCase.PanelWidth -and $layout.PanelBounds.Height -eq $dpiCase.PanelHeight) "$($dpiCase.Name) Панель не масштабируется ровно один раз."
            Assert-Condition ($layout.ExpandedRowHeight -eq $dpiCase.RowHeight) "$($dpiCase.Name) Высота строки не масштабируется ровно один раз."
        }
        $dpi192 = (Get-ProbeCase $response 'dpi-192').Layout
        Assert-Rect $dpi192.WindowBounds 1484 12 600 564 'Расширенные окна с разрешением 192 DPI должны быть строго в два раза больше окна с разрешением 96 DPI.'
        Assert-Rect $dpi192.CapsuleBounds 72 0 528 68 'Клиентская область капсулы с разрешением 192 DPI должна быть строго в два раза больше, чем размер клиентской области с разрешением 96 DPI.'
        Assert-Rect $dpi192.PanelBounds 0 80 600 484 'Клиентская область панели с разрешением 192 DPI должна быть строго вдвое больше, чем 96 DPI.'

        foreach ($boundedCase in @('negative-display', 'clipped-maximized', 'partially-offscreen')) {
            $layout = (Get-ProbeCase $response $boundedCase).Layout
            $hostFixture = switch ($boundedCase) {
                'negative-display' { $negativeWindow }
                'clipped-maximized' { $clippedWindow }
                default { $partiallyOffscreenWindow }
            }
            Assert-Condition ($layout.WindowBounds.X -ge $hostFixture.WorkingArea.X -and $layout.WindowBounds.Y -ge $hostFixture.WorkingArea.Y) "$boundedCase выходит за верхнюю левую границу рабочей области."
            Assert-Condition (($layout.WindowBounds.X + $layout.WindowBounds.Width) -le ($hostFixture.WorkingArea.X + $hostFixture.WorkingArea.Width)) "$boundedCase выходит за правую границу рабочей области."
            Assert-Condition (($layout.WindowBounds.Y + $layout.WindowBounds.Height) -le ($hostFixture.WorkingArea.Y + $hostFixture.WorkingArea.Height)) "$boundedCase выходит за нижнюю границу рабочей области."
            Assert-Condition (($layout.WindowBounds.X + $layout.CapsuleBounds.X + $layout.CapsuleBounds.Width) -le ($hostFixture.CaptionButtonBounds.X - 8)) "$boundedCase Капсула пересекла границу безопасности строки заголовка."
        }

        $autoCompressedDown = (Get-ProbeCase $response 'auto-compressed-down').Layout
        Assert-Condition ($autoCompressedDown.State -eq 1 -and $autoCompressedDown.ExpansionDirection -eq 0 -and $autoCompressedDown.ExpandedRowHeight -eq 24) 'В режиме «Авто» следует выбирать нижнюю часть, которая может вместить 24 строки сжатия DIP, а не верхнюю, которая не может вместить самую маленькую панель.'
        $autoInsideUp = (Get-ProbeCase $response 'auto-inside-up').Layout
        Assert-Condition ($autoInsideUp.State -eq 1 -and $autoInsideUp.ExpansionDirection -eq 1 -and $autoInsideUp.ExpandedRowHeight -eq 30) 'После того, как Auto вернется к координатам в окне, оно все равно должно расширяться вверх в соответствии с доступным пространством.'

        $title34 = (Get-ProbeCase $response 'title-fit-caption-34').Layout
        Assert-Condition ($title34.State -eq 0 -and $title34.ScalePercent -eq 101 -and $title34.CollapsedDisplay -eq 0) 'Эффективная пропорция строки заголовка размером 34 пикселя должна поддерживаться на уровне 101%.'
        Assert-Rect $title34.WindowBounds 775 0 267 34 'Строка заголовка высотой 34 пикселя должна вмещать капсулу шириной 267 DIP при масштабе 101%.'

        $title32 = (Get-ProbeCase $response 'title-fit-caption-32').Layout
        Assert-Condition ($title32.State -eq 0 -and $title32.ScalePercent -eq 95 -and $title32.CollapsedDisplay -eq 0) 'Необходимо выбрать строку заголовка размером 32 пикселя, чтобы полностью разместить двойное поле с максимальным соотношением 95 %.'
        Assert-Rect $title32.WindowBounds 791 0 251 32 'Неверная геометрия заголовка размером 32 пикселя.'

        $title20 = (Get-ProbeCase $response 'title-fit-caption-20').Layout
        Assert-Condition ($title20.State -eq 0 -and $title20.ScalePercent -eq 60 -and $title20.CollapsedDisplay -eq 0) 'Строка заголовка размером 20 пикселей должна полностью отображать двойное поле с соотношением минимум 60%.'
        Assert-Rect $title20.WindowBounds 884 0 158 20 'Неверная геометрия заголовка размером 20 пикселей.'

        $title19 = (Get-ProbeCase $response 'title-fit-caption-19-hidden').Layout
        Assert-Condition ($title19.State -eq 2) 'Строка заголовка размером 19 пикселей по-прежнему должна быть скрыта.'
        Assert-Rect $title19.WindowBounds 0 0 0 0 'Верхний правый прямоугольник в клиентской области не может быть создан, если нет безопасного соотношения сторон заголовка.'

        $title46 = (Get-ProbeCase $response 'title-fit-caption-46').Layout
        Assert-Condition ($title46.State -eq 0 -and $title46.ScalePercent -eq 130 -and $title46.CollapsedDisplay -eq 0) 'Строка заголовка размером 46 пикселей должна сохранять требуемое соотношение двойных полей 130%.'
        Assert-Rect $title46.WindowBounds 699 1 343 44 '130% Неправильная геометрия строки заголовка.'

        $titlePrimary = (Get-ProbeCase $response 'title-fit-primary-150').Layout
        Assert-Condition ($titlePrimary.State -eq 0 -and $titlePrimary.ScalePercent -eq 117 -and $titlePrimary.CollapsedDisplay -eq 1) 'При ширине 150 пикселей резервный режим одного поля должен достигать масштаба 117%.'
        Assert-Rect $titlePrimary.WindowBounds 160 3 150 40 'Границу одного поля размером 150 пикселей изменять нельзя.'

        $titleLow = (Get-ProbeCase $response 'title-fit-scale-low').Layout
        Assert-Condition ($titleLow.ScalePercent -eq 60) 'Сначала коэффициент запроса строки заголовка 20 % необходимо очистить до 60 %.'
        $titleHigh = (Get-ProbeCase $response 'title-fit-scale-high').Layout
        Assert-Condition ($titleHigh.ScalePercent -eq 130) 'Коэффициент запроса строки заголовка 999 %, поиск следует начинать со 130 %.'
        Assert-Condition ($title34.ScalePercent -eq 101 -and $title46.ScalePercent -eq 130) 'Неперезаписанное соотношение запросов 130 % необходимо повторно использовать после восстановления пространства в строке заголовка.'

        $titleExpanded = (Get-ProbeCase $response 'title-fit-expanded-caption-34').Layout
        Assert-Condition ($titleExpanded.State -eq 1 -and $titleExpanded.ScalePercent -eq 101 -and $titleExpanded.ExpandedRowHeight -eq 30) 'В макете расширения заголовка размером 34 пикселя должно использоваться эффективное соотношение 101 %.'
        Assert-Rect $titleExpanded.WindowBounds 739 0 303 283 '101% Неправильный прямоугольник развернутого окна.'
        Assert-Rect $titleExpanded.CapsuleBounds 36 0 267 34 '101% Неправильный прямоугольник расширенной клиентской области капсулы.'
        Assert-Rect $titleExpanded.PanelBounds 0 40 303 243 '101% Неправильный прямоугольник развернутой панели.'

        $layoutAssembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
        $renderMetricsType = $layoutAssembly.GetType('CodexTokenOverlay.OverlayRenderMetrics', $true)
        $createRenderMetrics = $renderMetricsType.GetMethod('Create', [System.Reflection.BindingFlags]'Public, Static')
        $titleRenderMetrics = $createRenderMetrics.Invoke($null, [object[]]@([uint32]96, [int]$titleExpanded.ScalePercent))
        Assert-Condition `
            ($titleRenderMetrics.LabelFontPoints -eq 9.09 -and $titleRenderMetrics.CompactValueFontPoints -eq 11.11 -and $titleRenderMetrics.CapsuleRadius -eq 10 -and $titleRenderMetrics.HorizontalPadding -eq 10) `
            'Показатели отображения заголовка должны быть взяты из 101% допустимого масштаба, возвращаемого макетом.'

        $metrics = $createRenderMetrics.Invoke($null, [object[]]@([uint32]96, [int]100))
        Add-Type -AssemblyName System.Windows.Forms
        $bitmap = $null
        $graphics = $null
        $labelFont = $null
        $valueFont = $null
        try {
            $bitmap = [System.Drawing.Bitmap]::new(1, 1)
            $bitmap.SetResolution(96, 96)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $labelFont = [System.Drawing.Font]::new(
                'Segoe UI',
                [single]$metrics.LabelFontPoints,
                [System.Drawing.FontStyle]::Regular,
                [System.Drawing.GraphicsUnit]::Point)
            $valueFont = [System.Drawing.Font]::new(
                'Segoe UI Semibold',
                [single]$metrics.CompactValueFontPoints,
                [System.Drawing.FontStyle]::Regular,
                [System.Drawing.GraphicsUnit]::Point)
            Assert-Condition ($labelFont.Name -eq 'Segoe UI') 'Реальные размеры шрифта необходимо анализировать в пользовательском интерфейсе Segoe.'
            Assert-Condition ($valueFont.Name -eq 'Segoe UI Semibold') 'Реальные размеры шрифта должны быть преобразованы в Segoe UI Semibold.'
            $measureFlags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
            $totalLabelWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
                $graphics, 'Всего', $labelFont, [System.Drawing.Size]::Empty, $measureFlags).Width
            $totalValueWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
                $graphics, '163.45M', $valueFont, [System.Drawing.Size]::Empty, $measureFlags).Width
            $hitLabelWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
                $graphics, 'Кэш %', $labelFont, [System.Drawing.Size]::Empty, $measureFlags).Width
            $hitValueWidth = [System.Windows.Forms.TextRenderer]::MeasureText(
                $graphics, '38%', $valueFont, [System.Drawing.Size]::Empty, $measureFlags).Width

            $capsuleWidth = 264
            $contentWidth = $capsuleWidth - (2 * $metrics.HorizontalPadding)
            $columnWidth = [math]::Floor($contentWidth / 2) - $metrics.MetricGap
            $totalRequired = $totalLabelWidth + $metrics.CompactMetricGap + $totalValueWidth
            $hitRequired = $hitLabelWidth + $metrics.CompactMetricGap + $hitValueWidth
            $totalMargin = $columnWidth - $totalRequired
            $hitMargin = $columnWidth - $hitRequired

            Write-Host "Измерение читаемости шрифта: капсула 264 DIP, столбец = $columnWidth totalRequired = $totalRequired totalMargin = $totalMargin hitRequired = $hitRequired hitMargin = $hitMargin минимальное поле = $($metrics.CompactMetricGap)"
            Assert-Condition ($totalMargin -ge $metrics.CompactMetricGap) 'Капсула 264 DIP должна вмещать подпись «Всего» и значение 163.45M с минимальным интервалом между колонками.'
            Assert-Condition ($hitMargin -ge $metrics.CompactMetricGap) 'Капсула 264 DIP должна вмещать подпись «Кэш %» и значение 38% с минимальным интервалом между колонками.'

            $oldContentWidth = 196 - (2 * $metrics.HorizontalPadding)
            $oldColumnWidth = [math]::Floor($oldContentWidth / 2) - $metrics.MetricGap
            $oldTotalMargin = $oldColumnWidth - $totalRequired
            Write-Host "Отрицательная проверка читаемости при ширине 196 DIP: столбец = $oldColumnWidth totalRequired = $totalRequired totalMargin = $oldTotalMargin минимальное поле = $($metrics.CompactMetricGap)"
            Assert-Condition `
                ($oldTotalMargin -lt $metrics.CompactMetricGap) `
                'При ширине 196 DIP подпись «Всего» и значение 163.45M должны оставлять меньше минимального интервала.'
        }
        finally {
            if ($null -ne $valueFont) { $valueFont.Dispose() }
            if ($null -ne $labelFont) { $labelFont.Dispose() }
            if ($null -ne $graphics) { $graphics.Dispose() }
            if ($null -ne $bitmap) { $bitmap.Dispose() }
        }

        $layoutResultType = $layoutAssembly.GetType('CodexTokenOverlay.OverlayLayoutResult', $true)
        $dpiGetter = $layoutResultType.GetProperty('Dpi').GetMethod
        $scaleGetter = $layoutResultType.GetProperty('ScalePercent').GetMethod
        $formType = $layoutAssembly.GetType('CodexTokenOverlay.TokenStripForm', $true)
        $applyLayout = $formType.GetMethod('ApplyLayout', [System.Reflection.BindingFlags]'Public, Instance')
        $onPaint = $formType.GetMethod('OnPaint', [System.Reflection.BindingFlags]'NonPublic, Instance')
        Assert-Condition `
            (Test-MethodCallChain $applyLayout @($dpiGetter, $scaleGetter, $createRenderMetrics)) `
            'TokenStripForm.ApplyLayout должен передавать эффективную пропорцию результата макета в индикатор рисования области.'
        Assert-Condition `
            (Test-MethodCallChain $onPaint @($dpiGetter, $scaleGetter, $createRenderMetrics)) `
            'TokenStripForm.OnPaint должен передавать эффективную пропорцию результата макета к фактическому индикатору рисования.'
        Assert-Condition ((Get-ProbeCase $response 'fallback-caption').Layout.State -ne 2) 'Действительные резервные индикаторы должны продолжать макет, даже если кнопка заголовка отсутствует.'
        $fallbackClipped = (Get-ProbeCase $response 'fallback-caption-clipped').Layout
        Assert-Condition ($fallbackClipped.State -eq 0 -and $fallbackClipped.ScalePercent -eq 83 -and $fallbackClipped.CapsuleBounds.Height -eq 28) 'Если резервная область заголовка обрезана до 28 пикселей, необходимо выбрать максимальный масштаб 83 % для полного соответствия.'
        Assert-Rect $fallbackClipped.WindowBounds 811 0 219 28 'Неправильный максимальный размер прямоугольника после обрезки резервной области заголовка.'
        Assert-Rect $fallbackClipped.CapsuleBounds 0 0 219 28 'При обрезке резервной области ширина капсулы должна соответствовать доступной ширине.'
        Assert-Condition ((Get-ProbeCase $response 'fallback-caption-192').Layout.CapsuleBounds.Height -eq 68) 'Резервные метрики с высоким разрешением не следует масштабировать.'
        Assert-Condition ((Get-ProbeCase $response 'invalid-fallback').Layout.State -eq 2) 'Недопустимая кнопка заголовка и индикатор недоступности резервного варианта должны быть скрыты.'

        Assert-Condition ((Get-ProbeCase $response 'dpi0-title').Layout.State -eq 2) 'Привязка строки заголовка должна быть скрыта, если Dpi=0.'
        foreach ($legacyCase in @('dpi0-auto', 'dpi0-inside-top', 'dpi0-inside-bottom')) {
            Assert-Condition ((Get-ProbeCase $response $legacyCase).Layout.State -ne 2) "Dpi=0 не должен скрывать старые точки привязки: $legacyCase"
        }
        Assert-Condition ((Get-ProbeCase $response 'inside-top-expanded').Layout.ExpansionDirection -eq 0) 'InsideTopRight необходимо развернуть вниз.'
        Assert-Condition ((Get-ProbeCase $response 'inside-top-expanded').Layout.CapsuleBounds.Width -eq 232) 'Старую ширину двойного поля привязки изменять нельзя.'
        Assert-Condition ((Get-ProbeCase $response 'inside-bottom-expanded').Layout.ExpansionDirection -eq 1) 'InsideBottomRight необходимо развернуть вверх.'

        $compressed = (Get-ProbeCase $response 'compressed-rows').Layout
        Assert-Condition ($compressed.State -eq 1 -and $compressed.ExpandedRowHeight -eq 29) 'Высоту ряда следует уменьшить с 30 DIP, чтобы приспособиться к ситуации, когда места недостаточно.'
        $tooShort = (Get-ProbeCase $response 'insufficient-height').Layout
        Assert-Condition ($tooShort.State -eq 0 -and $tooShort.ExpandedRowHeight -eq 0) 'Запросы должны оставаться закрытыми, если высокий уровень менее 24 строк DIP.'

        Assert-Condition ((Get-ProbeCase $response 'auto-right').Layout.WindowBounds.X -eq 1010) 'В режиме «Авто» приоритетом не является правая сторона за окном.'
        Assert-Condition ((Get-ProbeCase $response 'auto-left').Layout.WindowBounds.X -eq 678) 'Авто Левая сторона за окном не выбирается, когда правой стороны недостаточно.'
        Assert-Condition ((Get-ProbeCase $response 'auto-inside').Layout.WindowBounds.X -eq 1610) 'Auto не переключается на InsideTopRight, когда обе стороны недостаточны.'
        Assert-Condition ((Get-ProbeCase $response 'auto-down').Layout.ExpansionDirection -eq 0) 'Автоматически не разворачивается вниз, если внизу достаточно места.'
        Assert-Condition ((Get-ProbeCase $response 'auto-up').Layout.ExpansionDirection -eq 1) 'Автоматическое развертывание вверх не происходит, если нижней части недостаточно, а верхней части достаточно.'
    }

    if ($areas -contains 'Interaction') {
        $interactionCases = @(
            @{
                Name = 'open-release-outside-left'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $false }
                )
            },
            @{
                Name = 'capsule-click-while-expanded-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CapsuleMouseUp' }
                )
            },
            @{
                Name = 'inside-left-right-middle-stay-expanded'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 2; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 4; PointerInsideOverlay = $true }
                )
            },
            @{
                Name = 'outside-right-edge-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 2; PointerInsideOverlay = $false }
                )
            },
            @{
                Name = 'outside-middle-edge-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 4; PointerInsideOverlay = $false }
                )
            },
            @{
                Name = 'held-button-does-not-repeat-edge'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $true },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $false },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $false },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $false }
                )
            },
            @{
                Name = 'target-window-change-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForHostChange' }
                )
            },
            @{
                Name = 'pinned-monitor-route-thread-change-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '11111111-1111-1111-1111-111111111111'
                        RouteActiveWindowCount = 1
                        RouteIsConnected = $true
                        RouteVersion = 10
                        RouteLastError = $null
                    },
                    @{ Operation = 'DataOnlyUpdate' },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '22222222-2222-2222-2222-222222222222'
                        RouteActiveWindowCount = 1
                        RouteIsConnected = $true
                        RouteVersion = 11
                        RouteLastError = $null
                    }
                )
            },
            @{
                Name = 'route-metadata-only-change-stays-expanded'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '11111111-1111-1111-1111-111111111111'
                        RouteActiveWindowCount = 1
                        RouteIsConnected = $true
                        RouteVersion = 10
                        RouteLastError = $null
                    },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '11111111-1111-1111-1111-111111111111'
                        RouteActiveWindowCount = 0
                        RouteIsConnected = $false
                        RouteVersion = 11
                        RouteLastError = 'pipe closed'
                    }
                )
            },
            @{
                Name = 'first-route-thread-baseline-stays-expanded'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = $null
                        RouteActiveWindowCount = 0
                        RouteIsConnected = $false
                        RouteVersion = 0
                        RouteLastError = $null
                    },
                    @{
                        Operation = 'ObserveActiveRouteThread'
                        RouteThreadId = '11111111-1111-1111-1111-111111111111'
                        RouteActiveWindowCount = 1
                        RouteIsConnected = $true
                        RouteVersion = 1
                        RouteLastError = $null
                    }
                )
            },
            @{
                Name = 'active-thread-change-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForHostChange' }
                )
            },
            @{
                Name = 'foreground-loss-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForHostChange' }
                )
            },
            @{
                Name = 'minimization-collapses'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForHostChange' }
                )
            },
            @{
                Name = 'expanded-layout-failure-collapses-before-relayout'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'CollapseForExpandedLayoutFailure' }
                )
            },
            @{
                Name = 'primary-only-does-not-collapse'
                Events = @(
                    @{ Operation = 'CapsuleMouseUp' },
                    @{ Operation = 'PointerSample'; PressedButtons = 0; PointerInsideOverlay = $true },
                    @{ Operation = 'DataOnlyUpdate' }
                )
            },
            @{
                Name = 'hide-and-restore-space'
                Events = @(
                    @{ Operation = 'HideForSpace' },
                    @{ Operation = 'RestoreAfterSpace' }
                )
            },
            @{
                Name = 'hidden-pointer-sample-waits-for-space-restore'
                Events = @(
                    @{ Operation = 'HideForSpace' },
                    @{ Operation = 'PointerSample'; PressedButtons = 1; PointerInsideOverlay = $false },
                    @{ Operation = 'RestoreAfterSpace' }
                )
            },
            @{
                Name = 'data-only-update-keeps-collapsed'
                Events = @(
                    @{ Operation = 'DataOnlyUpdate' }
                )
            }
        )

        $response = Invoke-JsonProbe '--interaction-probe' $interactionCases
        $expandedWaiting = @{ State = 1; Polling = $true; WaitingForRelease = $true; StateChanged = $true }
        $expanded = @{ State = 1; Polling = $true; WaitingForRelease = $false; StateChanged = $false }
        $collapsed = @{ State = 0; Polling = $false; WaitingForRelease = $false; StateChanged = $true }
        $collapsedUnchanged = @{ State = 0; Polling = $false; WaitingForRelease = $false; StateChanged = $false }
        $hidden = @{ State = 2; Polling = $false; WaitingForRelease = $false; StateChanged = $true }
        $hiddenUnchanged = @{ State = 2; Polling = $false; WaitingForRelease = $false; StateChanged = $false }

        Assert-InteractionTrace (Get-ProbeCase $response 'open-release-outside-left') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'capsule-click-while-expanded-collapses') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'inside-left-right-middle-stay-expanded') @($expandedWaiting, $expanded, $expanded, $expanded, $expanded, $expanded, $expanded)
        Assert-InteractionTrace (Get-ProbeCase $response 'outside-right-edge-collapses') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'outside-middle-edge-collapses') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'held-button-does-not-repeat-edge') @($expandedWaiting, $expanded, $expanded, $expanded, $expanded, $collapsed)
        $anchorState = Invoke-AnchorStateReflectionProbe
        Assert-Condition $anchorState.HasMainOnlyObserveMethod 'Состояние привязки должно предоставлять только дескриптор хоста и интерфейс ObserveAndCollapse опорной точки.'
        Assert-Condition (-not $anchorState.BoundsOnlyMovementStaysExpanded) 'Одно только прямоугольное перемещение не должно изменять идентичность якоря или разрушаться.'
        Assert-Condition $anchorState.HostHandleChangeCollapses 'Изменения дескриптора хоста должны быть закрыты.'
        Assert-Condition $anchorState.ReferencePointChangeCollapses 'Изменения контрольной точки должны быть закрыты.'
        Assert-InteractionTrace (Get-ProbeCase $response 'pinned-monitor-route-thread-change-collapses') @($expandedWaiting, $expanded, $expanded, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'route-metadata-only-change-stays-expanded') @($expandedWaiting, $expanded, $expanded, $expanded)
        Assert-InteractionTrace (Get-ProbeCase $response 'first-route-thread-baseline-stays-expanded') @($expandedWaiting, $expanded, $expanded, $expanded)
        foreach ($hostChangeCase in @('target-window-change-collapses', 'active-thread-change-collapses', 'foreground-loss-collapses', 'minimization-collapses')) {
            Assert-InteractionTrace (Get-ProbeCase $response $hostChangeCase) @($expandedWaiting, $expanded, $collapsed)
        }
        Assert-InteractionTrace (Get-ProbeCase $response 'expanded-layout-failure-collapses-before-relayout') @($expandedWaiting, $expanded, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'primary-only-does-not-collapse') @($expandedWaiting, $expanded, $expanded)
        Assert-InteractionTrace (Get-ProbeCase $response 'hide-and-restore-space') @($hidden, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'hidden-pointer-sample-waits-for-space-restore') @($hidden, $hiddenUnchanged, $collapsed)
        Assert-InteractionTrace (Get-ProbeCase $response 'data-only-update-keeps-collapsed') @($collapsedUnchanged)
    }

    if ($areas -contains 'Window') {
        $normalStyle = 0x240100
        $toolStyle = 0x2800A8
        $main = @{ Handle = 100; ProcessId = 10; IsCodexProcess = $true; IsVisible = $true; IsMinimized = $false; OwnerHandle = 0; ExtendedStyle = $normalStyle; Bounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 }; ClassName = 'Chrome_WidgetWin_1' }
        $tool = @{ Handle = 200; ProcessId = 10; IsCodexProcess = $true; IsVisible = $true; IsMinimized = $false; OwnerHandle = 0; ExtendedStyle = $toolStyle; Bounds = @{ X = 1250; Y = 350; Width = 410; Height = 400 }; ClassName = 'Chrome_WidgetWin_1' }
        $response = Invoke-JsonProbe '--window-classification-probe' @(
            @{ Name = 'foreground-host'; ForegroundHandle = 100; Candidates = @($main, $tool) },
            @{ Name = 'foreground-tool'; ForegroundHandle = 200; Candidates = @($main, $tool) },
            @{ Name = 'foreground-non-codex'; ForegroundHandle = 300; Candidates = @($main, $tool, @{ Handle = 300; ProcessId = 30; IsCodexProcess = $false; IsVisible = $true; IsMinimized = $false; OwnerHandle = 0; ExtendedStyle = $normalStyle; Bounds = @{ X = 0; Y = 0; Width = 1600; Height = 1000 }; ClassName = 'Chrome_WidgetWin_1' }) },
            @{ Name = 'largest-host-and-lowest-handle-tie'; ForegroundHandle = 100; Candidates = @(
                (Copy-WindowCandidate $main @{ Handle = 100; Bounds = @{ X = 0; Y = 0; Width = 1000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 120; Bounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 110; Bounds = @{ X = 0; Y = 0; Width = 1500; Height = 1000 } })
            ) },
            @{ Name = 'invalid-normal-candidates'; ForegroundHandle = 100; Candidates = @(
                $main,
                (Copy-WindowCandidate $main @{ Handle = 1; IsVisible = $false; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 2; IsMinimized = $true; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 3; OwnerHandle = 100; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 4; Bounds = @{ X = 0; Y = 0; Width = 499; Height = 4000 } }),
                (Copy-WindowCandidate $main @{ Handle = 5; Bounds = @{ X = 0; Y = 0; Width = 4000; Height = 399 } }),
                (Copy-WindowCandidate $main @{ Handle = 6; ClassName = 'Other_Window_Class'; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 7; ExtendedStyle = 0x80000; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } }),
                (Copy-WindowCandidate $main @{ Handle = 8; ExtendedStyle = 0x80; Bounds = @{ X = 0; Y = 0; Width = 2000; Height = 1000 } })
            ) }
        )

        $foregroundHost = Get-ProbeCase $response 'foreground-host'
        Assert-Condition ($foregroundHost.HostHandle -eq 100) 'Если на переднем плане находится главное окно, необходимо выбрать то же главное окно процесса.'
        $foregroundTool = Get-ProbeCase $response 'foreground-tool'
        Assert-Condition ($foregroundTool.HostHandle -eq 100) 'Если передний план представляет собой инструмент/многослойное окно того же процесса, главное окно все равно должно быть расположено, а окно инструмента не должно быть целью возврата.'
        $nonCodexForeground = Get-ProbeCase $response 'foreground-non-codex'
        Assert-Condition ($null -eq $nonCodexForeground.HostHandle) 'Окна переднего плана, не относящиеся к Codex, не должны выдавать результаты выбора.'
        $tieBreaker = Get-ProbeCase $response 'largest-host-and-lowest-handle-tie'
        Assert-Condition ($tieBreaker.HostHandle -eq 110) 'Главное окно должно отдавать приоритет самой большой области и использовать самый маленький дескриптор, чтобы разорвать привязку областей.'
        $invalidNormal = Get-ProbeCase $response 'invalid-normal-candidates'
        Assert-Condition ($invalidNormal.HostHandle -eq 100) 'Кандидаты на скрытые, свернутые, принадлежащие, слишком маленькие, инструментальные/многоуровневые или неправильные имена классов не должны становиться главным окном.'

        $surfaceContract = Invoke-HostSurfaceContractReflectionProbe
        $classificationFieldsAreHostOnly = (@($foregroundHost.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'HostHandle,Name'
        $selectionTypeIsHostOnly = (@($surfaceContract.SelectionProperties) -join ',') -eq 'Host'
        $targetTypeIsHostOnly = (@($surfaceContract.TargetProperties) -join ',') -eq 'HostWindow'
        $removedHandleField = 'P' + 'etHandle'
        $removedBoundsField = 'P' + 'etBounds'
        $diagnosticFieldsAreHostOnly = `
            (@($surfaceContract.DiagnosticProperties) -contains 'HostHandle') -and `
            (-not (@($surfaceContract.DiagnosticProperties) -contains $removedHandleField)) -and `
            (-not (@($surfaceContract.DiagnosticProperties) -contains $removedBoundsField))
        $zOrderCasesAvailable = `
            ($surfaceContract.IgnoredOverlayThenHost -eq 100) -and `
            ($surfaceContract.ToolBeforeHost -eq 200) -and `
            ($surfaceContract.OtherAppBeforeHost -eq 300) -and `
            ($null -eq $surfaceContract.EmptyAfterIgnoredOverlay)
        Assert-Condition `
            ([string]::IsNullOrEmpty($surfaceContract.Error) -and $classificationFieldsAreHostOnly -and $selectionTypeIsHostOnly -and $targetTypeIsHostOnly -and $diagnosticFieldsAreHostOnly -and $surfaceContract.HasKnownHostMethod -and $zOrderCasesAvailable) `
            "Контракт поверхности главного окна должен быть только для хоста, при этом проникновение блокируется первым неигнорируемым полностью прямоугольным окном верхнего уровня. actual=$($surfaceContract | ConvertTo-Json -Compress -Depth 8)"
        Assert-Condition $surfaceContract.OwnShadowBeforeHostIsKnownHost `
            'SysShadow процесса строки состояния необходимо пропустить и перейти в главное окно Codex.'
        Assert-Condition $surfaceContract.HasCurrentProcessWrapper `
            'Метод получения идентификатора текущего процесса должен быть доступен.'
        Assert-Condition (-not $surfaceContract.ForeignShadowBeforeHostIsKnownHost) `
            'Изоморфные теневые окна других процессов должны продолжать блокироваться.'
        Assert-Condition (-not $surfaceContract.CodexNonHostBeforeHostIsKnownHost) `
            'Неосновные окна Codex должны оставаться заблокированными, и привязка домашних животных не может быть восстановлена.'
        Assert-Condition $surfaceContract.OwnUnreadableBeforeHostIsKnownHost `
            'Перед аварийным закрытием необходимо пропустить нечитаемое вспомогательное окно процесса строки состояния.'
        Assert-Condition (-not $surfaceContract.ForeignUnreadableBeforeHostIsKnownHost) `
            'Нечитаемые видимые окна других процессов должны оставаться закрытыми при сбое.'
        Assert-Condition (-not $surfaceContract.DestroyedForeignBeforeHostIsKnownHost) `
            'Кандидаты, уничтоженные во время чтения другими процессами, должны по-прежнему не закрываться.'
        Assert-Condition (-not $surfaceContract.ZeroIgnoredProcessDoesNotSkip) `
            'ignoreProcessId=0 Процесс не может проникнуть в кандидатов.'
        Assert-Condition $surfaceContract.ExplicitHandleStillSkippedWithZeroProcess `
            'Явное игнорирование дескриптора должно по-прежнему действовать, если ignoreProcessId=0.'
        $windowAssembly = [System.Reflection.Assembly]::LoadFrom($applicationDll)
        $windowLocatorType = $windowAssembly.GetType('CodexTokenOverlay.CodexWindowLocator', $true)
        $windowStaticFlags = [System.Reflection.BindingFlags]'Public, NonPublic, Static'
        $isPointOnKnownHost = $windowLocatorType.GetMethod('IsPointOnKnownHost', $windowStaticFlags)
        $currentProcessKnownHost = $windowLocatorType.GetMethod('IsUnderlyingWindowKnownHostForCurrentProcess', $windowStaticFlags)
        $productionPidWiring = `
            ($null -ne $isPointOnKnownHost) -and `
            ($null -ne $currentProcessKnownHost) -and `
            (Test-MethodCallChain `
                $isPointOnKnownHost `
                @($currentProcessKnownHost) `
                4)
        Assert-Condition `
            ($surfaceContract.HasCurrentProcessWrapper -and $surfaceContract.OwnShadowBeforeHostIsKnownHost -and $productionPidWiring) `
            'Проверка попадания курсора должна получать идентификатор текущего процесса во время выполнения.'
        Assert-Condition `
            (($null -ne $surfaceContract.VisibleInvalidBeforeHostIsKnownHost) -and (-not $surfaceContract.VisibleInvalidBeforeHostIsKnownHost) -and ($null -ne $surfaceContract.DestroyedDuringReadBeforeHostIsKnownHost) -and (-not $surfaceContract.DestroyedDuringReadBeforeHostIsKnownHost) -and $surfaceContract.RecoveredAfterCompleteReadsIsKnownHost -and $surfaceContract.InactiveInvalidBeforeHostIsKnownHost) `
            "Видимые прямоугольные поверхности сбоев считывания должны быть закрыты при сбое; следующее полное чтение и игнорируемые/невидимые/минимизированные сбои не должны навсегда блокировать восстановление. actual=$($surfaceContract | ConvertTo-Json -Compress -Depth 8)"

        $dpiAwareness = Invoke-WindowDpiAwarenessReflectionProbe
        Assert-Condition `
            ($dpiAwareness.DpiMode -eq 'PerMonitorV2') `
            "Датчики окон должны установить осведомленность о PerMonitorV2, прежде чем считывать индикаторы окон. фактическое=$($dpiAwareness.DpiMode)"

        $knownRefresh = Invoke-KnownTargetRefreshReflectionProbe
        Assert-Condition $knownRefresh.RefreshWhileOverlayForeground.Success 'Известно, что целевое обновление не должно зависеть от текущего окна переднего плана.'
        Assert-Condition ($knownRefresh.RefreshWhileOverlayForeground.HostHandle -eq 100) 'Известно, что целевое обновление должно сохранять исходный процесс Codex и возвращаться в текущее главное окно.'
        Assert-Rect $knownRefresh.RefreshWhileOverlayForeground.HostBounds 40 60 1500 1000 'Известно, что целевое обновление должно возвращать последний прямоугольник главного окна.'
        Assert-Condition (-not $knownRefresh.RejectProcessChange.Success) 'Известно, что целевое обновление должно отклонять изменения процесса.'
        Assert-Condition (-not $knownRefresh.DestroyedHostFailsClosed.Success) 'Уничтоженное исходное главное окно должно не закрываться.'
        Assert-Condition (-not $knownRefresh.ClassReadFailureAccepted) 'Кандидаты, для которых не удалось выполнить GetClassName, должны закрыться с ошибкой.'
        Assert-Condition (-not $knownRefresh.StyleReadFailureAccepted) 'Кандидаты на ошибки чтения в расширенном стиле должны закрываться с ошибкой.'
        Assert-Condition $knownRefresh.ZeroStyleWithoutErrorAccepted 'Расширенный стиль, равный нулю, но без ошибок Win32, считается допустимым чтением.'
        Assert-Condition $knownRefresh.SameConfirmedIdentityAccepted 'Тот же хост подтверждения + PID должен разрешать обновления известных целевых объектов.'
        Assert-Condition (-not $knownRefresh.ReusedHandleDifferentProcessAccepted) 'Тот же HWND, который повторно используется другими процессами, не должен обновляться.'
        Assert-Condition (-not $knownRefresh.DifferentHostSameProcessAccepted) 'Тот же процесс, но HWND другого хоста должен отказаться от обновления.'
    }

    if ($areas -contains 'Form') {
        $form = Invoke-JsonProbe '--form-probe' @(
            @{
                Name = 'non-activating-window-contract'
                CollapsedLayout = @{
                    State = 0
                    CollapsedDisplay = 0
                    ExpansionDirection = 0
                    Dpi = 96
                    WindowBounds = @{ X = 1400; Y = 100; Width = 196; Height = 34 }
                    CapsuleBounds = @{ X = 0; Y = 0; Width = 196; Height = 34 }
                    PanelBounds = @{ X = 0; Y = 0; Width = 0; Height = 0 }
                    ExpandedRowHeight = 0
                    ScalePercent = 100
                }
                Collapsed60Layout = @{
                    State = 0
                    CollapsedDisplay = 0
                    ExpansionDirection = 0
                    Dpi = 96
                    WindowBounds = @{ X = 1400; Y = 100; Width = 118; Height = 20 }
                    CapsuleBounds = @{ X = 0; Y = 0; Width = 118; Height = 20 }
                    PanelBounds = @{ X = 0; Y = 0; Width = 0; Height = 0 }
                    ExpandedRowHeight = 0
                    ScalePercent = 60
                }
                Collapsed130Layout = @{
                    State = 0
                    CollapsedDisplay = 0
                    ExpansionDirection = 0
                    Dpi = 96
                    WindowBounds = @{ X = 1400; Y = 100; Width = 255; Height = 44 }
                    CapsuleBounds = @{ X = 0; Y = 0; Width = 255; Height = 44 }
                    PanelBounds = @{ X = 0; Y = 0; Width = 0; Height = 0 }
                    ExpandedRowHeight = 0
                    ScalePercent = 130
                }
                ExpandedLayout = @{
                    State = 1
                    CollapsedDisplay = 0
                    ExpansionDirection = 0
                    Dpi = 96
                    WindowBounds = @{ X = 1326; Y = 100; Width = 270; Height = 304 }
                    CapsuleBounds = @{ X = 74; Y = 0; Width = 196; Height = 34 }
                    PanelBounds = @{ X = 0; Y = 40; Width = 270; Height = 264 }
                    ExpandedRowHeight = 30
                    ScalePercent = 100
                }
            }
        )

        $contract = Get-ProbeCase $form 'non-activating-window-contract'
        Assert-Condition $contract.WsExToolWindowPresent 'TokenStripForm должен установить WS_EX_TOOLWINDOW.'
        Assert-Condition $contract.WsExNoActivatePresent 'TokenStripForm должен установить WS_EX_NOACTIVATE.'
        Assert-Condition (-not $contract.WsExTransparentPresent) 'TokenStripForm не должен устанавливать WS_EX_TRANSPARENT.'
        Assert-Condition $contract.CsDropShadowPresent 'TokenStripForm следует запрашивать CS_DROPSHADOW.'
        Assert-Condition ($contract.MouseActivateResult -eq 3) 'WM_MOUSEACTIVATE должен возвращать MA_NOACTIVATE.'
        Assert-Condition ($contract.CapsuleCenterHitTest -ne -1) 'Центры капсул не должны возвращать HTTRANSPARENT.'
        Assert-Condition ($contract.PanelCenterHitTest -ne -1) 'Центр панели не должен возвращать значение HTTRANSPARENT.'
        Assert-Condition ($contract.TopLeftHitTest -eq -1) 'L-образный верхний левый угол должен возвращать значение HTTRANSPARENT.'
        Assert-Rect $contract.CollapsedBounds 1400 100 196 34 'Свернуть ApplyLayout должен соответствовать WindowBounds.'
        Assert-Rect $contract.ExpandedBounds 1326 100 270 304 'При расширении ApplyLayout WindowBounds должен применяться атомарно.'
        Assert-Condition ($contract.ExpandedSetBoundsCoreDelta -eq 1) 'При раскрытии ApplyLayout должен производиться только один вызов SetBoundsCore.'
        Assert-Condition $contract.ExpandedRegionMatchesUnion 'Расширенная область должна соответствовать объединению закругленных капсул и панелей.'
        Assert-Condition ($contract.NormalCapsuleClickCount -eq 1) 'В обычном режиме должно сохраняться существующее событие расширения щелчка капсулы.'
        Assert-Condition (-not $contract.NormalCommandIntercepted) 'Обычный режим не должен блокировать Enter или Esc.'
        Assert-Condition (-not $contract.NormalRenderDecorations.ShowBorder) 'В обычном режиме невозможно нарисовать границы редактирования.'
        Assert-Condition (-not $contract.NormalRenderDecorations.ShowDragHint) 'В обычном режиме невозможно отрисовать подсказки при перетаскивании.'
        Assert-Condition (-not $contract.NormalRenderDecorations.ShowResizeHandle) 'Маркеры масштабирования невозможно отрисовать в обычном режиме.'
        Assert-Condition $contract.BeginEditRejectsExpanded 'Режим редактирования должен отклонять несвернутые макеты.'
        Assert-Condition $contract.EditWsExToolWindowPresent 'В режиме редактирования по-прежнему должно быть установлено значение WS_EX_TOOLWINDOW.'
        Assert-Condition (-not $contract.EditWsExNoActivatePresent) 'В режиме редактирования необходимо временно удалить WS_EX_NOACTIVATE.'
        Assert-Condition ($contract.EditMouseActivateResult -ne 3) 'Режим редактирования не должен принудительно возвращать WM_MOUSEACTIVATE в MA_NOACTIVATE.'
        Assert-Condition $contract.EditIsCollapsed 'В режиме редактирования должен сохраняться свернутый макет.'
        Assert-Condition ($contract.EditCapsuleClickCount -eq 0) 'Режим редактирования не должен запускать расширение щелчка капсулы.'
        Assert-Rect $contract.EditResizeHandle60 111 13 7 7 '60% Ручка масштабирования редактирования должна находиться на расстоянии 7 пикселей от правого нижнего угла.'
        Assert-Rect $contract.EditResizeHandle100 184 22 12 12 'Маркер масштаба редактирования 100 % должен находиться на 12 пикселей ниже справа.'
        Assert-Rect $contract.EditResizeHandle130 239 28 16 16 '130% Ручка масштабирования редактирования должна иметь размер 16 пикселей в правом нижнем углу.'
        foreach ($decoration in @($contract.EditRenderDecorations60, $contract.EditRenderDecorations100, $contract.EditRenderDecorations130)) {
            Assert-Condition $decoration.ShowBorder 'В режиме редактирования границы должны быть тонкими.'
            Assert-Condition $decoration.ShowDragHint 'Подсказки для перетаскивания необходимо рисовать в режиме редактирования.'
            Assert-Condition $decoration.ShowResizeHandle 'В режиме редактирования должен отображаться нижний правый маркер масштабирования.'
            Assert-Condition (-not [string]::IsNullOrWhiteSpace($decoration.DragHintText)) 'Запрос на изменение перетаскивания не может быть пустым.'
        }
        Assert-Rect $contract.EditRenderDecorations60.DragHintBounds 6 0 94 20 '60% Макет подсказки о перетаскивании должен масштабироваться в соответствии с единым индикатором.'
        Assert-Rect $contract.EditRenderDecorations100.DragHintBounds 10 0 156 34 'Макет приглашения на 100% перетаскивание должен использовать область содержимого капсулы.'
        Assert-Rect $contract.EditRenderDecorations130.DragHintBounds 13 0 203 44 '130% Макет подсказки о перетаскивании должен масштабироваться в соответствии с унифицированным индикатором.'
        Assert-Condition `
            ($contract.EditRenderDecorations60.DragHintFontPoints -eq 5.4 -and $contract.EditRenderDecorations100.DragHintFontPoints -eq 9.0 -and $contract.EditRenderDecorations130.DragHintFontPoints -eq 11.7) `
            'Размер шрифта подсказки при перетаскивании должен учитывать масштаб из OverlayRenderMetrics.'
        Assert-Condition ($contract.MovePreview.Kind -eq 0) 'Моделирование перетаскивания должно сообщать о перемещении.'
        Assert-Condition `
            ($contract.MovePreview.CursorScreen.X -eq 1528 -and $contract.MovePreview.CursorScreen.Y -eq 137) `
            'Предварительный просмотр при перетаскивании должен сообщать о реальном курсоре на экране.'
        Assert-Rect $contract.MovePreviewBounds 1430 120 196 34 'Перетаскивание предварительного просмотра может изменить положение только с шагом на экране.'
        Assert-Condition $contract.MovePreservedSize 'При перетаскивании предварительного просмотра размер не должен меняться.'
        Assert-Condition ($contract.MinimumResizePreview.Kind -eq 1) 'Моделирование масштабирования должно сообщать об изменении размера.'
        Assert-Condition ($contract.MinimumResizePreview.ScalePercent -eq 60) 'Масштаб предварительного просмотра должен быть ограничен ровно 60 %.'
        Assert-Condition ($contract.MaximumResizePreview.ScalePercent -eq 130) 'Масштаб предварительного просмотра должен быть ограничен ровно до 130 %.'
        Assert-Condition `
            ($contract.MinimumResizePreview.FixedTopLeft.X -eq 1400 -and $contract.MinimumResizePreview.FixedTopLeft.Y -eq 100) `
            'Минимальное масштабирование должно оставаться фиксированным в верхнем левом углу.'
        Assert-Condition `
            ($contract.MaximumResizePreview.FixedTopLeft.X -eq 1400 -and $contract.MaximumResizePreview.FixedTopLeft.Y -eq 100) `
            'Максимальный масштаб должен оставаться зафиксированным в левом верхнем углу.'
        foreach ($lostCapture in @($contract.LostMoveCapture, $contract.LostResizeCapture)) {
            Assert-Condition $lostCapture.ActiveBeforeInterruption 'После создания предварительного просмотра жесты должны оставаться активными.'
            Assert-Condition (-not $lostCapture.ActiveAfterInterruption) 'Потеря внешнего захвата должна привести к выходу из состояния жеста.'
            Assert-Condition (-not $lostCapture.ActiveAfterRepeatedSignals) 'Повторная потеря захвата/MouseUp нельзя повторно активировать или завершать повторно.'
            Assert-Condition (-not $lostCapture.CaptureAfterInterruption) 'Формы не должны сохранять захват мыши после потери внешнего захвата.'
            Assert-Condition ($lostCapture.CompletionCount -eq 1) 'Потеря внешнего захвата. Жест необходимо выполнить ровно один раз.'
            Assert-Condition ($lostCapture.Completed.Kind -eq $lostCapture.ExpectedKind) 'Потеря захвата. Событие завершения должно сохранять тип жеста.'
            Assert-Condition `
                ($lostCapture.Completed.CursorScreen.X -eq $lostCapture.Preview.CursorScreen.X -and $lostCapture.Completed.CursorScreen.Y -eq $lostCapture.Preview.CursorScreen.Y) `
                'В событии завершения потери захвата должен использоваться последний курсор предварительного просмотра продукции.'
            Assert-Condition ($lostCapture.Completed.ScalePercent -eq $lostCapture.Preview.ScalePercent) 'Событие завершения потери захвата должно сохранять последний масштаб предварительного просмотра.'
        }
        Assert-Condition ($contract.LostMoveCapture.Completed.CursorScreen.X -eq 1529 -and $contract.LostMoveCapture.Completed.CursorScreen.Y -eq 136) 'При потере захвата перемещения необходимо сообщать точный курсор на экране.'
        Assert-Condition ($contract.LostResizeCapture.Completed.CursorScreen.X -eq 1621 -and $contract.LostResizeCapture.Completed.CursorScreen.Y -eq 147) 'Потеря захвата при изменении размера должна сообщать точный курсор на экране.'
        Assert-Condition ($contract.CancelCapture.CancelRequestCount -eq 1) 'Esc для отмены пути должен вызвать запрос на отмену.'
        Assert-Condition ($contract.CancelCapture.CompletionCount -eq 0) 'Esc/EndEditMode не должен вызывать ложное завершение жеста.'
        Assert-Condition (-not $contract.CancelCapture.ActiveAfterInterruption -and -not $contract.CancelCapture.CaptureAfterInterruption) 'Esc/EndEditMode должен автоматически очищать состояние захвата и жестов.'
        Assert-Condition ($contract.DisposeCapture.CompletionCount -eq 0) 'Dispose не должен вызывать ложное завершение жестов.'
        Assert-Condition (-not $contract.DisposeCapture.ActiveAfterInterruption -and -not $contract.DisposeCapture.CaptureAfterInterruption) 'Dispose должен автоматически очищать состояние захвата и жестов.'
        Assert-Condition ($contract.EditGestureCompletionCount -eq 3) 'Три смоделированных жеста должны вызывать событие завершения при отпускании мыши.'
        Assert-Condition ($contract.SaveRequestCount -eq 1) 'Вход в режим редактирования должен вызывать сохранение только один раз.'
        Assert-Condition ($contract.CancelRequestCount -eq 1) 'Состояние редактирования Esc должно инициировать отмену только один раз.'
        Assert-Condition $contract.RestoredWsExNoActivatePresent 'WS_EX_NOACTIVATE необходимо восстановить после завершения редактирования.'
        Assert-Condition ($contract.RestoredMouseActivateResult -eq 3) 'WM_MOUSEACTIVATE должен вернуться к MA_NOACTIVATE после завершения редактирования.'

        Assert-Condition `
            ($contract.Metrics60.LabelFontPoints -eq 5.4 -and $contract.Metrics100.LabelFontPoints -eq 9.0 -and $contract.Metrics130.LabelFontPoints -eq 11.7) `
            'Шрифты меток должны использовать единый пользовательский коэффициент масштабирования.'
        Assert-Condition `
            ($contract.Metrics60.CompactValueFontPoints -eq 6.6 -and $contract.Metrics100.CompactValueFontPoints -eq 11.0 -and $contract.Metrics130.CompactValueFontPoints -eq 14.3) `
            'Для компактных шрифтов должен использоваться единый пользовательский коэффициент масштабирования.'
        Assert-Condition `
            ($contract.Metrics60.PanelHeaderFontPoints -eq 7.2 -and $contract.Metrics100.PanelHeaderFontPoints -eq 12.0 -and $contract.Metrics130.PanelHeaderFontPoints -eq 15.6) `
            'Шрифты заголовков панелей должны использовать единый пользовательский коэффициент масштабирования.'
        Assert-Condition `
            ($contract.Metrics60.HighlightedValueFontPoints -eq 8.4 -and $contract.Metrics100.HighlightedValueFontPoints -eq 14.0 -and $contract.Metrics130.HighlightedValueFontPoints -eq 18.2) `
            'Шрифты со значением выделения должны использовать единый пользовательский коэффициент масштабирования.'
        Assert-Condition `
            ($contract.Metrics60.CapsuleRadius -eq 6 -and $contract.Metrics100.CapsuleRadius -eq 10 -and $contract.Metrics130.CapsuleRadius -eq 13) `
            'При округлении капсулы необходимо использовать единый коэффициент масштабирования DPI/пользователя.'
        Assert-Condition `
            ($contract.Metrics60.PanelRadius -eq 8 -and $contract.Metrics100.PanelRadius -eq 14 -and $contract.Metrics130.PanelRadius -eq 18) `
            'Для закругления углов панели необходимо использовать единый коэффициент масштабирования DPI/пользователя.'
        Assert-Condition `
            ($contract.Metrics60.HorizontalPadding -eq 6 -and $contract.Metrics100.HorizontalPadding -eq 10 -and $contract.Metrics130.HorizontalPadding -eq 13) `
            'Для горизонтального заполнения необходимо использовать единый коэффициент масштабирования DPI/пользователя.'
        Assert-Condition `
            ($contract.Metrics60.MetricGap -eq 5 -and $contract.Metrics100.MetricGap -eq 8 -and $contract.Metrics130.MetricGap -eq 10) `
            'Для расстояния между индикаторами должен использоваться единый коэффициент масштабирования DPI/пользователя.'
        Assert-Condition `
            ($contract.Metrics60.DividerHeight -eq 8 -and $contract.Metrics100.DividerHeight -eq 14 -and $contract.Metrics130.DividerHeight -eq 18) `
            'В разделителях должен использоваться единый коэффициент масштабирования DPI/пользователя.'
        Assert-Condition `
            ($contract.Metrics60.PanelPadding -eq 8 -and $contract.Metrics100.PanelPadding -eq 14 -and $contract.Metrics130.PanelPadding -eq 18) `
            'Для заполнения панели должен использоваться единый коэффициент масштабирования DPI/пользователя.'
        Assert-Condition `
            ($contract.Metrics60.EditHandleSize -eq 7 -and $contract.Metrics100.EditHandleSize -eq 12 -and $contract.Metrics130.EditHandleSize -eq 16) `
            'При редактировании маркеров масштабирования необходимо использовать единый коэффициент масштабирования DPI/пользователя.'

        Assert-Condition $contract.HighlightWsExToolWindowPresent 'Для выделения цели необходимо установить WS_EX_TOOLWINDOW.'
        Assert-Condition $contract.HighlightWsExNoActivatePresent 'Для выделения цели необходимо установить WS_EX_NOACTIVATE.'
        Assert-Condition $contract.HighlightWsExTransparentPresent 'Для выделения цели необходимо установить WS_EX_TRANSPARENT.'
        Assert-Condition (-not $contract.HighlightShowInTaskbar) 'Подсветка цели не должна отображаться на панели задач.'
        Assert-Condition ($contract.HighlightSetBoundsCoreDelta -eq 1) 'ShowTarget должен обновлять целевые границы с помощью SetBounds только один раз.'
        Assert-Rect $contract.HighlightBounds 300 240 420 260 'Целевое выделение должно совпадать с границами целевого окна.'
        $expectedHighlightThickness = [Math]::Max(
            1,
            [int][Math]::Round(
                2 * $contract.HighlightDeviceDpi / 96.0,
                [MidpointRounding]::AwayFromZero))
        Assert-Condition `
            ($contract.HighlightExpectedRingThicknessPixels -eq $expectedHighlightThickness) `
            "Ширина кольца DIP целевой подсветки 2 должна быть преобразована в текущее значение DPI. dpi=$($contract.HighlightDeviceDpi) ожидаемый=$expectedHighlightThickness проверка=$($contract.HighlightExpectedRingThicknessPixels)"
        Assert-Condition $contract.HighlightHasRingRegion 'Для выделения цели должно использоваться четырехстороннее кольцо. Область размером ровно 2 DIP.'
        Assert-Condition ($contract.HighlightHitTest -eq -1) 'Для проникновения необходимо нажать на выделение цели.'
        Assert-Condition $contract.HighlightHiddenAfterClear 'ClearTarget должен скрывать подсветку цели.'
        Assert-Condition $contract.HighlightRegionCleared 'ClearTarget должен освободить и очистить старый регион.'
    }

    Write-Host "Логические проверки Overlay пройдены: $($areas -join ', ')"
}
finally {
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $isInsideTemporaryRoot = $resolvedTestRoot.StartsWith(
        $temporaryRoot,
        [StringComparison]::OrdinalIgnoreCase)
    $hasExpectedPrefix = (Split-Path -Leaf $resolvedTestRoot).StartsWith(
        'CodexTokenOverlayLogicTests-',
        [StringComparison]::Ordinal)
    if ($isInsideTemporaryRoot -and $hasExpectedPrefix) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
