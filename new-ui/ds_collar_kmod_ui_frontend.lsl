/* =============================================================
   MODULE: ds_collar_kmod_ui_frontend.lsl
   ROLE  : Render dialogs; send touches/clicks to UI backend
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[UI-FE] " + s); return 0; }

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
string T_UI_RENDER = "ui_render";
string T_UI_CLICK  = "ui_click";
string T_UI_TOUCH  = "ui_touch";

/* State */
integer DialogChan;
integer DialogListen;
key     DialogAvatar;
string  DialogCtx;
list    DialogButtons; /* [label, id]* */

/* Helpers */
integer now(){ return llGetUnixTime(); }

integer make_chan(){
    integer base = (integer)llFrand(1000000.0) + 1000;
    if (base == 0) base = 777777;
    return -base;
}

string rid(){
    return (string)now() + "-" + (string)llRound(llFrand(9999.0));
}

/* API senders */
integer api_send_touch(key avatar){
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

integer api_send_click(string choiceId, string ctxJson){
    string j = llList2Json(JSON_OBJECT, []);
    j = llJsonSetValue(j, ["type"], T_UI_CLICK);
    j = llJsonSetValue(j, ["from"], "ui_frontend");
    j = llJsonSetValue(j, ["to"], "ui_backend");
    j = llJsonSetValue(j, ["req_id"], rid());
    j = llJsonSetValue(j, ["choice_id"], choiceId);
    j = llJsonSetValue(j, ["ctx"], ctxJson);
    j = llJsonSetValue(j, ["abi"], (string)ABI_VERSION);
    llMessageLinked(LINK_SET, L_API, j, NULL_KEY);
    return TRUE;
}

/* Rendering */
integer render_menu(string menuJson){
    if (DialogListen) llListenRemove(DialogListen);
    DialogListen = 0;
    DialogButtons = [];

    string title   = llJsonGetValue(menuJson, ["title"]);
    string prompt  = llJsonGetValue(menuJson, ["prompt"]);
    string ctx     = llJsonGetValue(menuJson, ["ctx"]);
    string buttons = llJsonGetValue(menuJson, ["buttons"]);

    DialogCtx    = ctx;
    DialogAvatar = (key)llJsonGetValue(ctx, ["avatar"]);

    list labels = [];
    integer i = 0;
    integer done = FALSE;
    while (!done){
        string b = llJsonGetValue(buttons, [(string)i]);
        if (b == JSON_INVALID){
            done = TRUE;
        } else {
            string lab = llJsonGetValue(b, ["label"]);
            string cid = llJsonGetValue(b, ["id"]);
            labels += lab;
            DialogButtons += [lab, cid];
            i += 1;
        }
    }

    string text = title + "\n" + prompt;
    DialogChan = make_chan();
    DialogListen = llListen(DialogChan, "", DialogAvatar, "");
    llDialog(DialogAvatar, text, labels, DialogChan);
    return TRUE;
}

string choice_id_from_label(string label){
    integer i = 0;
    integer n = llGetListLength(DialogButtons);
    while (i + 1 < n){
        if (llList2String(DialogButtons, i) == label) return llList2String(DialogButtons, i + 1);
        i += 2;
    }
    return "";
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
        DialogButtons = [];
    }

    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    /* New: forward touches upstream to backend */
    touch_start(integer n){
        integer i = 0;
        while (i < n){
            key av = llDetectedKey(i);
            api_send_touch(av);
            i += 1;
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

        string choiceId = choice_id_from_label(text);
        if (choiceId != ""){
            api_send_click(choiceId, DialogCtx);
        }

        if (DialogListen) llListenRemove(DialogListen);
        DialogListen = 0;
        DialogChan = 0;
    }
}
