/* =============================================================
   PLUGIN: ds_collar_plugin_public.lsl (Optimized)
   PURPOSE: Manage Public Access (enable/disable) with strict ACL
            - New kernel JSON register + heartbeat + soft-reset
            - Settings JSON key "public_mode" (scalar "0"/"1")
            - Animate/Status-style UI (Back centered)
            - Private dialog channel + safe listens
            - Defense-in-depth ACL validation
            - Dynamic registration based on owner state
   ACL: Allowed levels = TRUSTEE(3), UNOWNED(4), PRIMARY_OWNER(5)
   ============================================================= */

integer DEBUG = TRUE;

/* ---------- Link numbers (kernel ABI) ---------- */
integer K_PLUGIN_REG_QUERY   = 500;
integer K_PLUGIN_REG_REPLY   = 501;
integer K_PLUGIN_SOFT_RESET  = 504;

integer K_PLUGIN_PING        = 650;
integer K_PLUGIN_PONG        = 651;

integer AUTH_QUERY_NUM       = 700;
integer AUTH_RESULT_NUM      = 710;

integer K_SETTINGS_QUERY     = 800;
integer K_SETTINGS_SYNC      = 870;

integer K_PLUGIN_START       = 900;
integer K_PLUGIN_RETURN_NUM  = 901;

/* ---------- Protocol strings ---------- */
string CONS_TYPE_REGISTER          = "register";
string CONS_TYPE_REGISTER_NOW      = "register_now";
string CONS_TYPE_PLUGIN_START      = "plugin_start";
string CONS_TYPE_PLUGIN_RETURN     = "plugin_return";
string CONS_TYPE_PLUGIN_SOFT_RESET = "plugin_soft_reset";
string CONS_TYPE_PLUGIN_PING       = "plugin_ping";
string CONS_TYPE_PLUGIN_PONG       = "plugin_pong";

string CONS_SETTINGS_GET           = "settings_get";
string CONS_SETTINGS_SYNC          = "settings_sync";
string CONS_SETTINGS_SET           = "set";

string CONS_MSG_ACL_QUERY          = "acl_query";
string CONS_MSG_ACL_RESULT         = "acl_result";

/* ---------- ACL levels ---------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* Allowed ACL levels for public access control */
list ALLOWED_ACL_LEVELS = [ACL_TRUSTEE, ACL_UNOWNED, ACL_PRIMARY_OWNER];

/* ---------- Identity ---------- */
string  PLUGIN_CONTEXT   = "core_public";
string  ROOT_CONTEXT     = "core_root";
string  PLUGIN_LABEL     = "Public";
integer PluginSn         = 0;  /* Mutable: PascalCase per style guide */
integer PLUGIN_MIN_ACL   = 3;  /* kernel-side filter: 3+ covers 3,4,5 */

/* ---------- Settings ---------- */
string KEY_PUBLIC_MODE   = "public_mode";
string KEY_OWNER_KEY     = "owner_key";
string KEY_OWNER_LEGACY  = "owner";

/* ---------- UI/session state (PascalCase globals) ---------- */
integer DIALOG_TIMEOUT_SEC = 180;

key     User       = NULL_KEY;
integer Listen     = 0;
integer MenuChan   = 0;
string  Ctx        = "";

integer AclPending = FALSE;
integer AclLevel   = ACL_NOACCESS;

/* ---------- Plugin state ---------- */
integer PublicAccess = FALSE;
key     CollarOwner  = NULL_KEY;
integer OwnerPresent = FALSE;

/* ========================== Helpers ========================== */
integer json_has(string j, list path) { 
    return (llJsonGetValue(j, path) != JSON_INVALID); 
}

integer logd(string s) { 
    if (DEBUG) llOwnerSay("[PUBLIC] " + s); 
    return 0; 
}

/* ---------- ACL ---------- */
integer acl_is_allowed(integer level) {
    if (llListFindList(ALLOWED_ACL_LEVELS, [level]) != -1) return TRUE;
    return FALSE;
}

integer request_acl(key av) {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],   CONS_MSG_ACL_QUERY);
    j = llJsonSetValue(j, ["avatar"], (string)av);
    llMessageLinked(LINK_SET, AUTH_QUERY_NUM, j, NULL_KEY);
    AclPending = TRUE;
    logd("ACL query → " + (string)av);
    return 0;
}

/* ---------- Register / Soft reset ---------- */
integer register_plugin() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],     CONS_TYPE_REGISTER);
    j = llJsonSetValue(j, ["sn"],       (string)PluginSn);
    j = llJsonSetValue(j, ["label"],    PLUGIN_LABEL);
    j = llJsonSetValue(j, ["min_acl"],  (string)PLUGIN_MIN_ACL);
    j = llJsonSetValue(j, ["context"],  PLUGIN_CONTEXT);
    j = llJsonSetValue(j, ["script"],   llGetScriptName());

    /* Dynamic audience based on owner state:
       - When owned: only non-wearers see menu (TRUSTEE/PRIMARY_OWNER can control)
       - When unowned: everyone sees menu (UNOWNED wearer can control) */
    string audience = "all";
    if (OwnerPresent) {
        audience = "non_wearer_only";
    }
    j = llJsonSetValue(j, ["audience"], audience);

    llMessageLinked(LINK_SET, K_PLUGIN_REG_REPLY, j, NULL_KEY);
    logd("Registered (audience=" + audience + ", owner_present=" + (string)OwnerPresent + ")");
    return 0;
}

integer notify_soft_reset() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],    CONS_TYPE_PLUGIN_SOFT_RESET);
    j = llJsonSetValue(j, ["context"], PLUGIN_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_SOFT_RESET, j, NULL_KEY);
    logd("Soft reset notified.");
    return 0;
}

/* ---------- Settings I/O ---------- */
integer request_settings_get() {
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], CONS_SETTINGS_GET);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    logd("Requested settings_get.");
    return 0;
}

integer persist_public(integer value01) {
    if (value01 != 0) value01 = 1;
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"],  CONS_SETTINGS_SET);
    j = llJsonSetValue(j, ["key"],   KEY_PUBLIC_MODE);
    j = llJsonSetValue(j, ["value"], (string)value01);
    llMessageLinked(LINK_SET, K_SETTINGS_QUERY, j, NULL_KEY);
    logd("Persisted public_mode=" + (string)value01);
    return 0;
}

/* ---------- UI plumbing ---------- */
integer reset_listen() {
    if (Listen) llListenRemove(Listen);
    Listen = 0;
    MenuChan = 0;
    return 0;
}

integer begin_dialog(key user, string ctx, string body, list buttons) {
    reset_listen();
    User = user;
    Ctx  = ctx;

    MenuChan = -100000 - (integer)llFrand(1000000.0);
    Listen   = llListen(MenuChan, "", User, "");

    while ((llGetListLength(buttons) % 3) != 0) {
        buttons += " ";
    }

    llDialog(User, body, buttons, MenuChan);
    llSetTimerEvent((float)DIALOG_TIMEOUT_SEC);
    return 0;
}

integer ui_return_root(key to_user) {
    string r = llList2Json(JSON_OBJECT, []);
    r = llJsonSetValue(r, ["type"],    CONS_TYPE_PLUGIN_RETURN);
    r = llJsonSetValue(r, ["context"], ROOT_CONTEXT);
    llMessageLinked(LINK_SET, K_PLUGIN_RETURN_NUM, r, to_user);
    return 0;
}

/* ---------- UI content ---------- */
integer show_main_menu(key user) {
    list btns = ["~", "Back", "~"];
    if (PublicAccess) {
        btns += ["Disable"];
    } else {
        btns += ["Enable"];
    }

    string msg = "Public access is currently ";
    if (PublicAccess) {
        msg += "ENABLED.\nDisable public access?";
    } else {
        msg += "DISABLED.\nEnable public access?";
    }

    begin_dialog(user, "main", msg, btns);
    logd("Menu → " + (string)user + " chan=" + (string)MenuChan);
    return 0;
}

/* ---------- Settings intake ---------- */
integer apply_settings_sync(string payload) {
    if (!json_has(payload, ["type"])) return 0;
    if (llJsonGetValue(payload, ["type"]) != CONS_SETTINGS_SYNC) return 0;

    string body = "";
    integer have_payload = FALSE;

    if (json_has(payload, ["kv"])) {
        string kv = llJsonGetValue(payload, ["kv"]);
        if (llGetSubString(kv, 0, 0) == "{") {
            body = kv;
            have_payload = TRUE;
        }
    }

    if (!have_payload) {
        body = payload;
        have_payload = TRUE;
    }

    if (!have_payload) return 0;

    /* Apply public access setting */
    if (json_has(body, [KEY_PUBLIC_MODE])) {
        string v = llJsonGetValue(body, [KEY_PUBLIC_MODE]);
        if (v != JSON_INVALID) {
            integer want = (integer)v;
            if (want != 0) want = 1;
            if (PublicAccess != want) {
                PublicAccess = want;
                logd("Settings sync applied: public=" + (string)PublicAccess);
            }
        }
    }

    /* Track owner state for dynamic audience registration */
    integer saw_owner = FALSE;
    key new_owner = CollarOwner;

    if (json_has(body, [KEY_OWNER_KEY])) {
        new_owner = (key)llJsonGetValue(body, [KEY_OWNER_KEY]);
        saw_owner = TRUE;
    } else if (json_has(body, [KEY_OWNER_LEGACY])) {
        new_owner = (key)llJsonGetValue(body, [KEY_OWNER_LEGACY]);
        saw_owner = TRUE;
    }

    if (saw_owner) {
        key prev_owner = CollarOwner;
        integer prev_present = OwnerPresent;

        CollarOwner = new_owner;
        OwnerPresent = (CollarOwner != NULL_KEY);

        /* Re-register if owner presence state changed (affects audience field) */
        if (prev_present != OwnerPresent) {
            if (OwnerPresent) {
                logd("Collar now owned. Re-registering with audience=non_wearer_only.");
            } else {
                logd("Collar now unowned. Re-registering with audience=all.");
            }
            register_plugin();
        }
        /* Also re-register if owner identity changed (same presence, new owner) */
        else if (CollarOwner != prev_owner && CollarOwner != NULL_KEY) {
            logd("Owner identity changed. Refreshing registration metadata.");
            register_plugin();
        }
    }

    return 0;
}

/* =========================== Events ========================== */
default {
    state_entry() {
        PluginSn = (integer)(llFrand(1.0e9));

        PublicAccess = FALSE;
        CollarOwner = NULL_KEY;
        OwnerPresent = FALSE;

        notify_soft_reset();
        register_plugin();
        request_settings_get();

        User = NULL_KEY;
        reset_listen();
        Ctx = "";
        AclPending = FALSE;
        AclLevel = ACL_NOACCESS;
        llSetTimerEvent(0.0);

        logd("Ready. SN=" + (string)PluginSn);
    }

    on_rez(integer sp){ 
        llResetScript(); 
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llOwnerSay("[PUBLIC] Owner changed. Resetting plugin.");
            llResetScript();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == K_PLUGIN_PING) {
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_PING) {
                    if (json_has(msg, ["context"])){
                        if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                            string pong = llList2Json(JSON_OBJECT, []);
                            pong = llJsonSetValue(pong, ["type"],    CONS_TYPE_PLUGIN_PONG);
                            pong = llJsonSetValue(pong, ["context"], PLUGIN_CONTEXT);
                            llMessageLinked(LINK_SET, K_PLUGIN_PONG, pong, NULL_KEY);
                        }
                    }
                }
            }
            return;
        }

        if (num == K_PLUGIN_REG_QUERY) {
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_REGISTER_NOW) {
                    if (json_has(msg, ["script"])){
                        if (llJsonGetValue(msg, ["script"]) == llGetScriptName()) {
                            register_plugin();
                        }
                    }
                }
            }
            return;
        }

        if (num == K_SETTINGS_SYNC) {
            apply_settings_sync(msg);
            return;
        }

        if (num == K_PLUGIN_START) {
            if (json_has(msg, ["type"])){
                if (llJsonGetValue(msg, ["type"]) == CONS_TYPE_PLUGIN_START) {
                    if (json_has(msg, ["context"])){
                        if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                            User = id;
                            request_acl(User);
                            return;
                        }
                    }
                }
            }
            return;
        }

        if (num == AUTH_RESULT_NUM) {
            if (!AclPending) return;
            if (!json_has(msg, ["type"])) return;
            if (llJsonGetValue(msg, ["type"]) != CONS_MSG_ACL_RESULT) return;
            if (!json_has(msg, ["avatar"])) return;
            if (!json_has(msg, ["level"])) return;

            key who = (key)llJsonGetValue(msg, ["avatar"]);
            integer lvl = (integer)llJsonGetValue(msg, ["level"]);

            if (who != User) return;

            AclPending = FALSE;
            AclLevel = lvl;  /* Store ACL level for defense-in-depth */

            if (acl_is_allowed(AclLevel)) {
                show_main_menu(User);
            } else {
                llRegionSayTo(User, 0, "Access denied.");
                ui_return_root(User);
                reset_listen();
                User = NULL_KEY;
                Ctx = "";
                AclLevel = ACL_NOACCESS;
                llSetTimerEvent(0.0);
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string message) {
        if (chan != MenuChan) return;
        if (id != User) return;

        /* Defense-in-depth: Re-validate ACL hasn't changed */
        if (!acl_is_allowed(AclLevel)) {
            llRegionSayTo(id, 0, "Access denied - permission revoked.");
            ui_return_root(id);
            reset_listen();
            User = NULL_KEY;
            Ctx = "";
            AclLevel = ACL_NOACCESS;
            llSetTimerEvent(0.0);
            return;
        }

        if (message == "Back") {
            ui_return_root(User);
            reset_listen();
            User = NULL_KEY;
            Ctx = "";
            AclLevel = ACL_NOACCESS;
            llSetTimerEvent(0.0);
            return;
        }

        if (Ctx == "main") {
            if (message == "Enable") {
                PublicAccess = TRUE;
                persist_public(PublicAccess);
                show_main_menu(User);
                return;
            }
            if (message == "Disable") {
                PublicAccess = FALSE;
                persist_public(PublicAccess);
                show_main_menu(User);
                return;
            }
        }

        /* Fallback: redraw */
        show_main_menu(User);
    }

    timer() {
        reset_listen();
        User = NULL_KEY;
        Ctx = "";
        AclLevel = ACL_NOACCESS;
        llSetTimerEvent(0.0);
    }
}
