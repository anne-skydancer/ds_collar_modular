/* =============================================================================
   PLUGIN: ds_collar_plugin_public.lsl (v2.0 - Kanban Messaging Migration)

   PURPOSE: Toggle public access mode (direct button click)

   FEATURES:
   - Direct toggle from main menu (no submenu)
   - Dynamic button label (Public: Y / Public: N)
   - Settings persistence (public_mode key)
   - Settings sync and delta consumption
   - Restricted ACL: Trustee, Unowned, Primary Owner only

   TIER: 1 (Simple - binary toggle with settings)

   KANBAN MIGRATION (v2.0):
   - Uses universal kanban helper (~500-800 bytes)
   - All messages use standardized {from, payload, to} structure
   - Routing by channel + kFrom instead of "type" field
   ============================================================================= */

string CONTEXT = "core_public";

/* ═══════════════════════════════════════════════════════════
   KANBAN UNIVERSAL HELPER (~500-800 bytes)
   ═══════════════════════════════════════════════════════════ */

string kFrom = "";  // Sender context (populated by kRecv)
string kTo = "";    // Recipient context (populated by kRecv)

kSend(string from, string to, integer channel, string payload, key k) {
    llMessageLinked(LINK_SET, channel,
        llList2Json(JSON_OBJECT, [
            "from", from,
            "payload", payload,
            "to", to
        ]),
        k
    );
}

string kRecv(string msg, string my_context) {
    // Quick validation: must be JSON object
    if (llGetSubString(msg, 0, 0) != "{") return "";

    // Extract from
    string from = llJsonGetValue(msg, ["from"]);
    if (from == JSON_INVALID) return "";

    // Extract to
    string to = llJsonGetValue(msg, ["to"]);
    if (to == JSON_INVALID) return "";

    // Check if for me (broadcast "" or direct to my_context)
    if (to != "" && to != my_context) return "";

    // Extract payload
    string payload = llJsonGetValue(msg, ["payload"]);
    if (payload == JSON_INVALID) return "";

    // Set globals for routing
    kFrom = from;
    kTo = to;

    return payload;
}

string kPayload(list kvp) {
    return llList2Json(JSON_OBJECT, kvp);
}

string kDeltaSet(string setting_key, string val) {
    return llList2Json(JSON_OBJECT, [
        "op", "set",
        "key", setting_key,
        "value", val
    ]);
}

integer DEBUG = FALSE;
integer PRODUCTION = TRUE;  // Set FALSE for development builds

/* ═══════════════════════════════════════════════════════════
   CONSOLIDATED ABI
   ═══════════════════════════════════════════════════════════ */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* ═══════════════════════════════════════════════════════════
   PLUGIN IDENTITY
   ═══════════════════════════════════════════════════════════ */
string PLUGIN_LABEL_ON = "Public: Y";
string PLUGIN_LABEL_OFF = "Public: N";
integer PLUGIN_MIN_ACL = 3;  // Trustee minimum

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* ═══════════════════════════════════════════════════════════
   SETTINGS KEYS
   ═══════════════════════════════════════════════════════════ */
string KEY_PUBLIC_MODE = "public_mode";

/* ═══════════════════════════════════════════════════════════
   STATE
   ═══════════════════════════════════════════════════════════ */
integer PublicModeEnabled = FALSE;

/* ═══════════════════════════════════════════════════════════
   HELPERS
   ═══════════════════════════════════════════════════════════ */
integer logd(string msg) {
    if (DEBUG && !PRODUCTION) llOwnerSay("[PUBLIC] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

/* ═══════════════════════════════════════════════════════════
   LIFECYCLE MANAGEMENT
   ═══════════════════════════════════════════════════════════ */

register_self() {
    string label = PLUGIN_LABEL_OFF;
    if (PublicModeEnabled) {
        label = PLUGIN_LABEL_ON;
    }

    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload([
            "label", label,
            "min_acl", PLUGIN_MIN_ACL,
            "script", llGetScriptName()
        ]),
        NULL_KEY
    );
    logd("Registered with kernel as: " + label);
}

send_pong() {
    kSend(CONTEXT, "kernel", KERNEL_LIFECYCLE,
        kPayload(["pong", 1]),
        NULL_KEY
    );
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS CONSUMPTION
   ═══════════════════════════════════════════════════════════ */

apply_settings_sync(string payload) {
    if (!json_has(payload, ["kv"])) return;

    string kv_json = llJsonGetValue(payload, ["kv"]);

    integer old_state = PublicModeEnabled;
    PublicModeEnabled = FALSE;

    if (json_has(kv_json, [KEY_PUBLIC_MODE])) {
        PublicModeEnabled = (integer)llJsonGetValue(kv_json, [KEY_PUBLIC_MODE]);
    }

    logd("Settings sync: public=" + (string)PublicModeEnabled);

    // If state changed, update label
    if (old_state != PublicModeEnabled) {
        register_self();
    }
}

apply_settings_delta(string payload) {
    string op = llJsonGetValue(payload, ["op"]);

    if (op == "set") {
        string setting_key = llJsonGetValue(payload, ["key"]);
        string value = llJsonGetValue(payload, ["value"]);

        if (setting_key == KEY_PUBLIC_MODE) {
            integer old_state = PublicModeEnabled;
            PublicModeEnabled = (integer)value;
            logd("Delta: public_mode = " + value);

            // If state changed, update label
            if (old_state != PublicModeEnabled) {
                register_self();
            }
        }
    }
}

/* ═══════════════════════════════════════════════════════════
   SETTINGS MODIFICATION
   ═══════════════════════════════════════════════════════════ */

persist_public_mode(integer new_value) {
    if (new_value != 0) new_value = 1;

    kSend(CONTEXT, "settings", SETTINGS_BUS,
        kDeltaSet(KEY_PUBLIC_MODE, (string)new_value),
        NULL_KEY
    );
    logd("Persisting public_mode=" + (string)new_value);
}

/* ═══════════════════════════════════════════════════════════
   UI LABEL UPDATE
   ═══════════════════════════════════════════════════════════ */

update_ui_label_and_return(key user) {
    string new_label = PLUGIN_LABEL_OFF;
    if (PublicModeEnabled) {
        new_label = PLUGIN_LABEL_ON;
    }

    kSend(CONTEXT, "ui", UI_BUS,
        kPayload([
            "update_label", 1,
            "label", new_label
        ]),
        NULL_KEY
    );

    // Return user to root menu
    kSend(CONTEXT, "ui", UI_BUS,
        kPayload(["user", (string)user]),
        NULL_KEY
    );

    logd("Updated UI label to: " + new_label + " and returning to root");
}

/* ═══════════════════════════════════════════════════════════
   DIRECT TOGGLE ACTION
   ═══════════════════════════════════════════════════════════ */

toggle_public_access(key user, integer acl_level) {
    // Verify ACL (Trustee = 3 minimum)
    if (acl_level < PLUGIN_MIN_ACL) {
        llRegionSayTo(user, 0, "Access denied.");
        return;
    }
    
    // Toggle state
    PublicModeEnabled = !PublicModeEnabled;
    
    // Persist change
    persist_public_mode(PublicModeEnabled);
    
    // Notify user
    if (PublicModeEnabled) {
        llRegionSayTo(user, 0, "Public access enabled.");
    }
    else {
        llRegionSayTo(user, 0, "Public access disabled.");
    }
    
    // Update UI label and return to root menu
    update_ui_label_and_return(user);
}

/* ═══════════════════════════════════════════════════════════
   ACL VALIDATION
   ═══════════════════════════════════════════════════════════ */

request_acl_and_toggle(key user) {
    kSend(CONTEXT, "auth", AUTH_BUS,
        kPayload(["avatar", (string)user]),
        user
    );
}

/* ═══════════════════════════════════════════════════════════
   EVENTS
   ═══════════════════════════════════════════════════════════ */

default {
    state_entry() {
        PublicModeEnabled = FALSE;

        register_self();

        // Request settings
        kSend(CONTEXT, "settings", SETTINGS_BUS,
            kPayload(["get", 1]),
            NULL_KEY
        );

        logd("Ready");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        // Parse kanban message - kRecv validates and sets kFrom, kTo
        string payload = kRecv(msg, CONTEXT);
        if (payload == "") return;  // Not for us or invalid

        // Route by channel + kFrom + payload structure

        /* ===== KERNEL LIFECYCLE ===== */
        if (num == KERNEL_LIFECYCLE && kFrom == "kernel") {
            // Targeted soft_reset: has "context" field
            if (json_has(payload, ["context"])) {
                string target_context = llJsonGetValue(payload, ["context"]);
                if (target_context != "" && target_context != CONTEXT) {
                    return; // Not for us
                }
                llResetScript();
            }
            // Soft reset with "reset" marker
            else if (json_has(payload, ["reset"])) {
                llResetScript();
            }
            // Register now: has "register_now" marker
            else if (json_has(payload, ["register_now"])) {
                register_self();
            }
            // Ping: has "ping" marker
            else if (json_has(payload, ["ping"])) {
                send_pong();
            }
        }

        /* ===== SETTINGS BUS ===== */
        else if (num == SETTINGS_BUS && kFrom == "settings") {
            // Full sync: has "kv" field
            if (json_has(payload, ["kv"])) {
                apply_settings_sync(payload);
            }
            // Delta update: has "op" field
            else if (json_has(payload, ["op"])) {
                apply_settings_delta(payload);
            }
        }

        /* ===== UI START ===== */
        else if (num == UI_BUS) {
            // UI start: for our context
            if (kTo == CONTEXT && json_has(payload, ["user"])) {
                if (id == NULL_KEY) return;
                request_acl_and_toggle(id);
            }
        }

        /* ===== AUTH RESULT ===== */
        else if (num == AUTH_BUS && kFrom == "auth") {
            // ACL result: has "avatar" and "level" fields
            if (json_has(payload, ["avatar"]) && json_has(payload, ["level"])) {
                key avatar = (key)llJsonGetValue(payload, ["avatar"]);
                if (avatar != id) return;

                integer level = (integer)llJsonGetValue(payload, ["level"]);

                // Toggle immediately with this ACL level
                toggle_public_access(avatar, level);
            }
        }
    }
}
