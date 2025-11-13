using System.Collections.Generic;
using System.Text;

namespace LSLTestHarness;

/// <summary>
/// Main test harness for LSL scripts. Provides script loading, event injection,
/// and output capture for testing DS Collar scripts without a full simulator.
/// </summary>
public class LSLTestHarness
{
    private readonly MockLSLApi _api;
    private readonly EventInjector _eventInjector;
    private string? _scriptCode;
    private bool _isLoaded;

    public LSLTestHarness()
    {
        _api = new MockLSLApi();
        _eventInjector = new EventInjector(_api);
        _isLoaded = false;
    }

    /// <summary>
    /// Load and parse an LSL script for testing
    /// </summary>
    /// <param name="lslCode">Complete LSL script source code</param>
    public void LoadScript(string lslCode)
    {
        if (string.IsNullOrWhiteSpace(lslCode))
            throw new ArgumentException("Script code cannot be empty", nameof(lslCode));

        _scriptCode = lslCode;
        
        // Parse script to extract context and verify basic structure
        if (!lslCode.Contains("default"))
            throw new InvalidOperationException("Script must contain a default state");

        // Extract PLUGIN_CONTEXT if present
        var contextMatch = System.Text.RegularExpressions.Regex.Match(
            lslCode, 
            @"string\s+PLUGIN_CONTEXT\s*=\s*""([^""]+)""");
        
        if (contextMatch.Success)
        {
            _api.SetScriptContext(contextMatch.Groups[1].Value);
        }

        _isLoaded = true;
        
        // Trigger state_entry event
        InjectStateEntry();
    }

    /// <summary>
    /// Reset harness state between tests
    /// </summary>
    public void Reset()
    {
        _api.Reset();
        _eventInjector.Reset();
        _scriptCode = null;
        _isLoaded = false;
    }

    // ========================================================================
    // Event Injection Methods
    // ========================================================================

    /// <summary>
    /// Inject state_entry event
    /// </summary>
    public void InjectStateEntry()
    {
        ThrowIfNotLoaded();
        _eventInjector.InjectStateEntry(_scriptCode!);
    }

    /// <summary>
    /// Inject on_rez event
    /// </summary>
    public void InjectOnRez(int startParam = 0)
    {
        ThrowIfNotLoaded();
        _eventInjector.InjectOnRez(_scriptCode!, startParam);
    }

    /// <summary>
    /// Inject touch_start event
    /// </summary>
    public void InjectTouchStart(string avatarKey)
    {
        ThrowIfNotLoaded();
        _eventInjector.InjectTouchStart(_scriptCode!, avatarKey);
    }

    /// <summary>
    /// Inject timer event
    /// </summary>
    public void InjectTimer()
    {
        ThrowIfNotLoaded();
        _eventInjector.InjectTimer(_scriptCode!);
    }

    /// <summary>
    /// Inject link_message event
    /// </summary>
    public void InjectLinkMessage(int sender, int num, string msg, string id)
    {
        ThrowIfNotLoaded();
        _eventInjector.InjectLinkMessage(_scriptCode!, sender, num, msg, id);
    }

    /// <summary>
    /// Inject listen event (for dialog responses)
    /// </summary>
    public void InjectListen(int channel, string name, string id, string message)
    {
        ThrowIfNotLoaded();
        _eventInjector.InjectListen(_scriptCode!, channel, name, id, message);
    }

    /// <summary>
    /// Inject changed event
    /// </summary>
    public void InjectChanged(int change)
    {
        ThrowIfNotLoaded();
        _eventInjector.InjectChanged(_scriptCode!, change);
    }

    // ========================================================================
    // Output Capture Methods
    // ========================================================================

    /// <summary>
    /// Get all llOwnerSay messages captured
    /// </summary>
    public List<string> GetOwnerSayMessages()
    {
        return _api.GetOwnerSayMessages();
    }

    /// <summary>
    /// Get all llMessageLinked calls captured
    /// </summary>
    public List<LinkMessage> GetLinkMessages()
    {
        return _api.GetLinkMessages();
    }

    /// <summary>
    /// Get all llDialog calls captured
    /// </summary>
    public List<DialogCall> GetDialogCalls()
    {
        return _api.GetDialogCalls();
    }

    /// <summary>
    /// Get all llListen calls captured
    /// </summary>
    public List<ListenCall> GetListenCalls()
    {
        return _api.GetListenCalls();
    }

    /// <summary>
    /// Clear all captured outputs
    /// </summary>
    public void ClearOutputs()
    {
        _api.ClearOutputs();
    }

    // ========================================================================
    // Helper Methods
    // ========================================================================

    /// <summary>
    /// Get the script context (PLUGIN_CONTEXT value)
    /// </summary>
    public string? GetScriptContext()
    {
        return _api.GetScriptContext();
    }

    /// <summary>
    /// Check if a specific event handler exists in the script
    /// </summary>
    public bool HasEventHandler(string eventName)
    {
        if (_scriptCode == null) return false;
        
        // Simple regex check for event handler
        var pattern = $@"{eventName}\s*\([^)]*\)\s*{{";
        return System.Text.RegularExpressions.Regex.IsMatch(_scriptCode, pattern);
    }

    private void ThrowIfNotLoaded()
    {
        if (!_isLoaded)
            throw new InvalidOperationException("No script loaded. Call LoadScript() first.");
    }
}

/// <summary>
/// Captured link message data
/// </summary>
public record LinkMessage(int LinkNum, int Num, string Msg, string Id)
{
    public override string ToString() => $"LinkMessage({LinkNum}, {Num}, \"{Msg}\", \"{Id}\")";
}

/// <summary>
/// Captured dialog call data
/// </summary>
public record DialogCall(string Avatar, string Message, List<string> Buttons, int Channel)
{
    public override string ToString() => 
        $"Dialog(avatar={Avatar}, channel={Channel}, buttons={string.Join(",", Buttons)})";
}

/// <summary>
/// Captured listen call data
/// </summary>
public record ListenCall(int Channel, string Name, string Id, string Message)
{
    public override string ToString() => 
        $"Listen(channel={Channel}, name=\"{Name}\", id={Id}, msg=\"{Message}\")";
}
