#include <sourcemod>
#include <clients>
#include <clientprefs>
#undef REQUIRE_EXTENSIONS
#tryinclude <SteamWorks> ///< _SteamWorks_Included
#tryinclude <ripext> ///< _ripext_included_
#define REQUIRE_EXTENSIONS

#include <multicolors>

#include <sourcebanschecker>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "25w21a"

public Plugin myinfo = {
	name = "Trust Factor",
	author = "reBane",
	description = "Determin player trustfactor for premissive integration",
	version = PLUGIN_VERSION,
	url = "N/A"
}

#define MAX_STEAMID_LENGTH 32

enum TrustFactors {
	UNTRUSTED = 0,
	TrustPlaytime         = 0x0001, // t  playtime on server network
	TrustPremium          = 0x0002, // f  is using free2play account
	TrustDonorFlag        = 0x0004, // d  player is donor / has spent money on the server
	TrustCProfilePublic   = 0x0008, // p  is community profile public
	TrustCProfileSetup    = 0x0010, // s  is community profile set up
	TrustCProfileLevel    = 0x0020, // l  community profile level
	TrustCProfileGametime = 0x0040, // g  total playtime for the game
	TrustCProfileAge      = 0x0080, // o  profile age in months
	TrustCProfilePoCBadge = 0x0100, // b  progress for pillar of community badge
	TrustNoVACBans        = 0x0200, // v  no active or passed VAC banns
	TrustNotEconomyBanned = 0x0400, // e  not currently trade/economy banned
	TrustSBPPGameBan      = 0x0800, // a  has little to no sb game bans
	TrustSBPPCommBan      = 0x1000, // c  has little to no sb comm bans
}
#define ALLTRUSTFACTORS (view_as<TrustFactors>(0x0fff))

enum struct TrustData {
	int loaded;
	bool isDonor;
	int playtime;
	bool premium;
	bool profilePublic;
	bool profileSetup;
	int communityLevel;
	int gametime;
	int profileAge;
	int badgeLevel;
	bool vacBanned; //has vac bans on record (might decay after 6 years)
	bool tradeBanned; //is trade/economy banned
	int sbppGameBans;
	int sbppCommBans;
	TrustFactors trustFlags;
	int trustLevel;
}
#define LOADED_LOCALDATA 0x01
#define LOADED_PREMIUM 0x02
#define LOADED_PROFILEDATA 0x04
#define LOADED_SOURCEBANS 0x08
#define LOADED_ALL 0x0F
#define COOKIE_TRUST_PLAYTIME "TrustPlayTime"

#define GetClientTrustData(%1,%2) client_trustData.GetArray(client_steamIds[(%1)], (%2), sizeof(TrustData))
#define SetClientTrustData(%1,%2) client_trustData.SetArray(client_steamIds[(%1)], (%2), sizeof(TrustData))
#define HookAndLoadConVar(%1,%2) { char def[256],val[256]; %1.AddChangeHook(%2); %1.GetDefault(def,256); %1.GetString(val,256); %2(%1,def,val); }

StringMap client_trustData;
char client_steamIds[MAXPLAYERS][MAX_STEAMID_LENGTH];
static Cookie gCookiePlaytime = null;

#define SWAPI_CHECK_PROFILE 1
#define SWAPI_CHECK_STEAMLVL 2
#define SWAPI_CHECK_GAMETIME 4
#define SWAPI_CHECK_BANS 8

static int steamAppId, steamDlcId; //for game and premium dlc
static char engineMeta[2][32];
static int swapi_checks; //check flags for below Check* cvars
static bool dep_SBPP; //gate sourcebans stuff behind dep check
static bool dep_SteamWorks;
static bool dep_RIPext;
static char playerCacheUrl[PLATFORM_MAX_PATH]; //url to get stuff from
static char playerCacheUserAgent[128];
static int trust_communityLevel; //int
static int trust_gametime;       //in hours
static int trust_servertime;     //in minutes
static int trust_pocbadge;       //level (0,1,2,3)
static int trust_sbppbans;       //int
static int trust_sbppcomms;      //int
static int trust_donorflags;     //AdmFlag bit string
static char trust_donorgroup[MAX_NAME_LENGTH]; //OverrideGroup for donor permissions
static ConVar cvar_CheckProfile;    //check ISteamUser/GetPlayerSummaries for communityvisibilitystate==3, profilestate==1, timecreated
static ConVar cvar_CheckSteamLevel; //check IPlayerService/GetBadges for community level & poc level
static ConVar cvar_CheckGametime;   //check IPlayerService/GetOwnedGames for poc badge progress
static ConVar cvar_CheckBans;   //check IPlayerService/GetOwnedGames for poc badge progress
//maybe add this at some point : ISteamUser/GetPlayerBans
static ConVar cvar_PlayerCacheURL;      //cache php script url
static ConVar cvar_TrustCommunityLevel; //required community level to count as trusted
static ConVar cvar_TrustGametime;       //required overall game playtime to count as trusted
static ConVar cvar_TrustServertime;     //required on-server playtime to count as trusted
static ConVar cvar_TrustPoCBadge;       //required Pillar of Community badge progress to count as trusted
static ConVar cvar_TrustDonorFlags;     //required SourceMod AdminFlags to count as trusted
static ConVar cvar_TrustDonorGroup;     //required SourceMod Admin Group to count as trusted
static ConVar cvar_TrustSBPPBans;       //maximum SBPP Bans to count as trusted
static ConVar cvar_TrustSBPPComms;      //maximum SBPP Comm Bans to count as trusted
static ConVar cvar_version;
static GlobalForward fwdOnTrustLoaded;
static GlobalForward fwdOnTrustChanged;

bool b_lateLoad;

public void OnPluginStart() {
	LoadTranslations("common.phrases");

	GameData gamedata = new GameData("trustfactor.games");
	if (gamedata != INVALID_HANDLE) {
		char buffer[64];
		if (!gamedata.GetKeyValue("PremiumAppId", buffer, sizeof(buffer)) || (steamDlcId = StringToInt(buffer))<=0) {
			PrintToServer("Could not load premium DLC AppId");
			steamDlcId = 0;
		}
		delete gamedata;
	}
	GetSteamInf();
	GenerateUserAgent();
	PrintToServer("[TrustFactor] Detected: %s", playerCacheUserAgent);

	client_trustData = new StringMap();

	gCookiePlaytime = new Cookie(COOKIE_TRUST_PLAYTIME, "Playtime as tracked for trust factor", CookieAccess_Private);

	cvar_version =             CreateConVar("sm_trustfactor_version", PLUGIN_VERSION, "TrustFactor Version", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	cvar_CheckProfile =        CreateConVar("sm_trustfactor_checkprofile", "0", "Request steam profile to be checked", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0, true, 1.0);
	cvar_CheckSteamLevel =     CreateConVar("sm_trustfactor_checksteamlvl", "0", "Request steam community level and poc badge level to be checked", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0, true, 1.0);
	cvar_CheckGametime =       CreateConVar("sm_trustfactor_checkgametime", "0", "Request global gametime to be checked", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0, true, 1.0);
	cvar_CheckBans =           CreateConVar("sm_trustfactor_checkbans", "0", "Request vac and trade ban data to be checked", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0, true, 1.0);
	cvar_PlayerCacheURL =      CreateConVar("sm_trustfactor_playercacheurl", "", "Specifies the steam webapi proxy, set empty to not use any profile data", FCVAR_HIDDEN|FCVAR_PROTECTED|FCVAR_UNLOGGED);
	cvar_TrustCommunityLevel = CreateConVar("sm_trustfactor_minsteamlevel", "2", "Steam Community Level required to flag Trustworthy, 0 to disable", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0);
	cvar_TrustGametime =       CreateConVar("sm_trustfactor_mingametime", "24", "Global game playtime [hr] required to flag Trustworthy, 0 to disable", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0);
	cvar_TrustServertime =     CreateConVar("sm_trustfactor_minservertime", "300", "Playtime on server(network) [min] required to flag Trustworthy, 0 to disable", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0);
	cvar_TrustPoCBadge =       CreateConVar("sm_trustfactor_minpocprogress", "1", "Pillar of Community badge level required to flag Trustworthy, 0 to disable", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0, true, 3.0);
	cvar_TrustDonorFlags =     CreateConVar("sm_trustfactor_donorflag", "z", "SourceMod AdminFlag to flag Trustworthy (Donors), empty to disable", FCVAR_HIDDEN|FCVAR_UNLOGGED);
	cvar_TrustDonorGroup =     CreateConVar("sm_trustfactor_donorgroup", "", "SourceMod Admin Group name to flag Trustworthy (Donors), empty to disable", FCVAR_HIDDEN|FCVAR_UNLOGGED);
	cvar_TrustSBPPBans =      CreateConVar("sm_trustfactor_sbppbans", "0", "Maximum number of SourceBans++ bans to flag Trustworthy", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0);
	cvar_TrustSBPPComms =     CreateConVar("sm_trustfactor_sbppcomms", "0", "Maximum number of SourceBans++ comm bans to flag Trustworthy", FCVAR_HIDDEN|FCVAR_UNLOGGED, true, 0.0);
	HookAndLoadConVar(cvar_version, OnConVarChanged_locked)
	HookAndLoadConVar(cvar_CheckProfile, OnConVarChanged_checkProfile)
	HookAndLoadConVar(cvar_CheckSteamLevel, OnConVarChanged_checkSteamLvL)
	HookAndLoadConVar(cvar_CheckGametime, OnConVarChanged_checkGametime)
	HookAndLoadConVar(cvar_CheckBans, OnConVarChanged_checkBans)
	HookAndLoadConVar(cvar_PlayerCacheURL, OnConVarChanged_playerCacheURL)
	HookAndLoadConVar(cvar_TrustCommunityLevel, OnConVarChanged_trustCommunityLevel)
	HookAndLoadConVar(cvar_TrustGametime, OnConVarChanged_trustGametime)
	HookAndLoadConVar(cvar_TrustServertime, OnConVarChanged_trustServertime)
	HookAndLoadConVar(cvar_TrustPoCBadge, OnConVarChanged_trustPoCBadge)
	HookAndLoadConVar(cvar_TrustDonorFlags, OnConVarChanged_trustDonorFlags)
	HookAndLoadConVar(cvar_TrustDonorGroup, OnConVarChanged_trustDonorGroup)
	HookAndLoadConVar(cvar_TrustSBPPBans, OnConVarChanged_trustSBPPBans)
	HookAndLoadConVar(cvar_TrustSBPPComms, OnConVarChanged_trustSBPPComms)
	AutoExecConfig();

	fwdOnTrustLoaded = new GlobalForward("OnClientTrustFactorLoaded", ET_Ignore, Param_Cell, Param_Cell);
	fwdOnTrustChanged = new GlobalForward("OnClientTrustFactorChanged", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);

	RegAdminCmd("sm_checktrust", Command_CheckTrust, ADMFLAG_GENERIC, "Read all trust values for a player");
	RegAdminCmd("sm_reload_playertrust", Command_RecachePlayers, ADMFLAG_BAN, "Reload trust cache for players already connected");

	if (b_lateLoad) ReloadAllPlayers();
}

public void OnAllPluginsLoaded() {
	dep_SBPP = LibraryExists("sourcebans++");
	char buffer[4];
	dep_SteamWorks = GetExtensionFileStatus("SteamWorks.ext", buffer, 0) == 1;
	dep_RIPext = GetExtensionFileStatus("rip.ext", buffer, 0) == 1;

	PrintToServer("[TrustFactor] Detected Dependencies: SourceBans++ %s, SteamWorks %s, REST in Pawn %s",
		(dep_SBPP ? "yes" : "no"),
		(dep_SteamWorks ? "yes" : "no"),
		(dep_RIPext ? "yes" : "no"));
}
public void OnLibraryAdded(const char[] name) {
	if (StrEqual(name, "sourcebans++")) dep_SBPP = true;
}
public void OnLibraryRemoved(const char[] name) {
	if (StrEqual(name, "sourcebans++")) dep_SBPP = false;
}


public void OnMapStart() {
	CreateTimer(60.0, Timer_Playtime, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Playtime(Handle timer) {
	TrustData cdata;
	char buffer[32];
	for (int client=1; client<=MaxClients; client++) {
		if (!IsValidClient(client)) continue;
		if (client_steamIds[client][0]) {
			GetClientTrustData(client, cdata);
			if (cdata.loaded == LOADED_ALL) {
				cdata.playtime++;
				if (gCookiePlaytime != INVALID_HANDLE) {
					Format(buffer, sizeof(buffer), "%i", cdata.playtime);
					gCookiePlaytime.Set(client, buffer);
				}
				SetClientTrustData(client, cdata);
			}
		}
	}
	return Plugin_Continue;
}

public Action Command_CheckTrust(int client, int args) {
	char buffer[128];
	if (GetCmdArgs() != 1) {
		GetCmdArg(0, buffer, sizeof(buffer));
		ReplyToCommand(client, "Usage: %s <player>", buffer);
	} else {
		int players[1];
		char buffer2[64];
		bool tnisml;
		GetCmdArg(1, buffer, sizeof(buffer));
		int hits = ProcessTargetString(buffer, client, players, 1, COMMAND_FILTER_NO_BOTS|COMMAND_FILTER_NO_MULTI|COMMAND_FILTER_NO_IMMUNITY, buffer2, 0, tnisml);
		if (hits != 1) {
			ReplyToTargetError(client, hits);
			return Plugin_Handled;
		}
		CReplyToCommand(client, "{gray}Trust Data for{dodgerblue} %N", players[0]);
		TrustData cdata;
		if (!GetTrustClient(players[0], cdata)) {
			CReplyToCommand(client, "  {darkgray}Data for this player has not been loaded yet");
		} else {
			char colors[4][12] = { "green", "gold", "red", "darkgray" };
			char ynstr[3][8] = { "Yes", "No", "Unknown" };
			bool condition;
			int a,b;

			if (steamDlcId) {
				condition = cdata.premium;
				CReplyToCommand(client, "  Is Free2Play: {%s}%s", colors[condition?0:2], ynstr[condition?1:0]);
			}

			condition = cdata.isDonor;
			CReplyToCommand(client, "  Is Donator: {%s}%s", colors[condition?0:2], ynstr[condition?0:1]);

			condition = cdata.playtime >= trust_servertime;
			CReplyToCommand(client, "  Playtime Server: {%s}%d/%d min", colors[condition?0:2], cdata.playtime, trust_servertime);

			condition = cdata.gametime >= trust_gametime;
			if (swapi_checks & SWAPI_CHECK_GAMETIME)
				CReplyToCommand(client, "  Playtime Global: {%s}%d/%d hr", colors[condition?0:2], cdata.gametime, trust_gametime);
			else
				CReplyToCommand(client, "  Playtime Global: {gold}%d hr", cdata.gametime, trust_gametime);

			condition = cdata.profilePublic;
			a = (swapi_checks & SWAPI_CHECK_PROFILE) ? (condition?0:2) : 1;
			CReplyToCommand(client, "  Public Profile: {%s}%s", colors[a], ynstr[condition?0:1]);

			condition = cdata.profileSetup;
			a = (swapi_checks & SWAPI_CHECK_PROFILE) ? (condition?0:2) : 1;
			CReplyToCommand(client, "  Profile Set up: {%s}%s", colors[a], ynstr[condition?0:1]);

			if (cdata.profileAge) { a=0;b=1; }
			else if (cdata.profilePublic) { a=3;b=2; }
			else { a=2;b=0; }
			if ((swapi_checks & SWAPI_CHECK_PROFILE) && a==3) a=1;
			CReplyToCommand(client, "  Profile New: {%s}%s", colors[a], ynstr[b]);

			if (trust_communityLevel<1)
				CReplyToCommand(client, "  Profile Level: {gold}%d", cdata.communityLevel);
			else {
				condition = cdata.communityLevel >= trust_communityLevel;
				CReplyToCommand(client, "  Profile Level: {%s}%d/%d", colors[condition?0:2], cdata.communityLevel, trust_communityLevel);
			}

			if (trust_communityLevel<1)
				CReplyToCommand(client, "  Community Badge: {gold}%d", cdata.badgeLevel);
			else {
				condition = cdata.badgeLevel >= trust_pocbadge;
				CReplyToCommand(client, "  Community Badge: {%s}%d/%d", colors[condition?0:2], cdata.badgeLevel, trust_pocbadge);
			}

			condition = cdata.vacBanned;
			a = (swapi_checks & SWAPI_CHECK_BANS) ? (condition?2:0) : 1;
			CReplyToCommand(client, "  VAC Bans on Record: {%s}%s", colors[a], ynstr[condition?0:1]);

			condition = cdata.tradeBanned;
			a = (swapi_checks & SWAPI_CHECK_BANS) ? (condition?2:0) : 1;
			CReplyToCommand(client, "  Trade Banned: {%s}%s", colors[a], ynstr[condition?0:1]);

			if (!dep_SBPP)
				CReplyToCommand(client, "  SourceBans++: {darkgray}Not Available");
			else {
				condition = cdata.sbppGameBans <= trust_sbppbans;
				CReplyToCommand(client, "  SB++ Bans: {%s}%d/%d", colors[condition?0:2], cdata.sbppGameBans, trust_sbppbans);
				condition = cdata.sbppCommBans <= trust_sbppcomms;
				CReplyToCommand(client, "  SB++ Mutes: {%s}%d/%d", colors[condition?0:2], cdata.sbppCommBans, trust_sbppcomms);
			}

			CReplyToCommand(client, "  {gold}Trust Level: %d/13", cdata.trustLevel);
		}
	}
	return Plugin_Handled;
}

public Action Command_RecachePlayers(int admin, int args) {
	LogAction(admin, -1, "[TrustFactor] %L triggered a reload", admin);
	ReplyToCommand(admin, "[TrustFactor] Player Caches are rebuilding...");
	ReloadAllPlayers();
	return Plugin_Handled;
}

static void ReloadAllPlayers() {
	for (int client=1; client<=MaxClients; client++) {
		if (!IsValidClient(client)) continue;
		OnClientDisconnect(client);
		if (IsClientAuthorized(client)) {
			OnClientPostAdminCheck(client);
		}
		if (AreClientCookiesCached(client)) {
			OnClientCookiesCached(client);
		}
		if (SBPP_CheckerGetClientsBans(client)>=0) {
			SBPP_CheckerClientBanCheckPost(client);
		}
	}
}

// -- generic flag collection --

static void EnsureClientData(int client) {
	//already loaded, we have a steamid set
	if (client_steamIds[client][0]) return;

	//i've seen bots use steamid inited to 0 in tf2, ignore all bots
	char auth[MAX_STEAMID_LENGTH];
	if (!IsValidClient(client)) {
		return;
	}

	//prepare player structs
	GetClientAuthId(client, AuthId_SteamID64, client_steamIds[client], MAX_STEAMID_LENGTH);
	TrustData cdata;
	client_trustData.SetArray(auth, cdata, sizeof(TrustData));
}

public void OnClientConnected(int client)
{
	EnsureClientData(client);
}

public void OnClientPostAdminCheck(int client) {
	EnsureClientData(client);
	if (!IsValidClient(client)) return;

	TrustData cdata;
	GetClientTrustData(client, cdata);
	cdata.isDonor = CheckClientAdminFlags(client);
	if (!dep_SteamWorks) cdata.premium = false; // required to test
	else if (steamDlcId) cdata.premium = SteamWorks_HasLicenseForApp(client, steamDlcId) == k_EUserHasLicenseResultHasLicense;
	cdata.loaded |= LOADED_PREMIUM;
	SetClientTrustData(client, cdata);
	//can' be done loading here yet

	if (dep_SteamWorks) SteamWorksQueryClient(client);
	else if (dep_RIPext) RIPextQueryClient(client);
	else DontQueryClient(client);
}

public void OnRebuildAdminCache(AdminCachePart part) {
	RequestFrame(ReloadAdminFlags);
}
static void ReloadAdminFlags() {
	TrustData cdata;
	for (int client=1; client <= MaxClients; client++) {
		if (!GetTrustClient(client, cdata)) continue;
		bool nowDonor = CheckClientAdminFlags(client);
		bool change = nowDonor != cdata.isDonor;
		if (change) {
			cdata.isDonor = nowDonor;
			UpdateTrustfactor(client);
		}
	}
}

public void OnClientDisconnect(int client) {
	if (client_steamIds[client][0]!=0) {
		client_trustData.Remove(client_steamIds[client]);
		client_steamIds[client][0]=0;
	}
}

public void OnClientCookiesCached(int client) {
	EnsureClientData(client);
	if (!IsValidClient(client)) return;

	TrustData cdata;
	char buffer[32];
	int value;
	GetClientTrustData(client, cdata);
	if (gCookiePlaytime != INVALID_HANDLE) {
		gCookiePlaytime.Get(client, buffer, sizeof(buffer));
		value = StringToInt(buffer);
		cdata.playtime = value;
	}
	cdata.loaded |= LOADED_LOCALDATA;
	SetClientTrustData(client, cdata);
	Notify_OnTrustFactorLoaded(client);
}

// -- steam api helper --

static void ProcessWebValue(int client, const char[] value)
{
	TrustData cdata;
	GetClientTrustData(client, cdata);

	int contentLength = strlen(value);
	int version = SubStrToInt(value,0,2);
	if (version == 1 && contentLength >= 16) {
		int flags = SubStrToInt(value,2,2);
		cdata.profileSetup =  (flags & 0x01) != 0;
		cdata.profilePublic = (flags & 0x02) != 0;
		cdata.profileAge =    (flags & 0x04) != 0;
		cdata.badgeLevel =    (flags & 0xf0) >> 4;
		cdata.communityLevel = SubStrToInt(value,4,4);
		cdata.gametime = SubStrToInt(value,8,8);
		cdata.vacBanned = cdata.tradeBanned = false; //no data
	} else if (version == 2 && contentLength >= 18) {
		int flags = SubStrToInt(value,2,2);
		cdata.profileSetup =  (flags & 0x01) != 0;
		cdata.profilePublic = (flags & 0x02) != 0;
		cdata.profileAge =    (flags & 0x04) != 0;
		cdata.vacBanned =     (flags & 0x08) != 0;
		cdata.tradeBanned =   (flags & 0x10) != 0;
		cdata.badgeLevel =    SubStrToInt(value,4,2);
		cdata.communityLevel = SubStrToInt(value,6,4);
		cdata.gametime = SubStrToInt(value,10,8);
	} else {
		PrintToServer("[TrustFactor] Error or proxy response version not supported");
	}

	cdata.loaded |= LOADED_PROFILEDATA;
	SetClientTrustData(client, cdata);
	Notify_OnTrustFactorLoaded(client);
}
static void SkipWebData(int client)
{

	TrustData cdata;
	GetClientTrustData(client, cdata);
	cdata.loaded |= LOADED_PROFILEDATA;
	SetClientTrustData(client, cdata);
	Notify_OnTrustFactorLoaded(client);
}

// -- steamworks api query : steamworks --

static void SteamWorksQueryClient(int client) {
	//manually "finish" profile data if web disabled
	if (playerCacheUrl[0]==0 || swapi_checks==0) {
		TrustData cdata;
		GetClientTrustData(client, cdata);
		cdata.loaded |= LOADED_PROFILEDATA;
		SetClientTrustData(client, cdata);
		if (cdata.loaded == LOADED_ALL) UpdateTrustfactor(client);
		return;
	}

	char buffer[32];
//	PrintToServer("[Trustfactor] SteamWorkds : Connecting with cache at %s for %N: %s, %d, %d", playerCacheUrl, client, client_steamIds[client], steamAppId, swapi_checks);
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, playerCacheUrl);
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(request, 10_000);
	SteamWorks_SetHTTPRequestUserAgentInfo(request, playerCacheUserAgent);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "steamId", client_steamIds[client]);
	Format(buffer, sizeof(buffer), "%i", steamAppId);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "appId", buffer);
	Format(buffer, sizeof(buffer), "%i", swapi_checks);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "cdata", buffer);
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Trustfactor", PLUGIN_VERSION);
	SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", "text/plain");
	SteamWorks_SetHTTPRequestContextValue(request, GetClientUserId(client));
	SteamWorks_SetHTTPCallbacks(request, OnProfileDataCached_SW);
	SteamWorks_SendHTTPRequest(request);
}

public void OnProfileDataCached_SW(Handle handle, bool failed, bool successfull, EHTTPStatusCode statusCode, int userId) {
	int client = GetClientOfUserId(userId);
	if (!IsValidClient(client)) {
		//client disconnected, we don't care anymore
		delete handle;
		return;
	}

	if (!successfull || statusCode != k_EHTTPStatusCode200OK) {
		PrintToServer("[TrustFactor] Proxy response failed for %N", client);
		SkipWebData(client);
		if (successfull) delete handle;
	} else {
		int contentLength;
		if (SteamWorks_GetHTTPResponseBodySize(handle, contentLength)) {
			char buffer[128];
			SteamWorks_GetHTTPResponseBodyData(handle, buffer, (contentLength<sizeof(buffer) ? contentLength : sizeof(buffer)));

			ProcessWebValue(client, buffer);
		} else {
			SkipWebData(client);
		}
		delete handle;
	}
}

// -- steamworks api query : ripext--

static void RIPextQueryClient(int client) {
	//manually "finish" profile data if web disabled
	if (playerCacheUrl[0]==0 || swapi_checks==0) {
		TrustData cdata;
		GetClientTrustData(client, cdata);
		cdata.loaded |= LOADED_PROFILEDATA;
		SetClientTrustData(client, cdata);
		if (cdata.loaded == LOADED_ALL) UpdateTrustfactor(client);
		return;
	}

//	PrintToServer("[Trustfactor] RIPext : Connecting with cache at %s for %N: %s, %d, %d", playerCacheUrl, client, client_steamIds[client], steamAppId, swapi_checks);
	HTTPRequest request = new HTTPRequest(playerCacheUrl);
	request.ConnectTimeout = 10;
	request.Timeout = 10;
	request.SetHeader("User-Agent", "%s", playerCacheUserAgent);
	request.SetHeader("X-Trustfactor", "%s", PLUGIN_VERSION);
	request.SetHeader("Accept", "application/json");
	request.AppendQueryParam("steamId", "%s", client_steamIds[client]);
	request.AppendQueryParam("appId", "%i", steamAppId);
	request.AppendQueryParam("cdata", "%i", swapi_checks);
	request.Get(OnProfileDataCached_RIP, GetClientUserId(client));
}

void OnProfileDataCached_RIP(HTTPResponse response, any userId, const char[] error)
{
	int client = GetClientOfUserId(userId);
	if (!IsValidClient(client)) {
		//client disconnected, we don't care anymore
		return;
	}

	if (error[0] != 0) {
		LogError("[TrustFactor] Failed to query Steam API using RIPExt: %s", error);
		SkipWebData(client);
	} else if (response.Status != HTTPStatus_OK) {
		LogError("[TrustFactor] Failed to query Steam API using RIPExt: http.cat/%d", response.Status);
		SkipWebData(client);
	} else {
		char buffer[128];
		if (view_as<JSONObject>(response.Data).GetString("value", buffer, sizeof(buffer))) {
			ProcessWebValue(client, buffer);
		} else {
			SkipWebData(client);
		}
	}
}

// -- steamworks api query : skipped --

static void DontQueryClient(int client) {
	SkipWebData(client);
}

// -- sourcebans --

public void SBPP_CheckerClientBanCheckPost(int client) {
	EnsureClientData(client);
	if (!IsValidClient(client)) return;

	TrustData cdata;
	GetClientTrustData(client, cdata);
	cdata.sbppGameBans = SBPP_CheckerGetClientsBans(client);
	cdata.sbppCommBans = SBPP_CheckerGetClientsComms(client);
	cdata.loaded |= LOADED_SOURCEBANS;
	SetClientTrustData(client, cdata);
	Notify_OnTrustFactorLoaded(client);
}

// -- convars & notifier --

public void OnConVarChanged_locked(ConVar convar, const char[] oldValue, const char[] newValue) {
	char def[64];
	if (GetPluginInfo(INVALID_HANDLE, PlInfo_Version, def, sizeof(def)) && !StrEqual(def, newValue)) convar.SetString(def,_,true);
}
public void OnConVarChanged_checkProfile(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (convar.BoolValue)
		swapi_checks |= SWAPI_CHECK_PROFILE;
	else
		swapi_checks &=~SWAPI_CHECK_PROFILE;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_checkSteamLvL(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (convar.BoolValue)
		swapi_checks |= SWAPI_CHECK_STEAMLVL;
	else
		swapi_checks &=~SWAPI_CHECK_STEAMLVL;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_checkGametime(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (convar.BoolValue)
		swapi_checks |= SWAPI_CHECK_GAMETIME;
	else
		swapi_checks &=~SWAPI_CHECK_GAMETIME;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_checkBans(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (convar.BoolValue)
		swapi_checks |= SWAPI_CHECK_BANS;
	else
		swapi_checks &=~SWAPI_CHECK_BANS;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_playerCacheURL(ConVar convar, const char[] oldValue, const char[] newValue) {
	strcopy(playerCacheUrl, sizeof(playerCacheUrl), newValue);
	TrimString(playerCacheUrl);
	UpdateTrustfactorAll();
}
public void OnConVarChanged_trustCommunityLevel(ConVar convar, const char[] oldValue, const char[] newValue) {
	trust_communityLevel = convar.IntValue;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_trustGametime(ConVar convar, const char[] oldValue, const char[] newValue) {
	trust_gametime = convar.IntValue;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_trustPoCBadge(ConVar convar, const char[] oldValue, const char[] newValue) {
	trust_pocbadge = convar.IntValue;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_trustServertime(ConVar convar, const char[] oldValue, const char[] newValue) {
	trust_servertime = convar.IntValue;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_trustDonorFlags(ConVar convar, const char[] oldValue, const char[] newValue) {
	int read, len=strlen(newValue), flags;
	if (len > 0) {
		flags = ReadFlagString(newValue, read);
		if (read != len) convar.SetString(oldValue);
	}
	trust_donorflags = flags;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_trustDonorGroup(ConVar convar, const char[] oldValue, const char[] newValue) {
	strcopy(trust_donorgroup, sizeof(trust_donorgroup), newValue);
	UpdateTrustfactorAll();
}
public void OnConVarChanged_trustSBPPBans(ConVar convar, const char[] oldValue, const char[] newValue) {
	trust_sbppbans = convar.IntValue;
	UpdateTrustfactorAll();
}
public void OnConVarChanged_trustSBPPComms(ConVar convar, const char[] oldValue, const char[] newValue) {
	trust_sbppcomms = convar.IntValue;
	UpdateTrustfactorAll();
}

void Notify_OnTrustFactorLoaded(int client) {
	TrustData data;
	UpdateTrustfactor(client,false);
	GetClientTrustData(client,data);
	if (data.loaded == LOADED_ALL) {
		Call_StartForward(fwdOnTrustLoaded);
		Call_PushCell(client);
		Call_PushCell(data.trustFlags);
		Call_Finish();
	}
}

// -- utils --

static bool _updateTrustfactorAllIndirect=false;
/**
 * @param indirect - skip all further indirect calls until a scheduled call on the next frame has processed
 */
static void UpdateTrustfactorAll(bool indirect=true) {
	if (indirect) {
		if (_updateTrustfactorAllIndirect) return;
		_updateTrustfactorAllIndirect = true;
		RequestFrame(UpdateTrustfactorAll);
	} else {
		_updateTrustfactorAllIndirect = false;
		for (int client=1;client<=MaxClients;client++) {
			if (IsValidClient(client))
				UpdateTrustfactor(client);
		}
	}
}
static void UpdateTrustfactor(int client, bool broadcast=true) {
	TrustData cdata;
	TrustFactors previousFlags;
	int previousLevel;
	if (!GetTrustClient(client, cdata)) return;
	previousFlags = cdata.trustFlags;
	previousLevel = cdata.trustLevel;
	cdata.trustFlags = UNTRUSTED;
	cdata.trustLevel = 0;
	if (cdata.premium) { cdata.trustFlags |= TrustPremium; cdata.trustLevel++; }
	if (cdata.playtime > trust_servertime) { cdata.trustFlags |= TrustPlaytime; cdata.trustLevel++; }
	if (cdata.gametime > trust_gametime) { cdata.trustFlags |= TrustCProfileGametime; cdata.trustLevel++; }
	if (cdata.profileAge) { cdata.trustFlags |= TrustCProfileAge; cdata.trustLevel++; }
	if (cdata.profileSetup) { cdata.trustFlags |= TrustCProfileSetup; cdata.trustLevel++; }
	if (cdata.profilePublic) { cdata.trustFlags |= TrustCProfilePublic; cdata.trustLevel++; }
	if (cdata.badgeLevel > trust_pocbadge) { cdata.trustFlags |= TrustCProfilePoCBadge; cdata.trustLevel++; }
	if (cdata.communityLevel > trust_communityLevel) { cdata.trustFlags |= TrustCProfileLevel; cdata.trustLevel++; }
	if (!cdata.vacBanned) { cdata.trustFlags |= TrustNoVACBans; cdata.trustLevel++; }
	if (!cdata.tradeBanned) { cdata.trustFlags |= TrustNotEconomyBanned; cdata.trustLevel++; }
	if (dep_SBPP && cdata.sbppGameBans <= trust_sbppbans) { cdata.trustFlags |= TrustSBPPGameBan; cdata.trustLevel++; }
	if (dep_SBPP && cdata.sbppCommBans <= trust_sbppcomms) { cdata.trustFlags |= TrustSBPPCommBan; cdata.trustLevel++; }
	if (cdata.isDonor) { cdata.trustFlags |= TrustDonorFlag; cdata.trustLevel++; }
	SetClientTrustData(client, cdata);
	if (broadcast && (previousFlags != cdata.trustFlags || previousLevel != cdata.trustLevel)) {
		Call_StartForward(fwdOnTrustChanged);
		Call_PushCell(client);
		Call_PushCell(previousFlags);
		Call_PushCell(cdata.trustFlags);
		Call_Finish();
	}
}

static int SubStrToInt(const char[] str, int offset, int len, int radix=16) {
	char[] buf = new char[len+1];
	strcopy(buf, len+1, str[offset]);
	return StringToInt(buf, radix);
}

bool IsValidClient(int client) {
	return 1<=client<=MaxClients && IsClientConnected(client) &&
		!IsFakeClient(client) && !IsClientReplay(client) && !IsClientSourceTV(client);
}

static bool GetTrustClient(int client, TrustData data) {
	if (!IsValidClient(client)) return false;
	GetClientTrustData(client, data);
	if (!dep_SBPP) data.loaded |= LOADED_SOURCEBANS; //skip sbpp load if the plugin is not loaded, even if requested
	return data.loaded == LOADED_ALL;
}

//https://forums.alliedmods.net/showthread.php?t=233257
static void GetSteamInf() {
    File file = OpenFile("steam.inf", "r");
    if(file == INVALID_HANDLE) return;

    char line[128], parts[2][64];
    while(file.ReadLine(line, sizeof(line))) {
        ExplodeString(line, "=", parts, sizeof(parts), sizeof(parts[]));
        if(StrEqual(parts[0], "appID")) {
            steamAppId = StringToInt(parts[1]);
        } else if (StrEqual(parts[0], "PatchVersion")) {
        	strcopy(engineMeta[0], sizeof(engineMeta[]), parts[1]);
        	TrimString(engineMeta[0]);
        } else if (StrEqual(parts[0], "ServerAppID")) {
        	strcopy(engineMeta[1], sizeof(engineMeta[]), parts[1]);
        	TrimString(engineMeta[1]);
        }
    }

    CloseHandle(file);
}

static void GenerateUserAgent() {
	//fetch server and sourcemod versions to build a useragent string
	//this might seem unneccessarily complex, but can be a very good tool to e.g. block broken versions from accessing a server
	char smver[64];

	FindConVar("sourcemod_version").GetString(smver, sizeof(smver));
	//build useragent
	Format(playerCacheUserAgent, sizeof(playerCacheUserAgent), "TrustFactor/%s SourceMod/%s (EngineVersion %i) srcds/%s (AppId %i/%s)", PLUGIN_VERSION, smver, GetEngineVersion(), engineMeta[0], steamAppId, engineMeta[1]);
}

static TrustFactors ParseTrustString(const char[] string, int& read) {
	TrustFactors ret;
	int nchar;
	for (;string[nchar];nchar++) {
		switch(string[nchar]) {
			case 't': ret |= TrustPlaytime;
			case 'f': ret |= TrustPremium;
			case 'd': ret |= TrustDonorFlag;
			case 'p': ret |= TrustCProfilePublic;
			case 's': ret |= TrustCProfileSetup;
			case 'l': ret |= TrustCProfileLevel;
			case 'g': ret |= TrustCProfileGametime;
			case 'o': ret |= TrustCProfileAge;
			case 'b': ret |= TrustCProfilePoCBadge;
			case 'v': ret |= TrustNoVACBans;
			case 'e': ret |= TrustNotEconomyBanned;
			case 'a': ret |= TrustSBPPGameBan;
			case 'c': ret |= TrustSBPPCommBan;
			default: break; //breaks for
		}
	}
	read = nchar;
	return ret;
}
static int TrustFactorString(TrustFactors flags, char[] buffer, int maxLength) {
	int at;
	char fchar;
	maxLength--;//space for \0
	for (TrustFactors f = TrustPlaytime; f <= TrustCProfilePoCBadge && at < maxLength; f<<=view_as<TrustFactors>(1)) {
		if (f & flags) {
			switch(f) {
				case TrustPlaytime: fchar = 't';
				case TrustPremium: fchar = 'f';
				case TrustDonorFlag: fchar = 'd';
				case TrustCProfilePublic: fchar = 'p';
				case TrustCProfileSetup: fchar = 's';
				case TrustCProfileLevel: fchar = 'l';
				case TrustCProfileGametime: fchar = 'g';
				case TrustCProfileAge: fchar = 'o';
				case TrustCProfilePoCBadge: fchar = 'b';
				case TrustNoVACBans: fchar = 'v';
				case TrustNotEconomyBanned: fchar = 'e';
				case TrustSBPPGameBan: fchar = 'a';
				case TrustSBPPCommBan: fchar = 'c';
				default: fchar = 0;
			}
			if (fchar) {
				buffer[at] = fchar;
				at++;
			}
		}
	}
	buffer[at]=0;
	return at;
}

static bool CheckClientAdminFlags(int client) {
	if (!IsValidClient(client)) return false;
	if ((GetUserFlagBits(client) & trust_donorflags)!=0) return true; //has flag bits
	AdminId admin = GetUserAdmin(client);
	if (admin == INVALID_ADMIN_ID) return false;
	char name[MAX_NAME_LENGTH];
	for (int i; i<admin.GroupCount; i++) {
		//check all group names
		if (admin.GetGroup(i,name,sizeof(name)) != INVALID_GROUP_ID && StrEqual(trust_donorgroup, name)) return true;
	}
	return false;
}

// -- natives --

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	b_lateLoad = late;

	CreateNative("IsClientTrustFactorLoaded", Native_IsLoaded);
	CreateNative("GetClientTrustFactors", Native_GetFactor);
	CreateNative("GetClientTrustLevel", Native_GetLevel);
	CreateNative("GetClientTrustFactorValue", Native_GetTrustValue);
	CreateNative("ReadTrustFactorChars", Native_ReadFlagString);
	CreateNative("WriteTrustFactorChars", Native_WriteFlagString);
	CreateNative("ParseTrustConditionStringRaw", Native_ParseConditionString);
	CreateNative("ComposeTrustConditionStringRaw", Native_ComposeConditionFlagString);

	RegPluginLibrary("trustfactor");

	return APLRes_Success;
}

public any Native_IsLoaded(Handle plugin, int numParams) {
	int client = GetNativeCell(1);
	TrustData data;
	return GetTrustClient(client, data);
}
public any Native_GetFactor(Handle plugin, int numParams) {
	int client = GetNativeCell(1);
	TrustData data;
	if (!GetTrustClient(client, data)) ThrowNativeError(SP_ERROR_PARAM, "Invalid client/bot or client not yet loaded");
	return data.trustFlags;
}
public any Native_GetLevel(Handle plugin, int numParams) {
	int client = GetNativeCell(1);
	TrustData data;
	if (!GetTrustClient(client, data)) ThrowNativeError(SP_ERROR_PARAM, "Invalid client/bot or client not yet loaded");
	return data.trustLevel;
}
public any Native_GetTrustValue(Handle plugin, int numParams) {
	int client = GetNativeCell(1);
	TrustFactors factor = GetNativeCell(2);
	TrustData data;
	if (!GetTrustClient(client, data)) ThrowNativeError(SP_ERROR_PARAM, "Invalid client/bot or client not yet loaded");
	switch (factor) {
		case TrustPlaytime: return data.playtime;
		case TrustPremium: return data.premium;
		case TrustDonorFlag: return data.isDonor;
		case TrustCProfilePublic: return data.profilePublic;
		case TrustCProfileSetup: return data.profileSetup;
		case TrustCProfileLevel: return data.communityLevel;
		case TrustCProfileGametime: return data.gametime;
		case TrustCProfileAge: return data.profileAge;
		case TrustCProfilePoCBadge: return data.badgeLevel;
		case TrustNoVACBans: return data.vacBanned;
		case TrustNotEconomyBanned: return data.tradeBanned;
		case TrustSBPPGameBan: return data.sbppGameBans;
		case TrustSBPPCommBan: return data.sbppCommBans;
		default: ThrowNativeError(SP_ERROR_PARAM, "Specified number of trust factors != 1");
	}
	return 0;
}
public any Native_ReadFlagString(Handle plugin, int numParams) {
	//get string
	int len;
	GetNativeStringLength(1, len);
	char[] buf = new char[len+1];
	GetNativeString(1,buf,len+1);
	//read trust factor chars
	int readtf;
	TrustFactors factors = ParseTrustString(buf, readtf);
	//write back
	SetNativeCellRef(2, factors);
	return readtf;
}
public any Native_WriteFlagString(Handle plugin, int numParams) {
	char outbuf[16]; //more than we need
	//get args
	TrustFactors factors = GetNativeCell(1);
	int maxLength = GetNativeCell(3);
	//validate args
	int written;
	if (maxLength<=0) return 0;
	if (factors == UNTRUSTED) {
		SetNativeString(2, "", maxLength, _, written);
		return written;
	}
	//write chars
	TrustFactorString(factors, outbuf, sizeof(outbuf));
	//write out
	SetNativeString(2, outbuf, maxLength, _, written);
	return written;
}
public any Native_ParseConditionString(Handle plugin, int numParams) {
	// the format is loosly \w+(\+\w+)?[0-9]*
	//  \w+ -> required
	//  \w+\+\w+ -> required, optional as required
	//  \w+[0-9]* -> n optionals, no required
	//  \w+\+\w+[0-9]* -> required, n optionals
	//get string
	int len;
	GetNativeStringLength(1, len);
	char[] buf = new char[len+1];
	GetNativeString(1,buf,len+1);
	//read trust factor chars
	int read, tmp, ocount;
	bool readOptionals;
	TrustFactors reqflags, optflags;

	if (buf[0] != 0) { //shortcut for empty string
		if (buf[0]=='*') {
			reqflags = ALLTRUSTFACTORS;
			read = 1;
		} else {
			reqflags = ParseTrustString(buf, read);
		}
		//is the next char a plus? then the parsed chars are required
		if (buf[read]=='+') {
			read += 1;
			if (buf[read]=='*') {
				optflags = ALLTRUSTFACTORS;
				read += 1;
			} else {
				optflags = ParseTrustString(buf[read], tmp);
				read += tmp;
			}
			readOptionals = true;
		}
		//try to find a numeric suffix aka optional count
		// on a hit, if no +O string was read yet, this means there's no R string, and the assumed R is O
		tmp = StringToIntEx(buf[read], ocount);
		read += tmp;
		if (tmp) {
			// ocount 0 means no optionals are required, ignore them
			if (ocount == 0) {
				optflags = UNTRUSTED;
			} else if (ocount < 0) { //-1 => require all optionals. equal to mixing R=R|O and not using optionals
				reqflags |= optflags;
				ocount = 0;
			} else if (!readOptionals) { //the assumed R string is an O string, remap
				optflags = reqflags;
				reqflags = UNTRUSTED;
			}
			//otherwise the O string now has a count of ocount
		}
		if (!tmp && readOptionals) { //optionals have no count, treat requires by logic oring
			reqflags |= optflags;
			optflags = UNTRUSTED;
		}
	}
	//dedupe optionals (already required) and recount
	if (optflags && reqflags) {
		optflags &=~ reqflags;
		int max;
		for (tmp = view_as<int>(optflags); tmp; tmp >>= 1) if (tmp & 1) max+=1;
		if (ocount > max) ocount = max;
	}
	//create trustcondition "struct"
	any data[3];
	data[0] = reqflags;
	data[1] = optflags;
	data[2] = ocount;
	//write back
	SetNativeArray(2, data, 3);
	return read;
}
public any Native_ComposeConditionFlagString(Handle plugin, int numParams) {
	char buffer[32];
	any data[3];
	GetNativeArray(1, data, 3);
	int maxlen = GetNativeCell(3);

	//prepare components from trust condition
	char tmp[2][16];
	bool reqs,opts;
	if (data[0]!=UNTRUSTED) {
		if ((data[0]&ALLTRUSTFACTORS)==ALLTRUSTFACTORS) tmp[0][0]='*';
		else TrustFactorString(data[0], tmp[0], sizeof(tmp[]));
		reqs = true;
	}
	if (data[1]!=UNTRUSTED) {
		if ((data[1]&ALLTRUSTFACTORS)==ALLTRUSTFACTORS) tmp[1][0]='*';
		else TrustFactorString(data[1], tmp[1], sizeof(tmp[]));
		opts = true;
	}
	int optc = data[2];

	//preprocess output
	int max;
	for (int temp=view_as<int>(data[1]); temp; temp>>=1) if (temp&1) max++;
	if (optc >= max || optc < -1) {
		//all optionals are required
		reqs |= opts;
		optc = -1;
	}
	if (optc == 0) opts=false; //no optionals are required -> skip optionals

	//build string
	int written;
	if (!reqs && !opts) {
		//untrusted is ok
		if (maxlen>0) SetNativeString(2, "", maxlen, _, written);
	} else if (!opts) { //only required
		if (maxlen>0) SetNativeString(2, tmp[0], maxlen, _, written);
	} else if (!reqs) { //only optional
		FormatEx(buffer, sizeof(buffer), "%s%d", tmp[1], optc);
		if (maxlen>0) SetNativeString(2, buffer, maxlen, _, written);
	} else {
		FormatEx(buffer, sizeof(buffer), "%s+%s%d", tmp[0], tmp[1], optc);
		if (maxlen>0) SetNativeString(2, buffer, maxlen, _, written);
	}
	return written;
}
