/* =============================================================
   MODULE:  ds_collar_kmod_settings.lsl
   ROLE:    Settings authority (key/value + arrays), JSON-only
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers ---------- */
integer SETTINGS_QUERY_NUM = 800;  /* In : {"type":"settings_get"} | {"type":"set",...} | {"type":"list_add"/"list_remove",...} */
integer SETTINGS_SYNC_NUM  = 870;  /* Out: {"type":"settings_sync","kv":{...}} */

/* ---------- Whitelisted setting keys ---------- */
string KEY_OWNER_KEY        = "owner_key";
string KEY_OWNER_HON        = "owner_hon";
string KEY_TRUSTEES         = "trustees";
string KEY_TRUSTEE_HONS     = "trustee_honorifics";
string KEY_BLACKLIST        = "blacklist";
string KEY_PUBLIC_ACCESS    = "public_mode";

/* ---------- Internal JSON store ---------- */
string kv_json = "{}";

/* Optional bounds */
integer MAX_LIST_LEN = 64;
integer LAST_GET_TS  = 0;

/* ---------- Helpers ---------- */
integer logd(string s) { if (DEBUG) llOwnerSay("[SETTINGS] " + s); return 0; }

integer json_has(string j, list path) {
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return FALSE;
    return TRUE;
}

integer is_json_obj(string s) { return llGetSubString(s, 0, 0) == "{"; }
integer is_json_arr(string s) { return llGetSubString(s, 0, 0) == "["; }

string kv_get(string key_str) {
    string v = llJsonGetValue(kv_json, [ key_str ]);
    if (v == JSON_INVALID) return "";
    return v;
}

list json_array_to_capped_list(string arr_json) {
    list out = [];
    if (!is_json_arr(arr_json)) return out;
    list L = llJson2List(arr_json);
    integer n = llGetListLength(L);
    integer i = 0;
    while (i < n && i < MAX_LIST_LEN) {
        out += [ llList2String(L, i) ];
        i += 1;
    }
    return out;
}

string normalize_mode01(string s) {
    integer v = (integer)s;
    if (v != 0) v = 1;
    return (string)v;
}

integer json_value_equal(string a, string b) {
    return (a == b);
}

integer kv_set_scalar(string key_str, string val_str) {
    string oldv = kv_get(key_str);
    if (json_value_equal(oldv, val_str)) return FALSE;
    kv_json = llJsonSetValue(kv_json, [ key_str ], val_str);
    logd("SET " + key_str + " = " + val_str);
    return TRUE;
}

integer kv_set_list(string key_str, list values) {
    string new_arr = llList2Json(JSON_ARRAY, values);
    string old_arr = kv_get(key_str);
    if (json_value_equal(old_arr, new_arr)) return FALSE;
    kv_json = llJsonSetValue(kv_json, [ key_str ], new_arr);
    logd("SET " + key_str + " count=" + (string)llGetListLength(values));
    return TRUE;
}

integer kv_list_add_unique(string key_str, string elem) {
    string arr = kv_get(key_str);
    list L = [];
    if (is_json_arr(arr)) L = llJson2List(arr);
    integer idx = llListFindList(L, [ elem ]);
    if (idx != -1) return FALSE;
    if (llGetListLength(L) >= MAX_LIST_LEN) return FALSE;
    L += [ elem ];
    return kv_set_list(key_str, L);
}

integer kv_list_remove_all(string key_str, string elem) {
    string arr = kv_get(key_str);
    if (!is_json_arr(arr)) return FALSE;
    list L = llJson2List(arr);
    integer n = llGetListLength(L);
    integer i = 0;
    integer did_change = FALSE;
    list R = [];
    while (i < n) {
        string s = llList2String(L, i);
        if (s != elem) R += [ s ];
        else did_change = TRUE;
        i += 1;
    }
    if (!did_change) return FALSE;
    return kv_set_list(key_str, R);
}

integer broadcast_sync_once() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], "settings_sync");
    j = llJsonSetValue(j, ["kv"],   kv_json);
    llMessageLinked(LINK_SET, SETTINGS_SYNC_NUM, j, NULL_KEY);
    logd("sync → " + j);
    return 0;
}

integer maybe_broadcast_sync_on_get() {
    integer now = llGetUnixTime();
    if (now == LAST_GET_TS) return 0;
    LAST_GET_TS = now;
    broadcast_sync_once();
    return 0;
}

integer is_allowed_key(string k) {
    if (k == KEY_OWNER_KEY)      return TRUE;
    if (k == KEY_OWNER_HON)      return TRUE;
    if (k == KEY_TRUSTEES)       return TRUE;
    if (k == KEY_TRUSTEE_HONS)   return TRUE;
    if (k == KEY_BLACKLIST)      return TRUE;
    if (k == KEY_PUBLIC_ACCESS)  return TRUE;
    return FALSE;
}

/* ---------- Events ---------- */
default
{
    state_entry() {
        broadcast_sync_once();
    }

    link_message(integer sender, integer num, string str, key id)
    {
        if (num != SETTINGS_QUERY_NUM) return;
        if (!json_has(str, ["type"]))  return;

        string t = llJsonGetValue(str, ["type"]);

        if (t == "settings_get") {
            maybe_broadcast_sync_on_get();
            return;
        }

        if (t == "set") {
            if (!json_has(str, ["key"])) return;
            string key_str = llJsonGetValue(str, ["key"]);
            if (!is_allowed_key(key_str)) return;

            integer did_change_set = FALSE;

            if (json_has(str, ["values"])) {
                string arr = llJsonGetValue(str, ["values"]);
                if (is_json_arr(arr)) {
                    list L = json_array_to_capped_list(arr);
                    did_change_set = kv_set_list(key_str, L);
                }
            } 
            else if (json_has(str, ["value"])) {
                string val = llJsonGetValue(str, ["value"]);
                if (val != JSON_INVALID) {
                    if (key_str == KEY_PUBLIC_ACCESS) {
                        val = normalize_mode01(val);
                    }
                    did_change_set = kv_set_scalar(key_str, val);
                }
            }

            if (did_change_set) {
                broadcast_sync_once();
            }
            return;
        }

        if (t == "list_add" || t == "list_remove") {
            if (!json_has(str, ["key"]))  return;
            if (!json_has(str, ["elem"])) return;

            string key_str = llJsonGetValue(str, ["key"]);
            string elem    = llJsonGetValue(str, ["elem"]);
            if (!is_allowed_key(key_str)) return;

            integer did_change_list = FALSE;
            if (t == "list_add") {
                did_change_list = kv_list_add_unique(key_str, elem);
            } else {
                did_change_list = kv_list_remove_all(key_str, elem);
            }
            if (did_change_list) {
                broadcast_sync_once();
            }
            return;
        }
    }
}
