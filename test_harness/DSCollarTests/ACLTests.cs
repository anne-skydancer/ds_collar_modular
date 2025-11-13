using NUnit.Framework;
using LSLTestHarness;
using static DSCollarTests.TestHelpers;

namespace DSCollarTests;

/// <summary>
/// Tests for DS Collar ACL (Access Control List) validation
/// </summary>
[TestFixture]
public class ACLTests
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
    public void TestACL_RequestOnUIStart()
    {
        // When plugin receives UI start, it should request ACL validation
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";
        string msg = CreateUIStart(scriptId, TEST_AVATAR);

        _harness.InjectLinkMessage(0, UI_BUS, msg, NULL_KEY);

        // Should send ACL query
        var linkMessages = _harness.GetLinkMessages();
        AssertMessageSentOn(linkMessages, AUTH_BUS, "acl_query");

        // Verify avatar field in query
        var aclQuery = linkMessages.First(m => 
            m.Num == AUTH_BUS && 
            GetJsonField(m.Msg, "type") == "acl_query"
        );
        
        string avatarInQuery = GetJsonField(aclQuery.Msg, "avatar");
        Assert.That(avatarInQuery, Is.EqualTo(TEST_AVATAR), "ACL query should include avatar");
    }

    [Test]
    public void TestACL_DenialBlocksMenu()
    {
        // When ACL denies access, plugin should not show menu
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Start UI session
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);
        _harness.ClearOutputs();

        // Send ACL result with insufficient level (plugin_animate needs 3+)
        string aclResult = CreateACLResult(TEST_AVATAR, 2); // Level 2 = insufficient
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        // Should NOT open dialog
        var dialogCalls = _harness.GetDialogCalls();
        Assert.That(dialogCalls.Count, Is.EqualTo(0), "Should not show menu on ACL denial");

        // Should notify user
        var ownerSays = _harness.GetOwnerSayMessages();
        bool hasAccessDenied = ownerSays.Any(msg => 
            msg.Contains("Access denied") || 
            msg.Contains("permission") ||
            msg.Contains("insufficient")
        );
        
        Assert.That(hasAccessDenied, Is.True, "Should notify user of access denial");
    }

    [Test]
    public void TestACL_GrantShowsMenu()
    {
        // When ACL grants access, plugin should show menu
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Start UI session
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);
        _harness.ClearOutputs();

        // Send ACL result with sufficient level
        string aclResult = CreateACLResult(TEST_AVATAR, 5); // Level 5 = owner
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        // Should open dialog
        var dialogCalls = _harness.GetDialogCalls();
        Assert.That(dialogCalls.Count, Is.GreaterThan(0), "Should show menu on ACL grant");

        // Verify dialog is for correct avatar
        var dialog = dialogCalls.First();
        Assert.That(dialog.Avatar, Is.EqualTo(TEST_AVATAR), "Dialog should be for requesting avatar");
    }

    [Test]
    public void TestACL_NoRevalidationOnButtonClick()
    {
        // After initial ACL validation, button clicks should NOT re-request ACL
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Complete ACL validation flow
        string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        string aclResult = CreateACLResult(TEST_AVATAR, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        // Get dialog session ID
        var dialogCalls = _harness.GetDialogCalls();
        string sessionId = $"{scriptId}_test"; // Simplified for test

        _harness.ClearOutputs();

        // Click a button
        string buttonClick = CreateDialogResponse(sessionId, "Start", TEST_AVATAR);
        _harness.InjectLinkMessage(0, DIALOG_BUS, buttonClick, NULL_KEY);

        // Should NOT send another ACL query
        var linkMessages = _harness.GetLinkMessages();
        bool hasAclQuery = linkMessages.Any(m => 
            m.Num == AUTH_BUS && 
            GetJsonField(m.Msg, "type") == "acl_query"
        );

        Assert.That(hasAclQuery, Is.False, "Should not re-validate ACL on button click");
    }

    [Test]
    public void TestACL_SessionValidation()
    {
        // Only current session user should process dialog responses
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // User 1 starts session
        string user1 = TEST_AVATAR;
        string startMsg = CreateUIStart(scriptId, user1);
        _harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

        string aclResult = CreateACLResult(user1, 5);
        _harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

        string sessionId = $"{scriptId}_test";
        _harness.ClearOutputs();

        // User 2 tries to click button in User 1's session
        string user2 = "98765432-4321-4321-4321-210987654321";
        string buttonClick = CreateDialogResponse(sessionId, "Start", user2);
        _harness.InjectLinkMessage(0, DIALOG_BUS, buttonClick, NULL_KEY);

        // Should be rejected (no processing)
        var linkMessages = _harness.GetLinkMessages();
        Assert.That(linkMessages.Count, Is.EqualTo(0), "Should reject button click from wrong user");
    }

    [Test]
    public void TestACL_MultipleAccessLevels()
    {
        // Test different ACL levels with appropriate plugins
        var testCases = new[]
        {
            new { Plugin = "ds_collar_plugin_public.lsl", MinLevel = 1, TestLevel = 1, ShouldPass = true },
            new { Plugin = "ds_collar_plugin_public.lsl", MinLevel = 1, TestLevel = 0, ShouldPass = false },
            new { Plugin = "ds_collar_plugin_owner.lsl", MinLevel = 5, TestLevel = 5, ShouldPass = true },
            new { Plugin = "ds_collar_plugin_owner.lsl", MinLevel = 5, TestLevel = 3, ShouldPass = false }
        };

        foreach (var testCase in testCases)
        {
            var harness = new LSLTestHarness.LSLTestHarness();
            string script = LoadScript(testCase.Plugin);
            harness.LoadScript(script);

            string scriptId = harness.GetScriptContext() ?? "plugin_test";

            // Start and validate ACL
            string startMsg = CreateUIStart(scriptId, TEST_AVATAR);
            harness.InjectLinkMessage(0, UI_BUS, startMsg, NULL_KEY);

            string aclResult = CreateACLResult(TEST_AVATAR, testCase.TestLevel);
            harness.InjectLinkMessage(0, AUTH_BUS, aclResult, NULL_KEY);

            var dialogCalls = harness.GetDialogCalls();
            bool gotDialog = dialogCalls.Count > 0;

            Assert.That(gotDialog, Is.EqualTo(testCase.ShouldPass), 
                $"Plugin {testCase.Plugin} with level {testCase.TestLevel} (min {testCase.MinLevel})");
        }
    }
}
