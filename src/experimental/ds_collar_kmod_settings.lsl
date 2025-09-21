/* =============================================================
   MODULE: ds_collar_kmod_settings.lsl
   ROLE  : Headless settings persister with subscriptions
           • API-only (L_API → "to":"settings")
           • No-op guard (ACK only if unchanged)
           • Coalesced settings_sync to subscribers + broadcast
           • Volatile keys → ACK only (no sync)
           • No plugin/feature registration (headless)
   ============================================================= */

integer DEBUG = TRUE;
integer logd(string s){ if (DEBUG) llOwnerSay("[SETTINGS] " + s); return 0; }

/* === ABI & Lanes === */
integer ABI_VERSION   = 1;
integer L_API         = -1000;

/* Types */
string TYPE_ERROR             = "error";
string TYPE_SETTINGS_PUT      = "settings_put";
string TYPE_SETTINGS_GET      = "settings_get";
string TYPE_SETTINGS_DEL      = "settings_del";
string TYPE_SETTINGS_BATCH    = "settings_batch";
string TYPE_SETTINGS_SUB      = "settings_sub";
string TYPE_SETTINGS_UNSUB    = "settings_unsub";
string TYPE_SETTINGS_ACK      = "settings_ack";
string TYPE_SETTINGS_SNAPSHOT = "settings_snapshot";
string TYPE_SETTINGS_SYNC     = "settings_sync";

/* Value types */
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
list Store;  integer STORE_STRIDE = 5; /* [path,type,json,rev,ts] */
list Subs;   integer SUBS_STRIDE  = 2; /* [moduleId,prefix] */

/* Limits */
integer MAX_KEYS=128;
integer MAX_BATCH_OPS=6;
integer MAX_SUBS_TOTAL=24;
integer MAX_SUBS_PER_CALLER=4;
integer MAX_VALUE_CHARS=400;

/* Volatile keys (ACK only; no sync) */
list VolatilePaths = ["core.runtime.heartbeat"];

/* Helpers */
integer now(){ return llGetUnixTime(); }
string  lc(string s){ return llToLower(s); }
integer starts_with(string hay,string pre){ integer n=llStringLength(pre); if (n==0) return TRUE; return (llGetSubString(hay,0,n-1)==pre); }

integer is_core_path(string pathStr){ return (llSubStringIndex(pathStr,"core.")==0); }
integer is_mod_path(string pathStr){ return (llSubStringIndex(pathStr,"mod.")==0); }
integer is_plugin_path(string pathStr){ return (llSubStringIndex(pathStr,"plugin.")==0); }

integer is_volatile_path(string pathStr){
    integer i; integer n=llGetListLength(VolatilePaths);
    for (i=0; i<n; i++) if (llList2String(VolatilePaths,i)==pathStr) return TRUE;
    return FALSE;
}

/* Store ops */
integer store_index(string pathStr){
    integer i; integer n=llGetListLength(Store);
    for (i=0; i<n; i+=STORE_STRIDE) if (llList2String(Store,i)==pathStr) return i;
    return -1;
}
list store_get_tuple(string pathStr){
    integer idx=store_index(pathStr);
    if (idx==-1) return [];
    return llList2List(Store,idx,idx+4);
}
integer store_put(string pathStr,string vtypeStr,string jsonVal){
    integer idx=store_index(pathStr); integer ts=now();
    if (idx==-1){
        if ((llGetListLength(Store)/STORE_STRIDE)>=MAX_KEYS) return -1;
        Store += [pathStr,vtypeStr,jsonVal,1,ts]; return 1;
    }
    string old_json=llList2String(Store,idx+2);
    string old_type=llList2String(Store,idx+1);
    integer rev=llList2Integer(Store,idx+3);
    if (old_json!=jsonVal || old_type!=vtypeStr){
        Store=llListReplaceList(Store,[pathStr,vtypeStr,jsonVal,rev+1,ts],idx,idx+4); return 1;
    }
    Store=llListReplaceList(Store,[pathStr,old_type,old_json,rev,ts],idx,idx+4); return 0;
}
integer store_del(string pathStr){
    integer idx=store_index(pathStr); if (idx==-1) return 0;
    Store=llDeleteSubList(Store,idx,idx+4); return 1;
}

/* Validation */
list validate_value(string vtypeStr,string rawJson){
    if (llStringLength(rawJson)>MAX_VALUE_CHARS) return [FALSE,"","too large"];
    if (vtypeStr==VTYPE_NULL) return [TRUE,JSON_NULL,""];
    if (vtypeStr==VTYPE_INT) return [TRUE,(string)((integer)rawJson),""];
    if (vtypeStr==VTYPE_STRING) return [TRUE,rawJson,""];
    if (vtypeStr==VTYPE_UUID){
        string s=rawJson;
        if (llGetSubString(s,0,0)=="\"" && llGetSubString(s,-1,-1)=="\"") s=llGetSubString(s,1,llStringLength(s)-2);
        key k=(key)s; if ((string)k!=s) return [FALSE,"","invalid uuid"];
        return [TRUE,lc(s),""];
    }
    if (vtypeStr==VTYPE_LIST_STR && llGetSubString(rawJson,0,0)=="[") return [TRUE,rawJson,""];
    if (vtypeStr==VTYPE_MAP && llGetSubString(rawJson,0,0)=="{") return [TRUE,rawJson,""];
    return [FALSE,"","bad vtype"];
}

/* Access control */
integer list_has_exact(list L,string needle){ integer i; integer n=llGetListLength(L); for (i=0;i<n;i++) if (llList2String(L,i)==needle) return TRUE; return FALSE; }
integer can_write_path(string fromMod,string pathStr){
    if (is_core_path(pathStr)) return list_has_exact(CoreWriters, fromMod);
    if (is_mod_path(pathStr) || is_plugin_path(pathStr)) return TRUE; /* module/plugin owns its space */
    return FALSE;
}
integer can_subscribe_prefix(string fromMod,string prefix){
    if (starts_with(prefix,"core.")) return list_has_exact(CoreSubscribers, fromMod);
    return TRUE;
}

/* Outbound */
integer send_ack(string toMod,string reqId,string keyStr,integer ok,integer didChange,integer rev){
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],TYPE_SETTINGS_ACK);
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],toMod);
    j=llJsonSetValue(j,["req_id"],reqId);
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["ok"],(string)ok);
    j=llJsonSetValue(j,["changed"],(string)didChange);
    if (keyStr!="") j=llJsonSetValue(j,["key"],keyStr);
    if (rev>0) j=llJsonSetValue(j,["rev"],(string)rev);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}
integer send_error(string toMod,string reqId,string code,string msg){
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],TYPE_ERROR);
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],toMod);
    j=llJsonSetValue(j,["req_id"],reqId);
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["code"],code);
    j=llJsonSetValue(j,["message"],msg);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}
integer send_snapshot(string toMod,string reqId,list paths){
    string obj=llList2Json(JSON_OBJECT,[]);
    integer i; integer n=llGetListLength(paths);
    for (i=0;i<n;i++){
        string pathStr=llList2String(paths,i);
        list tup=store_get_tuple(pathStr);
        string meta=llList2Json(JSON_OBJECT,[]);
        if (llGetListLength(tup)>0){
            meta=llJsonSetValue(meta,["value"],llList2String(tup,2));
            meta=llJsonSetValue(meta,["type"], llList2String(tup,1));
            meta=llJsonSetValue(meta,["rev"],  (string)llList2Integer(tup,3));
        }else{
            meta=llJsonSetValue(meta,["value"],JSON_NULL);
            meta=llJsonSetValue(meta,["type"], VTYPE_NULL);
            meta=llJsonSetValue(meta,["rev"],  "0");
        }
        obj=llJsonSetValue(obj,[pathStr],meta);
    }
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],TYPE_SETTINGS_SNAPSHOT);
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],toMod);
    j=llJsonSetValue(j,["req_id"],reqId);
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["values"],obj);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}
integer send_sync_to(string toMod,string changedObj){
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],TYPE_SETTINGS_SYNC);
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],toMod);
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["changed"],changedObj);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}

/* Subs */
integer subs_has(string mod,string prefix){ integer i; integer n=llGetListLength(Subs); for (i=0;i<n;i+=SUBS_STRIDE) if (llList2String(Subs,i)==mod && llList2String(Subs,i+1)==prefix) return TRUE; return FALSE; }
integer subs_add(string mod,string prefix){ Subs += [mod,prefix]; return TRUE; }
integer subs_remove(string mod,string prefix){ integer i; integer n=llGetListLength(Subs); for (i=0;i<n;i+=SUBS_STRIDE) if (llList2String(Subs,i)==mod && llList2String(Subs,i+1)==prefix){ Subs=llDeleteSubList(Subs,i,i+1); return TRUE; } return FALSE; }

/* Deliver coalesced diffs */
integer deliver_sync(list changedPaths){
    string changedObj=llList2Json(JSON_OBJECT,[]);
    integer i; integer n=llGetListLength(changedPaths);
    for (i=0;i<n;i++){
        string pathStr=llList2String(changedPaths,i);
        list tup=store_get_tuple(pathStr);
        if (llGetListLength(tup)>0) changedObj=llJsonSetValue(changedObj,[pathStr], llList2String(tup,2));
        else changedObj=llJsonSetValue(changedObj,[pathStr], JSON_NULL);
    }
    /* Per-subscriber filtered syncs */
    integer si; integer sn=llGetListLength(Subs);
    for (si=0;si<sn;si+=SUBS_STRIDE){
        string mod=llList2String(Subs,si);
        string pref=llList2String(Subs,si+1);
        string subObj=llList2Json(JSON_OBJECT,[]); integer any=FALSE;
        for (i=0;i<n;i++){
            string p2=llList2String(changedPaths,i);
            if (starts_with(p2,pref)){ any=TRUE; subObj=llJsonSetValue(subObj,[p2], llJsonGetValue(changedObj,[p2])); }
        }
        if (any) send_sync_to(mod, subObj);
    }
    /* Broadcast to 'any' */
    string j=llList2Json(JSON_OBJECT,[]);
    j=llJsonSetValue(j,["type"],TYPE_SETTINGS_SYNC);
    j=llJsonSetValue(j,["from"],"settings");
    j=llJsonSetValue(j,["to"],"any");
    j=llJsonSetValue(j,["abi"],(string)ABI_VERSION);
    j=llJsonSetValue(j,["changed"],changedObj);
    llMessageLinked(LINK_SET,L_API,j,NULL_KEY); return TRUE;
}

/* Defaults */
integer seed_defaults(){
    list defs=[
        "core.owner.key",VTYPE_UUID,JSON_NULL,
        "core.self.owned",VTYPE_INT,"1",
        "core.public.mode",VTYPE_INT,"0",
        "core.restricted.mode",VTYPE_INT,"0",
        "core.locked",VTYPE_INT,"0",
        "core.rlv.enabled",VTYPE_INT,"0",
        "core.rlv.accepttp.enabled",VTYPE_INT,"1",
        "core.runtime.heartbeat",VTYPE_INT,(string)now()
    ];
    integer i; integer n=llGetListLength(defs);
    for (i=0;i<n;i+=3) store_put(llList2String(defs,i),llList2String(defs,i+1),llList2String(defs,i+2));
    return TRUE;
}

/* === Mutators === */
/* Normal (single op): ACK + optional SYNC */
integer handle_put(string fromMod,string reqId,string pathStr,string vtypeStr,string rawVal){
    pathStr=lc(pathStr);
    if (!can_write_path(fromMod,pathStr)){ send_error(fromMod,reqId,"E_DENIED","no write"); return FALSE; }
    list vv=validate_value(vtypeStr,rawVal);
    if (!llList2Integer(vv,0)){ send_error(fromMod,reqId,"E_TYPE",llList2String(vv,2)); return FALSE; }
    integer rc=store_put(pathStr,vtypeStr,llList2String(vv,1));
    integer rev=0; integer idx=store_index(pathStr); if (idx!=-1) rev=llList2Integer(Store,idx+3);
    send_ack(fromMod,reqId,pathStr,TRUE,(rc==1),rev);
    if (rc==1 && !is_volatile_path(pathStr)) deliver_sync([pathStr]);
    return TRUE;
}
integer handle_del(string fromMod,string reqId,string pathStr){
    pathStr=lc(pathStr); integer rc=store_del(pathStr);
    send_ack(fromMod,reqId,pathStr,TRUE,rc,0);
    if (rc && !is_volatile_path(pathStr)) deliver_sync([pathStr]);
    return TRUE;
}

/* Silent (batch): NO ack, NO sync; just mutate and say if changed */
integer put_silent(string fromMod,string pathStr,string vtypeStr,string rawVal){
    pathStr=lc(pathStr);
    if (!can_write_path(fromMod,pathStr)) return -2; /* denied */
    list vv=validate_value(vtypeStr,rawVal);
    if (!llList2Integer(vv,0)) return -3;          /* type error */
    integer beforeRev=-1; integer idxb=store_index(pathStr); if (idxb!=-1) beforeRev=llList2Integer(Store,idxb+3);
    integer rc=store_put(pathStr,vtypeStr,llList2String(vv,1));
    integer idxa=store_index(pathStr); integer afterRev=-1; if (idxa!=-1) afterRev=llList2Integer(Store,idxa+3);
    if (rc==-1) return -1;                          /* store full */
    if (afterRev!=beforeRev) return 1;              /* changed */
    return 0;                                       /* no change */
}
integer del_silent(string fromMod,string pathStr){
    pathStr=lc(pathStr);
    if (!can_write_path(fromMod,pathStr)) return -2;
    integer had=(store_index(pathStr)!=-1);
    integer rc=store_del(pathStr);
    if (rc && had) return 1;
    return 0;
}

default{
    state_entry(){
        Store=[]; Subs=[]; seed_defaults();
        logd("Settings ready (headless).");
    }
    on_rez(integer s){ llResetScript(); }
    changed(integer c){ if (c & CHANGED_OWNER) llResetScript(); }

    link_message(integer src, integer lane, string msg, key id){
        if (lane!=L_API) return;
        string toMod = llJsonGetValue(msg,["to"]); if (toMod!="settings") return;

        integer abi = (integer)llJsonGetValue(msg, ["abi"]);
        if (abi != 0 && abi != ABI_VERSION) return;

        string typeStr=llJsonGetValue(msg,["type"]);
        string fromMod=llJsonGetValue(msg,["from"]);
        string reqId  =llJsonGetValue(msg,["req_id"]);

        if (typeStr==TYPE_SETTINGS_PUT){
            handle_put(fromMod,reqId,
                llJsonGetValue(msg,["path"]),
                llJsonGetValue(msg,["vtype"]),
                llJsonGetValue(msg,["value"])
            ); return;
        }
        if (typeStr==TYPE_SETTINGS_DEL){
            handle_del(fromMod,reqId,
                llJsonGetValue(msg,["path"])
            ); return;
        }
        if (typeStr==TYPE_SETTINGS_GET){
            list outPaths=[]; string arr=llJsonGetValue(msg,["paths"]);
            if (arr!=JSON_INVALID){
                integer i; integer done=FALSE;
                while(!done){
                    string pth=llJsonGetValue(arr,[(string)i]);
                    if (pth==JSON_INVALID) done=TRUE; else { outPaths+=lc(pth); i++; }
                }
            }
            send_snapshot(fromMod,reqId,outPaths); return;
        }
        if (typeStr==TYPE_SETTINGS_BATCH){
            integer i2=0; integer count=0; integer done2=FALSE;
            list changedPaths=[];
            while(!done2){
                string op=llJsonGetValue(msg,["ops",(string)i2,"op"]);
                if (op==JSON_INVALID){ done2=TRUE; }
                else {
                    count++; if (count>MAX_BATCH_OPS){ send_error(fromMod,reqId,"E_LIMIT","too many ops"); return; }
                    string pth=llJsonGetValue(msg,["ops",(string)i2,"path"]);
                    if (op=="put"){
                        string vt=llJsonGetValue(msg,["ops",(string)i2,"vtype"]);
                        string raw=llJsonGetValue(msg,["ops",(string)i2,"value"]);
                        integer ch=put_silent(fromMod,pth,vt,raw);
                        if (ch<0){ /* surface a single error */
                            if (ch==-2) send_error(fromMod,reqId,"E_DENIED","no write");
                            else if (ch==-3) send_error(fromMod,reqId,"E_TYPE","bad value");
                            else send_error(fromMod,reqId,"E_LIMIT","store full");
                            return;
                        }
                        if (ch==1 && !is_volatile_path(lc(pth))) changedPaths+=lc(pth);
                    } else if (op=="del"){
                        integer ch2=del_silent(fromMod,pth);
                        if (ch2<0){ send_error(fromMod,reqId,"E_DENIED","no delete"); return; }
                        if (ch2==1 && !is_volatile_path(lc(pth))) changedPaths+=lc(pth);
                    } else {
                        send_error(fromMod,reqId,"E_BADREQ","bad op"); return;
                    }
                    i2++;
                }
            }
            /* Single ACK and coalesced SYNC (if anything changed) */
            send_ack(fromMod,reqId,"batch",TRUE,(llGetListLength(changedPaths)>0),0);
            if (llGetListLength(changedPaths)>0) deliver_sync(changedPaths);
            return;
        }
        if (typeStr==TYPE_SETTINGS_SUB){
            string pref=llJsonGetValue(msg,["prefix"]);
            if (pref==JSON_INVALID || pref==""){ send_error(fromMod,reqId,"E_BADREQ","missing prefix"); return; }
            if (llGetSubString(pref,-1,-1)!=".") pref+=".";
            if (!can_subscribe_prefix(fromMod,pref)){ send_error(fromMod,reqId,"E_DENIED","sub not allowed"); return; }
            if (subs_has(fromMod,pref)){ send_ack(fromMod,reqId,"sub",TRUE,0,0); return; }
            /* capacity checks */
            integer subsTotal = llGetListLength(Subs)/SUBS_STRIDE;
            integer subsForCaller = 0;
            integer j; integer jn=llGetListLength(Subs);
            for (j=0;j<jn;j+=SUBS_STRIDE) if (llList2String(Subs,j)==fromMod) subsForCaller++;
            if (subsForCaller>=MAX_SUBS_PER_CALLER){ send_error(fromMod,reqId,"E_LIMIT","per-caller sub cap"); return; }
            if (subsTotal>=MAX_SUBS_TOTAL){ send_error(fromMod,reqId,"E_LIMIT","global sub cap"); return; }
            Subs += [fromMod,pref]; send_ack(fromMod,reqId,"sub",TRUE,1,0); if (DEBUG) llOwnerSay("[SETTINGS] Sub "+fromMod+" ← "+pref); return;
        }
        if (typeStr==TYPE_SETTINGS_UNSUB){
            string pref2=llJsonGetValue(msg,["prefix"]);
            if (pref2==JSON_INVALID || pref2==""){ send_error(fromMod,reqId,"E_BADREQ","missing prefix"); return; }
            if (llGetSubString(pref2,-1,-1)!=".") pref2+=".";
            integer had=subs_remove(fromMod,pref2);
            send_ack(fromMod,reqId,"unsub",TRUE,had,0); if (DEBUG) llOwnerSay("[SETTINGS] Unsub "+fromMod+" ← "+pref2); return;
        }
        /* Unknown -> error */
        send_error(fromMod,reqId,"E_BADREQ","unknown type");
    }
}
