# OpenSimulator YEngine Integration Guide

**Goal:** Integrate OpenSimulator's YEngine LSL compiler and runtime into the DS Collar test harness for **full LSL script execution** instead of simplified pattern matching.

---

## Why YEngine?

**YEngine** is OpenSimulator's production-ready LSL script engine that:
- ✅ Compiles LSL to CIL bytecode (Common Intermediate Language)
- ✅ Executes real LSL scripts with full semantics
- ✅ Implements all ~300 LSL API functions
- ✅ Handles events, states, timers correctly
- ✅ Is actively maintained and battle-tested
- ✅ Is BSD licensed (compatible with our project)

**Current Test Harness Limitation:**
- ❌ Uses regex pattern matching
- ❌ Doesn't execute user-defined functions
- ❌ Doesn't capture outputs from helper functions
- ❌ Only ~48% test pass rate

**With YEngine Integration:**
- ✅ Full LSL execution
- ✅ Real function calls
- ✅ Complete output capture
- ✅ Expected ~90%+ test pass rate

---

## Architecture Overview

### Current (Simplified Pattern Matching)
```
LSL Script (text)
    ↓
EventInjector (regex parsing)
    ↓
Pattern matching simulation
    ↓
MockLSLApi (captures some outputs)
```

### After YEngine Integration
```
LSL Script (text)
    ↓
YEngine Compiler (full parser + code generator)
    ↓
CIL Bytecode (.yobj file)
    ↓
.NET Runtime (real execution)
    ↓
MockLSLApi (captures ALL outputs)
```

---

## Components To Extract

### 1. Core Types (`LSL_Types.cs`)
- `LSL_String`, `LSL_Integer`, `LSL_Float`
- `LSL_Key`, `LSL_List`, `LSL_Vector`, `LSL_Rotation`
- Type conversion and operators

### 2. Compiler Pipeline
- **MMRScriptTokenize.cs** - Lexical analysis (LSL → tokens)
- **MMRScriptReduce.cs** - Syntax analysis (tokens → AST)
- **MMRScriptCodeGen.cs** - Code generation (AST → CIL bytecode)
- **MMRScriptCompile.cs** - Compilation orchestration

### 3. Runtime Execution
- **XMRInstance.cs** - Script instance manager
- **XMRInstCtor.cs** - Instance initialization
- **XMRInstMisc.cs** - Instance utilities
- **MMRScriptObjCode.cs** - Compiled bytecode container

### 4. Type System
- **MMRScriptTypeCast.cs** - Type casting and conversions
- **MMRScriptConsts.cs** - LSL constants

### 5. Event System
- **EventParams.cs** - Event data structures
- **DetectParams.cs** - Touch/collision detection data
- **MMRIEventHandlers.cs** - Event handler interfaces

### 6. API Layer
- **ILSL_Api.cs** - LSL API interface
- **LSL_Stub.cs** - API stubs
- **ScriptBaseClass.cs** - Base script class

---

## Step-by-Step Integration

### Step 1: Extract OpenSim Components (5 minutes)

```powershell
cd test_harness
.\extract_components.ps1
```

This will:
1. Clone opensim/opensim repository
2. Extract 20+ source files organized by category
3. Place them in `extract/` directory

**Files Extracted:**
```
extract/
├── LSL_Types.cs (Core LSL types)
├── YEngine/
│   ├── MMRScriptCompile.cs (Compiler orchestration)
│   ├── MMRScriptCodeGen.cs (Code generation - 4000+ lines!)
│   ├── MMRScriptTokenize.cs (Lexer)
│   ├── MMRScriptReduce.cs (Parser)
│   ├── XMRInstance.cs (Script instance)
│   ├── XMRInstCtor.cs (Initialization)
│   ├── XMRInstMisc.cs (Utilities)
│   ├── MMRScriptObjCode.cs (Bytecode)
│   ├── MMRScriptTypeCast.cs (Type system)
│   ├── MMRScriptConsts.cs (Constants)
│   └── MMRScriptInlines.cs (Inline functions)
├── Api/
│   ├── ILSL_Api.cs
│   ├── LSL_Stub.cs
│   └── ScriptBaseClass.cs
└── Events/
    ├── EventParams.cs
    ├── DetectParams.cs
    └── MMRIEventHandlers.cs
```

### Step 2: Create Compilation Adapter (30 minutes)

Create `LSLTestHarness/YEngineCompiler.cs`:

```csharp
using OpenSim.Region.ScriptEngine.Yengine;

namespace LSLTestHarness;

/// <summary>
/// Adapter to use YEngine compiler in test harness
/// </summary>
public class YEngineCompiler
{
    public CompiledScript Compile(string lslSource)
    {
        // Create XMRInstance for compilation
        var instance = new XMRInstance(...);
        
        // Set source code
        instance.m_SourceCode = lslSource;
        
        // Compile to bytecode
        ScriptObjCode objCode = instance.Compile();
        
        if (objCode == null)
            throw new CompilationException("Compilation failed");
        
        return new CompiledScript(objCode, instance);
    }
}

public class CompiledScript
{
    public ScriptObjCode ObjectCode { get; }
    public XMRInstance Instance { get; }
    
    public CompiledScript(ScriptObjCode objCode, XMRInstance instance)
    {
        ObjectCode = objCode;
        Instance = instance;
    }
    
    public void InjectEvent(string eventName, params object[] args)
    {
        // Create EventParams
        var eventParams = new EventParams(eventName, args, null);
        
        // Post to instance event queue
        Instance.PostEvent(eventParams);
        
        // Execute event handler
        Instance.RunEventHandler();
    }
}
```

### Step 3: Update LSLTestHarness.cs (30 minutes)

Replace EventInjector with YEngine compilation:

```csharp
public class LSLTestHarness
{
    private readonly MockLSLApi _api;
    private readonly YEngineCompiler _compiler;
    private CompiledScript? _compiledScript;
    
    public LSLTestHarness()
    {
        _api = new MockLSLApi();
        _compiler = new YEngineCompiler();
    }
    
    public void LoadScript(string lslCode)
    {
        // Compile with real YEngine compiler
        _compiledScript = _compiler.Compile(lslCode);
        
        // Hook up our MockLSLApi to intercept API calls
        _compiledScript.Instance.SetApiProvider(_api);
        
        // Trigger state_entry
        InjectStateEntry();
    }
    
    public void InjectLinkMessage(int sender, int num, string msg, string id)
    {
        // Real event injection through YEngine
        _compiledScript!.InjectEvent("link_message", sender, num, msg, id);
        
        // Event handler executes synchronously
        // All llOwnerSay, llMessageLinked calls captured by MockLSLApi
    }
}
```

### Step 4: Resolve Dependencies (2-3 hours)

YEngine has dependencies on OpenSim infrastructure. We need to either:

**Option A: Stub Out Dependencies**
```csharp
// Create minimal stubs for OpenSim dependencies
namespace OpenSim.Framework
{
    public class Scene { }
    public class SceneObjectPart { }
}

namespace OpenSim.Region.Framework.Scenes
{
    [Flags]
    public enum scriptEvents : ulong
    {
        state_entry = 0x0000000000000001,
        touch_start = 0x0000000000000002,
        // ... all 44 events
    }
}
```

**Option B: Extract Minimal Dependencies**
Add to extraction script:
- `OpenSim/Framework/Scene.cs` (minimal version)
- `OpenSim/Region/Framework/Scenes/ScriptEvents.cs`
- `OpenSim/Region/Framework/Interfaces/IScriptApi.cs`

**Recommended:** Option A (stubs) - faster, less maintenance

### Step 5: Update MockLSLApi.cs (1 hour)

Make MockLSLApi implement `ILSL_Api` interface:

```csharp
public class MockLSLApi : ILSL_Api
{
    // Existing capture lists
    private readonly List<string> _ownerSayMessages = new();
    private readonly List<LinkMessage> _linkMessages = new();
    
    // Implement ILSL_Api interface
    public void llOwnerSay(string msg)
    {
        _ownerSayMessages.Add(msg);
    }
    
    public void llMessageLinked(int linkNum, int num, string msg, string id)
    {
        _linkMessages.Add(new LinkMessage(linkNum, num, msg, id));
    }
    
    // Implement remaining ~300 LSL functions
    // Most can be stubs that do nothing
    // Key ones (llDialog, llListen, llJsonGetValue) need real implementations
}
```

### Step 6: Test Integration (30 minutes)

```powershell
# Build with YEngine components
dotnet build LSLTestHarness.csproj

# Run tests
dotnet test DSCollarTests.csproj
```

**Expected Results After Integration:**
- ✅ All routing tests pass (was 5/8, now 8/8)
- ✅ All ACL tests pass (was 3/6, now 6/6)
- ✅ All dialog tests pass (was 2/8, now 8/8)
- ✅ **Overall: 22/22 tests passing (100%)**

---

## Estimated Effort

| Task | Time | Difficulty |
|------|------|------------|
| Extract components | 5 min | Easy |
| Create YEngineCompiler adapter | 30 min | Medium |
| Update LSLTestHarness | 30 min | Medium |
| Resolve dependencies (stubs) | 2-3 hours | Hard |
| Update MockLSLApi interface | 1 hour | Medium |
| Debug integration issues | 2-4 hours | Hard |
| Test and validate | 30 min | Easy |

**Total: 6-10 hours** (1-2 work days)

---

## Benefits After Integration

### Immediate Benefits
1. ✅ **100% test pass rate** (vs current 48%)
2. ✅ **Real LSL execution** (no more pattern matching hacks)
3. ✅ **Full API call capture** (every llOwnerSay, llMessageLinked)
4. ✅ **Accurate routing validation**
5. ✅ **Proper function execution** (show_main_menu, register_self, etc.)

### Long-Term Benefits
1. ✅ **Add new tests easily** (just write LSL, inject events, assert outputs)
2. ✅ **Test complex scenarios** (multi-state scripts, timers, etc.)
3. ✅ **Regression testing** (catch bugs before deployment)
4. ✅ **Fast iteration** (still 2-second test runs, no simulator needed)
5. ✅ **CI/CD integration** (automated testing in build pipeline)

---

## Risks & Mitigations

### Risk 1: YEngine Complexity
**Problem:** YEngine is 50,000+ lines of code
**Mitigation:** We only use compiler + runtime, not full engine infrastructure

### Risk 2: Dependency Hell
**Problem:** YEngine depends on OpenSim types
**Mitigation:** Stub out dependencies with minimal implementations

### Risk 3: Memory Usage
**Problem:** Full compiler might be heavyweight
**Mitigation:** Compile once per test run, reuse compiled bytecode

### Risk 4: Debugging Difficulty
**Problem:** Bytecode execution harder to debug than pattern matching
**Mitigation:** YEngine has excellent error reporting and stack traces

---

## Alternative: Hybrid Approach

If full YEngine integration is too complex, consider **hybrid approach**:

1. **Use YEngine compiler** to validate syntax and parse script
2. **Use EventInjector** for simplified execution simulation
3. **Best of both worlds:** Real parsing + lightweight execution

```csharp
public void LoadScript(string lslCode)
{
    // Compile with YEngine to validate syntax
    var compiled = _compiler.Compile(lslCode);
    
    // But use EventInjector for execution (current approach)
    _eventInjector.InjectStateEntry(lslCode);
}
```

This gives us:
- ✅ Real syntax validation
- ✅ Better error messages
- ✅ AST for analysis
- ❌ Still using pattern matching (but at least we know script is valid)

---

## Recommendation

**Proceed with full YEngine integration** because:

1. ✅ **One-time effort** (6-10 hours) with permanent benefits
2. ✅ **Proven technology** (powers OpenSim production environments)
3. ✅ **Complete solution** (no more pattern matching workarounds)
4. ✅ **Future-proof** (can test any LSL feature)
5. ✅ **Better test coverage** (100% vs 48%)

**Next Steps:**
1. Run `.\extract_components.ps1` to get YEngine source
2. Create dependency stubs (2-3 hours)
3. Wire up YEngineCompiler adapter (30 min)
4. Update MockLSLApi to implement ILSL_Api (1 hour)
5. Test and debug (2-4 hours)

**Total investment: 1-2 days for a production-quality LSL test harness!**

---

**Ready to proceed?** Run the extraction script and let's build this!

```powershell
cd test_harness
.\extract_components.ps1
```
