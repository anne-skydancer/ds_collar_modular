using Newtonsoft.Json.Linq;

namespace DSCollarTests;

/// <summary>
/// Helper utilities for DS Collar testing
/// </summary>
public static class TestHelpers
{
    public const string NULL_KEY = "00000000-0000-0000-0000-000000000000";
    public const string TEST_AVATAR = "12345678-1234-1234-1234-123456789012";
    
    // Channel constants (must match LSL scripts)
    public const int KERNEL_LIFECYCLE = 500;
    public const int AUTH_BUS = 700;
    public const int SETTINGS_BUS = 800;
    public const int UI_BUS = 900;
    public const int DIALOG_BUS = 950;

    /// <summary>
    /// Create a routed JSON message with optional "to" field
    /// </summary>
    public static string CreateRoutedMessage(string to, params object[] keyValues)
    {
        var obj = new JObject();
        
        // Add routing
        if (!string.IsNullOrEmpty(to))
            obj["to"] = to;
        
        // Add key-value pairs
        for (int i = 0; i < keyValues.Length - 1; i += 2)
        {
            string key = keyValues[i].ToString()!;
            object value = keyValues[i + 1];
            
            if (value is string s)
                obj[key] = s;
            else if (value is int n)
                obj[key] = n;
            else if (value is bool b)
                obj[key] = b;
            else
                obj[key] = value.ToString();
        }
        
        return obj.ToString(Newtonsoft.Json.Formatting.None);
    }

    /// <summary>
    /// Create unrouted JSON message (no "to" field)
    /// </summary>
    public static string CreateMessage(params object[] keyValues)
    {
        return CreateRoutedMessage("", keyValues);
    }

    /// <summary>
    /// Create ACL result message
    /// </summary>
    public static string CreateACLResult(string avatar, int level)
    {
        return CreateMessage("type", "acl_result", "avatar", avatar, "level", level);
    }

    /// <summary>
    /// Create UI start message
    /// </summary>
    public static string CreateUIStart(string scriptId, string avatar)
    {
        return CreateRoutedMessage(scriptId, "type", "start", "avatar", avatar);
    }

    /// <summary>
    /// Create dialog response message
    /// </summary>
    public static string CreateDialogResponse(string sessionId, string button, string avatar)
    {
        return CreateMessage(
            "type", "dialog_response",
            "session_id", sessionId,
            "button", button,
            "avatar", avatar
        );
    }

    /// <summary>
    /// Parse JSON field value
    /// </summary>
    public static string GetJsonField(string json, string field)
    {
        try
        {
            var obj = JObject.Parse(json);
            return obj[field]?.ToString() ?? "";
        }
        catch
        {
            return "";
        }
    }

    /// <summary>
    /// Check if JSON has field
    /// </summary>
    public static bool JsonHasField(string json, string field)
    {
        try
        {
            var obj = JObject.Parse(json);
            return obj.ContainsKey(field);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Load LSL script from file
    /// </summary>
    public static string LoadScript(string filename)
    {
        // Navigate from test_harness/bin/Debug/net8.0 to src/ng/
        string projectRoot = Path.GetFullPath(Path.Combine(
            AppContext.BaseDirectory, 
            "..", "..", "..", "..", "src", "ng"
        ));
        
        string path = Path.Combine(projectRoot, filename);
        
        if (!File.Exists(path))
            throw new FileNotFoundException($"Script not found: {path}");
        
        return File.ReadAllText(path);
    }

    /// <summary>
    /// Assert that message was sent on specific channel
    /// </summary>
    public static void AssertMessageSentOn(List<LSLTestHarness.LinkMessage> messages, int channel, string msgType)
    {
        var found = messages.Any(m => 
            m.Num == channel && 
            GetJsonField(m.Msg, "type") == msgType
        );
        
        if (!found)
        {
            var channelMsgs = string.Join("\n", messages.Where(m => m.Num == channel).Select(m => m.Msg));
            throw new AssertionException(
                $"Expected message type '{msgType}' on channel {channel}\n" +
                $"Messages on channel {channel}:\n{channelMsgs}"
            );
        }
    }

    /// <summary>
    /// Assert that no message was sent
    /// </summary>
    public static void AssertNoMessageSent(List<LSLTestHarness.LinkMessage> messages)
    {
        if (messages.Any())
        {
            var msgList = string.Join("\n", messages.Select(m => $"  ch:{m.Num} {m.Msg}"));
            throw new AssertionException($"Expected no messages, but got:\n{msgList}");
        }
    }
}

public class AssertionException : Exception
{
    public AssertionException(string message) : base(message) { }
}
