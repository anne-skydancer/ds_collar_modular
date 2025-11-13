using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using System.Collections.Generic;
using System.Text;

namespace LSLTestHarness;

/// <summary>
/// Mock implementation of LSL API functions for testing.
/// Captures outputs (llOwnerSay, llMessageLinked, llDialog) and provides
/// basic implementations of essential LSL functions.
/// </summary>
public class MockLSLApi
{
    // Output capture
    private readonly List<string> _ownerSayMessages = new();
    private readonly List<LinkMessage> _linkMessages = new();
    private readonly List<DialogCall> _dialogCalls = new();
    private readonly List<ListenCall> _listenCalls = new();
    
    // Script state
    private string? _scriptContext;
    private readonly Dictionary<int, bool> _activeListens = new();
    private int _nextListenHandle = 1;

    public MockLSLApi()
    {
    }

    // ========================================================================
    // State Management
    // ========================================================================

    public void SetScriptContext(string context)
    {
        _scriptContext = context;
    }

    public string? GetScriptContext()
    {
        return _scriptContext;
    }

    public void Reset()
    {
        ClearOutputs();
        _scriptContext = null;
        _activeListens.Clear();
        _nextListenHandle = 1;
    }

    public void ClearOutputs()
    {
        _ownerSayMessages.Clear();
        _linkMessages.Clear();
        _dialogCalls.Clear();
        _listenCalls.Clear();
    }

    // ========================================================================
    // Output Retrieval
    // ========================================================================

    public List<string> GetOwnerSayMessages() => new(_ownerSayMessages);
    public List<LinkMessage> GetLinkMessages() => new(_linkMessages);
    public List<DialogCall> GetDialogCalls() => new(_dialogCalls);
    public List<ListenCall> GetListenCalls() => new(_listenCalls);

    // ========================================================================
    // Mock LSL Functions - Communication
    // ========================================================================

    public void llOwnerSay(string msg)
    {
        _ownerSayMessages.Add(msg);
    }

    public void llMessageLinked(int linkNum, int num, string msg, string id)
    {
        _linkMessages.Add(new LinkMessage(linkNum, num, msg, id));
    }

    public void llRegionSayTo(string target, int channel, string msg)
    {
        // Capture as owner say for testing purposes
        _ownerSayMessages.Add($"[RegionSayTo {target} ch:{channel}] {msg}");
    }

    public void llDialog(string avatar, string message, string buttons, int channel)
    {
        // Parse button list from JSON array
        var buttonList = new List<string>();
        try
        {
            var jArray = JArray.Parse(buttons);
            foreach (var item in jArray)
            {
                buttonList.Add(item.ToString());
            }
        }
        catch
        {
            // If not JSON, treat as single button
            buttonList.Add(buttons);
        }

        _dialogCalls.Add(new DialogCall(avatar, message, buttonList, channel));
    }

    public int llListen(int channel, string name, string id, string msg)
    {
        int handle = _nextListenHandle++;
        _activeListens[handle] = true;
        _listenCalls.Add(new ListenCall(channel, name, id, msg));
        return handle;
    }

    public void llListenRemove(int handle)
    {
        _activeListens.Remove(handle);
    }

    // ========================================================================
    // Mock LSL Functions - JSON
    // ========================================================================

    public string llJsonGetValue(string json, string pathJson)
    {
        try
        {
            var jToken = JToken.Parse(json);
            var path = JArray.Parse(pathJson);

            foreach (var segment in path)
            {
                var key = segment.ToString();
                
                if (jToken is JObject jObj)
                {
                    if (!jObj.ContainsKey(key))
                        return "JSON_INVALID";
                    jToken = jObj[key]!;
                }
                else if (jToken is JArray jArr)
                {
                    if (!int.TryParse(key, out int index) || index < 0 || index >= jArr.Count)
                        return "JSON_INVALID";
                    jToken = jArr[index];
                }
                else
                {
                    return "JSON_INVALID";
                }
            }

            return jToken.ToString();
        }
        catch
        {
            return "JSON_INVALID";
        }
    }

    public string llList2Json(string type, string listJson)
    {
        try
        {
            var list = JArray.Parse(listJson);
            
            if (type == "JSON_OBJECT")
            {
                var obj = new JObject();
                for (int i = 0; i < list.Count - 1; i += 2)
                {
                    string key = list[i].ToString();
                    JToken value = list[i + 1];
                    obj[key] = value;
                }
                return obj.ToString(Formatting.None);
            }
            else if (type == "JSON_ARRAY")
            {
                return list.ToString(Formatting.None);
            }
            
            return "JSON_INVALID";
        }
        catch
        {
            return "JSON_INVALID";
        }
    }

    public string llJsonSetValue(string json, string pathJson, string value)
    {
        try
        {
            var jToken = JToken.Parse(json);
            var path = JArray.Parse(pathJson);

            if (path.Count == 0)
                return json;

            JToken? parent = jToken;
            for (int i = 0; i < path.Count - 1; i++)
            {
                var key = path[i].ToString();
                
                if (parent is JObject jObj)
                {
                    if (!jObj.ContainsKey(key))
                        jObj[key] = new JObject();
                    parent = jObj[key];
                }
                else if (parent is JArray jArr)
                {
                    if (!int.TryParse(key, out int index))
                        return "JSON_INVALID";
                    if (index < 0 || index >= jArr.Count)
                        return "JSON_INVALID";
                    parent = jArr[index];
                }
            }

            var lastKey = path[path.Count - 1].ToString();
            if (parent is JObject lastObj)
            {
                lastObj[lastKey] = value;
            }
            else if (parent is JArray lastArr)
            {
                if (!int.TryParse(lastKey, out int index))
                    return "JSON_INVALID";
                if (index < 0 || index >= lastArr.Count)
                    return "JSON_INVALID";
                lastArr[index] = value;
            }

            return jToken.ToString(Formatting.None);
        }
        catch
        {
            return "JSON_INVALID";
        }
    }

    // ========================================================================
    // Mock LSL Functions - List Operations
    // ========================================================================

    public int llGetListLength(string listJson)
    {
        try
        {
            var list = JArray.Parse(listJson);
            return list.Count;
        }
        catch
        {
            return 0;
        }
    }

    public string llList2String(string listJson, int index)
    {
        try
        {
            var list = JArray.Parse(listJson);
            if (index < 0 || index >= list.Count)
                return "";
            return list[index].ToString();
        }
        catch
        {
            return "";
        }
    }

    public int llList2Integer(string listJson, int index)
    {
        try
        {
            var list = JArray.Parse(listJson);
            if (index < 0 || index >= list.Count)
                return 0;
            return list[index].ToObject<int>();
        }
        catch
        {
            return 0;
        }
    }

    public int llListFindList(string listJson, string sublistJson)
    {
        try
        {
            var list = JArray.Parse(listJson);
            var sublist = JArray.Parse(sublistJson);
            
            if (sublist.Count == 0)
                return -1;

            for (int i = 0; i <= list.Count - sublist.Count; i++)
            {
                bool match = true;
                for (int j = 0; j < sublist.Count; j++)
                {
                    if (!JToken.DeepEquals(list[i + j], sublist[j]))
                    {
                        match = false;
                        break;
                    }
                }
                if (match)
                    return i;
            }
            
            return -1;
        }
        catch
        {
            return -1;
        }
    }

    // ========================================================================
    // Mock LSL Functions - String Operations
    // ========================================================================

    public int llStringLength(string str)
    {
        return str.Length;
    }

    public string llGetSubString(string str, int start, int end)
    {
        if (start < 0) start = 0;
        if (end >= str.Length) end = str.Length - 1;
        if (start > end) return "";
        
        int length = end - start + 1;
        return str.Substring(start, length);
    }

    public int llSubStringIndex(string str, string pattern)
    {
        return str.IndexOf(pattern);
    }

    // ========================================================================
    // Mock LSL Functions - Utility
    // ========================================================================

    public int llGetUnixTime()
    {
        return (int)DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    }

    public string llGetScriptName()
    {
        return _scriptContext ?? "test_script";
    }

    public void llResetScript()
    {
        // In test harness, just clear state
        Reset();
    }

    public void llSetTimerEvent(float seconds)
    {
        // Timer management would be handled by EventInjector
        // This is just a stub
    }

    // ========================================================================
    // Mock LSL Functions - Constants
    // ========================================================================

    public const string NULL_KEY = "00000000-0000-0000-0000-000000000000";
    public const string JSON_INVALID = "JSON_INVALID";
    public const string JSON_OBJECT = "JSON_OBJECT";
    public const string JSON_ARRAY = "JSON_ARRAY";
    public const int LINK_SET = -1;
    public const int TRUE = 1;
    public const int FALSE = 0;
}
