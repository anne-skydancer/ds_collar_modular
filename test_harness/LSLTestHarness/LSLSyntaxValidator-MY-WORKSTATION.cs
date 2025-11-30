using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace LSLTestHarness;

/// <summary>
/// Validates LSL script syntax and structure without full compilation.
/// Provides better error messages than simple pattern matching.
/// </summary>
public class LSLSyntaxValidator
{
    private readonly List<string> _errors = new();
    private readonly List<string> _warnings = new();

    public IReadOnlyList<string> Errors => _errors;
    public IReadOnlyList<string> Warnings => _warnings;
    public bool IsValid => _errors.Count == 0;

    /// <summary>
    /// Validate LSL script syntax and structure
    /// </summary>
    public bool Validate(string lslCode)
    {
        _errors.Clear();
        _warnings.Clear();

        if (string.IsNullOrWhiteSpace(lslCode))
        {
            _errors.Add("Script code is empty");
            return false;
        }

        // Check for required default state
        if (!Regex.IsMatch(lslCode, @"\bdefault\s*\{", RegexOptions.Multiline))
        {
            _errors.Add("Script must contain a 'default' state");
        }

        // Check for LSL-incompatible syntax
        CheckForTernaryOperator(lslCode);
        CheckForSwitchStatement(lslCode);
        CheckForContinueStatement(lslCode);
        CheckForBreakStatement(lslCode);
        CheckForReservedKeywords(lslCode);
        CheckBraceBalance(lslCode);
        CheckForCommonMistakes(lslCode);

        return IsValid;
    }

    private void CheckForTernaryOperator(string code)
    {
        // Look for pattern: condition ? true_val : false_val
        var match = Regex.Match(code, @"[^/]\s*\?\s*[^:]+\s*:", RegexOptions.Multiline);
        if (match.Success)
        {
            _errors.Add($"Ternary operator (? :) is not supported in LSL. Use if/else instead.");
        }
    }

    private void CheckForSwitchStatement(string code)
    {
        if (Regex.IsMatch(code, @"\bswitch\s*\(", RegexOptions.Multiline))
        {
            _errors.Add("'switch' statement is not supported in LSL. Use if/else if/else chain instead.");
        }
    }

    private void CheckForContinueStatement(string code)
    {
        if (Regex.IsMatch(code, @"\bcontinue\s*;", RegexOptions.Multiline))
        {
            _errors.Add("'continue' statement is not supported in LSL. Restructure your loop logic.");
        }
    }

    private void CheckForBreakStatement(string code)
    {
        // Break is only valid in loops (while, do-while, for)
        // LSL doesn't have switch, so any break outside loop context is invalid
        var breakMatches = Regex.Matches(code, @"\bbreak\s*;", RegexOptions.Multiline);
        if (breakMatches.Count > 0)
        {
            _warnings.Add($"Found {breakMatches.Count} 'break' statement(s). Ensure they're only in loops (LSL has no switch).");
        }
    }

    private void CheckForReservedKeywords(string code)
    {
        // Check for reserved words used as variable names
        var reservedKeywords = new[]
        {
            "key", "integer", "float", "string", "vector", "rotation", "list",
            "event", "state", "default", "for", "while", "do", "if", "else",
            "jump", "return"
        };

        foreach (var keyword in reservedKeywords)
        {
            // Look for pattern: keyword as variable name
            var pattern = $@"\b{keyword}\s+{keyword}\s*[=;]";
            if (Regex.IsMatch(code, pattern, RegexOptions.Multiline))
            {
                _errors.Add($"Reserved keyword '{keyword}' cannot be used as a variable name");
            }
        }
    }

    private void CheckBraceBalance(string code)
    {
        // Remove string literals and comments to avoid false positives
        var cleaned = RemoveStringsAndComments(code);

        int openBraces = 0;
        int closeBraces = 0;
        int openParens = 0;
        int closeParens = 0;

        foreach (char c in cleaned)
        {
            switch (c)
            {
                case '{': openBraces++; break;
                case '}': closeBraces++; break;
                case '(': openParens++; break;
                case ')': closeParens++; break;
            }
        }

        if (openBraces != closeBraces)
        {
            _errors.Add($"Mismatched braces: {openBraces} open, {closeBraces} close");
        }

        if (openParens != closeParens)
        {
            _errors.Add($"Mismatched parentheses: {openParens} open, {closeParens} close");
        }
    }

    private void CheckForCommonMistakes(string code)
    {
        // Check for function definitions after states
        var stateMatch = Regex.Match(code, @"\bdefault\s*\{", RegexOptions.Multiline);
        if (stateMatch.Success)
        {
            var afterState = code.Substring(stateMatch.Index);
            var afterStateEnd = afterState.IndexOf("\n}\n", StringComparison.Ordinal);
            if (afterStateEnd > 0)
            {
                var afterDefault = afterState.Substring(afterStateEnd);
                // Look for function definitions after state
                if (Regex.IsMatch(afterDefault, @"^\s*\w+\s+\w+\s*\([^)]*\)\s*\{", RegexOptions.Multiline))
                {
                    _errors.Add("Functions must be defined BEFORE the default state, not after");
                }
            }
        }

        // Check for incorrect string concatenation
        if (Regex.IsMatch(code, @"[""']\s*\+\s*[""']", RegexOptions.Multiline))
        {
            _warnings.Add("Adjacent string literals can be concatenated without + operator");
        }

        // Check for llSleep(0) which is wasteful
        if (Regex.IsMatch(code, @"llSleep\s*\(\s*0\.?0*\s*\)", RegexOptions.Multiline))
        {
            _warnings.Add("llSleep(0) is wasteful and should be removed");
        }
    }

    private string RemoveStringsAndComments(string code)
    {
        // Remove single-line comments
        code = Regex.Replace(code, @"//.*$", "", RegexOptions.Multiline);
        
        // Remove multi-line comments
        code = Regex.Replace(code, @"/\*.*?\*/", "", RegexOptions.Singleline);
        
        // Remove string literals
        code = Regex.Replace(code, @"""(?:[^""\\]|\\.)*""", "\"\"", RegexOptions.Singleline);
        
        return code;
    }

    /// <summary>
    /// Get a formatted error report
    /// </summary>
    public string GetErrorReport()
    {
        var report = new System.Text.StringBuilder();
        
        if (_errors.Count > 0)
        {
            report.AppendLine("=== ERRORS ===");
            foreach (var error in _errors)
            {
                report.AppendLine($"  ✗ {error}");
            }
        }

        if (_warnings.Count > 0)
        {
            if (report.Length > 0) report.AppendLine();
            report.AppendLine("=== WARNINGS ===");
            foreach (var warning in _warnings)
            {
                report.AppendLine($"  ⚠ {warning}");
            }
        }

        return report.ToString();
    }
}
