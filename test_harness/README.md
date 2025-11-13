# LSL Test Harness for DS Collar v2.0

A minimal, standalone LSL script testing environment extracted from OpenSimulator components. This allows testing LSL scripts without running a full 3D virtual world simulator.

## Purpose

Test DS Collar scripts by:
- Compiling actual LSL code
- Injecting events (touch, timer, link_message)
- Capturing outputs (llOwnerSay, llMessageLinked, llDialog)
- Validating message routing, ACL logic, and state management

## Architecture

### Core Components (from OpenSimulator)

1. **LSL Types** - Basic LSL data types (integer, float, string, key, list, vector, rotation)
2. **LSL Compiler** - Compiles LSL to executable bytecode
3. **Script Executor** - Runs compiled scripts with event queue
4. **API Stubs** - Mock implementations of llMessageLinked, llOwnerSay, etc.
5. **Event Injector** - Simulates touch_start, timer, link_message events

### Test Harness API

```csharp
// Create test environment
var harness = new LSLTestHarness();

// Load script
harness.LoadScript(File.ReadAllText("ds_collar_plugin_animate.lsl"));

// Inject events
harness.InjectTouchStart(avatarKey: testAvatarUUID);
harness.InjectTimer();
harness.InjectLinkMessage(sender: 1, num: 900, msg: routedMessage, id: NULL_KEY);

// Verify outputs
var ownerSays = harness.GetOwnerSayMessages();
var linkMessages = harness.GetLinkMessages();
Assert.Contains(linkMessages, m => m.channel == 900 && m.msg.Contains("plugin_animate"));
```

## Setup Instructions

### Prerequisites

- .NET 8.0 SDK or later
- OpenSimulator source code (for extraction)

### Step 1: Extract OpenSimulator Components

```powershell
# Clone OpenSimulator
cd test_harness
git clone --depth 1 https://github.com/opensim/opensim.git opensim_source

# Copy required files to extract/
./extract_components.ps1
```

### Step 2: Build Test Harness

```powershell
cd test_harness
dotnet build LSLTestHarness.csproj
```

### Step 3: Run Tests

```powershell
dotnet test DSCollarTests.csproj
```

## Usage Examples

### Test Message Routing

```csharp
[Test]
public void TestStrictRouting()
{
    var harness = new LSLTestHarness();
    harness.LoadScript(File.ReadAllText("../src/ng/ds_collar_plugin_animate.lsl"));
    
    // Message addressed to this plugin - should accept
    string validMsg = CreateRoutedMessage("plugin_animate", "type", "start");
    harness.InjectLinkMessage(0, 900, validMsg, NULL_KEY);
    
    // Verify plugin processed it
    var linkMsgs = harness.GetLinkMessages();
    Assert.That(linkMsgs.Count, Is.GreaterThan(0));
    
    // Broadcast message - should reject (STRICT routing)
    harness.Reset();
    string broadcastMsg = CreateRoutedMessage("*", "type", "start");
    harness.InjectLinkMessage(0, 900, broadcastMsg, NULL_KEY);
    
    // Verify plugin ignored it
    var linkMsgs2 = harness.GetLinkMessages();
    Assert.That(linkMsgs2.Count, Is.EqualTo(0));
}
```

### Test ACL Validation

```csharp
[Test]
public void TestACLValidation()
{
    var harness = new LSLTestHarness();
    harness.LoadScript(File.ReadAllText("../src/ng/ds_collar_plugin_animate.lsl"));
    
    // Simulate UI start
    string uiStart = CreateRoutedMessage("plugin_animate", 
        "type", "start",
        "context", "core_animate");
    harness.InjectLinkMessage(0, 900, uiStart, testAvatarUUID);
    
    // Should request ACL
    var aclRequests = harness.GetLinkMessages()
        .Where(m => m.channel == 700 && m.msg.Contains("acl_query"));
    Assert.That(aclRequests.Count(), Is.EqualTo(1));
    
    // Send ACL result (denied)
    string aclDeny = CreateRoutedMessage("plugin_animate",
        "type", "acl_result",
        "avatar", testAvatarUUID,
        "level", "1"); // Below PLUGIN_MIN_ACL
    harness.InjectLinkMessage(0, 700, aclDeny, NULL_KEY);
    
    // Verify access denied and no menu shown
    var ownerSays = harness.GetOwnerSayMessages();
    Assert.That(ownerSays.Any(m => m.Contains("Access denied")));
}
```

### Test Dialog Flow

```csharp
[Test]
public void TestDialogFlow()
{
    var harness = new LSLTestHarness();
    harness.LoadScript(File.ReadAllText("../src/ng/ds_collar_plugin_animate.lsl"));
    
    // Grant ACL and show menu
    GrantACL(harness, testAvatarUUID, level: 5);
    
    // Verify dialog was opened
    var dialogs = harness.GetLinkMessages()
        .Where(m => m.channel == 950 && m.msg.Contains("dialog_open"));
    Assert.That(dialogs.Count(), Is.EqualTo(1));
    
    // Simulate button click
    string sessionId = ExtractSessionId(dialogs.First().msg);
    string buttonClick = CreateRoutedMessage("plugin_animate",
        "type", "dialog_response",
        "session_id", sessionId,
        "button", "Sit",
        "user", testAvatarUUID);
    harness.InjectLinkMessage(0, 950, buttonClick, NULL_KEY);
    
    // Verify animation started
    var ownerSays = harness.GetOwnerSayMessages();
    Assert.That(ownerSays.Any(m => m.Contains("Playing: Sit")));
}
```

## Project Structure

```
test_harness/
├── README.md                    # This file
├── extract_components.ps1       # Script to extract OpenSim components
├── LSLTestHarness.csproj       # Test harness project
├── LSLTestHarness/
│   ├── LSLTestHarness.cs       # Main harness class
│   ├── MockLSLApi.cs           # Mock LSL API functions
│   ├── EventInjector.cs        # Event injection system
│   └── OutputCapture.cs        # Capture script outputs
├── DSCollarTests.csproj        # DS Collar test project
├── DSCollarTests/
│   ├── RoutingTests.cs         # Test routing system
│   ├── ACLTests.cs             # Test ACL validation
│   ├── DialogTests.cs          # Test dialog flows
│   └── TestHelpers.cs          # Common test utilities
└── opensim_source/             # OpenSimulator source (gitignored)
```

## Development Workflow

1. Write LSL scripts in `src/ng/`
2. Run lslint for syntax validation
3. Write C# tests in `test_harness/DSCollarTests/`
4. Run test suite to validate logic
5. Deploy to OpenSimulator/SL for integration testing

## Limitations

This test harness provides:
- ✅ Script compilation and execution
- ✅ Event injection and handling
- ✅ Message passing simulation
- ✅ Logic and routing validation

It does NOT provide:
- ❌ 3D rendering or physics
- ❌ Real avatar interactions
- ❌ Network communication
- ❌ Actual timer delays (simulated)
- ❌ Real RLV commands

For full integration testing, use OpenSimulator standalone mode.

## Contributing

When adding new tests:
1. Follow NUnit test conventions
2. Use descriptive test names
3. Test one behavior per test
4. Clean up resources in [TearDown]
5. Document complex test scenarios

## License

Test harness components extracted from OpenSimulator are under BSD license.
DS Collar test code follows the main project license.
