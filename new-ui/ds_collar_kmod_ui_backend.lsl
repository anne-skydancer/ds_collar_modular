/* =============================================================
   MODULE: ds_collar_kmod_ui_backend.lsl  (HEADLESS)
   ROLE  : Build filtered menus, handle clicks, write settings
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-BE] " + s); return 0; }

/* === DS Collar ABI & Lanes (CANONICAL) === */
integer ABI_VERSION   = 1;
integer L_API         = -1000;
integer L_BROADCAST   = -1001;
integer L_SETTINGS_IN = -1300;
integer L_AUTH_IN     = -1400;
integer L_ACL_IN      = -1500;
integer L_UI_BE_IN    = -1600;
integer L_UI_FE_IN    = -1700;
integer L_IDENTITY_IN = -1800;

/* Types */
string T_SETTINGS_SUB        = "settings_sub";
string T_SETTINGS_PUT        = "settings_put";
string T_SETTINGS_SNAPSHOT   = "settings_snapshot";
string T_SETTINGS_SYNC       = "settings_sync";

string T_AUTH_QUERY          = "auth_query";
string T_AUTH_RESULT         = "auth_result";

string T_ACL_REGISTER        = "acl_register_feature";
string T_ACL_FILTER          = "acl_filter";
string T_ACL_FILTER_RESULT   = "acl_filter_result";

string T_UI_TOUCH            = "ui_touch";
string T_UI_RENDER           = "ui_render";
string T_UI_CLICK            = "ui_click";
string T_ERROR               = "error";

/* Feature IDs */
string F_MENU_STATUS         = "plugin.core.menu.status";
string F_MENU_TOG_PUBLIC     = "plugin.core.menu.public_toggle";
string F_MENU_TOG_RESTRICTED = "plugin.core.menu.restricted_toggle";

/* Cache */
integer PublicMode;
integer RestrictedMode;
integer RlvEnabled;
string  RlvVersion;
key     OwnerKey;

/* Pending maps
   - AUTH map:   [authRid, coreRid, avatar]            stride 3
   - FILTER map: [filterRid, coreRid, avatar, level]   stride 4
*/
list    PendingAuth;
integer PA_STRIDE = 3;

list    PendingFilter;
integer PF_STRIDE = 4;

/* ---- Helpers ---- */
integer now(){ return llGetUnixTime(); }

string mk_rid(){
    return (string)now() + "-" + (string)llRound(llFrand(9999.0));
}

string jset(string j, list p, string v){
    return llJsonSetValue(j, p, v);
}
string jobj(){ return llList2Json(JSON_OBJECT, []); }
string jarr(){ return llList2Json(JSON_ARRAY, []); }

/* ---- API helpers ---- */
integer api_send(string type, string to, string reqId, list kv){
    string j = jobj();
    j = jset(j, ["type"], type);
    j = jset(j, ["from"], "ui_backend");
    j = jset(j, ["to"], to);
    if (reqId != "") j = jset(j, ["req_id"], reqId);
    j = jset(j, ["abi"], (string)ABI_VERSION);

    integer i = 0;
    integer n = llGetListLength(kv);
    while (i + 1 < n){
        j = jset(j, [llList2String(kv, i)], llList2String(kv, i + 1));
        i += 2;
    }
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

integer settings_put_int(string path, integer v){
    return api_send(T_SETTINGS_PUT, "settings", mk_rid(),
        ["path", path, "vtype", "int", "value", (string)v]);
}

integer subscribe_settings(){
    api_send(T_SETTINGS_SUB, "settings", mk_rid(), ["prefix", "core.public."]);
    api_send(T_SETTINGS_SUB, "settings", mk_rid(), ["prefix", "core.restricted."]);
    api_send(T_SETTINGS_SUB, "settings", mk_rid(), ["prefix", "core.rlv."]);
    api_send(T_SETTINGS_SUB, "settings", mk_rid(), ["prefix", "core.owner."]);
    return TRUE;
}

integer register_acl_features(){
    api_send(T_ACL_REGISTER, "acl", mk_rid(), ["feature_id", F_MENU_STATUS,         "default_min_level", "1"]);
    api_send(T_ACL_REGISTER, "acl", mk_rid(), ["feature_id", F_MENU_TOG_PUBLIC,     "default_min_level", "4"]);
    api_send(T_ACL_REGISTER, "acl", mk_rid(), ["feature_id", F_MENU_TOG_RESTRICTED, "default_min_level", "4"]);
    return TRUE;
}

/* ---- Menu builder ---- */
string build_menu_json(key avatar, integer level, list allowed){
    string menu = jobj();
    string ctx  = jobj();
    menu = jset(menu, ["title"], "Collar");

    string prompt = "Status:";
    prompt += "\n• Owner: ";
    if (OwnerKey != NULL_KEY) prompt += (string)OwnerKey;
    else prompt += "None";

    string pubStr = "OFF";
    if (PublicMode) pubStr = "ON";
    prompt += "\n• Public: " + pubStr;

    string resStr = "OFF";
    if (RestrictedMode) resStr = "ON";
    prompt += "\n• Restricted: " + resStr;

    string rlvStr = "OFF";
    if (RlvEnabled) rlvStr = "ON";
    prompt += "\n• RLV: " + rlvStr;
    if (RlvVersion != "") prompt += " (" + RlvVersion + ")";

    menu = jset(menu, ["prompt"], prompt);

    string btns = jarr();
    integer index = 0;

    if (llListFindList(allowed, [F_MENU_STATUS]) != -1){
        string b = jobj();
        b = jset(b, ["id"], "status");
        b = jset(b, ["label"], "Status");
        btns = llJsonSetValue(btns, [(string)index], b);
        index += 1;
    }

    if (llListFindList(allowed, [F_MENU_TOG_PUBLIC]) != -1){
        string b2 = jobj();
        string lab = "Public: ";
        if (PublicMode) lab += "ON → OFF";
        else lab += "OFF → ON";
        b2 = jset(b2, ["id"], "toggle_public");
        b2 = jset(b2, ["label"], lab);
        btns = llJsonSetValue(btns, [(string)index], b2);
        index += 1;
    }

    if (llListFindList(allowed, [F_MENU_TOG_RESTRICTED]) != -1){
        string b3 = jobj();
        string lab2 = "Restricted: ";
        if (RestrictedMode) lab2 += "ON → OFF";
        else lab2 += "OFF → ON";
        b3 = jset(b3, ["id"], "toggle_restricted");
        b3 = jset(b3, ["label"], lab2);
        btns = llJsonSetValue(btns, [(string)index], b3);
        index += 1;
    }

    string b4 = jobj();
    b4 = jset(b4, ["id"], "close");
    b4 = jset(b4, ["label"], "Close");
    btns = llJsonSetValue(btns, [(string)index], b4);

    menu = jset(menu, ["buttons"], btns);

    ctx = jset(ctx, ["avatar"], (string)avatar);
    ctx = jset(ctx, ["level"], (string)level);
    menu = jset(menu, ["ctx"], ctx);

    return menu;
}

/* ---- Flow helpers (rid threading, no collisions) ---- */
integer start_auth_flow(string coreRid, key avatar){
    string authRid = mk_rid();
    PendingAuth += [authRid, coreRid, (string)avatar];
    api_send(T_AUTH_QUERY, "auth", authRid, ["avatar", (string)avatar]);
    return TRUE;
}

integer continue_with_acl(string authRid, integer level){
    /* lookup authRid to get coreRid+avatar, then start ACL with fresh filterRid */
    integer idx = llListFindList(PendingAuth, [authRid]);
    if (idx == -1) return FALSE;

    string coreRid = llList2String(PendingAuth, idx + 1);
    key avatar = (key)llList2String(PendingAuth, idx + 2);
    PendingAuth = llDeleteSubList(PendingAuth, idx, idx + PA_STRIDE - 1);

    string feats = llList2Json(JSON_ARRAY, [F_MENU_STATUS, F_MENU_TOG_PUBLIC, F_MENU_TOG_RESTRICTED]);

    string filterRid = mk_rid();
    PendingFilter += [filterRid, coreRid, (string)avatar, (string)level];
    api_send(T_ACL_FILTER, "acl", filterRid, ["avatar", (string)avatar, "features", feats, "level", (string)level]);
    return TRUE;
}

integer finalize_with_render(string filterRid, string allowedJson){
    /* lookup filterRid to get coreRid+avatar+level; send ui_render with coreRid */
    integer idx = llListFindList(PendingFilter, [filterRid]);
    if (idx == -1) return FALSE;

    string coreRid = llList2String(PendingFilter, idx + 1);
    key avatar = (key)llList2String(PendingFilter, idx + 2);
    integer level = (integer)llList2String(PendingFilter, idx + 3);
    PendingFilter = llDeleteSubList(PendingFilter, idx, idx + PF_STRIDE - 1);

    list allowed = [];
    integer k = 0;
    integer done = FALSE;
    while (!done){
        string f = llJsonGetValue(allowedJson, [(string)k]);
        if (f == JSON_INVALID) done = TRUE;
        else{
            allowed += f;
            k += 1;
        }
    }

    string menu = build_menu_json(avatar, level, allowed);
    /* Important: respond with the ORIGINAL ui_touch/ui_click req_id (coreRid) */
    api_send(T_UI_RENDER, "ui_frontend", coreRid, ["menu", menu]);
    return TRUE;
}

integer do_toggle_public(){
    integer v = PublicMode;
    if (v != 0) v = 0;
    else v = 1;
    PublicMode = v; /* optimistic local flip */
    settings_put_int("core.public.mode", v);
    return TRUE;
}

integer do_toggle_restricted(){
    integer v = RestrictedMode;
    if (v != 0) v = 0;
    else v = 1;
    RestrictedMode = v; /* optimistic local flip */
    settings_put_int("core.restricted.mode", v);
    return TRUE;
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        PublicMode = 0;
        RestrictedMode = 0;
        RlvEnabled = 0;
        RlvVersion = "";
        OwnerKey = NULL_KEY;

        PendingAuth = [];
        PendingFilter = [];

        subscribe_settings();
        register_acl_features();
        logd("UI backend up");
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_UI_BE_IN) return;

        string ty = llJsonGetValue(msg, ["type"]);

        /* Settings intake (snapshot/sync) */
        if (ty == T_SETTINGS_SNAPSHOT || ty == T_SETTINGS_SYNC){
            string obj = "";
            if (ty == T_SETTINGS_SNAPSHOT) obj = llJsonGetValue(msg, ["values"]);
            else obj = llJsonGetValue(msg, ["changed"]);

            if (obj != JSON_INVALID){
                string pv = llJsonGetValue(obj, ["core.public.mode"]);
                if (pv != JSON_INVALID && pv != "") PublicMode = (integer)pv;

                string rv = llJsonGetValue(obj, ["core.restricted.mode"]);
                if (rv != JSON_INVALID && rv != "") RestrictedMode = (integer)rv;

                string rlv = llJsonGetValue(obj, ["core.rlv.enabled"]);
                if (rlv != JSON_INVALID && rlv != "") RlvEnabled = (integer)rlv;

                string rlvv = llJsonGetValue(obj, ["core.rlv.version"]);
                if (rlvv != JSON_INVALID){
                    if (llGetSubString(rlvv, 0, 0) == "\"" && llGetSubString(rlvv, -1, -1) == "\""){
                        rlvv = llGetSubString(rlvv, 1, llStringLength(rlvv) - 2);
                    }
                    RlvVersion = rlvv;
                }

                string ok = llJsonGetValue(obj, ["core.owner.key"]);
                if (ok != JSON_INVALID){
                    if (llGetSubString(ok, 0, 0) == "\"" && llGetSubString(ok, -1, -1) == "\""){
                        ok = llGetSubString(ok, 1, llStringLength(ok) - 2);
                    }
                    OwnerKey = (key)ok;
                }
            }
            return;
        }

        /* Touch from UI frontend: start pipeline with a fresh authRid, remember coreRid */
        if (ty == T_UI_TOUCH){
            string coreRid = llJsonGetValue(msg, ["req_id"]);
            key av = (key)llJsonGetValue(msg, ["avatar"]);
            start_auth_flow(coreRid, av);
            return;
        }

        /* Auth result → continue with ACL using a fresh filterRid */
        if (ty == T_AUTH_RESULT){
            string authRid = llJsonGetValue(msg, ["req_id"]);
            integer level = (integer)llJsonGetValue(msg, ["level"]);
            continue_with_acl(authRid, level);
            return;
        }

        /* ACL filter result → finalize with ui_render using the original coreRid */
        if (ty == T_ACL_FILTER_RESULT){
            string filterRid = llJsonGetValue(msg, ["req_id"]);
            string allowedArr = llList2Json(JSON_ARRAY, []);
            /* we already get "allowed" as an array — keep reference to the segment */
            finalize_with_render(filterRid, llJsonGetValue(msg, ["allowed"]));
            return;
        }

        /* Clicks: perform action, then re-run ACL with new filterRid, but keep FE coreRid */
        if (ty == T_UI_CLICK){
            string coreRid = llJsonGetValue(msg, ["req_id"]); /* FE's request id */
            string choice   = llJsonGetValue(msg, ["choice_id"]);
            string ctx      = llJsonGetValue(msg, ["ctx"]);
            key av          = (key)llJsonGetValue(ctx, ["avatar"]);
            integer level   = (integer)llJsonGetValue(ctx, ["level"]);

            if (choice == "toggle_public"){
                do_toggle_public();
            } else if (choice == "toggle_restricted"){
                do_toggle_restricted();
            } else if (choice == "status"){
                /* just refresh */
            } else if (choice == "close"){
                return;
            } else {
                return;
            }

            /* After action: start ACL with a fresh rid and map back to coreRid */
            string feats = llList2Json(JSON_ARRAY, [F_MENU_STATUS, F_MENU_TOG_PUBLIC, F_MENU_TOG_RESTRICTED]);
            string filterRid = mk_rid();
            PendingFilter += [filterRid, coreRid, (string)av, (string)level];
            api_send(T_ACL_FILTER, "acl", filterRid, ["avatar", (string)av, "features", feats, "level", (string)level]);
            return;
        }

        if (ty == T_ERROR){
            logd("ERR " + llGetSubString(msg, 0, 200));
            return;
        }
    }
}
