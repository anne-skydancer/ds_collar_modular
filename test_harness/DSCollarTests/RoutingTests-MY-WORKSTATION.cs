using NUnit.Framework;
using LSLTestHarness;
using static DSCollarTests.TestHelpers;

namespace DSCollarTests;

/// <summary>
/// Tests for DS Collar message routing system (STRICT mode)
/// </summary>
[TestFixture]
public class RoutingTests
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
    public void TestStrictRouting_AcceptsExactMatch()
    {
        // Load a plugin with STRICT routing
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        // Get the script's SCRIPT_ID
        string scriptId = _harness.GetScriptContext() ?? "plugin_animate";

        // Send routed message with exact match
        string msg = CreateRoutedMessage(
            scriptId,
            "type", "start",
            "avatar", TEST_AVATAR
        );

        _harness.InjectLinkMessage(0, UI_BUS, msg, NULL_KEY);

        // Should process message and request ACL
        var linkMessages = _harness.GetLinkMessages();
        AssertMessageSentOn(linkMessages, AUTH_BUS, "acl_query");
    }

    [Test]
    public void TestStrictRouting_RejectsBroadcast()
    {
        // Load a plugin with STRICT routing
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        // Send broadcast message (to: "*")
        string msg = CreateRoutedMessage(
            "*",
            "type", "start",
            "avatar", TEST_AVATAR
        );

        _harness.InjectLinkMessage(0, UI_BUS, msg, NULL_KEY);

        // Should NOT process message
        var linkMessages = _harness.GetLinkMessages();
        AssertNoMessageSent(linkMessages);
    }

    [Test]
    public void TestStrictRouting_RejectsWrongContext()
    {
        // Load animate plugin
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        // Send message routed to different plugin
        string msg = CreateRoutedMessage(
            "plugin_blacklist", // Wrong target
            "type", "start",
            "avatar", TEST_AVATAR
        );

        _harness.InjectLinkMessage(0, UI_BUS, msg, NULL_KEY);

        // Should NOT process message
        var linkMessages = _harness.GetLinkMessages();
        AssertNoMessageSent(linkMessages);
    }

    [Test]
    public void TestStrictRouting_RejectsMissingToField()
    {
        // Load a plugin with STRICT routing
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        // Send message WITHOUT "to" field (unrouted)
        string msg = CreateMessage(
            "type", "start",
            "avatar", TEST_AVATAR
        );

        _harness.InjectLinkMessage(0, UI_BUS, msg, NULL_KEY);

        // Should NOT process message
        var linkMessages = _harness.GetLinkMessages();
        AssertNoMessageSent(linkMessages);
    }

    [Test]
    public void TestStrictRouting_AcceptsKernelLifecycle()
    {
        // Kernel lifecycle messages should always be processed (unrouted)
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string msg = CreateMessage("type", "register_now");
        _harness.InjectLinkMessage(0, KERNEL_LIFECYCLE, msg, NULL_KEY);

        // Should send registration
        var linkMessages = _harness.GetLinkMessages();
        AssertMessageSentOn(linkMessages, KERNEL_LIFECYCLE, "register");
    }

    [Test]
    public void TestStrictRouting_PingPongFlow()
    {
        // Test heartbeat mechanism
        string script = LoadScript("ds_collar_plugin_animate.lsl");
        _harness!.LoadScript(script);

        string pingMsg = CreateMessage("type", "ping");
        _harness.InjectLinkMessage(0, KERNEL_LIFECYCLE, pingMsg, NULL_KEY);

        // Should respond with pong
        var linkMessages = _harness.GetLinkMessages();
        AssertMessageSentOn(linkMessages, KERNEL_LIFECYCLE, "pong");
    }

    [Test]
    public void TestStrictRouting_MultiplePlugins()
    {
        // Load two plugins and verify they only respond to their own messages
        var harness1 = new LSLTestHarness.LSLTestHarness();
        var harness2 = new LSLTestHarness.LSLTestHarness();

        string script1 = LoadScript("ds_collar_plugin_animate.lsl");
        string script2 = LoadScript("ds_collar_plugin_blacklist.lsl");

        harness1.LoadScript(script1);
        harness2.LoadScript(script2);

        string context1 = harness1.GetScriptContext() ?? "plugin_animate";
        string context2 = harness2.GetScriptContext() ?? "plugin_blacklist";

        // Send message to plugin 1
        string msg1 = CreateRoutedMessage(context1, "type", "start", "avatar", TEST_AVATAR);
        harness1.InjectLinkMessage(0, UI_BUS, msg1, NULL_KEY);
        harness2.InjectLinkMessage(0, UI_BUS, msg1, NULL_KEY);

        // Only harness1 should respond
        var messages1 = harness1.GetLinkMessages();
        var messages2 = harness2.GetLinkMessages();

        Assert.That(messages1.Count, Is.GreaterThan(0), "Plugin 1 should process its message");
        AssertNoMessageSent(messages2); // Plugin 2 should ignore

        // Clear and test reverse
        harness1.ClearOutputs();
        harness2.ClearOutputs();

        string msg2 = CreateRoutedMessage(context2, "type", "start", "avatar", TEST_AVATAR);
        harness1.InjectLinkMessage(0, UI_BUS, msg2, NULL_KEY);
        harness2.InjectLinkMessage(0, UI_BUS, msg2, NULL_KEY);

        messages1 = harness1.GetLinkMessages();
        messages2 = harness2.GetLinkMessages();

        AssertNoMessageSent(messages1); // Plugin 1 should ignore
        Assert.That(messages2.Count, Is.GreaterThan(0), "Plugin 2 should process its message");
    }
}
