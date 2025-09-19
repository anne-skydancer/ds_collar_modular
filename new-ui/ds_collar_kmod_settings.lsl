/* =============================================================
   MODULE: ds_collar_kmod_settings.lsl
   ROLE  : Generalized settings persister with subscriptions
   NOTE  : No soft-reset handler (per project decision)
   ============================================================= */

integer DEBUG = FALSE;
integer logd(string s){ if (DEBUG) llOwnerSay("[SETTINGS] " + s); return 0; }

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
string TYPE_ERROR               = "error";
string TYPE_SETTINGS_PUT        = "settings_put";
string TYPE_SETTINGS_GET        = "settings_get";
string TYPE_SETTINGS_DEL        = "settings_del";
string TYPE_SETTINGS_BATCH      = "settings_batch";
string TYPE_SETTINGS_SUB        = "settings_sub";
string TYPE_SETTINGS_UNSUB      = "settings_unsub";
string TYPE_SETTINGS_ACK        = "settings_ack";
string TYPE_SETTINGS_SNAPSHOT   = "settings_snapshot";
string TYPE_SETTINGS_SYNC       = "settings_sync";
string TYPE_REGISTER            = "register";
string TYPE_REGISTER_ACK        = "register_ack";
string TYPE_READY               = "ready";

/* Value type tags */
string VTYPE_INT      = "int";
string VTYPE_STRING   = "string";
string VTYPE_UUID     = "uuid";
string VTYPE_LIST_STR = "list_string";
string VTYPE_MAP      = "map";
string VTYPE_NULL     = "null";

/* Allow lists */
list CoreWriters     = ["kernel","ui_backend","owner_ui","bootstrap","rlv_enforcer","auth","acl"];
list CoreSubscribers = ["kernel","ui_backend","bootstrap","rlv_enforcer","auth","acl"];

/* Store & subs */
list Store;
integer STORE_STRIDE = 5; /* [path,type,json,rev,ts]* */
list Subs;
integer SUBS_STRIDE  = 2; /* [moduleId,prefix]* */

/* Limits */
integer MAX_KEYS=128;
integer MAX_BATCH_OPS=6; 
integer MAX_SUBS_TOTAL=24; 
integer MAX_SUBS_PER_CALLER=4; 
integer MAX_VALUE_CHARS=400;

/* Helpers */
integer now(){ return llGetUnixTime(); }
integer json_has(string j, list p){ if (llJsonGetValue(j,p)==JSON_INVALID) return FALSE; return TRUE; }
string  json_gets(string j, list p, string d){ string v=llJsonGetValue(j,p); if (v==JSON_INVALID) return d; return v; }
integer json_geti(string j, list p, integer d){ string v=llJsonGetValue(j,p); if (v==JSON_INVALID||v=="") return d; return (integer)v; }
string  lc(string s){ return llToLower(s); }

/* Path helpers */
integer starts_with(string s,string pre){ integer n=llStringLength(pre); if (llGetSubString(s,0,n-1)==pre) return TRUE; return FALSE; }
integer is_core_path(string path){ if (llSubStringIndex(path,"core.")==0) return TRUE; return FALSE; }
integer is_mod_path(string path){
    if (llSubStringIndex(path,"mod.")!=0) return FALSE;
    integer dot = llSubStringIndex(path,".");
    string rest = llGetSubString(path, dot+1, -1);
    integer next = llSubStringIndex(rest,".");
    if (next <= 0) return FALSE;
    return TRUE;
}
integer is_plugin_path(string path){
    if (llSubStringIndex(path,"plugin.")!=0) return FALSE;
    integer dot = llSubStringIndex(path,".");
    string rest = llGetSubString(path, dot+1, -1);
    integer next = llSubStringIndex(rest,".");
    if (next <= 0) return FALSE;
    return TRUE;
}

/* Store ops */
integer store_index(string path){
    integer i=0; integer n=llGetListLength(Store);
    while (i<n){ if (llList2String(Store,i)==path) return i; i+=STORE_STRIDE; }
    return -1;
}
list store_get_tuple(string path){ integer i=store_index(path); if (i==-1) return []; return llList2List(Store,i,i+4); }
integer store_put(string path,string vtype,string json_value){
    integer i=store_index(path); integer t=now();
    if (i==-1){
        integer keys = llGetListLength(Store)/STORE_STRIDE;
        if (keys>=MAX_KEYS) return -1;
        Store += [path,vtype,json_value,1,t]; return 1;
    }else{
        string old_json=llList2String(Store,i+2);
        string old_type=llList2String(Store,i+1);
        integer rev=llList2Integer(Store,i+3);
        if (old_json!=json_value || old_type!=vtype){
            Store=llListReplaceList(Store,[path,vtype,json_value,rev+1,t],i,i+4); return 1;
        }
        Store=llListReplaceList(Store,[path,old_type,old_json,rev,t],i,i+4); return 0;
    }
}
integer store_del(string path){
    integer i=store_index(path); if (i==-1) return 0;
    Store=llDeleteSubList(Store,i,i+4); return 1;
}

/* Validation */
list validate_value(string vtype,string rawJson){
    if (llStringLength(rawJson)>MAX_VALUE_CHARS) return [FALSE,"","value too large"];
    if (vtype==VTYPE_NULL)   return [TRUE,JSON_NULL,""];
    if (vtype==VTYPE_INT)    return [TRUE,(string)((integer)rawJson),""];
    if (vtype==VTYPE_STRING){ string j = llList2Json(JSON_OBJECT,[]); j=llJsonSetValue(j,["v"], rawJson); return [TRUE,llJsonGetValue(j,["v"]), ""]; }
    if (vtype==VTYPE_UUID){
        string s=rawJson;
        if (llGetSubString(s,0,0)=="\"" && llGetSubString(s,-1,-1)=="\"") s=llGetSubString(s,1,llStringLength(s)-2);
        s=lc(s);
        if (!(llStringLength(s)==36 && llSubStringIndex(s,"-")!=-1)) return [FALSE,"","invalid uuid"];
        string j2 = llList2Json(JSON_OBJECT,[]); j2=llJsonSetValue(j2,["v"], s); return [TRUE,llJsonGetValue(j2,["v"]),""]; 
    }
    if (vtype==VTYPE_LIST_STR){ if (llGetSubString(rawJson,0,0)!="[") return [FALSE,"","list_string must be JSON array"]; return [TRUE,rawJson,""]; }
    if (vtype==VTYPE_MAP){ if (llGetSubString(rawJson,0,0)!="{") return [FALSE,"","map must be JSON object"]; return [TRUE,rawJson,""]; }
    return [FALSE,"","unknown vtype"];
}

/* Access control */
integer list_has(list L,string needle){ integer i=0; integer n=llGetListLength(L); while(i<n){ if (llList2String(L,i)==needle) return TRUE; i+=1; } return FALSE; }
integer can_write_path(string fromMod,string path){
    if (is_core_path(path)) return list_has(CoreWriters, fromMod);
    if (is_mod_path(path)){
        integer dot = llSubStringIndex(path,".");
        string rest = llGetSubString(path, dot+1, -1);
        integer next = llSubStringIndex(rest,".");
        string owner = llGetSubString(rest, 0, next-1);
        if (fromMod == owner) return TRUE; return FALSE;
    }
    if (is_plugin_path(path)){
        integer dot = llSubStringIndex(path,".");
        string rest = llGetSubString(path, dot+1, -1);
        integer next = llSubStringIndex(rest,".");
        string owner = llGetSubString(rest, 0, next-1);
        if (fromMod == ("plugin."+owner)) return TRUE;
        if (fromMod == owner) return TRUE;
        return FALSE;
    }
    return FALSE;
}
integer can_subscribe_prefix(string fromMod,string prefix){
    if (starts_with(prefix,"core.")) return list_has(CoreSubscribers, fromMod);
    return TRUE;
}

/* Outbound */
integer send_ack(string toMod,string reqId,string keyOrPath,integer ok,integer didChange,integer rev){
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],"settings_ack");
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],toMod);
    j=llJsonSetValue(j,["req_id"],reqId);
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["ok"],(string)ok);
    j=llJsonSetValue(j,["changed"],(string)didChange);
    if (keyOrPath!="") j=llJsonSetValue(j,["key"],keyOrPath);
    if (rev>0) j=llJsonSetValue(j,["rev"],(string)rev);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}
integer send_error(string toMod,string reqId,string code,string message){
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],"error");
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],toMod);
    j=llJsonSetValue(j,["req_id"],reqId);
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["code"],code);
    j=llJsonSetValue(j,["message"],message);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}
integer send_snapshot(string toMod,string reqId,list paths){
    string obj=llList2Json(JSON_OBJECT,[]);
    integer i=0; integer n=llGetListLength(paths);
    while(i<n){
        string p=llList2String(paths,i);
        list t=store_get_tuple(p);
        string m=llList2Json(JSON_OBJECT,[]);
        if (llGetListLength(t)>0){
            m=llJsonSetValue(m,["value"], llList2String(t,2));
            m=llJsonSetValue(m,["type"],  llList2String(t,1));
            m=llJsonSetValue(m,["rev"],   (string)llList2Integer(t,3));
        }else{
            m=llJsonSetValue(m,["value"], JSON_NULL);
            m=llJsonSetValue(m,["type"],  VTYPE_NULL);
            m=llJsonSetValue(m,["rev"],   "0");
        }
        obj=llJsonSetValue(obj,[p],m);
        i+=1;
    }
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],"settings_snapshot");
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],toMod);
    j=llJsonSetValue(j,["req_id"],reqId);
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["values"],obj);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}
integer send_sync_to(string toMod,string changedObj){
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],"settings_sync");
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],toMod);
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["changed"],changedObj);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}

/* Subs */
integer subs_count_for(string mod){ integer i=0; integer n=llGetListLength(Subs); integer c=0; while(i<n){ if (llList2String(Subs,i)==mod) c+=1; i+=SUBS_STRIDE; } return c; }
integer subs_has(string mod,string prefix){ integer i=0; integer n=llGetListLength(Subs); while(i<n){ if (llList2String(Subs,i)==mod && llList2String(Subs,i+1)==prefix) return TRUE; i+=SUBS_STRIDE; } return FALSE; }
integer subs_add(string mod,string prefix){ Subs += [mod,prefix]; return TRUE; }
integer subs_remove(string mod,string prefix){ integer i=0; integer n=llGetListLength(Subs); while(i<n){ if (llList2String(Subs,i)==mod && llList2String(Subs,i+1)==prefix){ Subs=llDeleteSubList(Subs,i,i+1); return TRUE; } i+=SUBS_STRIDE; } return FALSE; }

/* Deliver coalesced diffs to subscribers AND broadcast */
integer deliver_sync_coalesced(list changedPaths){
    string changedObj=llList2Json(JSON_OBJECT,[]);
    integer i=0; integer n=llGetListLength(changedPaths);
    while(i<n){
        string p=llList2String(changedPaths,i);
        list tup=store_get_tuple(p);
        if (llGetListLength(tup)>0) changedObj=llJsonSetValue(changedObj,[p], llList2String(tup,2));
        else changedObj=llJsonSetValue(changedObj,[p], JSON_NULL);
        i+=1;
    }
    integer si=0; integer sn=llGetListLength(Subs);
    while (si<sn){
        string mod=llList2String(Subs,si);
        string pref=llList2String(Subs,si+1);

        string subObj=llList2Json(JSON_OBJECT,[]); integer any=FALSE;
        i=0;
        while (i<n){
            string p2=llList2String(changedPaths,i);
            if (starts_with(p2,pref)){
                any=TRUE;
                string val=llJsonGetValue(changedObj,[p2]);
                subObj=llJsonSetValue(subObj,[p2], val);
            }
            i+=1;
        }
        if (any) send_sync_to(mod, subObj);
        si+=SUBS_STRIDE;
    }
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],"settings_sync");
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],"any");
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["changed"],changedObj);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY);
    return TRUE;
}

/* Seed defaults */
integer seed_defaults(){
    list defaults = [
        "core.owner.key",            VTYPE_UUID, JSON_NULL,
        "core.self.owned",           VTYPE_INT,  "1",
        "core.public.mode",          VTYPE_INT,  "0",
        "core.restricted.mode",      VTYPE_INT,  "0",
        "core.locked",               VTYPE_INT,  "0",
        "core.rlv.enabled",          VTYPE_INT,  "0",
        "core.rlv.accepttp.enabled", VTYPE_INT,  "1"
    ];
    integer i=0; integer n=llGetListLength(defaults);
    while (i<n){ store_put(llList2String(defaults,i), llList2String(defaults,i+1), llList2String(defaults,i+2)); i+=3; }
    return TRUE;
}

/* Ops */
integer handle_put(string fromMod,string reqId,string pathIn,string vtype,string rawValue,integer ifRevPresent,integer ifRev){
    string path=lc(llStringTrim(pathIn, STRING_TRIM));
    if (path==""){ send_error(fromMod,reqId,"E_BADREQ","missing path"); return FALSE; }
    if (!can_write_path(fromMod,path)){ send_error(fromMod,reqId,"E_DENIED","write not permitted"); return FALSE; }

    list vv=validate_value(vtype,rawValue);
    if (!llList2Integer(vv,0)){ send_error(fromMod,reqId,"E_TYPE", llList2String(vv,2)); return FALSE; }
    if (ifRevPresent){
        integer idx0=store_index(path);
        if (idx0==-1){ send_error(fromMod,reqId,"E_CONFLICT","rev mismatch (missing key)"); return FALSE; }
        integer curRev0=llList2Integer(Store,idx0+3);
        if (curRev0!=ifRev){ send_error(fromMod,reqId,"E_CONFLICT","rev mismatch"); return FALSE; }
    }
    integer rc=store_put(path,vtype,llList2String(vv,1)); if (rc==-1){ send_error(fromMod,reqId,"E_LIMIT","store full"); return FALSE; }
    integer idx=store_index(path); integer rev=0; if (idx!=-1) rev=llList2Integer(Store,idx+3);
    integer changed_val = (rc==1);
    send_ack(fromMod,reqId,path,TRUE,changed_val,rev);
    if (changed_val) deliver_sync_coalesced([path]);
    return TRUE;
}
integer handle_del(string fromMod,string reqId,string pathIn,integer ifRevPresent,integer ifRev){
    string path=lc(llStringTrim(pathIn,STRING_TRIM));
    if (path==""){ send_error(fromMod,reqId,"E_BADREQ","missing path"); return FALSE; }
    if (!can_write_path(fromMod,path)){ send_error(fromMod,reqId,"E_DENIED","delete not permitted"); return FALSE; }
    if (ifRevPresent){
        integer idx0=store_index(path);
        if (idx0==-1){ send_error(fromMod,reqId,"E_CONFLICT","rev mismatch (missing key)"); return FALSE; }
        integer curRev0=llList2Integer(Store,idx0+3);
        if (curRev0!=ifRev){ send_error(fromMod,reqId,"E_CONFLICT","rev mismatch"); return FALSE; }
    }
    integer didChange=store_del(path);
    send_ack(fromMod,reqId,path,TRUE,didChange,0);
    if (didChange) deliver_sync_coalesced([path]);
    return TRUE;
}
list gather_paths_from_prefix(string prefix){
    list out=[]; integer i=0; integer n=llGetListLength(Store);
    while(i<n){ string p=llList2String(Store,i); if (starts_with(p,prefix)) out+=p; i+=STORE_STRIDE; }
    return out;
}

/* Events */
default{
    state_entry(){
        Store=[]; Subs=[]; seed_defaults();
        /* Register minimal presence for kernel if needed */
        string j=llList2Json(JSON_OBJECT,[]);
        j=llJsonSetValue(j,["type"],"register");
        j=llJsonSetValue(j,["from"],"settings");
        j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
        j=llJsonSetValue(j,["module_ver"],"1.0.0");
        llMessageLinked(LINK_SET, -1100, j, NULL_KEY); /* optional */
        logd("Settings ready.");
    }
    on_rez(integer sp){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer s, integer num, string msg, key id){
        if (num != L_SETTINGS_IN) return;
        string t = llJsonGetValue(msg, ["type"]);
        string fromMod = llJsonGetValue(msg, ["from"]);
        string reqId = llJsonGetValue(msg, ["req_id"]);

        if (t == "settings_put"){
            string path = llJsonGetValue(msg, ["path"]);
            string vtype= llJsonGetValue(msg, ["vtype"]);
            string raw  = llJsonGetValue(msg, ["value"]);
            integer ifp = FALSE; integer ifrev=0;
            string ir = llJsonGetValue(msg, ["if_rev"]); if (ir != JSON_INVALID && ir != ""){ ifp=TRUE; ifrev=(integer)ir; }
            handle_put(fromMod,reqId,path,vtype,raw,ifp,ifrev); return;
        }
        if (t == "settings_get"){
            list outPaths=[]; integer hasPrefix=FALSE;
            string prefix = llJsonGetValue(msg, ["prefix"]);
            if (prefix != JSON_INVALID && prefix != ""){ hasPrefix=TRUE; if (llGetSubString(prefix,-1,-1)!=".") prefix+="."; }
            string arr = llJsonGetValue(msg, ["paths"]);
            if (arr != JSON_INVALID){
                integer i=0; integer done=FALSE;
                while(!done){
                    string p=llJsonGetValue(arr,[(string)i]);
                    if (p==JSON_INVALID) done=TRUE; else { outPaths+=lc(p); i+=1; }
                }
            } else if (hasPrefix){
                outPaths=gather_paths_from_prefix(lc(prefix));
            } else {
                integer i2=0; integer n2=llGetListLength(Store);
                while(i2<n2){ outPaths+=llList2String(Store,i2); i2+=STORE_STRIDE; }
            }
            send_snapshot(fromMod,reqId,outPaths); return;
        }
        if (t == "settings_del"){
            string path=llJsonGetValue(msg,["path"]);
            integer ifp=FALSE; integer ifrev=0;
            string ir2=llJsonGetValue(msg,["if_rev"]); if (ir2!=JSON_INVALID && ir2!=""){ ifp=TRUE; ifrev=(integer)ir2; }
            handle_del(fromMod,reqId,path,ifp,ifrev); return;
        }
        if (t == "settings_batch"){
            integer i3=0; integer count=0; integer done2=FALSE;
            while(!done2){
                string op = llJsonGetValue(msg, ["ops",(string)i3,"op"]);
                if (op == JSON_INVALID){ done2=TRUE; }
                else {
                    count+=1; if (count>MAX_BATCH_OPS){ send_error(fromMod,reqId,"E_LIMIT","too many ops"); return; }
                    string path = llJsonGetValue(msg, ["ops",(string)i3,"path"]);
                    string vtype= llJsonGetValue(msg, ["ops",(string)i3,"vtype"]);
                    string raw  = llJsonGetValue(msg, ["ops",(string)i3,"value"]);
                    integer ifp=FALSE; integer ifrev=0;
                    string ir3=llJsonGetValue(msg,["ops",(string)i3,"if_rev"]); if (ir3!=JSON_INVALID && ir3!=""){ ifp=TRUE; ifrev=(integer)ir3; }
                    if (op == "put") handle_put(fromMod,reqId,path,vtype,raw,ifp,ifrev);
                    else if (op == "del") handle_del(fromMod,reqId,path,ifp,ifrev);
                    else { send_error(fromMod,reqId,"E_BADREQ","unknown op"); return; }
                    i3+=1;
                }
            }
            send_ack(fromMod,reqId,"batch",TRUE,1,0); return;
        }
        if (t == "settings_sub"){
            string prefix = llJsonGetValue(msg, ["prefix"]);
            if (prefix == JSON_INVALID || prefix == ""){ send_error(fromMod,reqId,"E_BADREQ","missing prefix"); return; }
            if (llGetSubString(prefix,-1,-1)!=".") prefix+=".";
            if (!can_subscribe_prefix(fromMod, prefix)){ send_error(fromMod,reqId,"E_DENIED","subscription not permitted"); return; }
            if (subs_has(fromMod,prefix)){ send_ack(fromMod,reqId,"sub",TRUE,0,0); return; }
            if (subs_count_for(fromMod)>=MAX_SUBS_PER_CALLER){ send_error(fromMod,reqId,"E_LIMIT","per-caller subscription cap"); return; }
            if ((llGetListLength(Subs)/SUBS_STRIDE)>=MAX_SUBS_TOTAL){ send_error(fromMod,reqId,"E_LIMIT","global subscription cap"); return; }
            subs_add(fromMod,prefix); send_ack(fromMod,reqId,"sub",TRUE,1,0); logd("Sub "+fromMod+" ← "+prefix); return;
        }
        if (t == "settings_unsub"){
            string prefix = llJsonGetValue(msg, ["prefix"]);
            if (prefix == JSON_INVALID || prefix == ""){ send_error(fromMod,reqId,"E_BADREQ","missing prefix"); return; }
            if (llGetSubString(prefix,-1,-1)!=".") prefix+=".";
            integer had=subs_has(fromMod,prefix);
            if (had) subs_remove(fromMod,prefix);
            send_ack(fromMod,reqId,"unsub",TRUE,had,0); logd("Unsub "+fromMod+" ← "+prefix); return;
        }
    }
}
