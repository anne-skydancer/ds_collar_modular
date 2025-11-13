using System.Text.RegularExpressions;

namespace LSLTestHarness;

/// <summary>
/// Injects LSL events into scripts for testing. Simulates event dispatch
/// by parsing the script and executing event handler code.
/// </summary>
public class EventInjector
{
    private readonly MockLSLApi _api;
    private readonly Dictionary<string, List<string>> _eventHandlers = new();

    public EventInjector(MockLSLApi api)
    {
        _api = api;
    }

    public void Reset()
    {
        _eventHandlers.Clear();
    }

    // ========================================================================
    // Event Injection Methods
    // ========================================================================

    public void InjectStateEntry(string scriptCode)
    {
        ExecuteEventHandler(scriptCode, "state_entry", Array.Empty<object>());
    }

    public void InjectOnRez(string scriptCode, int startParam)
    {
        ExecuteEventHandler(scriptCode, "on_rez", new object[] { startParam });
    }

    public void InjectTouchStart(string scriptCode, string avatarKey)
    {
        ExecuteEventHandler(scriptCode, "touch_start", new object[] { 1 });
    }

    public void InjectTimer(string scriptCode)
    {
        ExecuteEventHandler(scriptCode, "timer", Array.Empty<object>());
    }

    public void InjectLinkMessage(string scriptCode, int sender, int num, string msg, string id)
    {
        // This is the critical event for DS Collar testing
        // We need to simulate the routing logic execution
        
        // Extract link_message handler
        var handlerCode = ExtractEventHandler(scriptCode, "link_message");
        if (string.IsNullOrEmpty(handlerCode))
            return;

        // Simulate basic routing check
        SimulateLinkMessageRouting(handlerCode, sender, num, msg, id);
    }

    public void InjectListen(string scriptCode, int channel, string name, string id, string message)
    {
        ExecuteEventHandler(scriptCode, "listen", new object[] { channel, name, id, message });
    }

    public void InjectChanged(string scriptCode, int change)
    {
        ExecuteEventHandler(scriptCode, "changed", new object[] { change });
    }

    // ========================================================================
    // Simulation Logic
    // ========================================================================

    private void SimulateLinkMessageRouting(string handlerCode, int sender, int num, string msg, string id)
    {
        // Parse JSON message
        string msgType = ParseJsonField(msg, "type");
        string msgTo = ParseJsonField(msg, "to");
        string msgContext = ParseJsonField(msg, "context");

        string? scriptContext = _api.GetScriptContext();

        // Check for routing mode in script
        string routingMode = ExtractConstant(handlerCode, "ROUTING_MODE") ?? "STRICT";

        bool shouldProcess = false;

        if (routingMode == "STRICT")
        {
            // STRICT: Only accept exact SCRIPT_ID match
            string scriptId = ExtractConstant(handlerCode, "SCRIPT_ID") ?? scriptContext ?? "";
            shouldProcess = (msgTo == scriptId);
        }
        else if (routingMode == "CONTEXT")
        {
            // CONTEXT: Accept context match
            shouldProcess = (msgContext == scriptContext);
        }
        else if (routingMode == "BROADCAST")
        {
            // BROADCAST: Accept wildcard
            shouldProcess = (msgTo == "*" || msgTo == scriptContext);
        }

        if (!shouldProcess)
            return; // Message filtered out

        // Message accepted - simulate handler execution
        SimulateMessageProcessing(handlerCode, msgType, msg, num);
    }

    private void SimulateMessageProcessing(string handlerCode, string msgType, string msg, int channel)
    {
        // Look for common patterns in message handling
        
        // Pattern 1: Kernel lifecycle (channel 500)
        if (channel == 500)
        {
            if (msgType == "register_now")
            {
                // Simulate register_self() call
                SimulateRegisterSelf(handlerCode);
            }
            else if (msgType == "ping")
            {
                // Simulate send_pong() call
                SimulateSendPong(handlerCode);
            }
        }
        
        // Pattern 2: UI start (channel 900)
        if (channel == 900 && msgType == "start")
        {
            // Simulate ACL request
            SimulateACLRequest(msg);
        }
        
        // Pattern 3: ACL result (channel 700)
        if (channel == 700 && msgType == "acl_result")
        {
            // Simulate menu display
            SimulateMenuDisplay(handlerCode);
        }
        
        // Pattern 4: Dialog response (channel 950)
        if (channel == 950 && msgType == "dialog_response")
        {
            string button = ParseJsonField(msg, "button");
            SimulateButtonClick(handlerCode, button);
        }
    }

    private void SimulateRegisterSelf(string scriptCode)
    {
        // Extract plugin identity
        string context = ExtractConstant(scriptCode, "PLUGIN_CONTEXT") ?? "unknown";
        string label = ExtractConstant(scriptCode, "PLUGIN_LABEL") ?? "Unknown";
        string minAcl = ExtractConstant(scriptCode, "PLUGIN_MIN_ACL") ?? "3";

        // Build registration message
        string regMsg = $"{{\"type\":\"register\",\"context\":\"{context}\",\"label\":\"{label}\",\"min_acl\":{minAcl}}}";
        
        _api.llMessageLinked(-1, 500, regMsg, MockLSLApi.NULL_KEY);
    }

    private void SimulateSendPong(string scriptCode)
    {
        string context = ExtractConstant(scriptCode, "PLUGIN_CONTEXT") ?? "unknown";
        string pongMsg = $"{{\"type\":\"pong\",\"context\":\"{context}\"}}";
        
        _api.llMessageLinked(-1, 500, pongMsg, MockLSLApi.NULL_KEY);
    }

    private void SimulateACLRequest(string msg)
    {
        string avatar = ParseJsonField(msg, "avatar");
        string aclMsg = $"{{\"type\":\"acl_query\",\"avatar\":\"{avatar}\"}}";
        
        _api.llMessageLinked(-1, 700, aclMsg, MockLSLApi.NULL_KEY);
    }

    private void SimulateMenuDisplay(string scriptCode)
    {
        // Look for show_main_menu or similar function call
        // For now, just simulate dialog opening
        string context = ExtractConstant(scriptCode, "PLUGIN_CONTEXT") ?? "unknown";
        string label = ExtractConstant(scriptCode, "PLUGIN_LABEL") ?? "Menu";
        
        // Simulate dialog_open message
        string dialogMsg = $"{{\"type\":\"dialog_open\",\"session_id\":\"{context}_test\",\"title\":\"{label}\"}}";
        _api.llMessageLinked(-1, 950, dialogMsg, MockLSLApi.NULL_KEY);
    }

    private void SimulateButtonClick(string scriptCode, string button)
    {
        // This would trigger specific button handling logic
        // For basic testing, just capture that button was processed
        _api.llOwnerSay($"[Test] Button clicked: {button}");
    }

    // ========================================================================
    // Helper Methods
    // ========================================================================

    private void ExecuteEventHandler(string scriptCode, string eventName, object[] parameters)
    {
        string handlerCode = ExtractEventHandler(scriptCode, eventName);
        if (string.IsNullOrEmpty(handlerCode))
            return;

        // Very basic execution simulation
        // In a full implementation, this would compile and execute the handler
        // For testing purposes, we just look for known patterns
    }

    private string ExtractEventHandler(string scriptCode, string eventName)
    {
        // Find event handler in default state
        var pattern = $@"{eventName}\s*\([^)]*\)\s*{{";
        var match = Regex.Match(scriptCode, pattern);
        
        if (!match.Success)
            return string.Empty;

        // Extract handler body (very naive - doesn't handle nested braces properly)
        int start = match.Index + match.Length;
        int braceCount = 1;
        int end = start;

        while (end < scriptCode.Length && braceCount > 0)
        {
            if (scriptCode[end] == '{') braceCount++;
            if (scriptCode[end] == '}') braceCount--;
            end++;
        }

        return scriptCode.Substring(start, end - start - 1);
    }

    private string? ExtractConstant(string scriptCode, string constantName)
    {
        // Extract string constant
        var stringPattern = $@"{constantName}\s*=\s*""([^""]*)""";
        var stringMatch = Regex.Match(scriptCode, stringPattern);
        if (stringMatch.Success)
            return stringMatch.Groups[1].Value;

        // Extract integer constant
        var intPattern = $@"{constantName}\s*=\s*(\d+)";
        var intMatch = Regex.Match(scriptCode, intPattern);
        if (intMatch.Success)
            return intMatch.Groups[1].Value;

        return null;
    }

    private string ParseJsonField(string json, string field)
    {
        try
        {
            return _api.llJsonGetValue(json, $"[\"{field}\"]");
        }
        catch
        {
            return "";
        }
    }
}
