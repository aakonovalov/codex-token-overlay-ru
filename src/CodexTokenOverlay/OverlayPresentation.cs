using System.Globalization;

namespace CodexTokenOverlay;

internal sealed record OverlayMetric(
    DisplayField Field,
    string CompactLabel,
    string ExpandedLabel,
    string Value,
    bool HasValue);

internal sealed record OverlayPresentation(
    OverlayMetric Primary,
    OverlayMetric Secondary,
    IReadOnlyList<OverlayMetric> ExpandedRows,
    double ContextPercent,
    bool ShowContextProgress,
    string? StatusText);

internal static class OverlayPresentationBuilder
{
    private const string NoValue = "—";

    public static OverlayPresentation CreateWaiting(
        string statusText,
        DisplayField primaryField,
        DisplayField secondaryField,
        DisplayField visibleFields)
    {
        ValidateHighlightedFields(primaryField, secondaryField);
        return new OverlayPresentation(
            CreateWaitingMetric(primaryField),
            CreateWaitingMetric(secondaryField),
            CreateExpandedRows(visibleFields, primaryField, secondaryField, CreateWaitingMetric),
            0,
            false,
            SanitizeSingleLine(statusText));
    }

    public static OverlayPresentation Create(
        TokenSnapshot snapshot,
        DisplayField primaryField,
        DisplayField secondaryField,
        DisplayField visibleFields)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ValidateHighlightedFields(primaryField, secondaryField);
        var contextPercent = snapshot.ContextPercent;
        return new OverlayPresentation(
            CreateMetric(snapshot, primaryField, contextPercent),
            CreateMetric(snapshot, secondaryField, contextPercent),
            CreateExpandedRows(
                visibleFields,
                primaryField,
                secondaryField,
                field => CreateMetric(snapshot, field, contextPercent)),
            contextPercent,
            snapshot.HasContextUsage && (visibleFields & (DisplayField.ContextPercent | DisplayField.ContextRemaining)) != 0,
            null);
    }

    public static string FormatTokenCount(long value) => value switch
    {
        >= 1_000_000 => (value / 1_000_000d).ToString("0.00", CultureInfo.InvariantCulture) + "M",
        >= 1_000 => (value / 1_000d).ToString("0.0", CultureInfo.InvariantCulture) + "k",
        _ => value.ToString("N0", CultureInfo.InvariantCulture)
    };

    public static string ShortThreadId(string threadId, int maximumLength = 12)
    {
        var singleLineThreadId = SanitizeSingleLine(threadId);
        if (singleLineThreadId.Length <= maximumLength)
        {
            return singleLineThreadId;
        }

        if (maximumLength <= 1)
        {
            return maximumLength == 1 ? "…" : string.Empty;
        }

        var prefixLength = Math.Min(4, maximumLength - 1);
        var suffixLength = Math.Min(6, maximumLength - prefixLength - 1);
        return string.Concat(
            singleLineThreadId.AsSpan(0, prefixLength),
            "…",
            singleLineThreadId.AsSpan(singleLineThreadId.Length - suffixLength, suffixLength));
    }

    public static string GetFieldMenuText(DisplayField field)
    {
        return field switch
        {
            DisplayField.Total => "Всего токенов",
            DisplayField.Input => "Входные токены",
            DisplayField.Output => "Выходные токены",
            DisplayField.CacheHit => "Токены из кэша",
            DisplayField.CacheHitRate => "Доля токенов из кэша",
            DisplayField.CacheMiss => "Токены вне кэша (расчёт)",
            DisplayField.Context => "Использовано контекста",
            DisplayField.ContextRemaining => "Свободный контекст (%)",
            DisplayField.ContextPercent => "Использовано контекста (%)",
            DisplayField.Reasoning => "Токены рассуждения",
            DisplayField.Thread => "ID чата",
            _ => throw new ArgumentOutOfRangeException(nameof(field), field, "Неподдерживаемое поле отображения.")
        };
    }

    private static void ValidateHighlightedFields(DisplayField primaryField, DisplayField secondaryField)
    {
        if (!DisplayFieldRules.IsSingleSupported(primaryField)
            || !DisplayFieldRules.IsSingleSupported(secondaryField))
        {
            throw new ArgumentException("Для свёрнутого режима нужно выбрать одно поддерживаемое поле.");
        }
    }

    private static IReadOnlyList<OverlayMetric> CreateExpandedRows(
        DisplayField visibleFields,
        DisplayField primaryField,
        DisplayField secondaryField,
        Func<DisplayField, OverlayMetric> createMetric)
    {
        return DisplayFieldRules.Ordered
            .Where(field => (visibleFields & field) != 0)
            .Where(field => field != primaryField && field != secondaryField)
            .Select(createMetric)
            .ToArray();
    }

    private static OverlayMetric CreateWaitingMetric(DisplayField field)
    {
        var labels = GetLabels(field);
        return new OverlayMetric(field, labels.Compact, labels.Expanded, NoValue, false);
    }

    private static OverlayMetric CreateMetric(
        TokenSnapshot snapshot,
        DisplayField field,
        double contextPercent)
    {
        var labels = GetLabels(field);
        if (field is DisplayField.Context or DisplayField.ContextPercent or DisplayField.ContextRemaining
            && !snapshot.HasContextUsage)
        {
            return new OverlayMetric(field, labels.Compact, labels.Expanded, NoValue, false);
        }

        var value = field switch
        {
            DisplayField.Total => FormatTokenCount(snapshot.TotalTokens),
            DisplayField.Input => FormatTokenCount(snapshot.InputTokens),
            DisplayField.Output => FormatTokenCount(snapshot.OutputTokens),
            DisplayField.CacheHit => FormatTokenCount(snapshot.CachedInputTokens),
            DisplayField.CacheHitRate => $"{snapshot.CacheHitPercent:0}%",
            DisplayField.CacheMiss => FormatTokenCount(snapshot.UncachedInputTokens),
            DisplayField.Context => $"{FormatTokenCount(snapshot.ContextUsedTokens)} / {FormatTokenCount(snapshot.ContextWindowTokens)}",
            DisplayField.ContextRemaining => $"{100 - contextPercent:0.0}%",
            DisplayField.ContextPercent => $"{contextPercent:0}%",
            DisplayField.Reasoning => FormatTokenCount(snapshot.ReasoningOutputTokens),
            DisplayField.Thread => ShortThreadId(snapshot.ThreadId),
            _ => throw new ArgumentOutOfRangeException(nameof(field), field, "Неподдерживаемое поле отображения.")
        };
        var hasValue = field != DisplayField.Thread || !string.IsNullOrWhiteSpace(snapshot.ThreadId);
        return new OverlayMetric(field, labels.Compact, labels.Expanded, value, hasValue);
    }

    private static (string Compact, string Expanded) GetLabels(DisplayField field)
    {
        return field switch
        {
            DisplayField.Total => ("Всего", "Всего токенов"),
            DisplayField.Input => ("Вход", "Входные токены"),
            DisplayField.Output => ("Выход", "Выходные токены"),
            DisplayField.CacheHit => ("Кэш", "Токены из кэша"),
            DisplayField.CacheHitRate => ("Кэш %", "Доля токенов из кэша"),
            DisplayField.CacheMiss => ("Вне кэша", "Токены вне кэша"),
            DisplayField.Context => ("Контекст", "Занято контекста"),
            DisplayField.ContextRemaining => ("Ост.", "Свободный контекст"),
            DisplayField.ContextPercent => ("Контекст", "Заполнено (%)"),
            DisplayField.Reasoning => ("Рассужд.", "Токены рассуждения"),
            DisplayField.Thread => ("Чат", "Чат"),
            _ => throw new ArgumentOutOfRangeException(nameof(field), field, "Неподдерживаемое поле отображения.")
        };
    }

    private static string SanitizeSingleLine(string value)
    {
        return value.Replace("\r", string.Empty, StringComparison.Ordinal)
            .Replace("\n", string.Empty, StringComparison.Ordinal);
    }
}

internal sealed class PresentationProbeRequest
{
    public List<PresentationProbeCase> Cases { get; set; } = new();
}

internal sealed class PresentationProbeCase
{
    public string Name { get; set; } = string.Empty;
    public string Operation { get; set; } = string.Empty;
    public TokenSnapshot? Snapshot { get; set; }
    public int? PrimaryField { get; set; }
    public int? SecondaryField { get; set; }
    public int? VisibleFields { get; set; }
    public string? StatusText { get; set; }
}

internal sealed record PresentationProbeCaseResult(string Name, OverlayPresentation Presentation);

internal sealed record PresentationProbeResult(IReadOnlyList<PresentationProbeCaseResult> Cases);

internal static class PresentationProbe
{
    public static PresentationProbeResult Execute(PresentationProbeRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var results = new List<PresentationProbeCaseResult>();
        foreach (var probeCase in request.Cases)
        {
            var primaryField = RequireField(probeCase.PrimaryField, nameof(probeCase.PrimaryField));
            var secondaryField = RequireField(probeCase.SecondaryField, nameof(probeCase.SecondaryField));
            var visibleFields = (DisplayField)(probeCase.VisibleFields ?? 0);
            var presentation = probeCase.Operation switch
            {
                "Create" => OverlayPresentationBuilder.Create(
                    probeCase.Snapshot ?? throw new ArgumentException("Для операции Create требуется значение Snapshot.", nameof(probeCase)),
                    primaryField,
                    secondaryField,
                    visibleFields),
                "Waiting" => OverlayPresentationBuilder.CreateWaiting(
                    probeCase.StatusText ?? string.Empty,
                    primaryField,
                    secondaryField,
                    visibleFields),
                _ => throw new ArgumentException($"Не поддерживается операция проверки отображения: {probeCase.Operation}", nameof(probeCase))
            };
            results.Add(new PresentationProbeCaseResult(probeCase.Name, presentation));
        }

        return new PresentationProbeResult(results);
    }

    private static DisplayField RequireField(int? value, string parameterName)
    {
        if (!value.HasValue)
        {
            throw new ArgumentException("Для проверки отображения требуется поле.", parameterName);
        }

        return (DisplayField)value.Value;
    }
}
