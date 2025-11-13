using System.Text.RegularExpressions;

namespace LSLTestHarness;

/// <summary>
/// Injects LSL events into scripts for testing. Simulates event dispatch
/// by parsing the script and executing event handler code.
/// </summary>
public class EventInjector
{
    private Dictionary<string, int>? _aclContext;

    // Overloaded constructor for ACL simulation
    public EventInjector(Dictionary<string, int> aclContext)
    {
        _aclContext = aclContext;
    }

    public SimResult SimulateTouch(string avatarKey)
    {
        int aclLevel = (_aclContext != null && _aclContext.ContainsKey(avatarKey)) ? _aclContext[avatarKey] : 0;
        // Simulate touch event and ACL query
        return new SimResult { AvatarKey = avatarKey, AclLevel = aclLevel };
    }

    public class SimResult
    {
        public string AvatarKey { get; set; }
        public int AclLevel { get; set; }
    }
    private readonly MockLSLApi _api;
    private readonly Dictionary<string, List<string>> _eventHandlers = new();
    private YEngineAdapter? _adapter;

    public EventInjector(MockLSLApi api)
    {
        _api = api;
    }

    public void SetScript(string scriptCode)
    {
        _adapter = new YEngineAdapter(_api, scriptCode);
    }

    private void SimulateDialogModule(string msg)
    {
        // Dialog module simulation: when receiving dialog_open message, call llDialog
        try
        {
            var json = Newtonsoft.Json.Linq.JObject.Parse(msg);
            if (json["type"]?.ToString() == "dialog_open")
            {
                string avatar = json["user"]?.ToString() ?? "";
                string message = json["message"]?.ToString() ?? "";
                string buttonsJson = json["buttons"]?.ToString() ?? "[]";
                int channel = json["channel"]?.ToObject<int>() ?? -1000;

                // Robustly parse button array
                var buttonList = new List<string>();
                try
                {
                    var jArray = Newtonsoft.Json.Linq.JArray.Parse(buttonsJson);
                    foreach (var item in jArray)
                    {
                        buttonList.Add(item.ToString());
                    }
                }
                catch
                {
                    buttonList.Add(buttonsJson);
                }

                // Ensure Back button is present
                bool hasBack = buttonList.Any(b => b.Equals("Back", StringComparison.OrdinalIgnoreCase) || b.Equals("Close", StringComparison.OrdinalIgnoreCase));
                if (!hasBack)
                {
                    buttonList.Add("Back");
                }

                // Generate channel if not provided
                if (channel == -1000)
                {
                    channel = -1 * (1000000 + new Random().Next(999999));
                }

                TestLogger.D($"[EventInjector] SimulateDialogModule calling llDialog: avatar={avatar}, buttons={string.Join(",", buttonList)}");
                _api.llDialog(avatar, message, Newtonsoft.Json.JsonConvert.SerializeObject(buttonList), channel);
            }
        }
        catch (Exception ex)
        {
            TestLogger.D($"[EventInjector] SimulateDialogModule error: {ex.Message}");
        }
    }
    
    private void ProcessPendingDialogMessages()
    {
        // Check for messages on DIALOG_BUS (950) and process them
        var messages = _api.GetLinkMessages();
        foreach (var linkMsg in messages)
        {
            if (linkMsg.Num == 950)
            {
                try
                {
                    var json = Newtonsoft.Json.Linq.JObject.Parse(linkMsg.Msg);
                    if (json["type"]?.ToString() == "dialog_open")
                    {
                        TestLogger.D($"[EventInjector] ProcessPendingDialogMessages found dialog_open message");
                        SimulateDialogModule(linkMsg.Msg);
                    }
                }
                catch { /* Ignore parse errors */ }
            }
        }
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
        TestLogger.D($"[EventInjector] SimulateLinkMessageRouting called - channel={num}, msg={msg}");
        
        // Parse JSON message
        string msgType = ParseJsonField(msg, "type");
        TestLogger.D($"[EventInjector] Parsed msgType={msgType}");
        
        // Kernel lifecycle (channel 500) and auth (channel 700) are NEVER routed - always processed
        if (num == 500 || num == 700)
        {
            TestLogger.D($"[EventInjector] Unrouted channel - bypassing routing checks");
            SimulateMessageProcessing(handlerCode, msgType, msg, num);
            return;
        }

        // Dialog responses come from the dialog module and are not routed by 'to' field
        // Accept dialog_response messages on DIALOG_BUS regardless of routing mode so
        // they reach the script's dialog handling logic.
        if (num == 950 && msgType == "dialog_response")
        {
            TestLogger.D("[EventInjector] Dialog response - bypassing routing checks");
            SimulateMessageProcessing(handlerCode, msgType, msg, num);
            return;
        }
        
        string msgTo = ParseJsonField(msg, "to");
        string msgContext = ParseJsonField(msg, "context");

        string? scriptContext = _api.GetScriptContext();

        // Check for routing mode in script
        string routingMode = ExtractConstant(handlerCode, "ROUTING_MODE") ?? "STRICT";
        TestLogger.D($"[EventInjector] routingMode={routingMode}");

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
            TestLogger.D($"[EventInjector] Channel 500, msgType={msgType}, _adapter={(_adapter != null ? "EXISTS" : "NULL")}");
            if (msgType == "register_now" && _adapter != null)
            {
                // Execute register_self() function
                TestLogger.D("[EventInjector] Calling _adapter.ExecuteFunction(register_self)");
                _adapter.ExecuteFunction("register_self");
            }
            else if (msgType == "ping" && _adapter != null)
            {
                // Execute send_pong() function
                TestLogger.D("[EventInjector] Calling _adapter.ExecuteFunction(send_pong)");
                _adapter.ExecuteFunction("send_pong");
            }
        }
        
        // Pattern 2: UI start (channel 900)
        if (channel == 900 && msgType == "start")
        {
            // Extract avatar from start message and set CurrentUser
            if (_adapter != null)
            {
                try
                {
                    var json = Newtonsoft.Json.Linq.JObject.Parse(msg);
                    if (json["avatar"] != null)
                    {
                        string avatar = json["avatar"].ToString();
                        _adapter.SetRuntimeGlobal("CurrentUser", avatar);
                        _adapter.SetRuntimeGlobal("AclPending", "TRUE");
                    }
                }
                catch { /* Ignore parse errors */ }
            }
            
            // Simulate ACL request
            SimulateACLRequest(msg);
        }
        
        // Pattern 3: ACL result (channel 700)
        if (channel == 700 && msgType == "acl_result")
        {
            // Execute handle_acl_result function which will show menu if ACL passes
            if (_adapter != null)
            {
                // Provide the raw message to the adapter so functions can read it
                try
                {
                    var json = Newtonsoft.Json.Linq.JObject.Parse(msg);
                    if (json["level"] != null)
                    {
                        _adapter.SetExecutionContext("acl_level", json["level"].ToString());
                    }
                }
                catch { /* Ignore parse errors */ }

                // Make the full message available as runtime context so handle_acl_result can
                // call llJsonGetValue(msg, [...]) and json_has(msg, [...]) as expected.
                _adapter.SetExecutionContext("msg", msg);

                _adapter.ExecuteFunction("handle_acl_result");
                _adapter.ClearExecutionContext();
                
                // After execution, check if any dialog messages were sent and process them
                // Dump raw link messages for diagnostics
                try
                {
                    var all = _api.GetLinkMessages();
                    TestLogger.D($"[EventInjector] After ACL handler link messages count={all.Count}");
                    foreach (var lm in all)
                    {
                        TestLogger.D($"[EventInjector] LINKMSG: num={lm.Num} msg={lm.Msg}");
                    }
                }
                catch (Exception ex) { TestLogger.D("[EventInjector] Error dumping link messages: " + ex.Message); }

                ProcessPendingDialogMessages();
            }
        }
        
        // Pattern 4: Dialog response (channel 950)
        if (channel == 950 && msgType == "dialog_response")
        {
            string button = ParseJsonField(msg, "button");
            // Always simulate UI return message for Back button, regardless of session ID
            if (button.Equals("Back", System.StringComparison.OrdinalIgnoreCase))
            {
                string sessionId = ParseJsonField(msg, "session_id");
                string avatar = ParseJsonField(msg, "avatar");
                var returnMsg = Newtonsoft.Json.JsonConvert.SerializeObject(new Dictionary<string, object>
                {
                    { "type", "return" },
                    { "session_id", sessionId },
                    { "avatar", avatar }
                });
                _api.llMessageLinked(-1, 900, returnMsg, avatar);
            }
            SimulateButtonClick(handlerCode, button);
        }
        
        // Pattern 5: Dialog open (channel 950) - simulate dialog module
        if (channel == 950 && msgType == "dialog_open")
        {
            SimulateDialogModule(msg);
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
        // Look for show_main_menu function and execute it
        SimulateUserFunction(scriptCode, "show_main_menu");
    }

    private void SimulateButtonClick(string scriptCode, string button)
    {
        // This would trigger specific button handling logic
        // For basic testing, just capture that button was processed
        _api.llOwnerSay($"[Test] Button clicked: {button}");
    }

    /// <summary>
    /// Simulates execution of a user-defined function by finding LSL API calls within it
    /// </summary>
    private void SimulateUserFunction(string scriptCode, string functionName)
    {
        // Extract the function body
        string functionBody = ExtractFunctionBody(scriptCode, functionName);
        if (string.IsNullOrEmpty(functionBody))
            return;

        // Look for llMessageLinked calls
        var llMessageLinkedPattern = @"llMessageLinked\s*\(\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^)]+)\)";
        var matches = Regex.Matches(functionBody, llMessageLinkedPattern);
        
        foreach (Match match in matches)
        {
            // Extract parameters (simplified - doesn't handle complex expressions)
            string linkNum = match.Groups[1].Value.Trim();
            string num = match.Groups[2].Value.Trim();
            string msg = match.Groups[3].Value.Trim();
            string id = match.Groups[4].Value.Trim();

            // Resolve constants
            int linkNumVal = ResolveIntConstant(scriptCode, linkNum);
            int numVal = ResolveIntConstant(scriptCode, num);
            string msgVal = ResolveStringValue(scriptCode, msg);
            string idVal = ResolveStringValue(scriptCode, id);

            // Execute the API call
            _api.llMessageLinked(linkNumVal, numVal, msgVal, idVal);
        }

        // Look for llOwnerSay calls
        var llOwnerSayPattern = @"llOwnerSay\s*\(\s*([^)]+)\)";
        matches = Regex.Matches(functionBody, llOwnerSayPattern);
        
        foreach (Match match in matches)
        {
            string msg = match.Groups[1].Value.Trim();
            string msgVal = ResolveStringValue(scriptCode, msg);
            _api.llOwnerSay(msgVal);
        }

        // Look for llRegionSayTo calls
        var llRegionSayToPattern = @"llRegionSayTo\s*\(\s*([^,]+),\s*([^,]+),\s*([^)]+)\)";
        matches = Regex.Matches(functionBody, llRegionSayToPattern);
        
        foreach (Match match in matches)
        {
            string target = match.Groups[1].Value.Trim();
            string channel = match.Groups[2].Value.Trim();
            string msg = match.Groups[3].Value.Trim();

            string targetVal = ResolveStringValue(scriptCode, target);
            int channelVal = ResolveIntConstant(scriptCode, channel);
            string msgVal = ResolveStringValue(scriptCode, msg);

            _api.llRegionSayTo(targetVal, channelVal, msgVal);
        }
    }

    private string ExtractFunctionBody(string scriptCode, string functionName)
    {
        // Find function definition (before default state)
        var pattern = $@"(\w+)\s+{functionName}\s*\([^)]*\)\s*{{";
        var match = Regex.Match(scriptCode, pattern);
        
        if (!match.Success)
            return string.Empty;

        // Extract function body
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

    private int ResolveIntConstant(string scriptCode, string expr)
    {
        expr = expr.Trim();
        
        // Direct integer literal
        if (int.TryParse(expr, out int val))
            return val;

        // Constant reference
        string? constantVal = ExtractConstant(scriptCode, expr);
        if (constantVal != null && int.TryParse(constantVal, out int constVal))
            return constVal;

        // Special values
        if (expr == "LINK_SET") return -1;
        if (expr == "LINK_THIS") return -4;
        
        return 0;
    }

    private string ResolveStringValue(string scriptCode, string expr)
    {
        expr = expr.Trim();

        // String literal
        if (expr.StartsWith("\"") && expr.EndsWith("\""))
            return expr.Substring(1, expr.Length - 2);

        // Constant reference
        string? constantVal = ExtractConstant(scriptCode, expr);
        if (constantVal != null)
            return constantVal;

        // Special values
        if (expr == "NULL_KEY") return MockLSLApi.NULL_KEY;
        
        // Variable reference (look for CurrentUser, SessionId, etc.)
        if (expr == "CurrentUser") return "test-avatar-key";
        if (expr == "SessionId") return "test-session-id";

        return expr;
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
