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
    private readonly string UUID1 = "00000000-0000-0000-0000-000000000001"; // wearer
    private readonly string UUID2 = "00000000-0000-0000-0000-000000000002"; // user
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

        // Send ACL result with insufficient level (plugin_animate PLUGIN_MIN_ACL = 1)
        string aclResult = CreateACLResult(TEST_AVATAR, 0); // Level 0 = insufficient (less than 1)
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
        // Case 1: UUID1 (wearer) ACL level 4
        var aclContext1 = new Dictionary<string, int> { { UUID1, 4 } };
        var injector1 = new LSLTestHarness.EventInjector(aclContext1);
        var result1 = injector1.SimulateTouch(UUID1);
        Assert.That(result1.AclLevel, Is.EqualTo(4), "Wearer should have ACL level 4");

        // Case 2: UUID1 (wearer) ACL level 2, UUID2 (user) ACL level 5
        var aclContext2 = new Dictionary<string, int> { { UUID1, 2 }, { UUID2, 5 } };
        var injector2 = new LSLTestHarness.EventInjector(aclContext2);
        var result2Wearer = injector2.SimulateTouch(UUID1);
        var result2User = injector2.SimulateTouch(UUID2);
        Assert.That(result2Wearer.AclLevel, Is.EqualTo(2), "Wearer should have ACL level 2");
        Assert.That(result2User.AclLevel, Is.EqualTo(5), "User should have ACL level 5");
    }
}
