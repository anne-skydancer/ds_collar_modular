/*--------------------
MODULE: ds_collar_menu.lsl
VERSION: 1.00
REVISION: 13
PURPOSE: Menu rendering and visual presentation service
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- Improved menu performance 
- Receives render requests from ds_collar_kmod_ui via UI bus messages
- Constructs dialog layouts with correct bottom-to-top button ordering
- Maintains stateless presentation separate from business logic
- Routes dialogs through dedicated dialog module for display
- Provides single-responsibility rendering for easier maintenance
--------------------*/


/* -------------------- CONSOLIDATED ABI -------------------- */
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PROFILING -------------------- */

integer MENU_PROF_ENABLE = TRUE;
float   MENU_PROF_LAST = 0.0;

menu_profile(string tag, key user)
{
    if (!MENU_PROF_ENABLE) return;

    float now = llGetTime();
    float dt = 0.0;
    if (MENU_PROF_LAST != 0.0) dt = now - MENU_PROF_LAST;
    MENU_PROF_LAST = now;

    string who = (string)user;
    if (who == NULL_KEY) who = "<none>";

    llOwnerSay("[MENU PROF] " + tag + " user=" + who + " dt=" + (string)dt);
}

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}
string get_msg_type(string msg) {
    if (!json_has(msg, ["type"])) return "";
    return llJsonGetValue(msg, ["type"]);
}

integer validate_required_fields(string json_str, list field_names) {
    integer i = 0;
    while (i < llGetListLength(field_names)) {
        string field = llList2String(field_names, i);
        if (!json_has(json_str, [field])) {
            return FALSE;
        }
        i += 1;
    }
    return TRUE;
}

/* -------------------- BUTTON LAYOUT -------------------- */

list reverse_complete_rows(list button_list, integer row_size) {
    list reordered = [];
    integer count = llGetListLength(button_list);
    if (count == 0) return [];

    integer num_rows = count / row_size;
    integer row = num_rows - 1;
    while (row >= 0) {
        integer row_start = row * row_size;
        integer j = 0;
        while (j < row_size) {
            reordered += [llList2String(button_list, row_start + j)];
            j = j + 1;
        }
        row = row - 1;
    }
    return reordered;
}

list reorder_buttons_for_display(list buttons) {

    integer count = llGetListLength(buttons);
    if (count == 0) return [];

    integer row_size = 3;
    integer partial_count = count % row_size;

    if (partial_count == 0) {
        return reverse_complete_rows(buttons, row_size);
    }
    else {
        list partial_row = llList2List(buttons, 0, partial_count - 1);
        list complete_buttons = llList2List(buttons, partial_count, -1);
        list reordered_complete = reverse_complete_rows(complete_buttons, row_size);
        return reordered_complete + partial_row;
    }
}

/* -------------------- RENDERING -------------------- */

render_menu(string msg) {
    if (!validate_required_fields(msg, ["user", "session_id", "menu_type", "buttons"])) {
        return;
    }

    key user = (key)llJsonGetValue(msg, ["user"]);
    menu_profile("render_menu entry", user);

    string session_id = llJsonGetValue(msg, ["session_id"]);
    string menu_type = llJsonGetValue(msg, ["menu_type"]);
    integer current_page = (integer)llJsonGetValue(msg, ["page"]);
    integer total_pages = (integer)llJsonGetValue(msg, ["total_pages"]);
    string buttons_json = llJsonGetValue(msg, ["buttons"]);
    integer has_nav = (integer)llJsonGetValue(msg, ["has_nav"]);

    list button_data_list = llJson2List(buttons_json);
    list reordered = reorder_buttons_for_display(button_data_list);

    list final_button_data = [];
    if (has_nav) {
        final_button_data = ["<<", ">>", "Close"] + reordered;
    }
    else {
        final_button_data = ["Close"] + reordered;
    }

    string title = "";
    if (menu_type == "core_root") {
        title = "Main Menu";
    }
    else if (menu_type == "sos_root") {
        title = "Emergency Menu";
    }
    else {
        title = "Menu";
    }

    if (total_pages > 1) {
        title = title + " (" + (string)(current_page + 1) + "/" + (string)total_pages + ")";
    }

    string body_text = "";
    if (menu_type == "core_root") {
        body_text = "Select an option:";
    }
    else if (menu_type == "sos_root") {
        body_text = "Emergency options:";
    }
    else {
        body_text = "Choose:";
    }

    string final_button_data_json = llList2Json(JSON_ARRAY, final_button_data);

    string dialog_msg = llList2Json(JSON_OBJECT, [
        "type", "dialog_open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", body_text,
        "button_data", final_button_data_json,
        "timeout", 60
    ]);

    menu_profile("render_menu -> dialog_open", user);
    llMessageLinked(LINK_SET, DIALOG_BUS, dialog_msg, NULL_KEY);
}

show_message(string msg) {
    if (!validate_required_fields(msg, ["user", "message"])) {
        return;
    }

    key user = (key)llJsonGetValue(msg, ["user"]);
    string message_text = llJsonGetValue(msg, ["message"]);

    menu_profile("show_message", user);
    llRegionSayTo(user, 0, message_text);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        llResetTime();
        MENU_PROF_LAST = 0.0;
    }

    link_message(integer sender_num, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == UI_BUS) {
            if (msg_type == "render_menu") {
                render_menu(msg);
            }
            else if (msg_type == "show_message") {
                show_message(msg);
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}
