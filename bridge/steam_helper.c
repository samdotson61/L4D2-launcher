// steam_helper.c — native macOS arm64 process that loads libsteam_api.dylib
// and exposes it over a TCP socket so a Wine-side stub steam_api.dll can
// forward SteamAPI_Init() and a small set of interface methods to the
// running Mac Steam (steam_osx). User authentication, ticket signing, and
// IPC to Steam happen on the macOS side — Wine never touches them.
//
// Protocol (binary, little-endian, length-prefixed):
//   request:  [u32 op] [u32 arg_len] [arg bytes]
//   response: [u32 status (0=ok, !=0=err)] [u32 ret_len] [return bytes]
//
// Build:
//   clang -arch arm64 -o steam_helper steam_helper.c
//
// Run:
//   SteamAppId=550 ./steam_helper [port]

#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>

#define DEFAULT_PORT 54550
#define DYLIB_PATH "/Users/samdotson/Library/Application Support/Steam/steamapps/common/Left 4 Dead 2/bin/libsteam_api.dylib"

// ─── Debug logging gate ──────────────────────────────────────────────────────
// hlog() is the verbose per-op/per-callback trace; gated behind the
// L4D2_HELPER_DEBUG=1 environment variable (checked once at startup) so the
// normal run is quiet.  Genuine startup errors still use fprintf(stderr,…)
// directly and always print regardless of this flag.
static int g_helper_debug = 0;
__attribute__((format(printf, 1, 2)))
static void hlog(const char *fmt, ...) {
    if (!g_helper_debug) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

// ─── Opcodes ─────────────────────────────────────────────────────────────────
enum {
    OP_PING                  = 0x0001,
    OP_INIT                  = 0x0010,  // SteamAPI_Init() -> u32
    OP_IS_STEAM_RUNNING      = 0x0011,  // -> u32
    OP_GET_HSTEAMUSER        = 0x0012,  // -> u32
    OP_GET_HSTEAMPIPE        = 0x0013,  // -> u32
    OP_SHUTDOWN              = 0x0014,  // -> void

    // ISteamUser
    OP_USER_GETSTEAMID       = 0x0100,  // -> u64
    OP_USER_BLOGGEDON        = 0x0101,  // -> u32
    OP_USER_GETPLAYERSTEAMLEVEL = 0x0102,  // -> u32

    // ISteamApps
    OP_APPS_BISSUBSCRIBED    = 0x0200,  // -> u32
    OP_APPS_BISSUBSCRIBEDAPP = 0x0201,  // arg: u32 appid -> u32
    OP_APPS_GETCURRENTGAMELANG = 0x0202, // -> string
    OP_APPS_GETAPPBUILDID    = 0x0203,  // -> u32

    // ISteamUtils
    OP_UTILS_GETAPPID        = 0x0300,  // -> u32
    OP_UTILS_GETSTEAMUILANG  = 0x0301,  // -> string
    OP_UTILS_GETSECONDSSINCEAPPACTIVE = 0x0302, // -> u32
    // Real-Steam proxy for the async-result polling triplet that engine.dll's
    // BlockingCall wrapper uses (drives Source DRM CheckFileSignature path
    // among others).  Instead of synthesizing fake completion responses,
    // forward to native Mac Steam so the real call result lifecycle works.
    OP_UTILS_ISAPICALLCOMPLETED = 0x0303, // arg: u64 hCall -> u32 bCompleted + u32 bFailed
    OP_UTILS_GETAPICALLRESULT   = 0x0304, // arg: u64 hCall + u32 cb + u32 expCb -> u32 ok + u32 bFailed + bytes
    OP_UTILS_CHECKFILESIGNATURE = 0x0305, // arg: char* filename -> u64 hCall
    OP_UTILS_GETCONNECTEDUNIVERSE = 0x0306, // -> u32
    OP_UTILS_GETSERVERREALTIME    = 0x0307, // -> u32
    OP_UTILS_ISOVERLAYENABLED     = 0x0308, // -> u32 bool

    // ISteamNetworking — P2P session lifecycle for lobby/server connect.
    // Without these, the game's "establishing connection" stalls into
    // corrupt state and the next callback hits the bad pointer.
    OP_NET_SENDP2PPACKET                 = 0x0600, // u64 sid + u32 cb + u32 eP2PSend + u32 chan + data -> u32 bool
    OP_NET_ISP2PPACKETAVAILABLE          = 0x0601, // u32 chan -> u32 bool + u32 cubMsgSize
    OP_NET_READP2PPACKET                 = 0x0602, // u32 cubDest + u32 chan -> u32 bool + u32 cubMsgSize + u64 sid + data
    OP_NET_ACCEPTP2PSESSIONWITHUSER      = 0x0603, // u64 sid -> u32 bool
    OP_NET_CLOSEP2PSESSIONWITHUSER       = 0x0604, // u64 sid -> u32 bool
    OP_NET_CLOSEP2PCHANNELWITHUSER       = 0x0605, // u64 sid + u32 chan -> u32 bool
    OP_NET_GETP2PSESSIONSTATE            = 0x0606, // u64 sid -> u32 ok + state struct
    OP_NET_ALLOWP2PPACKETRELAY           = 0x0607,

    // ISteamMatchmakingServers — server browser.  Many methods are async
    // but the game also polls — we forward the polls and let real Steam's
    // async machinery run on the Mac side with a no-op response object.
    OP_MMS_REQUESTINTERNETSERVERLIST = 0x0700, // arg: filters key=val list + appid -> u64 hRequest
    OP_MMS_REQUESTLANSERVERLIST      = 0x0701, // arg: u32 appid -> u64 hRequest
    OP_MMS_REQUESTFRIENDSSERVERLIST  = 0x0702,
    OP_MMS_REQUESTFAVORITESSERVERLIST = 0x0703,
    OP_MMS_REQUESTHISTORYSERVERLIST   = 0x0704,
    OP_MMS_REQUESTSPECTATORSERVERLIST = 0x0705,
    OP_MMS_RELEASEREQUEST            = 0x0706, // arg: u64 hRequest
    OP_MMS_GETSERVERDETAILS          = 0x0707, // arg: u64 hRequest + i32 iServer -> 400 bytes
    OP_MMS_CANCELQUERY               = 0x0708, // arg: u64 hRequest
    OP_MMS_REFRESHQUERY              = 0x0709, // arg: u64 hRequest
    OP_MMS_ISREFRESHING              = 0x070A, // arg: u64 hRequest -> u32 bool
    OP_MMS_GETSERVERCOUNT            = 0x070B, // arg: u64 hRequest -> i32 count
    OP_MMS_REFRESHSERVER             = 0x070C, // arg: u64 hRequest + i32 iServer // u32 bAllow -> u32 bool

    // ISteamFriends
    OP_FRIENDS_GETPERSONANAME       = 0x0400, // -> string (local user)
    OP_FRIENDS_GETFRIENDPERSONANAME = 0x0401, // arg: u64 steamID -> string
    OP_FRIENDS_REQUESTUSERINFO      = 0x0402, // arg: u64 steamID + u32 nameOnly -> u32 (bool: 0 already cached)
    OP_FRIENDS_GETFRIENDPERSONASTATE = 0x0403, // arg: u64 -> u32 EPersonaState

    // ISteamUser auth ticket — needed for VAC-secure server connect.
    // GetAuthSessionTicket fills a buffer and returns the ticket handle + size;
    // we deliver GetAuthSessionTicketResponse_t (id 163) async via drain.
    OP_USER_GETAUTHSESSIONTICKET = 0x0103,  // -> u32 handle + u32 sz + bytes
    OP_USER_BEGINAUTHSESSION     = 0x0104,  // arg: u64 steamID + bytes -> u32 result
    // GameServer-side auth: Source listen-server calls SteamGameServer()->BeginAuthSession
    // not SteamUser()->BeginAuthSession.  Mac's libsteam_api exports
    // SteamAPI_ISteamGameServer_BeginAuthSession; we route the request through the
    // gameserver interface (acquired via FindOrCreateGameServerInterface).
    OP_GS_BEGINAUTHSESSION       = 0x0107,  // arg: u64 steamID + bytes -> u32 result
    OP_GS_ENDAUTHSESSION         = 0x0108,  // arg: u64 steamID
    OP_USER_ENDAUTHSESSION       = 0x0105,  // arg: u64 steamID
    OP_USER_CANCELAUTHTICKET     = 0x0106,  // arg: u32 handle

    // ISteamMatchmaking — lobby-based matchmaking. Async ops return a
    // SteamAPICall_t (u64) handle and resolve via the LobbyMatchList_t /
    // LobbyCreated_t / LobbyEnter_t callbacks delivered through OP_DRAIN.
    OP_MM_REQUESTLOBBYLIST                       = 0x0500,
    OP_MM_GETLOBBYBYINDEX                        = 0x0501, // arg: u32 idx -> u64
    OP_MM_CREATELOBBY                            = 0x0502, // arg: u32 type+u32 max -> u64
    OP_MM_JOINLOBBY                              = 0x0503, // arg: u64 lobby -> u64
    OP_MM_LEAVELOBBY                             = 0x0504, // arg: u64 lobby
    OP_MM_GETNUMLOBBYMEMBERS                     = 0x0505, // arg: u64 lobby -> u32
    OP_MM_GETLOBBYMEMBERBYINDEX                  = 0x0506, // arg: u64 lobby+u32 idx -> u64
    OP_MM_GETLOBBYDATA                           = 0x0507, // arg: u64+key -> string
    OP_MM_SETLOBBYDATA                           = 0x0508, // arg: u64+key+val -> u32
    OP_MM_GETLOBBYDATACOUNT                      = 0x0509, // arg: u64 -> u32
    OP_MM_GETLOBBYDATABYINDEX                    = 0x050A, // arg: u64+u32 -> packed key\0val\0
    OP_MM_GETLOBBYMEMBERLIMIT                    = 0x050B, // arg: u64 -> u32
    OP_MM_SETLOBBYMEMBERLIMIT                    = 0x050C, // arg: u64+u32 -> u32
    OP_MM_GETLOBBYOWNER                          = 0x050D, // arg: u64 -> u64
    OP_MM_SETLOBBYJOINABLE                       = 0x050E, // arg: u64+u32 -> u32
    OP_MM_SETLOBBYTYPE                           = 0x050F, // arg: u64+u32 -> u32
    OP_MM_REQUESTLOBBYDATA                       = 0x0510, // arg: u64 -> u32
    OP_MM_GETLOBBYGAMESERVER                     = 0x0511, // arg: u64 -> u32 ip+u16 port+u64 srv+u32 ok
    OP_MM_SETLOBBYGAMESERVER                     = 0x0512, // arg: u64+u32 ip+u16 port+u64
    OP_MM_ADDLOBBYLIST_STRINGFILTER              = 0x0513,
    OP_MM_ADDLOBBYLIST_NUMERICALFILTER           = 0x0514,
    OP_MM_ADDLOBBYLIST_NEARVALUEFILTER           = 0x0515,
    OP_MM_ADDLOBBYLIST_FILTERSLOTSAVAILABLE      = 0x0516,
    OP_MM_ADDLOBBYLIST_DISTANCEFILTER            = 0x0517,
    OP_MM_ADDLOBBYLIST_RESULTCOUNTFILTER         = 0x0518,

    // Callback delivery
    OP_DRAIN_CALLBACKS       = 0xD000,  // -> count:u32 + N*{id:u32, len:u32, data:bytes}

    OP_QUIT                  = 0xFFFF,
};

// ─── Loaded dylib symbols ────────────────────────────────────────────────────
static void *g_dylib = NULL;
static void *g_steam_user = NULL;     // ISteamUser*
static void *g_steam_apps = NULL;     // ISteamApps*
static void *g_steam_utils = NULL;    // ISteamUtils*
static void *g_steam_friends = NULL;  // ISteamFriends*
static void *g_steam_matchmaking = NULL;  // ISteamMatchmaking*
static void *g_steam_gameserver = NULL;   // ISteamGameServer* — for proper
                                          // server-side BeginAuthSession (Source
                                          // listen-server validates via the
                                          // GameServer interface, not User).

static int (*p_SteamAPI_Init)(void);
static int (*p_SteamAPI_IsSteamRunning)(void);
static int (*p_SteamAPI_GetHSteamUser)(void);
static int (*p_SteamAPI_GetHSteamPipe)(void);
static void (*p_SteamAPI_Shutdown)(void);
// SteamUser(), SteamApps() etc. are inline C++ helpers in steam_api.h, not
// dylib exports. Use SteamInternal_FindOrCreateUserInterface / -GameServerInterface
// with the versioned interface name. SteamInternal_ContextInit also works but
// requires laying out a CSteamAPIContext on our side.
static void *(*p_FindOrCreateUser)(int hUser, const char *name);
static void *(*p_FindOrCreateGS)(int hUser, const char *name);

// Flat-C dispatch for individual interface methods (these wrap the C++ virtual
// methods on the SDK side, so we don't have to mess with C++ ABI ourselves).
static uint64_t (*p_User_GetSteamID)(void *self);
static int      (*p_User_BLoggedOn)(void *self);
static int      (*p_User_GetPlayerSteamLevel)(void *self);
static int      (*p_Apps_BIsSubscribed)(void *self);
static int      (*p_Apps_BIsSubscribedApp)(void *self, uint32_t app);
static const char *(*p_Apps_GetCurrentGameLanguage)(void *self);
static int      (*p_Apps_GetAppBuildId)(void *self);
static uint32_t (*p_Utils_GetAppID)(void *self);
static const char *(*p_Utils_GetSteamUILanguage)(void *self);
static uint32_t (*p_Utils_GetSecondsSinceAppActive)(void *self);
static int       (*p_Utils_IsAPICallCompleted)(void *self, uint64_t hCall, int *pbFailed);
static int       (*p_Utils_GetAPICallResult)(void *self, uint64_t hCall, void *pCallback, int cbCallback, int iCallbackExpected, int *pbFailed);
static uint64_t  (*p_Utils_CheckFileSignature)(void *self, const char *szFileName);
static int       (*p_Utils_GetConnectedUniverse)(void *self);
static uint32_t  (*p_Utils_GetServerRealTime)(void *self);
static int       (*p_Utils_IsOverlayEnabled)(void *self);

// ISteamNetworking P2P
static void *g_steam_networking = NULL;

// ISteamMatchmakingServers — server browser
static void *g_steam_mm_servers = NULL;
static void* (*p_MMS_RequestInternetServerList)(void *self, uint32_t iApp, void **ppchFilters, uint32_t nFilters, void *pResponse);
static void* (*p_MMS_RequestLANServerList)(void *self, uint32_t iApp, void *pResponse);
static void* (*p_MMS_RequestFriendsServerList)(void *self, uint32_t iApp, void **ppchFilters, uint32_t nFilters, void *pResponse);
static void* (*p_MMS_RequestFavoritesServerList)(void *self, uint32_t iApp, void **ppchFilters, uint32_t nFilters, void *pResponse);
static void* (*p_MMS_RequestHistoryServerList)(void *self, uint32_t iApp, void **ppchFilters, uint32_t nFilters, void *pResponse);
static void* (*p_MMS_RequestSpectatorServerList)(void *self, uint32_t iApp, void **ppchFilters, uint32_t nFilters, void *pResponse);
static void  (*p_MMS_ReleaseRequest)(void *self, void *hRequest);
static void* (*p_MMS_GetServerDetails)(void *self, void *hRequest, int iServer);
static void  (*p_MMS_CancelQuery)(void *self, void *hRequest);
static void  (*p_MMS_RefreshQuery)(void *self, void *hRequest);
static int   (*p_MMS_IsRefreshing)(void *self, void *hRequest);
static int   (*p_MMS_GetServerCount)(void *self, void *hRequest);
static void  (*p_MMS_RefreshServer)(void *self, void *hRequest, int iServer);

// Dummy ISteamMatchmakingServerListResponse — real Steam calls into this
// when servers respond.  We don't relay events to the bridge (game polls
// GetServerCount/GetServerDetails directly), so the methods are no-ops.
// Vtable order must match SDK 1.53a:
//   vt[0] ServerResponded(self, hReq, iServer)
//   vt[1] ServerFailedToRespond(self, hReq, iServer)
//   vt[2] RefreshComplete(self, hReq, eMatchMakingServerResponse)
static void noop_ServerResponded(void *self, void *hReq, int iServer) {
    (void)self; (void)hReq;
    hlog("[helper] noop_ServerResponded: iServer=%d\n", iServer);
}
static void noop_ServerFailedToRespond(void *self, void *hReq, int iServer) {
    (void)self; (void)hReq; (void)iServer;
}
static void noop_RefreshComplete(void *self, void *hReq, int response) {
    (void)self; (void)hReq;
    hlog("[helper] noop_RefreshComplete: response=%d\n", response);
}
static void *g_noop_serverlist_response_vtable[] = {
    (void*)noop_ServerResponded,
    (void*)noop_ServerFailedToRespond,
    (void*)noop_RefreshComplete,
};
static struct { void **vtable; } g_noop_serverlist_response = {
    .vtable = (void**)&g_noop_serverlist_response_vtable
};
static int       (*p_Net_SendP2PPacket)(void *self, uint64_t sid, const void *pubData, uint32_t cubData, int eP2PSend, int channel);
static int       (*p_Net_IsP2PPacketAvailable)(void *self, uint32_t *pcubMsgSize, int channel);
static int       (*p_Net_ReadP2PPacket)(void *self, void *pubDest, uint32_t cubDest, uint32_t *pcubMsgSize, uint64_t *psteamIDRemote, int channel);
static int       (*p_Net_AcceptP2PSessionWithUser)(void *self, uint64_t steamIDRemote);
static int       (*p_Net_CloseP2PSessionWithUser)(void *self, uint64_t steamIDRemote);
static int       (*p_Net_CloseP2PChannelWithUser)(void *self, uint64_t steamIDRemote, int channel);
static int       (*p_Net_GetP2PSessionState)(void *self, uint64_t steamIDRemote, void *pConnectionState);
static int       (*p_Net_AllowP2PPacketRelay)(void *self, int bAllow);
static const char *(*p_Friends_GetPersonaName)(void *self);
static const char *(*p_Friends_GetFriendPersonaName)(void *self, uint64_t steamID);
static int         (*p_Friends_RequestUserInformation)(void *self, uint64_t steamID, int nameOnly);
static int         (*p_Friends_GetFriendPersonaState)(void *self, uint64_t steamID);

// ISteamUser auth ticket
static uint32_t (*p_User_GetAuthSessionTicket)(void *self, void *pTicket, int cbMax, uint32_t *pcbTicket);
static int      (*p_User_BeginAuthSession)(void *self, const void *pAuthTicket, int cbAuthTicket, uint64_t steamID);
static int      (*p_GS_BeginAuthSession)(void *self, const void *pAuthTicket, int cbAuthTicket, uint64_t steamID);
static void     (*p_GS_EndAuthSession)(void *self, uint64_t steamID);
static void     (*p_User_EndAuthSession)(void *self, uint64_t steamID);
static void     (*p_User_CancelAuthTicket)(void *self, uint32_t hAuthTicket);

// Critical for matchmaking call results: fetch the actual result blob
// associated with a completed SteamAPICall_t (signalled by callback id 703).
static int      (*p_ManualDispatch_GetAPICallResult)(int hSteamPipe, uint64_t hSteamAPICall,
                                                      void *pCallback, int cubCallback,
                                                      int iCallbackExpected, int *pbFailed);

// ISteamMatchmaking flat-C bindings. Each wraps a single virtual; CSteamID is
// passed as uint64_t and we use uint64_t for SteamAPICall_t.
static uint64_t (*p_MM_RequestLobbyList)(void *self);
static uint64_t (*p_MM_GetLobbyByIndex)(void *self, int iLobby);
static uint64_t (*p_MM_CreateLobby)(void *self, int eLobbyType, int cMaxMembers);
static uint64_t (*p_MM_JoinLobby)(void *self, uint64_t lobby);
static void     (*p_MM_LeaveLobby)(void *self, uint64_t lobby);
static int      (*p_MM_GetNumLobbyMembers)(void *self, uint64_t lobby);
static uint64_t (*p_MM_GetLobbyMemberByIndex)(void *self, uint64_t lobby, int idx);
static const char *(*p_MM_GetLobbyData)(void *self, uint64_t lobby, const char *key);
static int      (*p_MM_SetLobbyData)(void *self, uint64_t lobby, const char *key, const char *val);
static int      (*p_MM_GetLobbyDataCount)(void *self, uint64_t lobby);
static int      (*p_MM_GetLobbyDataByIndex)(void *self, uint64_t lobby, int iData, char *pKey, int kSize, char *pVal, int vSize);
static int      (*p_MM_GetLobbyMemberLimit)(void *self, uint64_t lobby);
static int      (*p_MM_SetLobbyMemberLimit)(void *self, uint64_t lobby, int cMax);
static uint64_t (*p_MM_GetLobbyOwner)(void *self, uint64_t lobby);
static int      (*p_MM_SetLobbyJoinable)(void *self, uint64_t lobby, int joinable);
static int      (*p_MM_SetLobbyType)(void *self, uint64_t lobby, int eLobbyType);
static int      (*p_MM_RequestLobbyData)(void *self, uint64_t lobby);
static int      (*p_MM_GetLobbyGameServer)(void *self, uint64_t lobby, uint32_t *ip, uint16_t *port, uint64_t *srvSteamID);
static void     (*p_MM_SetLobbyGameServer)(void *self, uint64_t lobby, uint32_t ip, uint16_t port, uint64_t srvSteamID);
static void     (*p_MM_AddLobbyListStringFilter)(void *self, const char *key, const char *val, int eCmp);
static void     (*p_MM_AddLobbyListNumericalFilter)(void *self, const char *key, int val, int eCmp);
static void     (*p_MM_AddLobbyListNearValueFilter)(void *self, const char *key, int val);
static void     (*p_MM_AddLobbyListFilterSlotsAvailable)(void *self, int nSlots);
static void     (*p_MM_AddLobbyListDistanceFilter)(void *self, int eDist);
static void     (*p_MM_AddLobbyListResultCountFilter)(void *self, int cMax);

// ─── Manual callback dispatch ────────────────────────────────────────────────
// Steam API 1.5+ exposes a manual dispatch path that lets us drain callbacks
// without registering CCallbackBase objects. Once Init() flips it into manual
// mode, normal SteamAPI_RunCallbacks() no-ops and we have to drive it.
//
// typedef struct CallbackMsg_t {
//     int        m_hSteamUser;   // 4 bytes
//     int        m_iCallback;    // 4 bytes
//     uint8     *m_pubParam;     // 4 bytes (32-bit) / 8 bytes (64-bit)
//     int        m_cubParam;     // 4 bytes
// } CallbackMsg_t;
// On 64-bit (this helper runs as arm64), sizeof = 4+4+8+4 (padded to 24).
typedef struct {
    int  m_hSteamUser;
    int  m_iCallback;
    uint8_t *m_pubParam;
    int  m_cubParam;
    int  _pad;
} CallbackMsg_t;

static void (*p_ManualDispatch_Init)(void);
static void (*p_ManualDispatch_RunFrame)(int hSteamPipe);
static int  (*p_ManualDispatch_GetNextCallback)(int hSteamPipe, CallbackMsg_t *msg);
static void (*p_ManualDispatch_FreeLastCallback)(int hSteamPipe);
static int g_dispatch_initialized = 0;
static int g_h_steam_pipe = 0;

// Synthetic-callback queue: things the helper needs to inject into the next
// OP_DRAIN_CALLBACKS response that real Mac Steam doesn't fire on its own.
// Currently used for ValidateAuthTicketResponse_t after BeginAuthSession,
// since Mac's USER-side BeginAuthSession doesn't fire the validation
// callback for self-validation (host validating their own ticket).
#define MAX_SYNTH_CB 16
typedef struct {
    uint32_t id;
    uint32_t dlen;
    uint8_t  data[64];
} synth_cb_t;
static synth_cb_t g_synth_cbs[MAX_SYNTH_CB];
static int g_synth_n = 0;

static void queue_synthetic_callback_validate_auth(uint64_t steamID) {
    if (g_synth_n >= MAX_SYNTH_CB) return;
    // ValidateAuthTicketResponse_t in WINDOWS pack(8) layout (24 bytes):
    //   {CSteamID m_SteamID @ 0; EAuthSessionResponse m_eAuthSessionResponse @ 8;
    //    pad @ 12; CSteamID m_OwnerSteamID @ 16;}
    // We write windows layout directly (skipping the repack step) since this
    // is synthesized for the windows side.
    synth_cb_t *e = &g_synth_cbs[g_synth_n++];
    e->id = 143;
    e->dlen = 24;
    memset(e->data, 0, sizeof e->data);
    memcpy(e->data,      &steamID, 8);     // m_SteamID
    // m_eAuthSessionResponse @ 8 = 0 (k_EAuthSessionResponseOK) — already zero
    memcpy(e->data + 16, &steamID, 8);     // m_OwnerSteamID (same as user → no F2P / family share)
    hlog("[helper] queued synthetic ValidateAuthTicketResponse_t sid=%llu OK\n",
            (unsigned long long)steamID);

    // L4D2's Source engine (and other 2009-2011 Valve titles) also registers
    // GSClientApprove_t (id 201 = k_iSteamGameServerCallbacks + 1) for the
    // server-side approve path.  Goldberg Steam Emulator fires BOTH on every
    // auth event; doing the same gives us belt-and-suspenders coverage for
    // whichever callback the engine's listen-server actually consumes.
    //
    // GSClientApprove_t layout (sizeof = 16 in both pack(4) and pack(8) since
    // both fields are uint64 at offsets 0 and 8):
    //   { CSteamID m_SteamID; CSteamID m_OwnerSteamID; }
    if (g_synth_n >= MAX_SYNTH_CB) return;
    synth_cb_t *g = &g_synth_cbs[g_synth_n++];
    g->id = 201;
    g->dlen = 16;
    memset(g->data, 0, sizeof g->data);
    memcpy(g->data,     &steamID, 8);     // m_SteamID
    memcpy(g->data + 8, &steamID, 8);     // m_OwnerSteamID
    hlog("[helper] queued synthetic GSClientApprove_t sid=%llu\n",
            (unsigned long long)steamID);
}

static void *load_sym(const char *name, int required) {
    void *p = dlsym(g_dylib, name);
    if (!p && required) {
        fprintf(stderr, "[helper] missing required symbol: %s\n", name);
        exit(2);
    }
    return p;
}

static int load_steam(void) {
    g_dylib = dlopen(DYLIB_PATH, RTLD_NOW | RTLD_LOCAL);
    if (!g_dylib) {
        fprintf(stderr, "[helper] dlopen: %s\n", dlerror());
        return -1;
    }

    p_SteamAPI_Init           = load_sym("SteamAPI_Init", 1);
    p_SteamAPI_IsSteamRunning = load_sym("SteamAPI_IsSteamRunning", 0);
    p_SteamAPI_GetHSteamUser  = load_sym("SteamAPI_GetHSteamUser", 0);
    p_SteamAPI_GetHSteamPipe  = load_sym("SteamAPI_GetHSteamPipe", 0);
    p_SteamAPI_Shutdown       = load_sym("SteamAPI_Shutdown", 0);
    p_FindOrCreateUser        = load_sym("SteamInternal_FindOrCreateUserInterface", 1);
    p_FindOrCreateGS          = load_sym("SteamInternal_FindOrCreateGameServerInterface", 0);

    p_User_GetSteamID            = load_sym("SteamAPI_ISteamUser_GetSteamID", 0);
    p_User_BLoggedOn             = load_sym("SteamAPI_ISteamUser_BLoggedOn", 0);
    p_User_GetPlayerSteamLevel   = load_sym("SteamAPI_ISteamUser_GetPlayerSteamLevel", 0);
    p_Apps_BIsSubscribed         = load_sym("SteamAPI_ISteamApps_BIsSubscribed", 0);
    p_Apps_BIsSubscribedApp      = load_sym("SteamAPI_ISteamApps_BIsSubscribedApp", 0);
    p_Apps_GetCurrentGameLanguage= load_sym("SteamAPI_ISteamApps_GetCurrentGameLanguage", 0);
    p_Apps_GetAppBuildId         = load_sym("SteamAPI_ISteamApps_GetAppBuildId", 0);
    p_Utils_GetAppID             = load_sym("SteamAPI_ISteamUtils_GetAppID", 0);
    p_Utils_GetSteamUILanguage   = load_sym("SteamAPI_ISteamUtils_GetSteamUILanguage", 0);
    p_Utils_GetSecondsSinceAppActive = load_sym("SteamAPI_ISteamUtils_GetSecondsSinceAppActive", 0);
    p_Utils_IsAPICallCompleted   = load_sym("SteamAPI_ISteamUtils_IsAPICallCompleted", 0);
    p_Utils_GetAPICallResult     = load_sym("SteamAPI_ISteamUtils_GetAPICallResult", 0);
    p_Utils_CheckFileSignature   = load_sym("SteamAPI_ISteamUtils_CheckFileSignature", 0);
    p_Utils_GetConnectedUniverse = load_sym("SteamAPI_ISteamUtils_GetConnectedUniverse", 0);
    p_Utils_GetServerRealTime    = load_sym("SteamAPI_ISteamUtils_GetServerRealTime", 0);
    p_Utils_IsOverlayEnabled     = load_sym("SteamAPI_ISteamUtils_IsOverlayEnabled", 0);

    // ISteamNetworking flat-C
    p_Net_SendP2PPacket             = load_sym("SteamAPI_ISteamNetworking_SendP2PPacket", 0);
    p_Net_IsP2PPacketAvailable      = load_sym("SteamAPI_ISteamNetworking_IsP2PPacketAvailable", 0);
    p_Net_ReadP2PPacket             = load_sym("SteamAPI_ISteamNetworking_ReadP2PPacket", 0);
    p_Net_AcceptP2PSessionWithUser  = load_sym("SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser", 0);
    p_Net_CloseP2PSessionWithUser   = load_sym("SteamAPI_ISteamNetworking_CloseP2PSessionWithUser", 0);
    p_Net_CloseP2PChannelWithUser   = load_sym("SteamAPI_ISteamNetworking_CloseP2PChannelWithUser", 0);
    p_Net_GetP2PSessionState        = load_sym("SteamAPI_ISteamNetworking_GetP2PSessionState", 0);
    p_Net_AllowP2PPacketRelay       = load_sym("SteamAPI_ISteamNetworking_AllowP2PPacketRelay", 0);

    // ISteamMatchmakingServers
    p_MMS_RequestInternetServerList  = load_sym("SteamAPI_ISteamMatchmakingServers_RequestInternetServerList", 0);
    p_MMS_RequestLANServerList       = load_sym("SteamAPI_ISteamMatchmakingServers_RequestLANServerList", 0);
    p_MMS_RequestFriendsServerList   = load_sym("SteamAPI_ISteamMatchmakingServers_RequestFriendsServerList", 0);
    p_MMS_RequestFavoritesServerList = load_sym("SteamAPI_ISteamMatchmakingServers_RequestFavoritesServerList", 0);
    p_MMS_RequestHistoryServerList   = load_sym("SteamAPI_ISteamMatchmakingServers_RequestHistoryServerList", 0);
    p_MMS_RequestSpectatorServerList = load_sym("SteamAPI_ISteamMatchmakingServers_RequestSpectatorServerList", 0);
    p_MMS_ReleaseRequest             = load_sym("SteamAPI_ISteamMatchmakingServers_ReleaseRequest", 0);
    p_MMS_GetServerDetails           = load_sym("SteamAPI_ISteamMatchmakingServers_GetServerDetails", 0);
    p_MMS_CancelQuery                = load_sym("SteamAPI_ISteamMatchmakingServers_CancelQuery", 0);
    p_MMS_RefreshQuery               = load_sym("SteamAPI_ISteamMatchmakingServers_RefreshQuery", 0);
    p_MMS_IsRefreshing               = load_sym("SteamAPI_ISteamMatchmakingServers_IsRefreshing", 0);
    p_MMS_GetServerCount             = load_sym("SteamAPI_ISteamMatchmakingServers_GetServerCount", 0);
    p_MMS_RefreshServer              = load_sym("SteamAPI_ISteamMatchmakingServers_RefreshServer", 0);
    p_Friends_GetPersonaName     = load_sym("SteamAPI_ISteamFriends_GetPersonaName", 0);
    p_Friends_GetFriendPersonaName = load_sym("SteamAPI_ISteamFriends_GetFriendPersonaName", 0);
    p_Friends_RequestUserInformation = load_sym("SteamAPI_ISteamFriends_RequestUserInformation", 0);
    p_Friends_GetFriendPersonaState = load_sym("SteamAPI_ISteamFriends_GetFriendPersonaState", 0);

    // Auth ticket for VAC-secure server connect.
    p_User_GetAuthSessionTicket  = load_sym("SteamAPI_ISteamUser_GetAuthSessionTicket", 0);
    p_User_BeginAuthSession      = load_sym("SteamAPI_ISteamUser_BeginAuthSession", 0);
    p_GS_BeginAuthSession        = load_sym("SteamAPI_ISteamGameServer_BeginAuthSession", 0);
    p_GS_EndAuthSession          = load_sym("SteamAPI_ISteamGameServer_EndAuthSession", 0);
    p_User_EndAuthSession        = load_sym("SteamAPI_ISteamUser_EndAuthSession", 0);
    p_User_CancelAuthTicket      = load_sym("SteamAPI_ISteamUser_CancelAuthTicket", 0);

    // Async result fetcher — paired with manual dispatch id-703 SteamAPICallCompleted_t.
    p_ManualDispatch_GetAPICallResult = load_sym("SteamAPI_ManualDispatch_GetAPICallResult", 0);

    // ISteamMatchmaking flat-C — wraps the v009 virtual interface. All optional
    // — if any aren't present (older SDK) we just no-op the matching OP.
    p_MM_RequestLobbyList                = load_sym("SteamAPI_ISteamMatchmaking_RequestLobbyList", 0);
    p_MM_GetLobbyByIndex                 = load_sym("SteamAPI_ISteamMatchmaking_GetLobbyByIndex", 0);
    p_MM_CreateLobby                     = load_sym("SteamAPI_ISteamMatchmaking_CreateLobby", 0);
    p_MM_JoinLobby                       = load_sym("SteamAPI_ISteamMatchmaking_JoinLobby", 0);
    p_MM_LeaveLobby                      = load_sym("SteamAPI_ISteamMatchmaking_LeaveLobby", 0);
    p_MM_GetNumLobbyMembers              = load_sym("SteamAPI_ISteamMatchmaking_GetNumLobbyMembers", 0);
    p_MM_GetLobbyMemberByIndex           = load_sym("SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex", 0);
    p_MM_GetLobbyData                    = load_sym("SteamAPI_ISteamMatchmaking_GetLobbyData", 0);
    p_MM_SetLobbyData                    = load_sym("SteamAPI_ISteamMatchmaking_SetLobbyData", 0);
    p_MM_GetLobbyDataCount               = load_sym("SteamAPI_ISteamMatchmaking_GetLobbyDataCount", 0);
    p_MM_GetLobbyDataByIndex             = load_sym("SteamAPI_ISteamMatchmaking_GetLobbyDataByIndex", 0);
    p_MM_GetLobbyMemberLimit             = load_sym("SteamAPI_ISteamMatchmaking_GetLobbyMemberLimit", 0);
    p_MM_SetLobbyMemberLimit             = load_sym("SteamAPI_ISteamMatchmaking_SetLobbyMemberLimit", 0);
    p_MM_GetLobbyOwner                   = load_sym("SteamAPI_ISteamMatchmaking_GetLobbyOwner", 0);
    p_MM_SetLobbyJoinable                = load_sym("SteamAPI_ISteamMatchmaking_SetLobbyJoinable", 0);
    p_MM_SetLobbyType                    = load_sym("SteamAPI_ISteamMatchmaking_SetLobbyType", 0);
    p_MM_RequestLobbyData                = load_sym("SteamAPI_ISteamMatchmaking_RequestLobbyData", 0);
    p_MM_GetLobbyGameServer              = load_sym("SteamAPI_ISteamMatchmaking_GetLobbyGameServer", 0);
    p_MM_SetLobbyGameServer              = load_sym("SteamAPI_ISteamMatchmaking_SetLobbyGameServer", 0);
    p_MM_AddLobbyListStringFilter        = load_sym("SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter", 0);
    p_MM_AddLobbyListNumericalFilter     = load_sym("SteamAPI_ISteamMatchmaking_AddRequestLobbyListNumericalFilter", 0);
    p_MM_AddLobbyListNearValueFilter     = load_sym("SteamAPI_ISteamMatchmaking_AddRequestLobbyListNearValueFilter", 0);
    p_MM_AddLobbyListFilterSlotsAvailable= load_sym("SteamAPI_ISteamMatchmaking_AddRequestLobbyListFilterSlotsAvailable", 0);
    p_MM_AddLobbyListDistanceFilter      = load_sym("SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter", 0);
    p_MM_AddLobbyListResultCountFilter   = load_sym("SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter", 0);

    // Manual callback dispatch (Steam API 1.5+). Lets us drain the same
    // callbacks that would normally fire to CCallbackBase handlers.
    p_ManualDispatch_Init             = load_sym("SteamAPI_ManualDispatch_Init", 0);
    p_ManualDispatch_RunFrame         = load_sym("SteamAPI_ManualDispatch_RunFrame", 0);
    p_ManualDispatch_GetNextCallback  = load_sym("SteamAPI_ManualDispatch_GetNextCallback", 0);
    p_ManualDispatch_FreeLastCallback = load_sym("SteamAPI_ManualDispatch_FreeLastCallback", 0);

    printf("[helper] dylib loaded\n");

    // Set AppID so SteamAPI_Init knows which game we are.
    setenv("SteamAppId", "550", 1);
    setenv("SteamGameId", "550", 1);

    if (!p_SteamAPI_Init()) {
        fprintf(stderr, "[helper] SteamAPI_Init returned false — is Mac Steam running and signed in?\n");
        return -1;
    }
    printf("[helper] SteamAPI_Init ok\n");

    int hUser = p_SteamAPI_GetHSteamUser ? p_SteamAPI_GetHSteamUser() : 1;
    g_steam_user    = p_FindOrCreateUser(hUser, "SteamUser019");
    g_steam_apps    = p_FindOrCreateUser(hUser, "STEAMAPPS_INTERFACE_VERSION007");
    g_steam_utils   = p_FindOrCreateUser(hUser, "SteamUtils009");
    g_steam_friends = p_FindOrCreateUser(hUser, "SteamFriends015");
    g_steam_networking = p_FindOrCreateUser(hUser, "SteamNetworking006");
    g_steam_mm_servers = p_FindOrCreateUser(hUser, "SteamMatchMakingServers002");
    // ISteamGameServer for listen-server auth validation.  We try multiple
    // version strings since Mac Steam may have different ones registered.
    // No SteamGameServer_Init required since Mac maintains a default game-
    // server interface for app-internal use even without server-side init.
    if (p_FindOrCreateGS) {
        const char* gs_versions[] = {
            "SteamGameServer014", "SteamGameServer013", "SteamGameServer012",
            "SteamGameServer011", "SteamGameServer010", NULL };
        for (int i = 0; gs_versions[i] && !g_steam_gameserver; i++) {
            g_steam_gameserver = p_FindOrCreateGS(hUser, gs_versions[i]);
            if (g_steam_gameserver) {
                hlog("[helper] acquired %s -> %p\n", gs_versions[i], g_steam_gameserver);
            }
        }
        if (!g_steam_gameserver) {
            fprintf(stderr, "[helper] no ISteamGameServer interface available; "
                            "GS auth will fall back to User-side BeginAuthSession\n");
        }
    }
    // Matchmaking interface is acquired LAZILY on first OP_MM_REQUESTLOBBYLIST
    // (see ensure_matchmaking()).  Acquiring at startup made Steam start
    // pushing LobbyDataUpdate_t / LobbyChatUpdate_t callbacks into our drain
    // before the game had any lobby state → campaign-load crash.
    g_steam_matchmaking = NULL;

    printf("[helper] hUser=%d  User=%p Apps=%p Utils=%p Friends=%p Matchmaking=%p\n",
           hUser, g_steam_user, g_steam_apps, g_steam_utils, g_steam_friends, g_steam_matchmaking);

    if (p_User_GetSteamID && g_steam_user) {
        uint64_t sid = p_User_GetSteamID(g_steam_user);
        printf("[helper] signed in as SteamID64 %llu\n", (unsigned long long)sid);
    }

    // Initialize manual callback dispatch so we can drain callbacks for the
    // Wine bridge to deliver to L4D2.
    g_h_steam_pipe = p_SteamAPI_GetHSteamPipe ? p_SteamAPI_GetHSteamPipe() : 1;
    if (p_ManualDispatch_Init) {
        p_ManualDispatch_Init();
        g_dispatch_initialized = 1;
        printf("[helper] ManualDispatch_Init done (hPipe=%d)\n", g_h_steam_pipe);
    } else {
        printf("[helper] ManualDispatch_Init NOT available — Steam SDK too old?\n");
    }

    return 0;
}

// ─── Framing helpers ─────────────────────────────────────────────────────────
static int read_exact(int fd, void *buf, size_t n) {
    uint8_t *p = buf; size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, p + got, n - got, 0);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf; size_t sent = 0;
    while (sent < n) {
        ssize_t w = send(fd, p + sent, n - sent, 0);
        if (w <= 0) return -1;
        sent += (size_t)w;
    }
    return 0;
}

static int send_resp(int fd, uint32_t status, const void *data, uint32_t len) {
    uint32_t hdr[2] = { status, len };
    if (write_exact(fd, hdr, sizeof hdr) < 0) return -1;
    if (len && write_exact(fd, data, len) < 0) return -1;
    return 0;
}

static int send_u32(int fd, uint32_t v)         { return send_resp(fd, 0, &v, sizeof v); }
static int send_u64(int fd, uint64_t v)         { return send_resp(fd, 0, &v, sizeof v); }
static int send_string(int fd, const char *s)   {
    if (!s) s = "";
    uint32_t len = (uint32_t)strlen(s) + 1; // include NUL
    return send_resp(fd, 0, s, len);
}
static int send_err(int fd, uint32_t code)      { return send_resp(fd, code, NULL, 0); }

// Lazy-init matchmaking interface on first MM operation.  Runs once.
static int g_mm_init_attempted = 0;
static void ensure_matchmaking(void) {
    if (g_steam_matchmaking || g_mm_init_attempted) return;
    g_mm_init_attempted = 1;
    int hUser = p_SteamAPI_GetHSteamUser ? p_SteamAPI_GetHSteamUser() : 1;
    g_steam_matchmaking = p_FindOrCreateUser(hUser, "SteamMatchMaking009");
    hlog("[helper] lazy MM init: SteamMatchMaking009 -> %p\n", g_steam_matchmaking);
}

// Repack a callback's pubParam from macOS pack(4) to Windows pack(8) layout.
//
// The Steamworks SDK selects struct packing per-platform:
//   - macOS / Linux: VALVE_CALLBACK_PACK_SMALL → #pragma pack(4)
//   - Windows:       VALVE_CALLBACK_PACK_LARGE → #pragma pack(8)
//
// The difference matters when a uint64 follows a uint32 — pack(4) places
// the uint64 at offset 4, pack(8) places it at offset 8 with 4 bytes of
// padding.  Real Mac Steam fills pubParam in pack(4); the Windows game
// reads with pack(8); if we ship the bytes raw the game reads garbage for
// any uint64 field that needed padding, which is exactly what bricked the
// "Creating a new public game…" flow — LobbyCreated_t.m_ulSteamIDLobby was
// being read from offset 8 where pack(4) had it at offset 4, so the game
// got a malformed SteamID and bailed even though m_eResult was OK.
//
// Returns the new packed size; writes into dst (caller ensures dst has
// at least 64 bytes, plenty for every callback we currently repack).  For
// IDs we don't have a layout transform for, the data is copied unchanged.
static uint32_t repack_pack4_to_pack8(uint32_t id, const uint8_t *src,
                                      uint32_t srclen, uint8_t *dst) {
    switch (id) {
    case 513:  // LobbyCreated_t { EResult result; uint64 lobby; }
        // pack(4): result@0, lobby@4   (size 12)
        // pack(8): result@0, lobby@8   (size 16, 4 bytes pad)
        if (srclen < 12) break;
        memcpy(dst, src, 4);
        memset(dst + 4, 0, 4);
        memcpy(dst + 8, src + 4, 8);
        return 16;
    case 1101: // UserStatsReceived_t { uint64 gameID; EResult result; uint64 steamID; }
        // pack(4): gameID@0, result@8, steamID@12  (size 20)
        // pack(8): gameID@0, result@8, steamID@16  (size 24, 4 bytes pad)
        if (srclen < 20) break;
        memcpy(dst, src, 12);
        memset(dst + 12, 0, 4);
        memcpy(dst + 16, src + 12, 8);
        return 24;
    case 143: // ValidateAuthTicketResponse_t — VAC validation result
              // { CSteamID m_SteamID; EAuthSessionResponse m_eAuthSessionResponse; CSteamID m_OwnerSteamID; }
        // pack(4): steamID@0, response@8, owner@12   (size 20)
        // pack(8): steamID@0, response@8, owner@16   (size 24, 4 bytes pad)
        if (srclen < 20) break;
        memcpy(dst, src, 12);
        memset(dst + 12, 0, 4);
        memcpy(dst + 16, src + 12, 8);
        return 24;
    // LobbyEnter_t (504): lobby@0 (uint64) — same in both, no diff.
    // LobbyDataUpdate_t (505): { uint64; uint64; uint8 } — same in both.
    // LobbyChatUpdate_t (506): { uint64; uint64; uint64; uint32 } — same.
    // LobbyMatchList_t (510): single uint32 — same.
    // SteamServersConnected_t (101): empty — same.
    // SteamServersDisconnected_t (103): { EResult } — same.
    // IPCountry_t (701): empty — same.
    default:
        break;
    }
    // Passthrough: copy raw.
    if (srclen > 1024) srclen = 1024;  // safety cap
    memcpy(dst, src, srclen);
    return srclen;
}

// ─── Per-connection request handler ──────────────────────────────────────────
static int handle_one(int fd) {
    uint32_t hdr[2];
    if (read_exact(fd, hdr, sizeof hdr) < 0) return -1;
    uint32_t op  = hdr[0];
    uint32_t alen = hdr[1];
    uint8_t  args[256] = {0};
    if (alen > sizeof args) return -1;
    if (alen && read_exact(fd, args, alen) < 0) return -1;
    hlog("[helper] op=0x%04x alen=%u\n", op, alen);
    fflush(stderr);

    switch (op) {
    case OP_PING:                   return send_u32(fd, 0xC0FFEE00);
    case OP_INIT:                   return send_u32(fd, 1);
    case OP_IS_STEAM_RUNNING:       return send_u32(fd, p_SteamAPI_IsSteamRunning ? p_SteamAPI_IsSteamRunning() : 1);
    case OP_GET_HSTEAMUSER:         return send_u32(fd, p_SteamAPI_GetHSteamUser ? p_SteamAPI_GetHSteamUser() : 1);
    case OP_GET_HSTEAMPIPE:         return send_u32(fd, p_SteamAPI_GetHSteamPipe ? p_SteamAPI_GetHSteamPipe() : 1);
    case OP_SHUTDOWN:               return send_resp(fd, 0, NULL, 0);

    case OP_USER_GETSTEAMID:
        if (!g_steam_user || !p_User_GetSteamID) return send_err(fd, 1);
        return send_u64(fd, p_User_GetSteamID(g_steam_user));
    case OP_USER_BLOGGEDON:
        if (!g_steam_user || !p_User_BLoggedOn) return send_u32(fd, 1);
        return send_u32(fd, p_User_BLoggedOn(g_steam_user) ? 1 : 0);
    case OP_USER_GETPLAYERSTEAMLEVEL:
        if (!g_steam_user || !p_User_GetPlayerSteamLevel) return send_u32(fd, 0);
        return send_u32(fd, p_User_GetPlayerSteamLevel(g_steam_user));

    case OP_USER_GETAUTHSESSIONTICKET: {
        if (!g_steam_user || !p_User_GetAuthSessionTicket) return send_err(fd, 1);
        // Steam tickets are typically <1024 bytes; allocate 2KB to be safe.
        uint8_t ticket[2048];
        uint32_t cb = 0;
        uint32_t handle = p_User_GetAuthSessionTicket(g_steam_user, ticket, sizeof ticket, &cb);
        if (cb > sizeof ticket) cb = sizeof ticket;
        // Wire: u32 handle + u32 cb + cb bytes.
        uint8_t resp[2056];
        memcpy(resp,     &handle, 4);
        memcpy(resp + 4, &cb,     4);
        if (cb) memcpy(resp + 8, ticket, cb);
        return send_resp(fd, 0, resp, 8 + cb);
    }

    case OP_USER_BEGINAUTHSESSION: {
        if (!g_steam_user || !p_User_BeginAuthSession) return send_err(fd, 1);
        // arg: u64 steamID + ticket bytes (rest of alen)
        if (alen < 8) return send_err(fd, 1);
        uint64_t steamID; memcpy(&steamID, args, 8);
        const void *ticket = args + 8;
        int cb = (int)(alen - 8);
        int rv = p_User_BeginAuthSession(g_steam_user, ticket, cb, steamID);
        const char* rvName = "?";
        switch (rv) {
          case 0: rvName="OK"; break;
          case 1: rvName="InvalidTicket"; break;
          case 2: rvName="DuplicateRequest"; break;
          case 3: rvName="InvalidVersion"; break;
          case 4: rvName="GameMismatch"; break;
          case 5: rvName="ExpiredTicket"; break;
        }
        hlog("[helper] BeginAuthSession sid=%llu cb=%d rv=%d (%s)\n",
                (unsigned long long)steamID, cb, rv, rvName);
        // Queue a synthetic ValidateAuthTicketResponse_t (id=143).  Real Mac
        // Steam's USER-side BeginAuthSession doesn't always fire this for
        // self-validation (host validating their own ticket); the Source
        // listen-server kicks the local client after ~5s as "STEAM validation
        // rejected" without it.  We know the validation succeeded if rv == 0
        // (Steam accepted the ticket for processing), so we generate the OK
        // response ourselves and deliver it on the next drain.  If Mac Steam
        // ALSO fires its own response the engine's CCallback is idempotent
        // (the second call simply re-confirms OK).
        if (rv == 0) {
            queue_synthetic_callback_validate_auth(steamID);
        }
        return send_u32(fd, (uint32_t)rv);
    }

    case OP_USER_ENDAUTHSESSION: {
        if (!g_steam_user || !p_User_EndAuthSession) return send_resp(fd, 0, NULL, 0);
        if (alen < 8) return send_err(fd, 1);
        uint64_t steamID; memcpy(&steamID, args, 8);
        p_User_EndAuthSession(g_steam_user, steamID);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_USER_CANCELAUTHTICKET: {
        if (!g_steam_user || !p_User_CancelAuthTicket) return send_resp(fd, 0, NULL, 0);
        if (alen < 4) return send_err(fd, 1);
        uint32_t handle; memcpy(&handle, args, 4);
        p_User_CancelAuthTicket(g_steam_user, handle);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_GS_BEGINAUTHSESSION: {
        // Source listen-server's auth path calls SteamGameServer()->BeginAuthSession.
        // arg: u64 steamID + ticket bytes
        if (alen < 8) return send_err(fd, 1);
        uint64_t steamID; memcpy(&steamID, args, 8);
        const void *ticket = args + 8;
        int cb = (int)(alen - 8);

        // Prefer the real game-server interface if Mac Steam offered us one.
        // Falls back to user-side validation (which Mac may swallow without
        // firing the callback — that's what the synthetic injection covers).
        int rv = -1;
        const char* path = "?";
        if (g_steam_gameserver && p_GS_BeginAuthSession) {
            rv = p_GS_BeginAuthSession(g_steam_gameserver, ticket, cb, steamID);
            path = "ISteamGameServer";
        } else if (g_steam_user && p_User_BeginAuthSession) {
            rv = p_User_BeginAuthSession(g_steam_user, ticket, cb, steamID);
            path = "ISteamUser fallback";
        }
        const char* rvName = "?";
        switch (rv) {
          case 0: rvName="OK"; break;
          case 1: rvName="InvalidTicket"; break;
          case 2: rvName="DuplicateRequest"; break;
          case 3: rvName="InvalidVersion"; break;
          case 4: rvName="GameMismatch"; break;
          case 5: rvName="ExpiredTicket"; break;
        }
        hlog("[helper] GS_BeginAuthSession sid=%llu cb=%d rv=%d (%s) via %s\n",
                (unsigned long long)steamID, cb, rv, rvName, path);

        // Engine treats the callback as advisory ("default to approved if it
        // doesn't fire") — what really matters is BeginAuthSession returning
        // 0.  When the host is validating their own ticket the answer is
        // ALWAYS valid (it's literally the user's own Steam-issued ticket).
        // If Mac says non-zero (duplicate request, expired, user-side rejecting
        // a server ticket, etc.) we override to 0 since the user IS valid.
        if (rv != 0) {
            hlog("[helper] overriding GS BeginAuthSession rv to OK "
                            "(host self-validation always succeeds)\n");
            rv = 0;
        }
        // Belt-and-suspenders: queue the synthetic callback as well so the
        // engine's OnValidateAuthTicketResponse / GSClientApprove handler fires.
        queue_synthetic_callback_validate_auth(steamID);
        return send_u32(fd, (uint32_t)rv);
    }

    case OP_GS_ENDAUTHSESSION: {
        if (alen < 8) return send_resp(fd, 0, NULL, 0);
        uint64_t steamID; memcpy(&steamID, args, 8);
        if (g_steam_gameserver && p_GS_EndAuthSession) {
            p_GS_EndAuthSession(g_steam_gameserver, steamID);
        } else if (g_steam_user && p_User_EndAuthSession) {
            p_User_EndAuthSession(g_steam_user, steamID);
        }
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_APPS_BISSUBSCRIBED:
        if (!g_steam_apps || !p_Apps_BIsSubscribed) return send_u32(fd, 1);
        return send_u32(fd, p_Apps_BIsSubscribed(g_steam_apps) ? 1 : 0);
    case OP_APPS_BISSUBSCRIBEDAPP: {
        if (alen < 4) return send_err(fd, 1);
        uint32_t appid;
        memcpy(&appid, args, 4);
        if (!g_steam_apps || !p_Apps_BIsSubscribedApp) return send_u32(fd, 1);
        return send_u32(fd, p_Apps_BIsSubscribedApp(g_steam_apps, appid) ? 1 : 0);
    }
    case OP_APPS_GETCURRENTGAMELANG:
        return send_string(fd, (g_steam_apps && p_Apps_GetCurrentGameLanguage)
                                ? p_Apps_GetCurrentGameLanguage(g_steam_apps) : "english");
    case OP_APPS_GETAPPBUILDID:
        if (!g_steam_apps || !p_Apps_GetAppBuildId) return send_u32(fd, 0);
        return send_u32(fd, p_Apps_GetAppBuildId(g_steam_apps));

    case OP_UTILS_GETAPPID:
        return send_u32(fd, (g_steam_utils && p_Utils_GetAppID)
                            ? p_Utils_GetAppID(g_steam_utils) : 550);
    case OP_UTILS_GETSTEAMUILANG:
        return send_string(fd, (g_steam_utils && p_Utils_GetSteamUILanguage)
                                ? p_Utils_GetSteamUILanguage(g_steam_utils) : "english");
    case OP_UTILS_GETSECONDSSINCEAPPACTIVE:
        if (!g_steam_utils || !p_Utils_GetSecondsSinceAppActive) return send_u32(fd, 0);
        return send_u32(fd, p_Utils_GetSecondsSinceAppActive(g_steam_utils));

    case OP_UTILS_ISAPICALLCOMPLETED: {
        if (alen < 8) return send_err(fd, 1);
        uint64_t hCall; memcpy(&hCall, args, 8);
        if (!g_steam_utils || !p_Utils_IsAPICallCompleted) {
            // No real impl available; default to "completed, not failed" so the
            // game's wait loop exits cleanly.
            uint32_t resp[2] = {1, 0};
            return send_resp(fd, 0, resp, sizeof resp);
        }
        int bFailed = 0;
        int rv = p_Utils_IsAPICallCompleted(g_steam_utils, hCall, &bFailed);
        uint32_t resp[2] = { (uint32_t)(rv ? 1 : 0), (uint32_t)(bFailed ? 1 : 0) };
        return send_resp(fd, 0, resp, sizeof resp);
    }

    case OP_UTILS_GETAPICALLRESULT: {
        if (alen < 16) return send_err(fd, 1);
        uint64_t hCall; uint32_t cb; uint32_t expCb;
        memcpy(&hCall, args, 8);
        memcpy(&cb, args + 8, 4);
        memcpy(&expCb, args + 12, 4);
        if (cb > 4096) cb = 4096;
        uint8_t blob[4096 + 8];
        uint32_t *hdr = (uint32_t*)blob;       // [ok, bFailed]
        uint8_t  *body = blob + 8;
        memset(body, 0, cb);
        if (!g_steam_utils || !p_Utils_GetAPICallResult) {
            // No real impl; report "ok, not failed" with zero-fill (safe default).
            hdr[0] = 1; hdr[1] = 0;
            return send_resp(fd, 0, blob, 8 + cb);
        }
        int bFailed = 0;
        int ok = p_Utils_GetAPICallResult(g_steam_utils, hCall, body, (int)cb, (int)expCb, &bFailed);
        hdr[0] = (uint32_t)(ok ? 1 : 0);
        hdr[1] = (uint32_t)(bFailed ? 1 : 0);
        return send_resp(fd, 0, blob, 8 + cb);
    }

    case OP_UTILS_CHECKFILESIGNATURE: {
        if (alen < 2) return send_err(fd, 1);
        const char *fn = (const char*)args;
        if (!g_steam_utils || !p_Utils_CheckFileSignature) return send_u64(fd, 0);
        return send_u64(fd, p_Utils_CheckFileSignature(g_steam_utils, fn));
    }

    case OP_UTILS_GETCONNECTEDUNIVERSE:
        if (!g_steam_utils || !p_Utils_GetConnectedUniverse) return send_u32(fd, 1); // 1=k_EUniversePublic
        return send_u32(fd, (uint32_t)p_Utils_GetConnectedUniverse(g_steam_utils));

    case OP_UTILS_GETSERVERREALTIME:
        if (!g_steam_utils || !p_Utils_GetServerRealTime) return send_u32(fd, (uint32_t)time(NULL));
        return send_u32(fd, p_Utils_GetServerRealTime(g_steam_utils));

    case OP_UTILS_ISOVERLAYENABLED:
        if (!g_steam_utils || !p_Utils_IsOverlayEnabled) return send_u32(fd, 0);
        return send_u32(fd, p_Utils_IsOverlayEnabled(g_steam_utils) ? 1 : 0);

    // ─── ISteamNetworking ──────────────────────────────────────────────────
    case OP_NET_SENDP2PPACKET: {
        // arg: u64 sid + u32 cb + u32 eP2PSend + u32 channel + data
        if (alen < 20 || !g_steam_networking || !p_Net_SendP2PPacket) return send_u32(fd, 0);
        uint64_t sid; uint32_t cb, eP2PSend, channel;
        memcpy(&sid, args, 8);
        memcpy(&cb, args + 8, 4);
        memcpy(&eP2PSend, args + 12, 4);
        memcpy(&channel, args + 16, 4);
        const void *pubData = args + 20;
        if (alen < 20 + cb) cb = alen - 20;
        return send_u32(fd, p_Net_SendP2PPacket(g_steam_networking, sid, pubData, cb, (int)eP2PSend, (int)channel) ? 1 : 0);
    }

    case OP_NET_ISP2PPACKETAVAILABLE: {
        if (alen < 4 || !g_steam_networking || !p_Net_IsP2PPacketAvailable) return send_u32(fd, 0);
        uint32_t channel; memcpy(&channel, args, 4);
        uint32_t cubMsgSize = 0;
        int avail = p_Net_IsP2PPacketAvailable(g_steam_networking, &cubMsgSize, (int)channel);
        uint32_t resp[2] = { (uint32_t)(avail ? 1 : 0), cubMsgSize };
        return send_resp(fd, 0, resp, sizeof resp);
    }

    case OP_NET_READP2PPACKET: {
        if (alen < 8 || !g_steam_networking || !p_Net_ReadP2PPacket) return send_u32(fd, 0);
        uint32_t cubDest, channel;
        memcpy(&cubDest, args, 4);
        memcpy(&channel, args + 4, 4);
        if (cubDest > 4096) cubDest = 4096;
        uint8_t blob[4096 + 16];
        uint8_t *body = blob + 16;
        uint32_t cubMsgSize = 0;
        uint64_t steamIDRemote = 0;
        int ok = p_Net_ReadP2PPacket(g_steam_networking, body, cubDest, &cubMsgSize, &steamIDRemote, (int)channel);
        uint32_t okU = ok ? 1 : 0;
        memcpy(blob, &okU, 4);
        memcpy(blob + 4, &cubMsgSize, 4);
        memcpy(blob + 8, &steamIDRemote, 8);
        return send_resp(fd, 0, blob, 16 + (ok ? cubMsgSize : 0));
    }

    case OP_NET_ACCEPTP2PSESSIONWITHUSER: {
        if (alen < 8 || !g_steam_networking || !p_Net_AcceptP2PSessionWithUser) return send_u32(fd, 1);
        uint64_t sid; memcpy(&sid, args, 8);
        return send_u32(fd, p_Net_AcceptP2PSessionWithUser(g_steam_networking, sid) ? 1 : 0);
    }

    case OP_NET_CLOSEP2PSESSIONWITHUSER: {
        if (alen < 8 || !g_steam_networking || !p_Net_CloseP2PSessionWithUser) return send_u32(fd, 1);
        uint64_t sid; memcpy(&sid, args, 8);
        return send_u32(fd, p_Net_CloseP2PSessionWithUser(g_steam_networking, sid) ? 1 : 0);
    }

    case OP_NET_CLOSEP2PCHANNELWITHUSER: {
        if (alen < 12 || !g_steam_networking || !p_Net_CloseP2PChannelWithUser) return send_u32(fd, 1);
        uint64_t sid; uint32_t channel;
        memcpy(&sid, args, 8); memcpy(&channel, args + 8, 4);
        return send_u32(fd, p_Net_CloseP2PChannelWithUser(g_steam_networking, sid, (int)channel) ? 1 : 0);
    }

    case OP_NET_GETP2PSESSIONSTATE: {
        if (alen < 8 || !g_steam_networking || !p_Net_GetP2PSessionState) return send_u32(fd, 0);
        uint64_t sid; memcpy(&sid, args, 8);
        // P2PSessionState_t is small: 4+4+4+4+8 = 24 bytes typically (with padding)
        uint8_t state[32] = {0};
        int ok = p_Net_GetP2PSessionState(g_steam_networking, sid, state);
        uint8_t resp[36];
        uint32_t okU = ok ? 1 : 0;
        memcpy(resp, &okU, 4);
        memcpy(resp + 4, state, 32);
        return send_resp(fd, 0, resp, 36);
    }

    case OP_NET_ALLOWP2PPACKETRELAY: {
        if (alen < 4 || !g_steam_networking || !p_Net_AllowP2PPacketRelay) return send_u32(fd, 1);
        uint32_t bAllow; memcpy(&bAllow, args, 4);
        return send_u32(fd, p_Net_AllowP2PPacketRelay(g_steam_networking, (int)bAllow) ? 1 : 0);
    }

    // ─── ISteamMatchmakingServers ──────────────────────────────────────────
#define MMS_REQUIRE(p) do { if (!g_steam_mm_servers || !(p)) return send_u64(fd, 0); } while (0)
    case OP_MMS_REQUESTINTERNETSERVERLIST: {
        MMS_REQUIRE(p_MMS_RequestInternetServerList);
        // arg: u32 appid + serialized filters (key\0val\0)* — for now we
        // forward with no filters (the game's RequestLobbyList filters were
        // applied at the lobby layer; server browser filters are separate
        // and L4D2 typically doesn't use them).
        if (alen < 4) return send_u64(fd, 0);
        uint32_t appid; memcpy(&appid, args, 4);
        void *h = p_MMS_RequestInternetServerList(g_steam_mm_servers, appid, NULL, 0, &g_noop_serverlist_response);
        hlog("[helper] MMS_RequestInternetServerList(app=%u) -> %p\n", appid, h);
        return send_u64(fd, (uint64_t)(uintptr_t)h);
    }
    case OP_MMS_REQUESTLANSERVERLIST: {
        MMS_REQUIRE(p_MMS_RequestLANServerList);
        if (alen < 4) return send_u64(fd, 0);
        uint32_t appid; memcpy(&appid, args, 4);
        return send_u64(fd, (uint64_t)(uintptr_t)p_MMS_RequestLANServerList(g_steam_mm_servers, appid, &g_noop_serverlist_response));
    }
    case OP_MMS_REQUESTFRIENDSSERVERLIST: {
        MMS_REQUIRE(p_MMS_RequestFriendsServerList);
        if (alen < 4) return send_u64(fd, 0);
        uint32_t appid; memcpy(&appid, args, 4);
        return send_u64(fd, (uint64_t)(uintptr_t)p_MMS_RequestFriendsServerList(g_steam_mm_servers, appid, NULL, 0, &g_noop_serverlist_response));
    }
    case OP_MMS_REQUESTFAVORITESSERVERLIST: {
        MMS_REQUIRE(p_MMS_RequestFavoritesServerList);
        if (alen < 4) return send_u64(fd, 0);
        uint32_t appid; memcpy(&appid, args, 4);
        return send_u64(fd, (uint64_t)(uintptr_t)p_MMS_RequestFavoritesServerList(g_steam_mm_servers, appid, NULL, 0, &g_noop_serverlist_response));
    }
    case OP_MMS_REQUESTHISTORYSERVERLIST: {
        MMS_REQUIRE(p_MMS_RequestHistoryServerList);
        if (alen < 4) return send_u64(fd, 0);
        uint32_t appid; memcpy(&appid, args, 4);
        return send_u64(fd, (uint64_t)(uintptr_t)p_MMS_RequestHistoryServerList(g_steam_mm_servers, appid, NULL, 0, &g_noop_serverlist_response));
    }
    case OP_MMS_REQUESTSPECTATORSERVERLIST: {
        MMS_REQUIRE(p_MMS_RequestSpectatorServerList);
        if (alen < 4) return send_u64(fd, 0);
        uint32_t appid; memcpy(&appid, args, 4);
        return send_u64(fd, (uint64_t)(uintptr_t)p_MMS_RequestSpectatorServerList(g_steam_mm_servers, appid, NULL, 0, &g_noop_serverlist_response));
    }
    case OP_MMS_RELEASEREQUEST: {
        if (!g_steam_mm_servers || !p_MMS_ReleaseRequest) return send_resp(fd, 0, NULL, 0);
        if (alen < 8) return send_err(fd, 1);
        uint64_t h; memcpy(&h, args, 8);
        p_MMS_ReleaseRequest(g_steam_mm_servers, (void*)(uintptr_t)h);
        return send_resp(fd, 0, NULL, 0);
    }
    case OP_MMS_GETSERVERDETAILS: {
        if (!g_steam_mm_servers || !p_MMS_GetServerDetails) return send_err(fd, 1);
        if (alen < 12) return send_err(fd, 1);
        uint64_t h; int32_t iServer;
        memcpy(&h, args, 8); memcpy(&iServer, args + 8, 4);
        void *p = p_MMS_GetServerDetails(g_steam_mm_servers, (void*)(uintptr_t)h, iServer);
        if (!p) return send_err(fd, 1);
        // Forward 400 bytes of gameserveritem_t (struct size ~376; round up).
        return send_resp(fd, 0, p, 400);
    }
    case OP_MMS_CANCELQUERY: {
        if (!g_steam_mm_servers || !p_MMS_CancelQuery) return send_resp(fd, 0, NULL, 0);
        if (alen < 8) return send_err(fd, 1);
        uint64_t h; memcpy(&h, args, 8);
        p_MMS_CancelQuery(g_steam_mm_servers, (void*)(uintptr_t)h);
        return send_resp(fd, 0, NULL, 0);
    }
    case OP_MMS_REFRESHQUERY: {
        if (!g_steam_mm_servers || !p_MMS_RefreshQuery) return send_resp(fd, 0, NULL, 0);
        if (alen < 8) return send_err(fd, 1);
        uint64_t h; memcpy(&h, args, 8);
        p_MMS_RefreshQuery(g_steam_mm_servers, (void*)(uintptr_t)h);
        return send_resp(fd, 0, NULL, 0);
    }
    case OP_MMS_ISREFRESHING: {
        if (!g_steam_mm_servers || !p_MMS_IsRefreshing) return send_u32(fd, 0);
        if (alen < 8) return send_u32(fd, 0);
        uint64_t h; memcpy(&h, args, 8);
        return send_u32(fd, p_MMS_IsRefreshing(g_steam_mm_servers, (void*)(uintptr_t)h) ? 1 : 0);
    }
    case OP_MMS_GETSERVERCOUNT: {
        if (!g_steam_mm_servers || !p_MMS_GetServerCount) return send_u32(fd, 0);
        if (alen < 8) return send_u32(fd, 0);
        uint64_t h; memcpy(&h, args, 8);
        return send_u32(fd, (uint32_t)p_MMS_GetServerCount(g_steam_mm_servers, (void*)(uintptr_t)h));
    }
    case OP_MMS_REFRESHSERVER: {
        if (!g_steam_mm_servers || !p_MMS_RefreshServer) return send_resp(fd, 0, NULL, 0);
        if (alen < 12) return send_err(fd, 1);
        uint64_t h; int32_t iServer;
        memcpy(&h, args, 8); memcpy(&iServer, args + 8, 4);
        p_MMS_RefreshServer(g_steam_mm_servers, (void*)(uintptr_t)h, iServer);
        return send_resp(fd, 0, NULL, 0);
    }
#undef MMS_REQUIRE

    case OP_FRIENDS_GETPERSONANAME:
        return send_string(fd, (g_steam_friends && p_Friends_GetPersonaName)
                                ? p_Friends_GetPersonaName(g_steam_friends) : "Player");

    case OP_FRIENDS_GETFRIENDPERSONANAME: {
        if (alen < 8) return send_err(fd, 1);
        uint64_t steamID; memcpy(&steamID, args, 8);
        if (!g_steam_friends || !p_Friends_GetFriendPersonaName) return send_string(fd, "Player");
        const char *name = p_Friends_GetFriendPersonaName(g_steam_friends, steamID);
        return send_string(fd, name ? name : "Player");
    }

    case OP_FRIENDS_REQUESTUSERINFO: {
        if (alen < 12) return send_err(fd, 1);
        uint64_t steamID; uint32_t nameOnly;
        memcpy(&steamID, args, 8); memcpy(&nameOnly, args + 8, 4);
        if (!g_steam_friends || !p_Friends_RequestUserInformation) return send_u32(fd, 0);
        // Returns true if info needs to be fetched (callback will fire later).
        // False = already cached; no callback needed.
        return send_u32(fd, p_Friends_RequestUserInformation(g_steam_friends, steamID, (int)nameOnly) ? 1 : 0);
    }

    case OP_FRIENDS_GETFRIENDPERSONASTATE: {
        if (alen < 8) return send_err(fd, 1);
        uint64_t steamID; memcpy(&steamID, args, 8);
        if (!g_steam_friends || !p_Friends_GetFriendPersonaState) return send_u32(fd, 0);
        return send_u32(fd, (uint32_t)p_Friends_GetFriendPersonaState(g_steam_friends, steamID));
    }

    // ─── ISteamMatchmaking ──────────────────────────────────────────────────
    // Bail with 0/empty if interface or symbol wasn't loaded.
#define MM_REQUIRE(p) do { ensure_matchmaking(); if (!g_steam_matchmaking || !(p)) return send_err(fd, 1); } while (0)

    case OP_MM_REQUESTLOBBYLIST:
        MM_REQUIRE(p_MM_RequestLobbyList);
        return send_u64(fd, p_MM_RequestLobbyList(g_steam_matchmaking));

    case OP_MM_GETLOBBYBYINDEX: {
        MM_REQUIRE(p_MM_GetLobbyByIndex);
        if (alen < 4) return send_err(fd, 1);
        uint32_t idx; memcpy(&idx, args, 4);
        return send_u64(fd, p_MM_GetLobbyByIndex(g_steam_matchmaking, (int)idx));
    }

    case OP_MM_CREATELOBBY: {
        MM_REQUIRE(p_MM_CreateLobby);
        if (alen < 8) return send_err(fd, 1);
        uint32_t type, max; memcpy(&type, args, 4); memcpy(&max, args + 4, 4);
        return send_u64(fd, p_MM_CreateLobby(g_steam_matchmaking, (int)type, (int)max));
    }

    case OP_MM_JOINLOBBY: {
        MM_REQUIRE(p_MM_JoinLobby);
        if (alen < 8) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        return send_u64(fd, p_MM_JoinLobby(g_steam_matchmaking, lobby));
    }

    case OP_MM_LEAVELOBBY: {
        MM_REQUIRE(p_MM_LeaveLobby);
        if (alen < 8) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        p_MM_LeaveLobby(g_steam_matchmaking, lobby);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_MM_GETNUMLOBBYMEMBERS: {
        MM_REQUIRE(p_MM_GetNumLobbyMembers);
        if (alen < 8) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        return send_u32(fd, (uint32_t)p_MM_GetNumLobbyMembers(g_steam_matchmaking, lobby));
    }

    case OP_MM_GETLOBBYMEMBERBYINDEX: {
        MM_REQUIRE(p_MM_GetLobbyMemberByIndex);
        if (alen < 12) return send_err(fd, 1);
        uint64_t lobby; uint32_t idx;
        memcpy(&lobby, args, 8); memcpy(&idx, args + 8, 4);
        return send_u64(fd, p_MM_GetLobbyMemberByIndex(g_steam_matchmaking, lobby, (int)idx));
    }

    case OP_MM_GETLOBBYDATA: {
        MM_REQUIRE(p_MM_GetLobbyData);
        // arg: u64 lobby + NUL-terminated key
        if (alen < 9) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        const char *key = (const char*)args + 8;
        return send_string(fd, p_MM_GetLobbyData(g_steam_matchmaking, lobby, key));
    }

    case OP_MM_SETLOBBYDATA: {
        MM_REQUIRE(p_MM_SetLobbyData);
        // arg: u64 lobby + key\0value\0
        if (alen < 10) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        const char *key = (const char*)args + 8;
        size_t keylen = strnlen(key, alen - 8);
        if (keylen >= alen - 8) return send_err(fd, 1);
        const char *val = key + keylen + 1;
        return send_u32(fd, p_MM_SetLobbyData(g_steam_matchmaking, lobby, key, val) ? 1 : 0);
    }

    case OP_MM_GETLOBBYDATACOUNT: {
        MM_REQUIRE(p_MM_GetLobbyDataCount);
        if (alen < 8) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        return send_u32(fd, (uint32_t)p_MM_GetLobbyDataCount(g_steam_matchmaking, lobby));
    }

    case OP_MM_GETLOBBYDATABYINDEX: {
        MM_REQUIRE(p_MM_GetLobbyDataByIndex);
        if (alen < 12) return send_err(fd, 1);
        uint64_t lobby; uint32_t idx;
        memcpy(&lobby, args, 8); memcpy(&idx, args + 8, 4);
        char key[256] = {0}, val[256] = {0};
        int ok = p_MM_GetLobbyDataByIndex(g_steam_matchmaking, lobby, (int)idx, key, sizeof key, val, sizeof val);
        if (!ok) return send_err(fd, 1);
        // Pack key\0val\0
        size_t kl = strlen(key), vl = strlen(val);
        if (kl + vl + 2 > 512) return send_err(fd, 1);
        uint8_t buf[512];
        memcpy(buf, key, kl + 1);
        memcpy(buf + kl + 1, val, vl + 1);
        return send_resp(fd, 0, buf, (uint32_t)(kl + vl + 2));
    }

    case OP_MM_GETLOBBYMEMBERLIMIT: {
        MM_REQUIRE(p_MM_GetLobbyMemberLimit);
        if (alen < 8) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        return send_u32(fd, (uint32_t)p_MM_GetLobbyMemberLimit(g_steam_matchmaking, lobby));
    }

    case OP_MM_SETLOBBYMEMBERLIMIT: {
        MM_REQUIRE(p_MM_SetLobbyMemberLimit);
        if (alen < 12) return send_err(fd, 1);
        uint64_t lobby; uint32_t max;
        memcpy(&lobby, args, 8); memcpy(&max, args + 8, 4);
        return send_u32(fd, p_MM_SetLobbyMemberLimit(g_steam_matchmaking, lobby, (int)max) ? 1 : 0);
    }

    case OP_MM_GETLOBBYOWNER: {
        MM_REQUIRE(p_MM_GetLobbyOwner);
        if (alen < 8) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        return send_u64(fd, p_MM_GetLobbyOwner(g_steam_matchmaking, lobby));
    }

    case OP_MM_SETLOBBYJOINABLE: {
        MM_REQUIRE(p_MM_SetLobbyJoinable);
        if (alen < 12) return send_err(fd, 1);
        uint64_t lobby; uint32_t joinable;
        memcpy(&lobby, args, 8); memcpy(&joinable, args + 8, 4);
        return send_u32(fd, p_MM_SetLobbyJoinable(g_steam_matchmaking, lobby, (int)joinable) ? 1 : 0);
    }

    case OP_MM_SETLOBBYTYPE: {
        MM_REQUIRE(p_MM_SetLobbyType);
        if (alen < 12) return send_err(fd, 1);
        uint64_t lobby; uint32_t type;
        memcpy(&lobby, args, 8); memcpy(&type, args + 8, 4);
        return send_u32(fd, p_MM_SetLobbyType(g_steam_matchmaking, lobby, (int)type) ? 1 : 0);
    }

    case OP_MM_REQUESTLOBBYDATA: {
        MM_REQUIRE(p_MM_RequestLobbyData);
        if (alen < 8) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        return send_u32(fd, p_MM_RequestLobbyData(g_steam_matchmaking, lobby) ? 1 : 0);
    }

    case OP_MM_GETLOBBYGAMESERVER: {
        MM_REQUIRE(p_MM_GetLobbyGameServer);
        if (alen < 8) return send_err(fd, 1);
        uint64_t lobby; memcpy(&lobby, args, 8);
        uint32_t ip = 0; uint16_t port = 0; uint64_t srv = 0;
        int ok = p_MM_GetLobbyGameServer(g_steam_matchmaking, lobby, &ip, &port, &srv);
        // packed: u32 ip + u16 port + 2 pad + u64 srv + u32 ok
        uint8_t buf[24];
        memcpy(buf,     &ip,   4);
        memcpy(buf + 4, &port, 2);
        buf[6] = buf[7] = 0;
        memcpy(buf + 8, &srv,  8);
        uint32_t okU = ok ? 1 : 0;
        memcpy(buf + 16, &okU, 4);
        return send_resp(fd, 0, buf, 20);
    }

    case OP_MM_SETLOBBYGAMESERVER: {
        MM_REQUIRE(p_MM_SetLobbyGameServer);
        if (alen < 22) return send_err(fd, 1);
        uint64_t lobby; uint32_t ip; uint16_t port; uint64_t srv;
        memcpy(&lobby, args,     8);
        memcpy(&ip,    args + 8, 4);
        memcpy(&port,  args + 12, 2);
        memcpy(&srv,   args + 14, 8);
        p_MM_SetLobbyGameServer(g_steam_matchmaking, lobby, ip, port, srv);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_MM_ADDLOBBYLIST_STRINGFILTER: {
        MM_REQUIRE(p_MM_AddLobbyListStringFilter);
        // packed: key\0 val\0 i32 cmp
        if (alen < 6) return send_err(fd, 1);
        const char *key = (const char*)args;
        size_t kl = strnlen(key, alen);
        if (kl + 1 >= alen) return send_err(fd, 1);
        const char *val = key + kl + 1;
        size_t vl = strnlen(val, alen - kl - 1);
        if (kl + 1 + vl + 1 + 4 > alen) return send_err(fd, 1);
        int32_t cmp; memcpy(&cmp, val + vl + 1, 4);
        p_MM_AddLobbyListStringFilter(g_steam_matchmaking, key, val, (int)cmp);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_MM_ADDLOBBYLIST_NUMERICALFILTER: {
        MM_REQUIRE(p_MM_AddLobbyListNumericalFilter);
        // packed: key\0 i32 val i32 cmp
        if (alen < 10) return send_err(fd, 1);
        const char *key = (const char*)args;
        size_t kl = strnlen(key, alen);
        if (kl + 1 + 8 > alen) return send_err(fd, 1);
        int32_t val, cmp;
        memcpy(&val, key + kl + 1,     4);
        memcpy(&cmp, key + kl + 1 + 4, 4);
        p_MM_AddLobbyListNumericalFilter(g_steam_matchmaking, key, (int)val, (int)cmp);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_MM_ADDLOBBYLIST_NEARVALUEFILTER: {
        MM_REQUIRE(p_MM_AddLobbyListNearValueFilter);
        if (alen < 6) return send_err(fd, 1);
        const char *key = (const char*)args;
        size_t kl = strnlen(key, alen);
        if (kl + 1 + 4 > alen) return send_err(fd, 1);
        int32_t val; memcpy(&val, key + kl + 1, 4);
        p_MM_AddLobbyListNearValueFilter(g_steam_matchmaking, key, (int)val);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_MM_ADDLOBBYLIST_FILTERSLOTSAVAILABLE: {
        MM_REQUIRE(p_MM_AddLobbyListFilterSlotsAvailable);
        if (alen < 4) return send_err(fd, 1);
        int32_t n; memcpy(&n, args, 4);
        p_MM_AddLobbyListFilterSlotsAvailable(g_steam_matchmaking, (int)n);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_MM_ADDLOBBYLIST_DISTANCEFILTER: {
        MM_REQUIRE(p_MM_AddLobbyListDistanceFilter);
        if (alen < 4) return send_err(fd, 1);
        int32_t n; memcpy(&n, args, 4);
        p_MM_AddLobbyListDistanceFilter(g_steam_matchmaking, (int)n);
        return send_resp(fd, 0, NULL, 0);
    }

    case OP_MM_ADDLOBBYLIST_RESULTCOUNTFILTER: {
        MM_REQUIRE(p_MM_AddLobbyListResultCountFilter);
        if (alen < 4) return send_err(fd, 1);
        int32_t n; memcpy(&n, args, 4);
        p_MM_AddLobbyListResultCountFilter(g_steam_matchmaking, (int)n);
        return send_resp(fd, 0, NULL, 0);
    }

#undef MM_REQUIRE

    case OP_DRAIN_CALLBACKS: {
        // Drain pending Steam callbacks and ship them back as
        //   [n_cb:u32] N*{ id:u32, data_len:u32, data:bytes }
        //
        // Each callback's data is repacked from macOS pack(4) to Windows
        // pack(8) layout via repack_pack4_to_pack8 — see comment above the
        // function defn for why this matters (LobbyCreated_t etc).
        //
        // Special handling for SteamAPICallCompleted_t (id 703) — this is
        // the manual-dispatch marker for "an async result is ready."  Its
        // pubParam is { u64 hAsyncCall; int iCallback; uint32 cubParam }
        // (16 bytes).  We immediately fetch the real result blob via
        // GetAPICallResult and re-ship it as a special id = 0xFFFFFFFE
        // envelope { realId:u32, hAsyncCall:u64, bFailed:u32, data:bytes }.
        // The bridge looks this id up in its CCallResult registry and
        // invokes vtable slot 1 — RegisterCallback wouldn't catch it.
        // 256 KB drain buffer.  Was 64 KB, but populated lobbies produced
        // single drains of ~65 KB — right at the old limit — which forced the
        // "buffer full → break" paths below to fire mid-callback.  A bigger
        // buffer makes that effectively never happen so no callback is dropped.
        static uint8_t buf[262144];
        uint32_t off = 4;  // reserve space for count
        uint32_t n_cb = 0;

        if (g_dispatch_initialized && p_ManualDispatch_RunFrame &&
            p_ManualDispatch_GetNextCallback && p_ManualDispatch_FreeLastCallback) {
            p_ManualDispatch_RunFrame(g_h_steam_pipe);
            CallbackMsg_t msg;
            while (off + 16 < sizeof buf) {
                if (!p_ManualDispatch_GetNextCallback(g_h_steam_pipe, &msg)) break;
                uint32_t id   = (uint32_t)msg.m_iCallback;
                uint32_t dlen = (uint32_t)msg.m_cubParam;

                if (id == 703 && p_ManualDispatch_GetAPICallResult && dlen >= 16 && msg.m_pubParam) {
                    // SteamAPICallCompleted_t — fetch the real result.
                    uint64_t hAsyncCall;
                    uint32_t realId;
                    uint32_t cubParam;
                    memcpy(&hAsyncCall, msg.m_pubParam,     8);
                    memcpy(&realId,     msg.m_pubParam + 8, 4);
                    memcpy(&cubParam,   msg.m_pubParam + 12, 4);
                    // Fetch into a scratch buffer.
                    uint8_t result[4096];
                    if (cubParam > sizeof result) cubParam = sizeof result;
                    int bFailed = 0;
                    int ok = p_ManualDispatch_GetAPICallResult(g_h_steam_pipe, hAsyncCall,
                                                                result, (int)cubParam,
                                                                (int)realId, &bFailed);
                    if (!ok) cubParam = 0;
                    // Repack pack(4) → pack(8) for the data portion before
                    // we wire the envelope (LobbyCreated_t etc. need their
                    // uint64 fields moved to 8-aligned offsets).
                    uint8_t repacked[1024];
                    uint32_t repackedLen = cubParam;
                    if (cubParam) {
                        repackedLen = repack_pack4_to_pack8(realId, result, cubParam, repacked);
                        if (repackedLen > sizeof repacked) repackedLen = sizeof repacked;
                    }
                    // Wire as id=0xFFFFFFFE { realId:u32, hAsyncCall:u64, bFailed:u32, data:bytes }
                    uint32_t envelopeLen = 4 + 8 + 4 + repackedLen;
                    if (off + 8 + envelopeLen > sizeof buf) {
                        // Buffer full.  We already pulled this callback via
                        // GetNextCallback — we MUST FreeLastCallback before
                        // breaking, or Steam's pipe keeps an "outstanding
                        // callback" forever and every subsequent Steam call
                        // trips the m_OutstandingCallbackThreadId assertion,
                        // wedging all future callback delivery (this is what
                        // hung matchmaking at "Searching for Games").  We lose
                        // this one callback; the 256 KB buffer makes that path
                        // effectively unreachable in practice.
                        p_ManualDispatch_FreeLastCallback(g_h_steam_pipe);
                        break;
                    }
                    uint32_t marker = 0xFFFFFFFEu;
                    uint32_t bFailedU = bFailed ? 1 : 0;
                    memcpy(buf + off, &marker,      4); off += 4;
                    memcpy(buf + off, &envelopeLen, 4); off += 4;
                    memcpy(buf + off, &realId,      4); off += 4;
                    memcpy(buf + off, &hAsyncCall,  8); off += 8;
                    memcpy(buf + off, &bFailedU,    4); off += 4;
                    if (repackedLen) { memcpy(buf + off, repacked, repackedLen); off += repackedLen; }
                    n_cb++;
                    hlog("[helper] call-result id=%u hCall=%llu bFailed=%d cb=%u→%u\n",
                            realId, (unsigned long long)hAsyncCall, bFailed, cubParam, repackedLen);
                    p_ManualDispatch_FreeLastCallback(g_h_steam_pipe);
                    continue;
                }

                // Plain CCallback path — also repack pack(4) → pack(8).
                uint8_t repacked[1024];
                uint32_t repackedLen = dlen;
                if (dlen && msg.m_pubParam) {
                    repackedLen = repack_pack4_to_pack8(id, msg.m_pubParam, dlen, repacked);
                    if (repackedLen > sizeof repacked) repackedLen = sizeof repacked;
                }
                if (off + 8 + repackedLen > sizeof buf) {
                    // Same as the call-result path above: free before breaking
                    // so Steam's pipe doesn't keep an outstanding callback and
                    // wedge all future delivery.
                    p_ManualDispatch_FreeLastCallback(g_h_steam_pipe);
                    break;
                }
                memcpy(buf + off, &id,           4); off += 4;
                memcpy(buf + off, &repackedLen,  4); off += 4;
                if (repackedLen) {
                    memcpy(buf + off, repacked, repackedLen);
                    off += repackedLen;
                }
                n_cb++;
                p_ManualDispatch_FreeLastCallback(g_h_steam_pipe);
            }
        }
        // Inject any queued synthetic callbacks.  Data is already in
        // Windows pack(8) layout, so it skips the per-id repack table.
        for (int i = 0; i < g_synth_n; i++) {
            synth_cb_t *e = &g_synth_cbs[i];
            if (off + 8 + e->dlen > sizeof buf) break;
            memcpy(buf + off, &e->id,   4); off += 4;
            memcpy(buf + off, &e->dlen, 4); off += 4;
            if (e->dlen) { memcpy(buf + off, e->data, e->dlen); off += e->dlen; }
            n_cb++;
            hlog("[helper] injected synthetic callback id=%u dlen=%u\n",
                    e->id, e->dlen);
        }
        g_synth_n = 0;  // queue emptied
        memcpy(buf, &n_cb, 4);
        if (n_cb) hlog("[helper] drained %u callback(s) (%u bytes)\n", n_cb, off);
        return send_resp(fd, 0, buf, off);
    }

    case OP_QUIT:
        printf("[helper] quit requested\n");
        send_u32(fd, 0);
        if (p_SteamAPI_Shutdown) p_SteamAPI_Shutdown();
        exit(0);

    default:
        fprintf(stderr, "[helper] unknown op 0x%04x\n", op);
        return send_err(fd, 0xFFFFFFFF);
    }
}

int main(int argc, char **argv) {
    int port = (argc > 1) ? atoi(argv[1]) : DEFAULT_PORT;

    // Verbose per-op/per-callback tracing is off unless L4D2_HELPER_DEBUG=1.
    const char *dbgEnv = getenv("L4D2_HELPER_DEBUG");
    g_helper_debug = (dbgEnv && dbgEnv[0] == '1') ? 1 : 0;

    signal(SIGPIPE, SIG_IGN);

    if (load_steam() < 0) return 1;

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }
    int yes = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);

    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(port),
                                .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (bind(srv, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("bind"); return 1;
    }
    if (listen(srv, 4) < 0) { perror("listen"); return 1; }
    printf("[helper] listening on 127.0.0.1:%d\n", port);

    for (;;) {
        int c = accept(srv, NULL, NULL);
        if (c < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            break;
        }
        int one = 1;
        setsockopt(c, IPPROTO_TCP, 1 /* TCP_NODELAY */, &one, sizeof one);
        while (handle_one(c) == 0) { /* loop */ }
        close(c);
    }
    return 0;
}
