/* ===============================================================
   PLUGIN: ds_collar_plugin_tpe.lsl (v1.0 - Wearer Confirmation)
   
   PURPOSE: Toggle Total Power Exchange (TPE) mode with wearer consent
   
   FEATURES:
   - Wearer confirmation dialog for TPE activation
   - Direct disable by owner (no confirmation needed)
   - Dynamic button label (TPE: Y / TPE: N)
   - Settings persistence (tpe_mode key)
   - Settings sync and delta consumption
   - Restricted ACL: Primary Owner (5) ONLY
   - When TPE is ON, wearer gets ACL 0 (no access to collar)
   
   BEHAVIOR:
   - TPE OFF  +' ON: Shows confirmation dialog to wearer
     - Wearer clicks "Yes"  +' TPE activates, wearer's UI closes, owner returns to root
     - Wearer clicks "No"  +' Activation cancelled, wearer's UI closes, owner returns to root
     - Dialog times out  +' Activation cancelled, wearer's UI closes, owner returns to root
   - TPE ON  +' OFF: Direct disable by owner, owner returns to root menu
   - TPE ON: Wearer cannot access collar at all (ACL 0)
   - TPE OFF: Wearer has normal access (ACL 2 when owned, 4 when unowned)
   - Only Primary Owner (ACL 5) can manage TPE mode
   
   UI BEHAVIOR:
   - Wearer's UI always closes after clicking Yes/No on confirmation dialog
   - Owner's UI always returns to root menu to see the updated button state
   - Owner never has their UI closed (they're in control)
   
   TIER: 1 (Simple toggle with confirmation dialog)
   ============================================================================== */

integer DEBUG = FALSE;

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   CONSOLIDATED ABI
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   PLUGIN IDENTITY
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */
string PLUGIN_CONTEXT = "core_tpe";
string PLUGIN_LABEL_ON = "TPE: Y";
string PLUGIN_LABEL_OFF = "TPE: N";
integer PLUGIN_MIN_ACL = 5;  // Primary Owner ONLY
string ROOT_CONTEXT = "core_root";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access (wearer in TPE mode)
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner (ONLY ACL that can manage TPE)
*/

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   SETTINGS KEYS
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */
string KEY_TPE_MODE = "tpe_mode";

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   STATE
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */
integer TpeModeEnabled = FALSE;

// Session management for confirmation dialog
key CurrentUser = NULL_KEY;        // Who initiated the action
integer UserAcl = -999;
string SessionId = "";
key WearerKey = NULL_KEY;          // Owner of the collar (for confirmation)
integer AclPending = FALSE;        // Waiting for ACL result

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   HELPERS
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */
integer logd(string msg) {
    if (DEBUG) llOwnerSay("[TPE] " + msg);
    return FALSE;
}

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

integer is_json_arr(string j) {
    return (llGetSubString(j, 0, 0) == "[");
}

string gen_session() {
    return (string)llGetKey() + "_" + (string)llGetUnixTime();
}

cleanup_session() {
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
}

close_ui_for_user(key user) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "close",
        "context", PLUGIN_CONTEXT,
        "user", (string)user
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, user);
    logd("Closed UI for " + (string)user);
}

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   KERNEL MESSAGES
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */

register_with_kernel() {
    string initial_label = PLUGIN_LABEL_OFF;
    if (TpeModeEnabled) {
        initial_label = PLUGIN_LABEL_ON;
    }
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "register",
        "context", PLUGIN_CONTEXT,
        "label", initial_label,
        "min_acl", PLUGIN_MIN_ACL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    logd("Registered with kernel as: " + initial_label);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   SETTINGS MANAGEMENT
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */

request_settings_sync() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "sync_request"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    logd("Requesting settings sync");
}

persist_tpe_mode(integer new_value) {
    if (new_value != 0) new_value = 1;
    
    string msg = llList2Json(JSON_OBJECT, [
        "type", "set",
        "key", KEY_TPE_MODE,
        "value", (string)new_value
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
    logd("Persisting tpe_mode=" + (string)new_value);
}

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   BUTTON HANDLING
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */

handle_button_click(string button) {
    if (button == "Yes") {
        // Wearer confirmed - enable TPE
        TpeModeEnabled = TRUE;
        persist_tpe_mode(TRUE);
        
        llRegionSayTo(WearerKey, 0, "TPE mode enabled. You have relinquished collar control.");
        if (CurrentUser != WearerKey) {
            llRegionSayTo(CurrentUser, 0, "TPE mode enabled with wearer consent.");
        }
        
        // Update UI label
        string new_label = PLUGIN_LABEL_ON;
        string msg = llList2Json(JSON_OBJECT, [
            "type", "update_label",
            "context", PLUGIN_CONTEXT,
            "label", new_label
        ]);
        llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
        logd("Updated UI label to: " + new_label);
        
        // Close UI for wearer (who clicked the dialog)
        close_ui_for_user(WearerKey);
        
        // Return owner to root menu to see updated button (if different from wearer)
        if (CurrentUser != WearerKey) {
            msg = llList2Json(JSON_OBJECT, [
                "type", "return",
                "user", (string)CurrentUser
            ]);
            llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
            logd("Returning owner to root menu");
        }
        
        cleanup_session();
    }
    else if (button == "No") {
        // Wearer declined - cancel TPE activation
        llRegionSayTo(WearerKey, 0, "TPE activation cancelled.");
        if (CurrentUser != WearerKey) {
            llRegionSayTo(CurrentUser, 0, "Wearer declined TPE activation.");
        }
        
        // Close UI for wearer (who clicked the dialog)
        close_ui_for_user(WearerKey);
        
        // Return owner to root menu (if different from wearer)
        if (CurrentUser != WearerKey) {
            string msg = llList2Json(JSON_OBJECT, [
                "type", "return",
                "user", (string)CurrentUser
            ]);
            llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
            logd("Returning owner to root menu");
        }
        
        cleanup_session();
    }
}

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   TPE TOGGLE LOGIC
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */

handle_tpe_click(key user, integer acl_level) {
    // Verify ACL (only 5=Primary Owner)
    if (acl_level != 5) {
        llRegionSayTo(user, 0, "Access denied. Only primary owner can manage TPE mode.");
        logd("Access denied for user with ACL " + (string)acl_level);
        return;
    }
    
    CurrentUser = user;
    UserAcl = acl_level;
    WearerKey = llGetOwner();
    
    if (TpeModeEnabled) {
        // TPE is currently ON - disable it directly (no confirmation needed)
        // This allows owner to release TPE without wearer consent
        TpeModeEnabled = FALSE;
        persist_tpe_mode(FALSE);
        
        llRegionSayTo(user, 0, "TPE mode disabled. Wearer regains collar access.");
        
        // Update UI label
        string new_label = PLUGIN_LABEL_OFF;
        string msg = llList2Json(JSON_OBJECT, [
            "type", "update_label",
            "context", PLUGIN_CONTEXT,
            "label", new_label
        ]);
        llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
        logd("Updated UI label to: " + new_label);
        
        // Return owner to root menu (so they see the updated button)
        msg = llList2Json(JSON_OBJECT, [
            "type", "return",
            "user", (string)user
        ]);
        llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
        logd("Returning owner to root menu");
        
        cleanup_session();
    }
    else {
        // TPE is currently OFF - requires wearer consent
        // Send dialog to WEARER, not CurrentUser
        logd("TPE activation requested by " + (string)user);
        
        string msg_body = "Your owner wants to enable TPE mode.\n\n";
        msg_body += "By clicking Yes, you relinquish all control of this collar.\n\n";
        msg_body += "You will not be able to access the collar menu while TPE is active.\n\n";
        msg_body += "Do you consent -- ;
        
        SessionId = gen_session();
        
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "dialog_open",
            "session_id", SessionId,
            "user", (string)llGetOwner(),  // Send to WEARER, not CurrentUser
            "title", "TPE Confirmation",
            "body", msg_body,
            "buttons", llList2Json(JSON_ARRAY, ["Yes", "No"]),
            "timeout", 60
        ]), NULL_KEY);
        
        logd("Sent TPE confirmation dialog to wearer: " + (string)llGetOwner());
    }
}

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   SETTINGS CONSUMPTION
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */

apply_settings_sync(string kv_json) {
    if (json_has(kv_json, [KEY_TPE_MODE])) {
        TpeModeEnabled = (integer)llJsonGetValue(kv_json, [KEY_TPE_MODE]);
        logd("TPE mode from sync: " + (string)TpeModeEnabled);
    }
}

apply_settings_delta(string msg) {
    if (!json_has(msg, ["op"])) return;
    
    string op = llJsonGetValue(msg, ["op"]);
    
    if (op == "set") {
        if (!json_has(msg, ["changes"])) return;
        string changes = llJsonGetValue(msg, ["changes"]);
        
        if (json_has(changes, [KEY_TPE_MODE])) {
            TpeModeEnabled = (integer)llJsonGetValue(changes, [KEY_TPE_MODE]);
            logd("TPE mode from delta: " + (string)TpeModeEnabled);
        }
    }
}

/*  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o 
   EVENTS
    o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  o  */

default
{
    state_entry() {
        logd("=== TPE PLUGIN STATE_ENTRY ===");
        TpeModeEnabled = FALSE;
        WearerKey = llGetOwner();
        AclPending = FALSE;
        logd("WearerKey initialized to: " + (string)WearerKey);
        cleanup_session();
        logd("About to register with kernel...");
        register_with_kernel();
        logd("About to request settings sync...");
        request_settings_sync();
        logd("=== TPE PLUGIN INITIALIZATION COMPLETE ===");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
    
    link_message(integer sender_num, integer num, string str, key id) {
        // Skip logging kernel lifecycle messages (too noisy)
        if (num != KERNEL_LIFECYCLE) {
            logd("link_message: num=" + (string)num + " str=" + llGetSubString(str, 0, 100));
        }
        
        if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(str, ["type"]);
            
            if (msg_type == "register_now") {
                register_with_kernel();
            }
            else if (msg_type == "ping") {
                send_pong();
            }
            else if (msg_type == "soft_reset") {
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);
            
            if (msg_type == "sync") {
                if (json_has(str, ["kv"])) {
                    string kv_json = llJsonGetValue(str, ["kv"]);
                    apply_settings_sync(kv_json);
                }
            }
            else if (msg_type == "delta") {
                apply_settings_delta(str);
            }
        }
        else if (num == UI_BUS) {
            logd("UI_BUS message received: " + str);
            string msg_type = llJsonGetValue(str, ["type"]);
            logd("Message type: " + msg_type);
            
            if (msg_type == "start") {
                string context = llJsonGetValue(str, ["context"]);
                logd("Context: " + context + " (expecting " + PLUGIN_CONTEXT + ")");
                if (context != PLUGIN_CONTEXT) return;
                
                // User key is passed as the id parameter to link_message, not in JSON
                CurrentUser = id;
                logd("TPE button activated by " + (string)CurrentUser);
                
                // Request ACL for this user
                AclPending = TRUE;
                string acl_msg = llList2Json(JSON_OBJECT, [
                    "type", "acl_query",
                    "avatar", (string)CurrentUser
                ]);
                llMessageLinked(LINK_SET, AUTH_BUS, acl_msg, CurrentUser);
                logd("Requested ACL for user: " + (string)CurrentUser);
            }
        }
        else if (num == AUTH_BUS) {
            logd("AUTH_BUS message received: " + str);
            string msg_type = llJsonGetValue(str, ["type"]);
            
            if (msg_type == "acl_result") {
                if (!AclPending) {
                    logd("Ignoring ACL result - not pending");
                    return;
                }
                if (!json_has(str, ["avatar"])) return;
                
                key avatar = (key)llJsonGetValue(str, ["avatar"]);
                logd("ACL result: avatar=" + (string)avatar + " CurrentUser=" + (string)CurrentUser);
                
                if (avatar != CurrentUser) {
                    logd("Skipping ACL result - not for current user");
                    return;
                }
                
                if (!json_has(str, ["level"])) return;
                integer acl_level = (integer)llJsonGetValue(str, ["level"]);
                
                AclPending = FALSE;
                
                logd("TPE button clicked by " + (string)avatar + " (ACL " + (string)acl_level + ")");
                logd("WearerKey=" + (string)WearerKey + " TpeModeEnabled=" + (string)TpeModeEnabled);
                
                // Handle click - may show confirmation dialog or toggle directly
                handle_tpe_click(avatar, acl_level);
            }
        }
        else if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);
            
            if (msg_type == "dialog_response") {
                string session_id = llJsonGetValue(str, ["session_id"]);
                if (session_id != SessionId) return;
                
                string button = llJsonGetValue(str, ["button"]);
                logd("Dialog button: " + button);
                
                handle_button_click(button);
            }
            else if (msg_type == "dialog_timeout") {
                string session_id = llJsonGetValue(str, ["session_id"]);
                if (session_id != SessionId) return;
                
                logd("Dialog timeout - TPE activation cancelled");
                llRegionSayTo(WearerKey, 0, "TPE confirmation timed out.");
                if (CurrentUser != WearerKey) {
                    llRegionSayTo(CurrentUser, 0, "TPE confirmation timed out.");
                }
                
                // Close UI for wearer
                close_ui_for_user(WearerKey);
                
                // Return owner to root menu (if different from wearer)
                if (CurrentUser != WearerKey) {
                    string msg = llList2Json(JSON_OBJECT, [
                        "type", "return",
                        "user", (string)CurrentUser
                    ]);
                    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
                    logd("Returning owner to root menu");
                }
                
                cleanup_session();
            }
        }
    }
}
