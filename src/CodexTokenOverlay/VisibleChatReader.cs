using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;

namespace CodexTokenOverlay;

internal sealed class VisibleChatReader(string sessionRoot)
{
    private static readonly Condition ChatToolbar = new AndCondition(
        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ToolBar),
        new OrCondition(
            new PropertyCondition(AutomationElement.NameProperty, "Панель инструментов чата"),
            new PropertyCondition(AutomationElement.NameProperty, "Chat toolbar")));

    private readonly string _indexPath = Path.Combine(
        Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(sessionRoot)) ?? sessionRoot,
        "session_index.jsonl");
    private readonly Dictionary<Guid, string> _titles = new();
    private (long Length, DateTime LastWriteUtc)? _indexVersion;

    public string? ReadThreadId(IntPtr window)
    {
        try
        {
            var toolbars = AutomationElement.FromHandle(window).FindAll(TreeScope.Descendants, ChatToolbar);
            if (toolbars.Count != 1)
            {
                return null;
            }

            var child = TreeWalker.ControlViewWalker.GetFirstChild(toolbars[0]);
            if (child?.Current.ControlType == ControlType.Image)
            {
                child = TreeWalker.ControlViewWalker.GetNextSibling(child);
            }
            var title = child?.Current.Name;
            if (child?.Current.ControlType != ControlType.Button
                && child?.Current.ControlType != ControlType.Text
                || string.IsNullOrWhiteSpace(title))
            {
                return null;
            }

            RefreshIndex();
            var matches = _titles.Where(entry => string.Equals(entry.Value, title, StringComparison.Ordinal))
                .Take(2)
                .ToArray();
            return matches.Length == 1 ? matches[0].Key.ToString() : null;
        }
        catch (Exception error) when (
            error is ElementNotAvailableException or COMException or ArgumentException
                or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void RefreshIndex()
    {
        var info = new FileInfo(_indexPath);
        var version = (info.Length, info.LastWriteTimeUtc);
        if (version == _indexVersion)
        {
            return;
        }

        _indexVersion = null;
        _titles.Clear();
        using var stream = File.Open(_indexPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        while (reader.ReadLine() is { } line)
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                var entry = document.RootElement;
                if (entry.ValueKind == JsonValueKind.Object
                    && entry.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String
                    && id.TryGetGuid(out var threadId)
                    && entry.TryGetProperty("thread_name", out var name) && name.ValueKind == JsonValueKind.String)
                {
                    _titles[threadId] = name.GetString()!;
                }
            }
            catch (JsonException)
            {
                // The last line may still be in the process of being written.
            }
        }

        _indexVersion = version;
    }
}
