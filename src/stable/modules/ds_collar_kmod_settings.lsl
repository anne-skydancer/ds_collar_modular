/* =============================================================
   MODULE:  ds_collar_kmod_settings.lsl
   ROLE:    Settings authority (key/value + arrays), JSON-only
            Enforces mutual exclusivity between Owner / Trustees / Blacklist
   ============================================================= */

integer DEBUG = FALSE;

/* ---------- Global String Constants (Magic Words) ---------- */
key LastOwner = NULL_KEY;

string TYPE_SETTINGS_GET       = "settings_get";
string TYPE_SETTINGS_SYNC      = "settings_sync";
string TYPE_SET                = "set";
string TYPE_LIST_ADD           = "list_add";
string TYPE_LIST_REMOVE        = "list_remove";

/* Settings keys */
string KEY_OWNER_KEY           = "owner_key";
string KEY_OWNER_HON           = "owner_hon";
string KEY_TRUSTEES            = "trustees";
string KEY_TRUSTEE_HONS        = "trustee_honorifics";
string KEY_BLACKLIST           = "blacklist";
string KEY_PUBLIC_ACCESS       = "public_mode";
string KEY_TPE_MODE            = "tpe_mode";
string KEY_LOCKED              = "locked";

/* ---------- Link numbers ---------- */
integer SETTINGS_QUERY_NUM     = 800;  /* In : {"type":"settings_get"} | {"type":"set",...} | {"type":"list_add"/"list_remove",...} */
integer SETTINGS_SYNC_NUM      = 870;  /* Out: {"type":"settings_sync","kv":{...}} */

/* ---------- Internal JSON store ---------- */
string KvJson = "{}";

/* Optional bounds */
integer MaxListLen = 64;
integer LastGetTs  = 0;

/* ---------- Helpers ---------- */
integer logd(string s) { if (DEBUG) llOwnerSay("[SETTINGS] " + s); return 0; }

integer json_has(string j, list path) {
    string v = llJsonGetValue(j, path);
    if (v == JSON_INVALID) return FALSE;
    return TRUE;
}
integer is_json_obj(string s) { if (llGetSubString(s, 0, 0) == "{") return TRUE; return FALSE; }
integer is_json_arr(string s) { if (llGetSubString(s, 0, 0) == "[") return TRUE; return FALSE; }

string kv_get(string key_str) {
    string v = llJsonGetValue(KvJson, [ key_str ]);
    if (v == JSON_INVALID) return "";
    return v;
}

list json_array_to_capped_list(string arr_json) {
    list out = [];
    if (!is_json_arr(arr_json)) return out;
    list L = llJson2List(arr_json);
    integer n = llGetListLength(L);
    integer i = 0;
    while (i < n && i < MaxListLen) {
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

integer json_value_equal(string a, string b) { if (a == b) return TRUE; return FALSE; }

integer kv_set_scalar(string key_str, string val_str) {
    string oldv = kv_get(key_str);
    if (json_value_equal(oldv, val_str)) return FALSE;
    KvJson = llJsonSetValue(KvJson, [ key_str ], val_str);
    logd("SET " + key_str + " = " + val_str);
    return TRUE;
}

integer kv_set_list(string key_str, list values) {
    string new_arr = llList2Json(JSON_ARRAY, values);
    string old_arr = kv_get(key_str);
    if (json_value_equal(old_arr, new_arr)) return FALSE;
    KvJson = llJsonSetValue(KvJson, [ key_str ], new_arr);
    logd("SET " + key_str + " count=" + (string)llGetListLength(values));
    return TRUE;
}

integer kv_list_add_unique(string key_str, string elem) {
    string arr = kv_get(key_str);
    list L = [];
    if (is_json_arr(arr)) L = llJson2List(arr);
    integer idx = llListFindList(L, [ elem ]);
    if (idx != -1) return FALSE;
    if (llGetListLength(L) >= MaxListLen) return FALSE;
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

integer is_allowed_key(string k) {
    if (k == KEY_OWNER_KEY)      return TRUE;
    if (k == KEY_OWNER_HON)      return TRUE;
    if (k == KEY_TRUSTEES)       return TRUE;
    if (k == KEY_TRUSTEE_HONS)   return TRUE;
    if (k == KEY_BLACKLIST)      return TRUE;
    if (k == KEY_PUBLIC_ACCESS)  return TRUE;
    if (k == KEY_TPE_MODE)       return TRUE;
    if (k == KEY_LOCKED)         return TRUE;
    return FALSE;
}

/* ---------- Local list helpers (non-JSON) ---------- */
integer list_contains(list L, string s) { if (llListFindList(L, [s]) != -1) return TRUE; return FALSE; }
list list_remove_all_local(list L, string s) {
    integer idx = llListFindList(L, [s]);
    while (idx != -1) {
        L = llDeleteSubList(L, idx, idx);
        idx = llListFindList(L, [s]);
    }
    return L;
}
list list_unique(list L) {
    list U = [];
    integer i = 0;
    integer n = llGetListLength(L);
    while (i < n) {
        string s = llList2String(L, i);
        if (!list_contains(U, s)) U += [s];
        i += 1;
    }
    return U;
}

/* ---------- Role exclusivity sanitizer ---------- */
string sanitize_roles_in_kv(string in_kv) {
    string kv = in_kv;

    /* Extract current roles */
    key owner_key = NULL_KEY;
    string v = llJsonGetValue(kv, [KEY_OWNER_KEY]);
    if (v != JSON_INVALID) owner_key = (key)v;

    list trustees = [];
    v = llJsonGetValue(kv, [KEY_TRUSTEES]);
    if (v != JSON_INVALID && is_json_arr(v)) trustees = llJson2List(v);

    list blacklist = [];
    v = llJsonGetValue(kv, [KEY_BLACKLIST]);
    if (v != JSON_INVALID && is_json_arr(v)) blacklist = llJson2List(v);

    /* Uniq-ify lists */
    trustees  = list_unique(trustees);
    blacklist = list_unique(blacklist);

    /* Owner cannot be trustee */
    if (owner_key != NULL_KEY) {
        trustees = list_remove_all_local(trustees, (string)owner_key);
    }

    /* If owner appears in blacklist → clear owner (blacklist wins here) */
    if (owner_key != NULL_KEY) {
        if (list_contains(blacklist, (string)owner_key)) {
            owner_key = NULL_KEY;
        }
    }

    /* Trustees cannot be blacklisted: remove trustees from blacklist OR remove trusteeship?
       Global sanitize adopts "blacklist wins": strip trustees that are blacklisted.
       Operation-level guards will ensure user's intent when they add trustees. */
    integer i = 0;
    list clean_trustees = [];
    integer n = llGetListLength(trustees);
    while (i < n) {
        string t = llList2String(trustees, i);
        if (!list_contains(blacklist, t)) clean_trustees += [t];
        i += 1;
    }
    trustees = clean_trustees;

    /* Repack */
    kv = llJsonSetValue(kv, [KEY_OWNER_KEY], (string)owner_key);
    kv = llJsonSetValue(kv, [KEY_TRUSTEES],  llList2Json(JSON_ARRAY, trustees));
    kv = llJsonSetValue(kv, [KEY_BLACKLIST], llList2Json(JSON_ARRAY, blacklist));

    return kv;
}

/* ---------- Broadcasting with sanitize ---------- */
integer broadcast_sync_once() {
    /* Ensure a consistent snapshot before broadcasting */
    KvJson = sanitize_roles_in_kv(KvJson);

    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], TYPE_SETTINGS_SYNC);
    j = llJsonSetValue(j, ["kv"],   KvJson);
    llMessageLinked(LINK_SET, SETTINGS_SYNC_NUM, j, NULL_KEY);
    logd("sync → " + j);
    return 0;
}

integer maybe_broadcast_sync_on_get() {
    integer now = llGetUnixTime();
    if (now == LastGetTs) return 0;
    LastGetTs = now;
    broadcast_sync_once();
    return 0;
}

/* ---------- Operation-level role guards ---------- */
integer apply_owner_set_guard(string new_owner_str) {
    /* When setting owner:
       - Remove from trustees
        - Remove from blacklist
    */
    if (new_owner_str == "" || new_owner_str == (string)NULL_KEY) return FALSE;

    /* Trustees */
    string arr_tr = kv_get(KEY_TRUSTEES);
    if (is_json_arr(arr_tr)) {
        list tr = llJson2List(arr_tr);
        tr = list_remove_all_local(tr, new_owner_str);
        kv_set_list(KEY_TRUSTEES, tr);
    }

    /* Blacklist */
    string arr_bl = kv_get(KEY_BLACKLIST);
    if (is_json_arr(arr_bl)) {
        list bl = llJson2List(arr_bl);
        bl = list_remove_all_local(bl, new_owner_str);
        kv_set_list(KEY_BLACKLIST, bl);
    }
    return TRUE;
}

integer apply_trustee_add_guard(string who) {
    /* Adding trustee:
       - Remove from blacklist
       - Do NOT add if same as owner
    */
    string cur_owner = kv_get(KEY_OWNER_KEY);
    if (cur_owner != "" && cur_owner != JSON_INVALID) {
        if (who == cur_owner) return FALSE; /* owner can't be trustee */
    }
    string arr_bl = kv_get(KEY_BLACKLIST);
    if (is_json_arr(arr_bl)) {
        list bl = llJson2List(arr_bl);
        bl = list_remove_all_local(bl, who);
        kv_set_list(KEY_BLACKLIST, bl);
    }
    return TRUE;
}

integer apply_blacklist_add_guard(string who) {
    /* Adding to blacklist:
       - Remove from trustees
       - If owner matches → clear owner
    */
    string arr_tr = kv_get(KEY_TRUSTEES);
    if (is_json_arr(arr_tr)) {
        list tr = llJson2List(arr_tr);
        tr = list_remove_all_local(tr, who);
        kv_set_list(KEY_TRUSTEES, tr);
    }
    string cur_owner = kv_get(KEY_OWNER_KEY);
    if (cur_owner != "" && cur_owner != JSON_INVALID) {
        if (who == cur_owner) {
            kv_set_scalar(KEY_OWNER_KEY, (string)NULL_KEY);
            /* Optional: clear honorific
               kv_set_scalar(KEY_OWNER_HON, "");
            */
        }
    }
    return TRUE;
}

/* ---------- Events ---------- */
default
{
    state_entry() {
        LastOwner = llGetOwner();
        /* Initial broadcast of (possibly empty) KvJson */
        broadcast_sync_once();
    }

    on_rez(integer start_param) {
        key current_owner = llGetOwner();
        if (current_owner != LastOwner) {
            LastOwner = current_owner;
            llResetScript();
        }
    }

    attach(key id) {
        if (id == NULL_KEY) return;

        key current_owner = llGetOwner();
        if (current_owner != LastOwner) {
            LastOwner = current_owner;
            llResetScript();
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            key current_owner = llGetOwner();
            if (current_owner != LastOwner) {
                LastOwner = current_owner;
                llResetScript();
            }
        }
    }

    link_message(integer sender, integer num, string str, key id)
    {
        if (num != SETTINGS_QUERY_NUM) return;
        if (!json_has(str, ["type"]))  return;

        string t = llJsonGetValue(str, ["type"]);

        if (t == TYPE_SETTINGS_GET) {
            maybe_broadcast_sync_on_get();
            return;
        }

        if (t == TYPE_SET) {
            if (!json_has(str, ["key"])) return;
            string key_str = llJsonGetValue(str, ["key"]);
            if (!is_allowed_key(key_str)) return;

            integer did_change_set = FALSE;

            /* Bulk list set: values=[] */
            if (json_has(str, ["values"])) {
                string arr = llJsonGetValue(str, ["values"]);
                if (is_json_arr(arr)) {
                    list L = json_array_to_capped_list(arr);
                    L = list_unique(L);

                    if (key_str == KEY_TRUSTEES) {
                        /* Remove owner from trustees; remove all trustees from blacklist */
                        string cur_owner = kv_get(KEY_OWNER_KEY);
                        if (cur_owner != "" && cur_owner != JSON_INVALID) {
                            L = list_remove_all_local(L, cur_owner);
                        }
                        /* Remove each trustee from blacklist */
                        string arr_bl = kv_get(KEY_BLACKLIST);
                        list bl = [];
                        if (is_json_arr(arr_bl)) bl = llJson2List(arr_bl);
                        integer i = 0;
                        while (i < llGetListLength(L)) {
                            string who = llList2String(L, i);
                            bl = list_remove_all_local(bl, who);
                            i += 1;
                        }
                        kv_set_list(KEY_BLACKLIST, bl);

                        did_change_set = kv_set_list(KEY_TRUSTEES, L);
                    }
                    else if (key_str == KEY_BLACKLIST) {
                        /* Remove blacklisted from trustees; clear owner if present */
                        /* Trustees */
                        string arr_tr = kv_get(KEY_TRUSTEES);
                        list tr = [];
                        if (is_json_arr(arr_tr)) tr = llJson2List(arr_tr);

                        integer i2 = 0;
                        while (i2 < llGetListLength(L)) {
                            string who = llList2String(L, i2);
                            tr = list_remove_all_local(tr, who);
                            i2 += 1;
                        }
                        kv_set_list(KEY_TRUSTEES, tr);

                        /* Owner */
                        string cur_owner = kv_get(KEY_OWNER_KEY);
                        if (cur_owner != "" && cur_owner != JSON_INVALID) {
                            if (list_contains(L, cur_owner)) {
                                kv_set_scalar(KEY_OWNER_KEY, (string)NULL_KEY);
                                /* Optional: also clear hon
                                   kv_set_scalar(KEY_OWNER_HON, "");
                                */
                            }
                        }

                        did_change_set = kv_set_list(KEY_BLACKLIST, L);
                    }
                    else {
                        /* Any other list (e.g., trustee_honorifics), set directly */
                        did_change_set = kv_set_list(key_str, L);
                    }
                }
            }
            /* Scalar set: value="..." */
            else if (json_has(str, ["value"])) {
                string val = llJsonGetValue(str, ["value"]);
                if (val != JSON_INVALID) {

                    /* Normalize boolean scalars */
                    if (key_str == KEY_PUBLIC_ACCESS) val = normalize_mode01(val);
                    if (key_str == KEY_TPE_MODE)      val = normalize_mode01(val);
                    if (key_str == KEY_LOCKED)        val = normalize_mode01(val);

                    if (key_str == KEY_OWNER_KEY) {
                        /* Guard: remove from trustees + blacklist */
                        apply_owner_set_guard(val);
                        did_change_set = kv_set_scalar(KEY_OWNER_KEY, val);
                    } else {
                        did_change_set = kv_set_scalar(key_str, val);
                    }
                }
            }

            if (did_change_set) {
                broadcast_sync_once();
            }
            return;
        }

        if (t == TYPE_LIST_ADD || t == TYPE_LIST_REMOVE) {
            if (!json_has(str, ["key"]))  return;
            if (!json_has(str, ["elem"])) return;

            string key_str = llJsonGetValue(str, ["key"]);
            string elem    = llJsonGetValue(str, ["elem"]);
            if (!is_allowed_key(key_str)) return;

            integer did_change_list = FALSE;

            if (t == TYPE_LIST_ADD) {
                if (key_str == KEY_TRUSTEES) {
                    /* Trustee add guard */
                    integer ok = apply_trustee_add_guard(elem);
                    if (ok) did_change_list = kv_list_add_unique(KEY_TRUSTEES, elem);
                }
                else if (key_str == KEY_BLACKLIST) {
                    /* Blacklist add guard */
                    apply_blacklist_add_guard(elem);
                    did_change_list = kv_list_add_unique(KEY_BLACKLIST, elem);
                }
                else {
                    /* Other lists: normal add */
                    did_change_list = kv_list_add_unique(key_str, elem);
                }
            } else {
                /* Remove from given list */
                did_change_list = kv_list_remove_all(key_str, elem);
            }

            if (did_change_list) {
                broadcast_sync_once();
            }
            return;
        }
    }
}
