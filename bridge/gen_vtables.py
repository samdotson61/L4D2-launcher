#!/usr/bin/env python3
"""
gen_vtables.py — parse Steamworks SDK headers and emit C vtable arrays
matching the correct __thiscall arg count for every method.

The output goes into steam_api_wine.c. For each method, we emit either:
- A reference to a real implementation (e.g., user_GetSteamID), if listed in REAL_IMPLS
- A stub_N reference, where N = total arg bytes / 4

Pointer / reference args are 4 bytes. Integral types are mostly 4 bytes; 64-bit
ints, CSteamID, CGameID etc. are 8 bytes. Methods returning structs by value
(CSteamID, CGameID, very rare) on MSVC x86 use a hidden first arg pointer,
so we add 4 bytes for those.
"""

import re
import sys
import os

# Byte size of arg types. Anything not listed defaults to 4 (int/enum/handle).
TYPE_SIZE = {
    'void': 0,
    # 32-bit ish
    'bool': 4, 'char': 4, 'unsigned char': 4, 'uint8': 4, 'int8': 4,
    'short': 4, 'unsigned short': 4, 'uint16': 4, 'int16': 4,
    'int': 4, 'unsigned int': 4, 'uint32': 4, 'int32': 4,
    'long': 4, 'unsigned long': 4, 'DWORD': 4, 'WORD': 4, 'BYTE': 4,
    'float': 4,
    'size_t': 4,
    # 64-bit
    'long long': 8, 'unsigned long long': 8,
    'uint64': 8, 'int64': 8, 'double': 8,
    'CSteamID': 8, 'CGameID': 8,
    'SteamAPICall_t': 8,
    'PublishedFileId_t': 8, 'PublishedFileUpdateHandle_t': 8, 'UGCHandle_t': 8,
    'UGCFileWriteStreamHandle_t': 8,
    'UGCQueryHandle_t': 8, 'UGCUpdateHandle_t': 8,
    'SteamLeaderboard_t': 8, 'SteamLeaderboardEntries_t': 8,
    'SteamInventoryUpdateHandle_t': 8,
    'PartyBeaconID_t': 8, 'SteamItemInstanceID_t': 8,
    'HTTPRequestHandle': 4, 'HTTPCookieContainerHandle': 4,
    'HHTMLBrowser': 4,
    'ControllerHandle_t': 8, 'ControllerActionSetHandle_t': 8,
    'ControllerDigitalActionHandle_t': 8, 'ControllerAnalogActionHandle_t': 8,
    'InputHandle_t': 8, 'InputActionSetHandle_t': 8,
    'InputDigitalActionHandle_t': 8, 'InputAnalogActionHandle_t': 8,
    'HServerListRequest': 4,
    'HServerQuery': 4,
}

# Types that, when returned by value, use the hidden-pointer ABI on MSVC x86.
STRUCT_RETURN_TYPES = {'CSteamID', 'CGameID', 'SteamIPAddress_t'}

# Methods we have real RPC-backed implementations for — referenced by their
# expected SDK name. These names map to the C function in steam_api_wine.c.
REAL_IMPLS = {
    # ISteamUser
    'GetHSteamUser': 'user_GetHSteamUser',
    'BLoggedOn':     'user_BLoggedOn',
    'GetSteamID':    'user_GetSteamID',
    # Auth ticket triplet — re-enabled with steam_api.dll pinning workaround.
    # Previous attempt crashed after the auth flow because engine.dll's IAT
    # slot for SteamAPI_RunCallbacks was being zeroed (suspected: FreeLibrary
    # path triggered by Source DRM or matchmaking defensive cleanup).  Now
    # that DllMain holds 3 extra references to ourselves, the OS refcount
    # never reaches 0, the unload path never fires, and the IAT stays valid.
    'GetAuthSessionTicket':  'user_GetAuthSessionTicket',
    'BeginAuthSession':      'user_BeginAuthSession',
    'EndAuthSession':        'user_EndAuthSession',
    'CancelAuthTicket':      'user_CancelAuthTicket',
    # ISteamApps
    'BIsSubscribed':            'apps_BIsSubscribed',
    'BIsSubscribedApp':         'apps_BIsSubscribedApp',
    'GetCurrentGameLanguage':   'apps_GetCurrentGameLanguage',
    'GetAppBuildId':            'apps_GetAppBuildId',
    # ISteamUtils
    'GetAppID':                'utils_GetAppID',
    'GetSteamUILanguage':      'utils_GetSteamUILanguage',
    # IsAPICallCompleted + GetAPICallResult are critical: engine.dll has a
    # BlockingCall pattern that wait-loops on these for CheckFileSignature
    # (Source DRM file-integrity check).  Stub_3 returning 0 causes the loop
    # to enter and read the IAT slot for SteamAPI_RunCallbacks into EBX —
    # which crashes if any matchmaking-path side-effect has zeroed the slot.
    # Returning TRUE (completed) bypasses the loop entirely.
    'IsAPICallCompleted':      'utils_IsAPICallCompleted',
    'GetAPICallResult':        'utils_GetAPICallResult',
    'CheckFileSignature':      'utils_CheckFileSignature',
    'GetConnectedUniverse':    'utils_GetConnectedUniverse',
    'GetServerRealTime':       'utils_GetServerRealTime',
    'IsOverlayEnabled':        'utils_IsOverlayEnabled',
    # ISteamNetworking P2P — required for lobby-host connection after JoinLobby.
    'SendP2PPacket':                'net_SendP2PPacket',
    'IsP2PPacketAvailable':         'net_IsP2PPacketAvailable',
    'ReadP2PPacket':                'net_ReadP2PPacket',
    'AcceptP2PSessionWithUser':     'net_AcceptP2PSessionWithUser',
    'CloseP2PSessionWithUser':      'net_CloseP2PSessionWithUser',
    'CloseP2PChannelWithUser':      'net_CloseP2PChannelWithUser',
    'GetP2PSessionState':           'net_GetP2PSessionState',
    'AllowP2PPacketRelay':          'net_AllowP2PPacketRelay',
    # ISteamMatchmakingServers — server browser; game uses for finding
    # active dedicated/listen servers during matchmaking fallback path.
    'RequestInternetServerList':    'mms_RequestInternetServerList',
    'RequestLANServerList':         'mms_RequestLANServerList',
    'RequestFriendsServerList':     'mms_RequestFriendsServerList',
    'RequestFavoritesServerList':   'mms_RequestFavoritesServerList',
    'RequestHistoryServerList':     'mms_RequestHistoryServerList',
    'RequestSpectatorServerList':   'mms_RequestSpectatorServerList',
    'ReleaseRequest':               'mms_ReleaseRequest',
    'GetServerDetails':             'mms_GetServerDetails',
    'CancelQuery':                  'mms_CancelQuery',
    'RefreshQuery':                 'mms_RefreshQuery',
    'IsRefreshing':                 'mms_IsRefreshing',
    'GetServerCount':               'mms_GetServerCount',
    'RefreshServer':                'mms_RefreshServer',
    # ISteamFriends
    'GetPersonaName':              'friends_GetPersonaName',
    'GetFriendPersonaName':        'friends_GetFriendPersonaName',
    'RequestUserInformation':      'friends_RequestUserInformation',
    'GetFriendPersonaState':       'friends_GetFriendPersonaState',
    # ISteamMatchmaking — re-enabled 2026-05-24 with lazy helper-side init
    # (only acquires SteamMatchMaking009 on first OP_MM_REQUESTLOBBYLIST)
    # + matchmaking callback gate in steam_api_wine.c (drops ids 500-599
    # until the first matchmaking RPC opens the gate).  Async results
    # (RequestLobbyList / CreateLobby / JoinLobby return SteamAPICall_t)
    # are now properly routed via the call-result drain path (id 703
    # → SteamAPICallCompleted_t → GetAPICallResult → cr_fire by hAPICall).
    'RequestLobbyList':                          'mm_RequestLobbyList',
    'CreateLobby':                               'mm_CreateLobby',
    'JoinLobby':                                 'mm_JoinLobby',
    'LeaveLobby':                                'mm_LeaveLobby',
    'GetLobbyByIndex':                           'mm_GetLobbyByIndex',
    'GetNumLobbyMembers':                        'mm_GetNumLobbyMembers',
    'GetLobbyMemberByIndex':                     'mm_GetLobbyMemberByIndex',
    'GetLobbyOwner':                             'mm_GetLobbyOwner',
    'GetLobbyData':                              'mm_GetLobbyData',
    'SetLobbyData':                              'mm_SetLobbyData',
    'GetLobbyDataCount':                         'mm_GetLobbyDataCount',
    'GetLobbyDataByIndex':                       'mm_GetLobbyDataByIndex',
    'GetLobbyMemberLimit':                       'mm_GetLobbyMemberLimit',
    'SetLobbyMemberLimit':                       'mm_SetLobbyMemberLimit',
    'SetLobbyJoinable':                          'mm_SetLobbyJoinable',
    'SetLobbyType':                              'mm_SetLobbyType',
    'RequestLobbyData':                          'mm_RequestLobbyData',
    'GetLobbyGameServer':                        'mm_GetLobbyGameServer',
    'SetLobbyGameServer':                        'mm_SetLobbyGameServer',
    'AddRequestLobbyListStringFilter':           'mm_AddRequestLobbyListStringFilter',
    'AddRequestLobbyListNumericalFilter':        'mm_AddRequestLobbyListNumericalFilter',
    'AddRequestLobbyListNearValueFilter':        'mm_AddRequestLobbyListNearValueFilter',
    'AddRequestLobbyListFilterSlotsAvailable':   'mm_AddRequestLobbyListFilterSlotsAvailable',
    'AddRequestLobbyListDistanceFilter':         'mm_AddRequestLobbyListDistanceFilter',
    'AddRequestLobbyListResultCountFilter':      'mm_AddRequestLobbyListResultCountFilter',
    # ISteamClient interface getters — these return our singleton interfaces.
    # Without these, engine.dll's pClient->GetISteamX() calls get NULL.
    'CreateSteamPipe':              'client_CreateSteamPipe',
    'BReleaseSteamPipe':            'client_BReleaseSteamPipe',
    'ConnectToGlobalUser':          'client_ConnectToGlobalUser',
    'CreateLocalUser':              'client_CreateLocalUser',
    'GetISteamUser':                'client_GetISteamUser',
    'GetISteamGameServer':          'client_GetISteamGameServer',
    'GetISteamFriends':             'client_GetISteamFriends',
    'GetISteamUtils':               'client_GetISteamUtils',
    'GetISteamMatchmaking':         'client_GetISteamMatchmaking',
    'GetISteamMatchmakingServers':  'client_GetISteamMatchmakingServers',
    'GetISteamGenericInterface':    'client_GetISteamGenericInterface',
    'GetISteamUserStats':           'client_GetISteamUserStats',
    'GetISteamGameServerStats':     'client_GetISteamGameServerStats',
    'GetISteamApps':                'client_GetISteamApps',
    'GetISteamNetworking':          'client_GetISteamNetworking',
    'GetISteamRemoteStorage':       'client_GetISteamRemoteStorage',
    'GetISteamScreenshots':         'client_GetISteamScreenshots',
    'GetISteamGameSearch':          'client_GetISteamGameSearch',
    'GetISteamHTTP':                'client_GetISteamHTTP',
    'GetISteamController':          'client_GetISteamController',
    'GetISteamUGC':                 'client_GetISteamUGC',
    'GetISteamAppList':             'client_GetISteamAppList',
    'GetISteamMusic':               'client_GetISteamMusic',
    'GetISteamMusicRemote':         'client_GetISteamMusicRemote',
    'GetISteamHTMLSurface':         'client_GetISteamHTMLSurface',
    'GetISteamInventory':           'client_GetISteamInventory',
    'GetISteamVideo':               'client_GetISteamVideo',
    'GetISteamParentalSettings':    'client_GetISteamParentalSettings',
    'GetISteamInput':               'client_GetISteamInput',
    'GetISteamParties':             'client_GetISteamParties',
    'GetISteamRemotePlay':          'client_GetISteamRemotePlay',
}

# Per-interface header + class name. All headers come from Steamworks SDK
# 1.53a — the rev whose interface versions (SteamClient020, SteamUser021,
# SteamFriends017, SteamInput006, …) match L4D2's compiled binary exactly,
# as confirmed by grepping the L4D2 DLLs for interface-version strings.
INTERFACES = [
    # (output_var, header_file, class_name, padding_extra_entries)
    ('vt_client',            'isteamclient.h',              'ISteamClient',           20),
    ('vt_user',              'isteamuser.h',                'ISteamUser',             20),
    ('vt_friends',           'isteamfriends.h',             'ISteamFriends',          30),
    ('vt_utils',             'isteamutils.h',               'ISteamUtils',            20),
    ('vt_matchmaking',       'isteammatchmaking.h',         'ISteamMatchmaking',      20),
    ('vt_matchmakingsrvs',   'isteammatchmaking.h',         'ISteamMatchmakingServers', 10),
    ('vt_userstats',         'isteamuserstats.h',           'ISteamUserStats',        30),
    ('vt_apps',              'isteamapps.h',                'ISteamApps',             20),
    ('vt_networking',        'isteamnetworking.h',          'ISteamNetworking',       20),
    ('vt_remotestorage',     'isteamremotestorage.h',       'ISteamRemoteStorage',    30),
    ('vt_screenshots',       'isteamscreenshots.h',         'ISteamScreenshots',      10),
    ('vt_http',              'isteamhttp.h',                'ISteamHTTP',             20),
    ('vt_controller',        'isteamcontroller.h',          'ISteamController',       30),
    ('vt_ugc',               'isteamugc.h',                 'ISteamUGC',              30),
    ('vt_applist',           'isteamapplist.h',             'ISteamAppList',          10),
    ('vt_music',             'isteammusic.h',               'ISteamMusic',            10),
    ('vt_musicremote',       'isteammusicremote.h',         'ISteamMusicRemote',      10),
    ('vt_htmlsurface',       'isteamhtmlsurface.h',         'ISteamHTMLSurface',      20),
    ('vt_inventory',         'isteaminventory.h',           'ISteamInventory',        20),
    ('vt_video',             'isteamvideo.h',               'ISteamVideo',            10),
    ('vt_parental',          'isteamparentalsettings.h',    'ISteamParentalSettings', 10),
    ('vt_input',             'isteaminput.h',               'ISteamInput',            30),
    # Added in Steamworks 1.60. L4D2 asks for STEAMTIMELINE_INTERFACE_V001;
    # without it, we returned an ISteamUtils-shaped pointer and the game
    # crashed in a downstream callback chain.
    ('vt_timeline',          'isteamtimeline.h',            'ISteamTimeline',         10),
    ('vt_gameserver',        'isteamgameserver.h',          'ISteamGameServer',       20),
    ('vt_gameserverstats',   'isteamgameserverstats.h',     'ISteamGameServerStats',  10),
    ('vt_appticket',         'isteamappticket.h',           'ISteamAppTicket',        5),
]

def arg_bytes(arg_type):
    arg_type = arg_type.strip()
    # Strip leading const
    arg_type = re.sub(r'^\s*const\s+', '', arg_type)
    # Pointers and references are always 4 bytes on i386.
    if '*' in arg_type or '&' in arg_type:
        return 4
    # Direct lookup.
    if arg_type in TYPE_SIZE:
        return TYPE_SIZE[arg_type]
    # Enum, handle, opaque — assume 4 bytes.
    return 4

def parse_method(decl):
    """Parse 'virtual <ret> <name>( <args> ) [const] = 0;' → (name, ret, args_byte_total)."""
    # Normalise `type *name` and `type* name` to `type * name` so the regex
    # doesn't mistakenly consume the `*` as part of the method name.
    decl = re.sub(r'\s*\*\s*', ' * ', decl)
    # Search (not match) so leading 'public:' / whitespace / preceding text doesn't anchor-fail.
    m = re.search(
        r'virtual\s+'
        r'((?:[\w:]+\s+|\*\s+)+)'  # return type tokens (including `*`)
        r'(\w+)\s*'                # name
        r'\(\s*(.*?)\s*\)\s*'      # args
        r'(?:const\s*)?'
        r'(?:override\s*)?'
        r'=\s*0\s*;',
        decl, re.DOTALL)
    if not m:
        return None
    ret_type, name, args_str = m.group(1).strip(), m.group(2), m.group(3)
    # Parse args.
    args = []
    if args_str:
        # Split by comma; ignore nested parens (function-pointer args — rare).
        depth = 0; cur = []
        for ch in args_str:
            if ch == '(': depth += 1
            elif ch == ')': depth -= 1
            if ch == ',' and depth == 0:
                args.append(''.join(cur).strip()); cur = []
            else:
                cur.append(ch)
        if cur and ''.join(cur).strip():
            args.append(''.join(cur).strip())
    # Skip default values.
    args = [a.split('=')[0].strip() for a in args]
    # Each arg: "type name" — extract type (everything except last word if last
    # word is plain identifier without *).
    arg_types = []
    for a in args:
        if not a: continue
        # If looks like a function pointer (e.g., "void (*)(int)"), call it 4 bytes.
        if '(' in a and '*' in a:
            arg_types.append('PTR')
            continue
        # Strip trailing array specifier like "[8]".
        a = re.sub(r'\[[^\]]*\]', '', a)
        # Last token = name, rest = type (unless single token like "int").
        tokens = a.split()
        if len(tokens) >= 2 and re.match(r'^\w+$', tokens[-1]):
            t = ' '.join(tokens[:-1])
        else:
            t = a
        arg_types.append(t)
    total = sum(arg_bytes(t) for t in arg_types)
    # Struct-by-value return uses hidden first pointer arg on MSVC x86.
    ret_clean = re.sub(r'^\s*const\s+', '', ret_type).strip()
    if ret_clean in STRUCT_RETURN_TYPES and '*' not in ret_type and '&' not in ret_type:
        total += 4
    return (name, ret_clean, total, arg_types)

def parse_class(header_path, class_name):
    if not os.path.exists(header_path):
        return None
    with open(header_path, encoding='latin-1') as f:
        text = f.read()
    # Strip block comments.
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    # Strip line comments.
    text = re.sub(r'//[^\n]*', '', text)
    # Class names in versioned headers may have a version suffix
    # (e.g. ISteamClient → ISteamClient019). Match either form.
    cre = re.compile(
        rf'\bclass\s+(?:S_CALLTYPE\s+)?{re.escape(class_name)}\d*\b[^{{]*\{{(.*?)\}}\s*;',
        re.DOTALL)
    m = cre.search(text)
    if not m:
        return None
    body = m.group(1)
    # Find every `virtual ... = 0;` statement.
    methods = []
    # Loose state machine to capture multi-line declarations.
    for stmt in re.split(r';\s*', body):
        stmt = stmt.strip()
        if 'virtual' not in stmt: continue
        if '=' not in stmt: continue
        if '= 0' not in stmt and '=0' not in stmt: continue
        m = parse_method(stmt + ';')
        if m:
            methods.append(m)
    return methods

# Per-vtable method overrides — take precedence over REAL_IMPLS for the
# specific (var_name, method_name) pair.  Used when the same method name
# means different things on different interfaces.  Example: ISteamGameServer's
# BeginAuthSession needs to route through ISteamGameServer on Mac (gs_*),
# not ISteamUser (user_*) — otherwise Mac rejects server-issued tickets
# with the user-side validator → "STEAM validation rejected" disconnect.
PER_VTABLE_IMPLS = {
    'vt_gameserver': {
        'BeginAuthSession': 'gs_BeginAuthSession',
        'EndAuthSession':   'gs_EndAuthSession',
    },
}

def emit_vtable(var_name, methods, padding):
    overrides = PER_VTABLE_IMPLS.get(var_name, {})
    out = []
    out.append(f"static void* const {var_name}[] = {{")
    for i, (name, ret, total, arg_types) in enumerate(methods):
        slots = total // 4
        if name in overrides:
            entry = f"(void*){overrides[name]}"
        elif name in REAL_IMPLS:
            entry = f"(void*){REAL_IMPLS[name]}"
        elif 'char' in ret and ('*' in ret):
            # Method returns const char* / char*. Use a stub that returns
            # a valid empty string instead of NULL — otherwise engine.dll
            # tries to deref a NULL string pointer.
            entry = f"(void*)stub_str_{slots}"
        else:
            entry = f"(void*)stub_{slots}"
        out.append(f"    /* {i:3d} {name:48s} args={total:3d}B ret={ret:20s} */ {entry},")
    # Padding.
    for i in range(padding):
        out.append(f"    /* {len(methods)+i:3d} <padding {i:2d}> */ (void*)stub_0,")
    out.append("};")
    return '\n'.join(out)

def main():
    sdk_dir = '/Users/samdotson/L4D2-launcher/bridge/sdk'
    blocks = []
    needed_stub_sizes = set()
    for var, header, cls, pad in INTERFACES:
        path = os.path.join(sdk_dir, header)
        methods = parse_class(path, cls)
        if methods is None:
            print(f"// WARNING: failed to parse {cls} from {header}", file=sys.stderr)
            blocks.append(f"// MISSING: {var} (couldn't parse {cls} from {header})")
            continue
        for _, _, total, _ in methods:
            needed_stub_sizes.add(total // 4)
        for _ in range(pad): needed_stub_sizes.add(0)
        block = f"// ── {cls} ({header}) — {len(methods)} methods + {pad} padding ───────────────\n"
        block += emit_vtable(var, methods, pad)
        blocks.append(block)
    # Emit required-stub-size summary so we can ensure we have stub_N for every N used.
    print("// Auto-generated by gen_vtables.py — DO NOT EDIT BY HAND.")
    print("// Stubs needed:", sorted(needed_stub_sizes))
    print()
    print("\n\n".join(blocks))

if __name__ == '__main__':
    main()
