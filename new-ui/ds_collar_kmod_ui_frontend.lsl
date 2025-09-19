/* =============================================================
   MODULE: ds_collar_kmod_ui_frontend.lsl (BLANK-CANVAS)
   ROLE  : Pure renderer + event forwarder
           - Renders exactly what BE sends (no normalization)
           - Adds minimal trailing spaces only (llDialog requirement)
           - Sends click events with both index and label
   NOTE   : Touch is forwarded to BE (for external harness/plugins)
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-FE] " + s); return 0; }

/* === Canonical lanes === */
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
string T_UI_TOUCH  = "ui_touch";
string T_UI_RENDER = "ui_render";
string T_UI_CLICK  = "ui_click";

/* State */
integer DialogChan;
integer DialogListen;
key     DialogAvatar;
string  DialogCtx;
list    DialogLabels;  /* ["Label A","Label B",...] */

/* Helpers */
integer now(){ return llGetUnixTime(); }
string rid(){ return (string)now() + "-" + (string)llRound(llFrand(9999.0)); }
integer make_chan(){
    integer base = (integer)llFrand(1000000.0) + 1000;
    if (base == 0) base = 777777;
    return -base;
}
list pad_for_dialog(list labels){
    integer L = llGetListLength(labels);
    integer mod = L % 3;
    if (mod == 0) return labels;
    if (mod == 1) return labels + [" ", " "];
    return labels + [" "]; /* mod == 2 */
}

/* API senders */
integer api_touch_be(key avatar){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], T_UI_TOUCH);
    j = llJsonSetValue(j, ["from"], "ui_frontend");
    j = llJsonSetValue(j, ["to"], "ui_backend");
    j = llJsonSetValue(j, ["req_id"], rid());
    j = llJsonSetValue(j, ["avatar"], (string)avatar);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

integer api_click_be(string session, integer index, string label){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], T_UI_CLICK);
    j = llJsonSetValue(j, ["from"], "ui_frontend");
    j = llJsonSetValue(j, ["to"], "ui_backend");
    j = llJsonSetValue(j, ["req_id"], rid());
    j = llJsonSetValue(j, ["session"], session);
    j = llJsonSetValue(j, ["index"], (string)index);
    j = llJsonSetValue(j, ["label"], label);
    j = llJsonSetValue(j, ["ctx"], DialogCtx);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* Rendering */
integer render_menu(string menuJson){
    /* Close previous listen */
    if (DialogListen) llListenRemove(DialogListen);
    DialogListen = 0;

    DialogLabels = [];
    DialogCtx = llJsonGetValue(menuJson, ["ctx"]);

    /* ctx must contain avatar key */
    DialogAvatar = (key)llJsonGetValue(DialogCtx, ["avatar"]);

    string title  = llJsonGetValue(menuJson, ["title"]);
    string prompt = llJsonGetValue(menuJson, ["prompt"]);
    string buttons = llJsonGetValue(menuJson, ["buttons"]);

    list labels = [];
    integer i = 0; integer done = FALSE;
    while (!done){
        string b = llJsonGetValue(buttons, [ (string)i ]);
        if (b == JSON_INVALID) done = TRUE;
        else{
            string lab = llJsonGetValue(b, ["label"]);
            labels += lab;
            i = i + 1;
        }
    }

    DialogLabels = labels;

    string text = title + "\n" + prompt;

    DialogChan   = make_chan();
    DialogListen = llListen(DialogChan, "", DialogAvatar, "");

    list padded = pad_for_dialog(labels);
    llDialog(DialogAvatar, text, padded, DialogChan);
    return TRUE;
}

/* =============================================================
   EVENTS
   ============================================================= */
default{
    state_entry(){
        DialogChan = 0;
        DialogListen = 0;
        DialogAvatar = NULL_KEY;
        DialogCtx = "";
        DialogLabels = [];
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    /* Frontend owns touch → external harness/plugin may react via BE */
    touch_start(integer n){
        integer i = 0;
        while (i < n){
            api_touch_be(llDetectedKey(i));
            i = i + 1;
        }
    }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_UI_FE_IN) return;

        string t = llJsonGetValue(msg, ["type"]);
        if (t == T_UI_RENDER){
            string menu = llJsonGetValue(msg, ["menu"]);
            if (menu != JSON_INVALID) render_menu(menu);
            return;
        }
    }

    listen(integer chan, string name, key id, string text){
        if (chan != DialogChan) return;
        if (id != DialogAvatar) return;

        /* Find index of clicked label (first match) */
        integer idx = -1;
        integer n = llGetListLength(DialogLabels);
        integer i = 0;
        while (i < n){
            if (llList2String(DialogLabels, i) == text){
                idx = i; i = n;
            } else {
                i = i + 1;
            }
        }

        string session = llJsonGetValue(DialogCtx, ["session"]);
        api_click_be(session, idx, text);

        if (DialogListen) llListenRemove(DialogListen);
        DialogListen = 0;
        DialogChan = 0;
    }
}
