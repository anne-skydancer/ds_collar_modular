using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace LSLTestHarness
{
    /// <summary>
    /// Simplified LSL interpreter that handles function calls and control flow
    /// Uses regex-based parsing with better recursion handling
    /// </summary>
    public class YEngineAdapter
    {
        private readonly MockLSLApi _api;
        private readonly string _scriptCode;
        private readonly Dictionary<string, string> _functionBodies = new();
        private readonly Dictionary<string, string> _constants = new();
        private readonly Dictionary<string, string> _globals = new();
        private readonly Dictionary<string, string> _runtimeGlobals = new(); // Runtime state of globals
        private int _recursionDepth = 0;
        private const int MAX_RECURSION = 10;
        private readonly Dictionary<string, string> _executionContext = new();

        public YEngineAdapter(MockLSLApi api, string scriptCode)
        {
            _api = api;
            _scriptCode = scriptCode;
            ParseScript();
            
            // Initialize runtime globals with parsed initial values
            foreach (var kvp in _globals)
            {
                _runtimeGlobals[kvp.Key] = kvp.Value;
            }

        }

        public void SetExecutionContext(string key, string value)
        {
            _executionContext[key] = value;
        }

        public void ClearExecutionContext()
        {
            _executionContext.Clear();
        }
        
        public void SetRuntimeGlobal(string name, string value)
        {
            _runtimeGlobals[name] = value;
            Console.WriteLine($"[YEngineAdapter] SetRuntimeGlobal: {name} = {value}");
        }
        
        public string GetRuntimeGlobal(string name)
        {
            return _runtimeGlobals.TryGetValue(name, out string? value) ? value : "";
        }

        private void ParseScript()
        {
            Console.WriteLine($"[YEngineAdapter] ParseScript started");
            
            // Extract all constants
            var constantPattern = @"(integer|float|string|key|list)\s+([A-Z_][A-Z0-9_]*)\s*=\s*([^;]+);";
            foreach (Match match in Regex.Matches(_scriptCode, constantPattern))
            {
                string name = match.Groups[2].Value;
                string value = match.Groups[3].Value.Trim();
                _constants[name] = value;
            }
            Console.WriteLine($"[YEngineAdapter] Found {_constants.Count} constants");

            // Extract all global variables
            var globalPattern = @"^(integer|float|string|key|list|vector|rotation)\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*([^;]+);";
            foreach (Match match in Regex.Matches(_scriptCode, globalPattern, RegexOptions.Multiline))
            {
                string name = match.Groups[2].Value;
                string value = match.Groups[3].Value.Trim();
                
                // Skip constants (already captured)
                if (_constants.ContainsKey(name))
                    continue;
                    
                _globals[name] = value;
            }
            Console.WriteLine($"[YEngineAdapter] Found {_globals.Count} globals");

            // Extract all function definitions
            // Match both typed functions (integer foo()) and typeless functions (foo())
            // Need to exclude event handlers (inside default state) and control flow keywords
            var funcPattern = @"^\s*(?:(?:integer|float|string|key|list|vector|rotation)\s+)?(\w+)\s*\(([^)]*)\)\s*\{";
            var matches = Regex.Matches(_scriptCode, funcPattern, RegexOptions.Multiline);
            Console.WriteLine($"[YEngineAdapter] Found {matches.Count} potential function matches");

            foreach (Match match in matches)
            {
                string funcName = match.Groups[1].Value;
                
                // Skip control flow keywords
                if (funcName == "if" || funcName == "else" || funcName == "while" || funcName == "for" || funcName == "default")
                {
                    Console.WriteLine($"[YEngineAdapter] Skipping {funcName} (control flow keyword)");
                    continue;
                }
                
                // Skip if it's in default state
                int matchPos = match.Index;
                int defaultStatePos = _scriptCode.IndexOf("default");
                if (defaultStatePos >= 0 && matchPos > defaultStatePos)
                {
                    Console.WriteLine($"[YEngineAdapter] Skipping {funcName} (in default state)");
                    continue;
                }

                // Find the opening brace and extract body
                int bracePos = _scriptCode.IndexOf('{', matchPos);
                if (bracePos >= 0)
                {
                    string body = ExtractFunctionBody(bracePos + 1);
                    if (!string.IsNullOrEmpty(body))
                    {
                        _functionBodies[funcName] = body;
                        Console.WriteLine($"[YEngineAdapter] Extracted function: {funcName}");
                    }
                }
            }
            
            Console.WriteLine($"[YEngineAdapter] Total functions extracted: {_functionBodies.Count}");
            foreach (var func in _functionBodies.Keys)
            {
                Console.WriteLine($"[YEngineAdapter]   - {func}");
            }
        }

        private string ExtractFunctionBody(int startPos)
        {
            int braceCount = 1;
            int pos = startPos;
            
            while (pos < _scriptCode.Length && braceCount > 0)
            {
                char c = _scriptCode[pos];
                if (c == '{') braceCount++;
                else if (c == '}') braceCount--;
                pos++;
            }

            if (braceCount == 0)
            {
                return _scriptCode.Substring(startPos, pos - startPos - 1);
            }

            return string.Empty;
        }

        public void ExecuteFunction(string functionName, params string[] args)
        {
            Console.WriteLine($"[YEngineAdapter] ExecuteFunction called: {functionName}");
            
            if (_recursionDepth >= MAX_RECURSION)
            {
                Console.WriteLine($"[YEngineAdapter] Max recursion depth reached for {functionName}");
                return;
            }

            if (!_functionBodies.ContainsKey(functionName))
            {
                Console.WriteLine($"[YEngineAdapter] Function not found: {functionName}. Available functions: {string.Join(", ", _functionBodies.Keys)}");
                return;
            }

            _recursionDepth++;
            try
            {
                string body = _functionBodies[functionName];
                // Execute function body; ignore return flag at top-level
                ExecuteFunctionBody(body, null);
            }
            finally
            {
                _recursionDepth--;
            }
        }

        private string CombineMultilineStatements(string body)
        {
            // Combine lines that don't end with ; into single statements
            var lines = body.Split('\n');
            var result = new System.Text.StringBuilder();
            string currentStatement = "";
            
            foreach (var line in lines)
            {
                string trimmed = line.Trim();
                
                // Skip comments and empty lines
                if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith("//"))
                {
                    if (!string.IsNullOrEmpty(currentStatement))
                    {
                        result.AppendLine(currentStatement);
                        currentStatement = "";
                    }
                    continue;
                }
                
                currentStatement += " " + trimmed;
                
                // Check if statement is complete (ends with ; or { or })
                if (trimmed.EndsWith(";") || trimmed.EndsWith("{") || trimmed.EndsWith("}"))
                {
                    result.AppendLine(currentStatement.Trim());
                    currentStatement = "";
                }
            }
            
            // Add any remaining statement
            if (!string.IsNullOrEmpty(currentStatement))
                result.AppendLine(currentStatement.Trim());
            
            return result.ToString();
        }
        
        private bool ExecuteFunctionBody(string body, Dictionary<string,string>? initialLocalVars = null)
        {
            // Track local variables in this function execution
            var localVars = initialLocalVars != null ? new Dictionary<string,string>(initialLocalVars) : new Dictionary<string, string>();

            Console.WriteLine($"[YEngineAdapter] ExecuteFunctionBody - processing {body.Split('\n').Length} lines");

            // First, combine multi-line statements into single lines
            body = CombineMultilineStatements(body);

            // Process line by line to handle control flow
            var lines = body.Split('\n');

            for (int i = 0; i < lines.Length; i++)
            {
                string trimmed = lines[i].Trim();

                if (trimmed.Length > 0)
                    Console.WriteLine($"[YEngineAdapter] Processing line {i}: {trimmed.Substring(0, Math.Min(80, trimmed.Length))}");

                // Skip empty lines and comments
                if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith("//"))
                    continue;

                // Handle return statements
                if (trimmed.StartsWith("return"))
                {
                    Console.WriteLine($"[YEngineAdapter] Return statement - exiting function");
                    return true; // indicate we returned
                }

                // Handle if statements with proper evaluation
                if (trimmed.StartsWith("if ("))
                {
                    // Extract condition within parentheses
                    var condMatch = Regex.Match(trimmed, @"if\s*\((.+)\)\s*(\{)?");
                    string cond = condMatch.Success ? condMatch.Groups[1].Value.Trim() : "";
                    bool hasBlock = condMatch.Success && condMatch.Groups.Count > 2 && condMatch.Groups[2].Value == "{";

                    Console.WriteLine($"[YEngineAdapter] If statement: condition='{cond}', hasBlock={hasBlock}");

                    bool condResult = EvaluateCondition(cond, localVars);
                    Console.WriteLine($"[YEngineAdapter] Condition evaluated: {condResult}");

                    // Single-line guard: if (...) return;
                    if (!hasBlock && trimmed.Contains("return;") )
                    {
                        if (condResult)
                        {
                            Console.WriteLine($"[YEngineAdapter] Guard clause - condition true, performing return");
                            return true;
                        }
                        else
                        {
                            Console.WriteLine($"[YEngineAdapter] Guard clause - condition false, continuing");
                            continue;
                        }
                    }

                    if (hasBlock)
                    {
                        // Find block range
                        int braceCount = 0;
                        int startIdx = -1;
                        int endIdx = -1;
                        for (int j = i; j < lines.Length; j++)
                        {
                            string ln = lines[j];
                            if (ln.Contains("{"))
                            {
                                if (startIdx == -1) startIdx = j + 1;
                                braceCount += CountChar(ln, '{');
                            }
                            if (ln.Contains("}")) braceCount -= CountChar(ln, '}');
                            if (startIdx != -1 && braceCount == 0)
                            {
                                endIdx = j - 0; // inclusive end index is j
                                break;
                            }
                        }

                        if (startIdx == -1 || endIdx == -1)
                        {
                            Console.WriteLine($"[YEngineAdapter] Malformed if-block, skipping");
                            continue;
                        }

                        if (condResult)
                        {
                            Console.WriteLine($"[YEngineAdapter] If block - executing body ({startIdx}..{endIdx})");
                            // Execute inner block using same localVars
                            string blockText = string.Join("\n", lines[startIdx..endIdx]);
                            bool innerReturned = ExecuteFunctionBody(blockText, localVars);
                            if (innerReturned) return true;
                        }
                        else
                        {
                            Console.WriteLine($"[YEngineAdapter] If block - skipping body");
                        }

                        // Advance i to after the block end
                        i = endIdx;

                        // Handle optional else block
                        int nextIdx = i + 1;
                        while (nextIdx < lines.Length && string.IsNullOrWhiteSpace(lines[nextIdx])) nextIdx++;
                        if (nextIdx < lines.Length && lines[nextIdx].TrimStart().StartsWith("else"))
                        {
                            // Determine else block range
                            int elseStart = -1; int elseEnd = -1; braceCount = 0;
                            for (int j = nextIdx; j < lines.Length; j++)
                            {
                                string ln = lines[j];
                                if (ln.Contains("{"))
                                {
                                    if (elseStart == -1) elseStart = j + 1;
                                    braceCount += CountChar(ln, '{');
                                }
                                if (ln.Contains("}")) braceCount -= CountChar(ln, '}');
                                if (elseStart != -1 && braceCount == 0)
                                {
                                    elseEnd = j - 0;
                                    break;
                                }
                            }

                            if (elseStart != -1 && elseEnd != -1)
                            {
                                if (!condResult)
                                {
                                    Console.WriteLine($"[YEngineAdapter] Else block - executing body ({elseStart}..{elseEnd})");
                                    string elseText = string.Join("\n", lines[elseStart..elseEnd]);
                                    bool innerReturned = ExecuteFunctionBody(elseText, localVars);
                                    if (innerReturned) return true;
                                }
                                else
                                {
                                    Console.WriteLine($"[YEngineAdapter] Else block - skipping body");
                                }

                                i = elseEnd;
                            }
                        }

                        continue;
                    }

                    // Fallback for any other form
                    Console.WriteLine($"[YEngineAdapter] If pattern not handled, continuing");
                    continue;
                }

                // Skip closing braces (they're structural, not code)
                if (trimmed == "}")
                {
                    continue;
                }

                // Handle typed variable declarations: string msg = ...;
                var declPattern = @"^\s*(?:string|integer|float|key|list)\s+(\w+)\s*=\s*(.+?);";
                var declMatch = Regex.Match(trimmed, declPattern);
                if (declMatch.Success)
                {
                    string varName = declMatch.Groups[1].Value;
                    string valueExpr = declMatch.Groups[2].Value.Trim();
                    
                    Console.WriteLine($"[YEngineAdapter] Variable declaration: {varName} = {valueExpr}");
                    
                    // Try to resolve the value
                    string resolvedValue = ResolveStringOrCallFunction(valueExpr, localVars);
                    localVars[varName] = resolvedValue;
                    
                    Console.WriteLine($"[YEngineAdapter] Stored local {varName} = {resolvedValue}");
                    continue;
                }
                
                // Handle untyped assignments: VarName = ...;
                var assignPattern = @"^(\w+)\s*=\s*(.+?);";
                var assignMatch = Regex.Match(trimmed, assignPattern);
                if (assignMatch.Success)
                {
                    string varName = assignMatch.Groups[1].Value;
                    string valueExpr = assignMatch.Groups[2].Value.Trim();
                    
                    // Check if this is a global variable or local
                    bool isGlobal = _globals.ContainsKey(varName) || char.IsUpper(varName[0]);
                    
                    Console.WriteLine($"[YEngineAdapter] Assignment: {varName} = {valueExpr} (global={isGlobal})");
                    
                    // Try to resolve the value
                    string resolvedValue = ResolveStringOrCallFunction(valueExpr, localVars);
                    
                    if (isGlobal)
                    {
                        SetRuntimeGlobal(varName, resolvedValue);
                    }
                    else
                    {
                        localVars[varName] = resolvedValue;
                    }
                    
                    Console.WriteLine($"[YEngineAdapter] Stored {(isGlobal ? "global" : "local")} {varName} = {resolvedValue}");
                    continue;
                }


                // Handle user function calls (not starting with ll)
                var userFuncPattern = @"^(\w+)\s*\(([^)]*)\)\s*;";
                var userFuncMatch = Regex.Match(trimmed, userFuncPattern);
                if (userFuncMatch.Success)
                {
                    string calledFunc = userFuncMatch.Groups[1].Value;
                    
                    // Skip LSL API functions
                    if (!calledFunc.StartsWith("ll") && _functionBodies.ContainsKey(calledFunc))
                    {
                        Console.WriteLine($"[YEngineAdapter] Calling user function: {calledFunc}");
                        
                        // For now, ignore parameters (would need proper parameter passing)
                        // TODO: Parse and pass actual parameters
                        ExecuteFunction(calledFunc);
                        continue;
                    }
                }

                // Handle llMessageLinked calls
                var llMessageLinkedPattern = @"llMessageLinked\s*\(\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^)]+)\)";
                var match2 = Regex.Match(trimmed, llMessageLinkedPattern);
                if (match2.Success)
                {
                    Console.WriteLine($"[YEngineAdapter] Found llMessageLinked call");
                    int linkNum = ResolveInt(match2.Groups[1].Value.Trim());
                    int num = ResolveInt(match2.Groups[2].Value.Trim());
                    string msg = ResolveString(match2.Groups[3].Value.Trim(), localVars);
                    string id = ResolveString(match2.Groups[4].Value.Trim(), localVars);
                    
                    Console.WriteLine($"[YEngineAdapter] Calling _api.llMessageLinked({linkNum}, {num}, {msg}, {id})");
                    _api.llMessageLinked(linkNum, num, msg, id);
                    continue;
                }

                // Handle llOwnerSay calls
                var llOwnerSayPattern = @"llOwnerSay\s*\(\s*([^)]+)\)";
                match2 = Regex.Match(trimmed, llOwnerSayPattern);
                if (match2.Success)
                {
                    string msg = ResolveString(match2.Groups[1].Value.Trim(), localVars);
                    _api.llOwnerSay(msg);
                    continue;
                }

                // Handle llRegionSayTo calls
                var llRegionSayToPattern = @"llRegionSayTo\s*\(\s*([^,]+),\s*([^,]+),\s*([^)]+)\)";
                match2 = Regex.Match(trimmed, llRegionSayToPattern);
                if (match2.Success)
                {
                    string target = ResolveString(match2.Groups[1].Value.Trim(), localVars);
                    int channel = ResolveInt(match2.Groups[2].Value.Trim());
                    string msg = ResolveString(match2.Groups[3].Value.Trim(), localVars);
                    
                    _api.llRegionSayTo(target, channel, msg);
                    continue;
                }

                // Handle llDialog calls
                var llDialogPattern = @"llDialog\s*\(\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^)]+)\)";
                match2 = Regex.Match(trimmed, llDialogPattern);
                if (match2.Success)
                {
                    string avatar = ResolveString(match2.Groups[1].Value.Trim(), localVars);
                    string message = ResolveString(match2.Groups[2].Value.Trim(), localVars);
                    string buttons = ResolveString(match2.Groups[3].Value.Trim(), localVars);
                    int channel = ResolveInt(match2.Groups[4].Value.Trim());
                    
                    _api.llDialog(avatar, message, buttons, channel);
                    continue;
                }
            }
        }

        private int ResolveInt(string expr)
        {
            // Try to parse as direct integer
            if (int.TryParse(expr, out int result))
                return result;

            // Check if it's a constant
            if (_constants.TryGetValue(expr, out string? constValue))
            {
                if (int.TryParse(constValue, out result))
                    return result;
            }

            // Handle special values
            if (expr == "LINK_SET") return -1;
            if (expr == "LINK_THIS") return -4;
            if (expr == "LINK_ROOT") return 1;
            if (expr == "LINK_ALL_OTHERS") return -2;
            if (expr == "LINK_ALL_CHILDREN") return -3;

            // Default
            return 0;
        }

        private string ResolveStringOrCallFunction(string expr, Dictionary<string, string> localVars)
        {
            // Handle llList2Json calls by executing and returning result
            if (expr.Contains("llList2Json"))
            {
                return ResolveString(expr, localVars);
            }
            
            // Handle user-defined function calls that return values
            var funcCallMatch = Regex.Match(expr, @"^(\w+)\s*\(([^)]*)\)");
            if (funcCallMatch.Success)
            {
                string funcName = funcCallMatch.Groups[1].Value;
                if (_functionBodies.ContainsKey(funcName))
                {
                    Console.WriteLine($"[YEngineAdapter] Executing function call for return value: {funcName}");
                    
                    // Execute the function - this will process the function body
                    ExecuteFunction(funcName);
                    
                    // Now check if there's a return value captured
                    // For now, we need to parse the return statement from the function
                    string body = _functionBodies[funcName];
                    var returnMatch = Regex.Match(body, @"return\s+([^;]+);");
                    if (returnMatch.Success)
                    {
                        string returnExpr = returnMatch.Groups[1].Value.Trim();
                        Console.WriteLine($"[YEngineAdapter] Found return expression: {returnExpr}");
                        
                        // Resolve the return expression
                        string returnValue = ResolveString(returnExpr, new Dictionary<string, string>());
                        Console.WriteLine($"[YEngineAdapter] Function {funcName} returned: {returnValue}");
                        return returnValue;
                    }
                    
                    return "";
                }
            }
            
            return ResolveString(expr, localVars);
        }
        
        private string ResolveString(string expr, Dictionary<string, string> localVars)
        {
            // Strip quotes if present
            expr = expr.Trim();
            if (expr.StartsWith("\"") && expr.EndsWith("\""))
                return expr.Substring(1, expr.Length - 2);

            // Handle type casts: (string)VarName, (key)VarName, etc.
            var castMatch = Regex.Match(expr, @"^\((?:string|integer|float|key|list|vector|rotation)\)\s*(.+)$");
            if (castMatch.Success)
            {
                // Recursively resolve the inner expression
                return ResolveString(castMatch.Groups[1].Value, localVars);
            }

            // Check if it's a local variable first
            if (localVars.TryGetValue(expr, out string? localValue))
            {
                return localValue;
            }

            // Check if it's a constant
            if (_constants.TryGetValue(expr, out string? constValue))
            {
                return ResolveString(constValue, localVars);
            }

            // Check if it's a global variable (runtime state first, then initial value)
            if (_runtimeGlobals.TryGetValue(expr, out string? runtimeValue))
            {
                return ResolveString(runtimeValue, localVars);
            }
            if (_globals.TryGetValue(expr, out string? globalValue))
            {
                return ResolveString(globalValue, localVars);
            }

            // Handle special values and boolean constants
            if (expr == "NULL_KEY") return "00000000-0000-0000-0000-000000000000";
            if (expr == "TRUE") return "TRUE";
            if (expr == "FALSE") return "FALSE";
            
            // Handle LSL API function calls
            if (expr.StartsWith("ll") && expr.Contains("("))
            {
                var apiFuncMatch = Regex.Match(expr, @"^(ll\w+)\s*\(([^)]*)\)");
                if (apiFuncMatch.Success)
                {
                    string funcName = apiFuncMatch.Groups[1].Value;
                    Console.WriteLine($"[YEngineAdapter] Calling API function: {funcName}");
                    
                    // Handle specific API functions
                    if (funcName == "llGetUnixTime")
                    {
                        return DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
                    }
                    // Add more API functions as needed
                }
            }
            
            // If it looks like a variable name but wasn't found, return a safe default
            if (Regex.IsMatch(expr, @"^[A-Z][a-zA-Z0-9_]*$"))
            {
                // Looks like a global variable that wasn't initialized - use safe defaults
                Console.WriteLine($"[YEngineAdapter] Unknown variable '{expr}' - using default");
                if (expr == "CurrentUser") return "00000000-0000-0000-0000-000000000000";
                if (expr == "SessionId") return "test_session_" + DateTime.Now.Ticks;
                if (expr == "AclPending") return "FALSE";
                if (expr == "UserAcl") return "-999";
                return "";
            }

            // Handle llList2Json calls (very simplified)
            if (expr.Contains("llList2Json"))
            {
                // Try to extract JSON construction
                var jsonMatch = Regex.Match(expr, @"llList2Json\s*\(\s*JSON_OBJECT\s*,\s*\[([^\]]+)\]");
                if (jsonMatch.Success)
                {
                    // Build JSON object from list
                    string[] parts = jsonMatch.Groups[1].Value.Split(',');
                    var jsonPairs = new List<string>();
                    
                    for (int i = 0; i < parts.Length - 1; i += 2)
                    {
                        string key = ResolveString(parts[i].Trim(), localVars);
                        string value = ResolveString(parts[i + 1].Trim(), localVars);
                        jsonPairs.Add($"\"{key}\":\"{value}\"");
                    }
                    
                    return "{" + string.Join(",", jsonPairs) + "}";
                }
            }

            // Handle string concatenation (simplified)
            if (expr.Contains("+"))
            {
                var parts = expr.Split('+');
                string result = "";
                foreach (var part in parts)
                {
                    result += ResolveString(part.Trim(), localVars);
                }
                return result;
            }

            // Return as-is
            return expr;
        }

        private static int CountChar(string s, char c)
        {
            int cnt = 0;
            foreach (var ch in s)
                if (ch == c) cnt++;
            return cnt;
        }

        private bool EvaluateCondition(string cond, Dictionary<string, string> localVars)
        {
            if (string.IsNullOrWhiteSpace(cond)) return false;
            cond = cond.Trim();

            // Handle negation
            if (cond.StartsWith("!"))
            {
                string inner = cond.Substring(1).Trim();
                // strip surrounding parentheses
                if (inner.StartsWith("(") && inner.EndsWith(")"))
                    inner = inner.Substring(1, inner.Length - 2).Trim();
                return !EvaluateCondition(inner, localVars);
            }

            // Handle json_has like patterns: json_has(msg, ["field"]) or llJsonGetValue(...) != JSON_INVALID
            if (cond.Contains("json_has") || cond.Contains("llJsonGetValue"))
            {
                // Try to extract a field name in square brackets
                var m = Regex.Match(cond, "\\[\\s*\"(.*?)\"\\s*\\]");
                if (m.Success)
                {
                    string field = m.Groups[1].Value;
                    // Attempt to find json variable name (e.g., msg)
                    var varMatch = Regex.Match(cond, @"json_has\s*\(\s*(\w+)\s*,");
                    string jsonVar = varMatch.Success ? varMatch.Groups[1].Value : "";
                    string jsonValue = "";
                    if (!string.IsNullOrEmpty(jsonVar))
                        jsonValue = localVars.TryGetValue(jsonVar, out var v) ? v : (_runtimeGlobals.TryGetValue(jsonVar, out var rv) ? rv : "");

                    if (string.IsNullOrEmpty(jsonValue))
                    {
                        // If not found as variable, fallback to checking globals/constants
                        if (_runtimeGlobals.TryGetValue(jsonVar, out var rv2)) jsonValue = rv2;
                    }

                    if (!string.IsNullOrEmpty(jsonValue))
                    {
                        string pathJson = "[\"" + field + "\"]";
                        var val = _api.llJsonGetValue(jsonValue, pathJson);
                        return val != MockLSLApi.JSON_INVALID;
                    }
                }
                // Fallback: if contains '!=' JSON_INVALID, try to evaluate that pattern
                var neqMatch = Regex.Match(cond, @"llJsonGetValue\(([^,]+),\s*\[([^\]]+)\]\)\s*!=\s*JSON_INVALID");
                if (neqMatch.Success)
                {
                    // Best effort: return true
                    return true;
                }
            }

            // Comparison operators
            var compMatch = Regex.Match(cond, @"^(.+?)(==|!=|<=|>=|<|>)(.+)$");
            if (compMatch.Success)
            {
                string left = compMatch.Groups[1].Value.Trim();
                string op = compMatch.Groups[2].Value.Trim();
                string right = compMatch.Groups[3].Value.Trim();

                string leftVal = ResolveString(left, localVars);
                string rightVal = ResolveString(right, localVars);

                // Try numeric compare
                if (int.TryParse(leftVal, out int lnum) && int.TryParse(rightVal, out int rnum))
                {
                    return op switch
                    {
                        "==" => lnum == rnum,
                        "!=" => lnum != rnum,
                        "<" => lnum < rnum,
                        ">" => lnum > rnum,
                        "<=" => lnum <= rnum,
                        ">=" => lnum >= rnum,
                        _ => false,
                    };
                }

                // String compare
                return op switch
                {
                    "==" => leftVal == rightVal,
                    "!=" => leftVal != rightVal,
                    _ => false,
                };
            }

            // Existence/truthy checks: treat non-empty strings as true
            var resolved = ResolveString(cond, localVars);
            if (!string.IsNullOrEmpty(resolved))
            {
                // Special boolean tokens
                if (resolved == "TRUE" || resolved == "1") return true;
                if (resolved == "FALSE" || resolved == "0") return false;
                return true;
            }

            return false;
        }

        public string? GetConstant(string name)
        {
            return _constants.TryGetValue(name, out string? value) ? value : null;
        }

        public bool HasFunction(string name)
        {
            return _functionBodies.ContainsKey(name);
        }
    }


}

}

}

}
