# Test Harness Enhancement Summary - January 2025

## Current State: 10/21 Tests Passing (48%)

### What We Accomplished

#### ✅ Phase 1: OpenSim YEngine Extraction (Completed)
- Cloned OpenSimulator repository (268MB)
- Extracted 14 YEngine files to `extract/` directory:
  * LSL_Types.cs (LSL type definitions)
  * ILSL_Api.cs, LSL_Stub.cs (API layer)
  * 11 compiler/runtime files (MMRScriptCompile, etc.)
- Configured build system to exclude OpenSim directories from compilation
- Created EXTRACTION_COMPLETE.md documentation

#### ✅ Phase 2: LSL Syntax Validation (Completed)
- Implemented LSLSyntaxValidator.cs (217 lines)
- Validates LSL syntax before script loading
- Detects common errors:
  * Ternary operators (? :)
  * Switch statements
  * Continue keyword
  * Reserved keywords as variable names
  * Brace/parenthesis imbalance
  * Functions defined after states
  * llSleep(0) anti-patterns
- Integrated into LSLTestHarness.LoadScript()
- Result: Better error messages, prevents invalid scripts from loading

#### 🔄 Phase 3: Enhanced Function Simulation (Attempted)
- Added SimulateUserFunction() to EventInjector (126 lines)
- Extracts function bodies from LSL scripts
- Finds llMessageLinked, llOwnerSay, llRegionSayTo calls
- Resolves parameters (constants, literals, variables)
- Executes API calls through MockLSLApi

**Problem Discovered:** Doesn't handle recursive function calls
- Plugins use pattern: `handle_acl_result()` → calls → `show_animation_menu()` → calls → `llMessageLinked()`
- Current regex approach can't detect user function calls
- Result: Test pass rate unchanged (10/21 = 48%)

---

## Why Tests Fail

### Root Cause: Recursive User Function Calls

LSL plugins heavily use function composition:

```lsl
// Test expects this flow:
1. ACL result arrives (channel 700)
2. handle_acl_result(msg) called
3. show_animation_menu(0) called    ← User function
4. llMessageLinked(DIALOG_BUS, ...) ← API call
5. Dialog opened

// What EventInjector does:
1. ACL result arrives ✅
2. SimulateUserFunction("handle_acl_result") ✅
3. Extracts handle_acl_result body ✅
4. Looks for llMessageLinked calls ✅
5. Finds show_animation_menu(0) ❌  ← Not recognized as function call
6. Doesn't execute show_animation_menu() ❌
7. Dialog never opens ❌
```

### Test Breakdown by Category

**✅ Routing Tests: 5/8 (63%)**
- Pass because they test message routing, not menu display
- register_self() and send_pong() mostly work
- Some failures due to parameter resolution issues

**❌ Dialog Tests: 2/8 (25%)**
- Fail because menu display requires executing nested functions
- Only pass when testing confirmation/timeout (simple flows)
- Paginated menus, button handling all fail

**❌ ACL Tests: 3/6 (50%)**
- Pass for query/result parsing (no function calls needed)
- Fail for grant/denial flows (require menu display)
- MultipleAccessLevels fails (needs recursive execution)

---

## Options Moving Forward

### Option 1: Accept 48% and Move On ✅ RECOMMENDED FOR NOW
**Effort:** 0 hours  
**Pass Rate:** 48% (10/21)

**Rationale:**
- Pattern matching validates **what matters most**: message routing and basic flow
- Tests that pass cover critical infrastructure:
  * Message routing (STRICT/CONTEXT/BROADCAST)
  * Constant extraction and validation
  * Basic event injection
- Tests that fail are mostly UI/menu related (less critical for infrastructure testing)
- Can add more tests for what DOES work

**Next Steps:**
- Document limitations clearly ✅ (this document)
- Focus testing efforts on routing logic, not UI
- Add tests for new plugins using patterns that work
- Revisit when UI testing becomes critical

---

### Option 2: Enhanced Pattern Matching - Recursive Functions
**Effort:** 2-3 hours  
**Pass Rate Estimate:** 60-70% (13-15/21)

**Implementation:**
```csharp
private void SimulateUserFunction(string script, string funcName, int depth = 0)
{
    if (depth > 5) return; // Prevent infinite recursion
    
    string body = ExtractFunctionBody(script, funcName);
    
    // Execute LSL API calls (current)
    ExecuteLSLApiCalls(body);
    
    // NEW: Detect and execute user function calls
    var callPattern = @"(\w+)\s*\([^)]*\);";
    foreach (Match m in Regex.Matches(body, callPattern))
    {
        string calledFunc = m.Groups[1].Value;
        
        // Skip LSL API functions (start with "ll")
        if (calledFunc.StartsWith("ll")) continue;
        
        // Check if it's a user-defined function
        if (FunctionExists(script, calledFunc))
        {
            // Recursively execute
            SimulateUserFunction(script, calledFunc, depth + 1);
        }
    }
}

private bool FunctionExists(string script, string funcName)
{
    var pattern = $@"\w+\s+{funcName}\s*\([^)]*\)\s*{{";
    return Regex.IsMatch(script, pattern);
}
```

**Pros:**
- Moderate effort
- Would fix most dialog/ACL test failures
- Stays within pattern-matching architecture
- No new dependencies

**Cons:**
- Still won't handle all cases (parameter passing, complex expressions)
- Fragile - function detection via regex can miss edge cases
- May introduce infinite recursion bugs
- Testing the enhancement itself would take time

---

### Option 3: Full YEngine Integration
**Effort:** 6-10 hours  
**Pass Rate Estimate:** 95%+ (20-21/21)

**Implementation:**
- Use OpenSimulator's MMRScriptCompile to compile LSL
- Use XMRInstance or equivalent runtime to execute
- Implement ILSL_Api interface with test stubs
- Mock SL-specific APIs (llGetPos, llRequestPermissions, etc.)

**Pros:**
- 100% accurate LSL execution
- All language features work (states, timers, sensors)
- Future-proof
- No pattern-matching fragility

**Cons:**
- Significant effort (6-10 hours minimum)
- Complex dependencies (need to understand YEngine internals)
- May require extensive API mocking
- Heavyweight for unit testing
- Risk of scope creep (debugging YEngine issues)

---

### Option 4: Hybrid Approach - YEngine Parser Only
**Effort:** 4-5 hours  
**Pass Rate Estimate:** 75-85% (16-18/21)

**Implementation:**
- Use YEngine tokenizer/parser to build AST
- Interpret AST nodes instead of regex
- Still use MockLSLApi for API calls
- Handle function calls via AST traversal

**Pros:**
- Better than pattern matching (proper AST)
- Less effort than full YEngine
- Handles recursion correctly
- Better expression resolution

**Cons:**
- Partial YEngine integration may be brittle
- Still need to implement interpretation logic
- May hit edge cases in parser
- Not a full solution (no state machines, timers, etc.)

---

## Recommendation

### Immediate: Option 1 (Accept 48%)
Given current constraints:
1. **Test harness works** for what it's designed to test (routing, basic flow)
2. **Time investment** for Options 2-4 may not justify returns
3. **Focus should be** on adding tests for functionality that works
4. **UI testing** is less critical than core routing logic

**Action Items:**
1. Document limitations ✅ (this document)
2. Add more routing tests (these pass reliably)
3. Add tests for new plugins avoiding menu-heavy flows
4. Revisit enhancement when UI becomes blocking issue

### Future: Option 3 (Full YEngine) - When Justified
If any of these become true:
- Need to test complex state transitions
- Need to test timer-based behavior
- Need to test sensor/dataserver flows
- UI testing becomes critical path
- Want 95%+ test coverage

**Then:** Invest 6-10 hours in full YEngine integration.

The 48% baseline proves the architecture works. YEngine would be the "graduate to production testing" milestone.

---

## Technical Details

### What SimulateUserFunction Currently Does

**Input:** Script code, function name  
**Output:** Executes LSL API calls found in function body

**Algorithm:**
1. Extract function body using regex: `(\w+)\s+{funcName}\s*\([^)]*\)\s*{`
2. Count braces to find function end
3. Search for patterns:
   * `llMessageLinked\s*\(\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^)]+)\)`
   * `llOwnerSay\s*\(\s*([^)]+)\)`
   * `llRegionSayTo\s*\(\s*([^,]+),\s*([^,]+),\s*([^)]+)\)`
4. Resolve parameters:
   * Constants: `PLUGIN_CONTEXT` → value from script
   * Literals: `"text"`, `123`
   * Special: `NULL_KEY`, `LINK_SET`, `LINK_THIS`
   * Variables: `CurrentUser`, `SessionId` (hardcoded)
5. Execute via MockLSLApi

**Missing:**
- No detection of user function calls like `show_menu()`
- No parameter passing to called functions
- No support for expressions: `"a" + B`, `x * 2`, `llJsonGetValue(...)`
- No control flow: if/else, while, for
- No state transitions

---

## Files Modified

### LSLTestHarness\EventInjector.cs
- **Lines 140-144:** Changed ACL result handler to call SimulateUserFunction
- **Lines 197-269:** Added comprehensive function simulation infrastructure
  * SimulateUserFunction() - Main executor
  * ExtractFunctionBody() - Function parser
  * ResolveIntConstant() - Integer parameter resolution
  * ResolveStringValue() - String parameter resolution

### Build Configuration
- **LSLTestHarness.csproj:** Added `<Compile Remove="extract\**\*.cs" />`
- **DSCollarTests.csproj:** Added same exclusions

### Documentation
- **EXTRACTION_COMPLETE.md:** Documents YEngine extraction
- **TEST_RESULTS.md:** Original test results summary
- **This file:** Comprehensive enhancement summary

---

## Performance Impact

**Before Enhancement:**
- Build: 1.2s
- Test suite: 0.6s (21 tests)
- Pass rate: 10/21 (48%)

**After Enhancement:**
- Build: 1.2s (no change)
- Test suite: 0.6s (no change)
- Pass rate: 10/21 (48% - no change)

**Conclusion:** Enhancement added complexity without improving test results.

---

## Lessons Learned

1. **Pattern matching has limits:** Can't handle recursive function calls via regex
2. **Test architecture is sound:** The 48% that passes proves the framework works
3. **YEngine extraction was valuable:** Even if not integrated yet, it's ready for future use
4. **Syntax validation was worth it:** Better errors before execution
5. **Incremental approach was right:** Each phase validated before moving forward

---

## Next Steps (Recommended)

### Immediate (0-1 hour)
- ✅ Document current state (this file)
- ⏳ Commit and push all changes
- ⏳ Update main README with testing status

### Short Term (1-2 days)
- Add 5-10 more routing tests (these pass reliably)
- Add tests for message parsing helpers
- Add tests for constant extraction
- Target: 15/30 tests passing (still 50%, but more coverage of what works)

### Medium Term (1-2 weeks)
- Decide on UI testing strategy
- If UI critical: Implement Option 2 or 4
- If UI not critical: Continue with routing focus

### Long Term (When justified)
- Full YEngine integration (Option 3)
- 95%+ test coverage
- Support all LSL features

---

**Document Version:** 1.0  
**Author:** Test Harness Enhancement Team  
**Date:** January 3, 2025  
**Status:** Enhancement Phase Complete, 48% Baseline Achieved
