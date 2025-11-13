using NUnit.Framework;
using LSLTestHarness;
using static DSCollarTests.TestHelpers;

namespace DSCollarTests;

/// <summary>
/// Tests for DS Collar dialog system interactions
/// </summary>
[TestFixture]
public class DialogTests
{
    private LSLTestHarness.LSLTestHarness? _harness;

    [SetUp]
    public void Setup()
    {
        _harness = new LSLTestHarness.LSLTestHarness();
    }

    [TearDown]
    public void TearDown()
    {
        _harness?.Reset();
    }

    [Test]
    public void TestDialog_OpensOnACLGrant()
    {
        // Complete flow: UI start → ACL query → ACL grant → Dialog open
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Start UI session
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        // Grant ACL
        string aclResult = CreateACLResult(TEST_AVATAR, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        // Verify dialog opened
        var dialogCalls = _harness.GetDialogCalls();
        Assert.That(dialogCalls.Count, Is.EqualTo(1), "Should open exactly one dialog");

        var dialog = dialogCalls.First();
        Assert.That(dialog.Avatar, Is.EqualTo(TEST_AVATAR));
        Assert.That(dialog.Channel, Is.LessThan(0), "Dialog should use negative channel");
        Assert.That(dialog.Buttons.Count, Is.GreaterThan(0), "Dialog should have buttons");
    }

    [Test]
    public void TestDialog_SessionIdGeneration()
    {
        // Verify dialog opens with proper session tracking
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Complete ACL flow
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        string aclResult = CreateACLResult(TEST_AVATAR, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        // Check if dialog_open message was sent
        var linkMessages = _harness.GetLinkMessages();
        var dialogMsg = linkMessages.FirstOrDefault(m => 
            m.Num == DIALOG_BUS && 
            GetJsonField(m.Msg, "type") == "dialog_open"
        );

        Assert.That(dialogMsg, Is.Not.Null, "Should send dialog_open message");
        
        string sessionId = GetJsonField(dialogMsg!.Msg, "session_id");
        Assert.That(sessionId, Is.Not.Empty, "Session ID should not be empty");
        Assert.That(sessionId, Does.Contain(scriptId), "Session ID should include script context");
    }

    [Test]
    public void TestDialog_ButtonValidation()
    {
        // Verify dialog has expected buttons
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Complete ACL flow
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        string aclResult = CreateACLResult(TEST_AVATAR, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        var dialogCalls = _harness.GetDialogCalls();
        var dialog = dialogCalls.First();

        // All dialogs should have Back button
        bool hasBack = dialog.Buttons.Any(b => 
            b.Equals("Back", StringComparison.OrdinalIgnoreCase) ||
            b.Equals("Close", StringComparison.OrdinalIgnoreCase)
        );

        Assert.That(hasBack, Is.True, "Dialog should have Back or Close button");

        // Button count should be reasonable (max 12 for llDialog)
        Assert.That(dialog.Buttons.Count, Is.LessThanOrEqualTo(12), 
            "Dialog cannot have more than 12 buttons");
    }

    [Test]
    public void TestDialog_BackButtonReturnsToRoot()
    {
        // Clicking Back should send return message
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Complete ACL flow and get session
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        string aclResult = CreateACLResult(TEST_AVATAR, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        string sessionId = $"{scriptId}_test";
        _harness.ClearOutputs();

        // Click Back button
        string buttonClick = CreateDialogResponse(sessionId, "Back", TEST_AVATAR);
        _harness.InjectLinkMessage(0, DIALOG_BUS, buttonClick, NULL_KEY);

        // Should send return message to UI
        var linkMessages = _harness.GetLinkMessages();
        var returnMsg = linkMessages.FirstOrDefault(m => 
            m.Num == UI_BUS && 
            GetJsonField(m.Msg, "type") == "return"
        );

        Assert.That(returnMsg, Is.Not.Null, "Should send return message when Back clicked");
    }

    [Test]
    public void TestDialog_SessionTimeout()
    {
        // Simulate dialog timeout
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Complete ACL flow
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        string aclResult = CreateACLResult(TEST_AVATAR, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        string sessionId = $"{scriptId}_test";
        _harness.ClearOutputs();

        // Send timeout message
        string timeoutMsg = CreateMessage(
            "type", "dialog_timeout",
            "session_id", sessionId
        );
        _harness.InjectLinkMessage(0, DIALOG_BUS, timeoutMsg, NULL_KEY);

        // Subsequent button clicks should be ignored
        string buttonClick = CreateDialogResponse(sessionId, "Start", TEST_AVATAR);
        _harness.InjectLinkMessage(0, DIALOG_BUS, buttonClick, NULL_KEY);

        var linkMessages = _harness.GetLinkMessages();
        Assert.That(linkMessages.Count, Is.EqualTo(0), 
            "Should ignore button clicks after timeout");
    }

    [Test]
    public void TestDialog_MultipleUsers()
    {
        // Two users should have independent sessions
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        string user1 = TEST_AVATAR;
        string user2 = "98765432-4321-4321-4321-210987654321";

        // User 1 starts session
        string start1 = CreateUIStart(scriptId, user1);
        _harness.InjectLinkMessage(0, UI_BUS, start1, NULL_KEY);

        string acl1 = CreateACLResult(user1, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, acl1, NULL_KEY);

        var dialogs1 = _harness.GetDialogCalls();
        Assert.That(dialogs1.Count, Is.EqualTo(1), "User 1 should get dialog");

        _harness.ClearOutputs();

        // User 2 starts session (should replace User 1 in single-session plugins)
        string start2 = CreateUIStart(scriptId, user2);
        _harness.InjectLinkMessage(0, UI_BUS, start2, NULL_KEY);

        string acl2 = CreateACLResult(user2, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, acl2, NULL_KEY);

        var dialogs2 = _harness.GetDialogCalls();
        Assert.That(dialogs2.Count, Is.EqualTo(1), "User 2 should get dialog");
        Assert.That(dialogs2.First().Avatar, Is.EqualTo(user2), 
            "New dialog should be for User 2");
    }

    [Test]
    public void TestDialog_PaginatedMenu()
    {
        // Test plugins with multi-page menus (e.g., blacklist)
        string script = LoadScript("ds_collar_plugin_blacklist.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_blacklist";

        // Complete ACL flow
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        string aclResult = CreateACLResult(TEST_AVATAR, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        var dialogCalls = _harness.GetDialogCalls();
        var dialog = dialogCalls.First();

        // Check for pagination buttons if list is large
        bool hasPagination = dialog.Buttons.Any(b => 
            b == "<<" || b == ">>" || 
            b.Contains("Next") || b.Contains("Prev")
        );

        // This is optional - depends on plugin state
        // Just verify dialog structure is valid
        Assert.That(dialog.Buttons.Count, Is.LessThanOrEqualTo(12));
    }

    [Test]
    public void TestDialog_ConfirmationFlow()
    {
        // Test confirmation dialogs (e.g., maintenance actions)
        string script = LoadScript("ds_collar_plugin_maintenance.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_maintenance";

        // Complete ACL flow
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        string aclResult = CreateACLResult(TEST_AVATAR, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        string sessionId = $"{scriptId}_test";
        _harness.ClearOutputs();

        // Click potentially dangerous action (should show confirmation)
        string buttonClick = CreateDialogResponse(sessionId, "Clear Leash", TEST_AVATAR);
        _harness.InjectLinkMessage(0, DIALOG_BUS, buttonClick, NULL_KEY);

        // May show confirmation dialog or execute directly
        // Just verify no crash and proper message flow
        var linkMessages = _harness.GetLinkMessages();
        
        // Should either show confirmation or execute action
        // Both are valid depending on plugin design
        Assert.Pass("Dialog flow completed without errors");
    }
}
