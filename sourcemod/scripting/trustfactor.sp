#include <sourcemod>
#include <clients>
#include <clientprefs>
#include <steamworks>

#include <multicolors>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "22w03a"

public Plugin myinfo = {
	name = "Trust Factor",
	author = "reBane",
	description = "Determin player trustfactor for premissive integration",
	version = PLUGIN_VERSION,
	url = "N/A"
}

#define MAX_STEAMID_LENGTH 32

enum TrustFactors (<<=1) {
	UNTRUSTED = 0,
	TrustPlaytime = 1,     // t  playtime on server network
	TrustPremium,          // f  is using free2play account
	TrustDonorFlag,        // d  player is donor / has spent money on the server
	TrustCProfilePublic,   // p  is community profile public
	TrustCProfileSetup,    // s  is community profile set up
	TrustCProfileLevel,    // l  community profile level
	TrustCProfileGametime, // g  total playtime for the game
	TrustCProfileAge,      // o  profile age in months
	TrustCProfilePoCBadge, // b  progress for pillar of community badge
}
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
	TrustFactors trustFlags;
	int trustLevel;
}
#define LOADED_LOCALDATA 0x01
#define LOADED_PREMIUM 0x02
#define LOADED_PROFILEDATA 0x04
#define LOADED_ALL 0x07
#define COOKIE_TRUST_PLAYTIME "TrustPlayTime"

#define GetClientTrustData(%1,%2) client_trustData.GetArray(client_steamIds[(%1)], (%2), sizeof(TrustData))
#define SetClientTrustData(%1,%2) client_trustData.SetArray(client_steamIds[(%1)], (%2), sizeof(TrustData))
#define HookAndLoadConVar(%1,%2) { char def[256],val[256]; %1.AddChangeHook(%2); %1.GetDefault(def,256); %1.GetString(val,256); %2(%1,def,val); }

static StringMap client_trustData;
static char client_steamIds[MAXPLAYERS][MAX_STEAMID_LENGTH];
static Cookie gCookiePlaytime = null;

#define SWAPI_CHECK_PROFILE 1
#define SWAPI_CHECK_STEAMLVL 2
#define SWAPI_CHECK_GAMETIME 4

static int steamAppId, steamDlcId; //for game and premium dlc
static char engineMeta[2][32];
static int swapi_checks; //check flags for below Check* cvars
static char playerCacheUrl[PLATFORM_MAX_PATH]; //url to get stuff from
static char playerCacheUserAgent[128];
static int trust_communityLevel; //int
static int trust_gametime;       //in hours
static int trust_servertime;     //in minutes
static int trust_pocbadge;       //level (0,1,2,3)
static int trust_donorflags;     //AdmFlag bit string
static char trust_donorgroup[MAX_NAME_LENGTH]; //OverrideGroup for donor permissions
static ConVar cvar_CheckProfile;    //check ISteamUser/GetPlayerSummaries for communityvisibilitystate==3, profilestate==1, timecreated
static ConVar cvar_CheckSteamLevel; //check IPlayerService/GetBadges for community level & poc level
static ConVar cvar_CheckGametime;   //check IPlayerService/GetOwnedGames for poc badge progress
//maybe add this at some point : ISteamUser/GetPlayerBans
static ConVar cvar_PlayerCacheURL;      //cache php script url
static ConVar cvar_TrustCommunityLevel; //required community level to count as trusted
static ConVar cvar_TrustGametime;       //required overall game playtime to count as trusted
static ConVar cvar_TrustServertime;     //required on-server playtime to count as trusted
static ConVar cvar_TrustPoCBadge;       //required Pillar of Community badge progress to count as trusted
static ConVar cvar_TrustDonorFlags;     //required SourceMod AdminFlags to count as trusted
static ConVar cvar_TrustDonorGroup;     //required SourceMod Admin Group to count as trusted
static GlobalForward fwdOnTrustLoaded;
static GlobalForward fwdOnTrustChanged;

public void OnPluginStart() {
	
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
	
	cvar_CheckProfile =        CreateConVar("sm_trustfactor_checkprofile", "0", "Request steam profile to be checked", FCVAR_HIDDEN, true, 0.0, true, 1.0);
	cvar_CheckSteamLevel =     CreateConVar("sm_trustfactor_checksteamlvl", "0", "Request steam community level and poc badge level to be checked", FCVAR_HIDDEN, true, 0.0, true, 1.0);
	cvar_CheckGametime =       CreateConVar("sm_trustfactor_checkgametime", "0", "Request global gametime to be checked", FCVAR_HIDDEN, true, 0.0, true, 1.0);
	cvar_PlayerCacheURL =      CreateConVar("sm_trustfactor_playercacheurl", "", "Specifies the steam webapi proxy, set empty to not use any profile data", FCVAR_HIDDEN|FCVAR_PROTECTED);
	cvar_TrustCommunityLevel = CreateConVar("sm_trustfactor_minsteamlevel", "2", "Steam Community Level required to flag Trustworthy, 0 to disable", FCVAR_HIDDEN, true, 0.0);
	cvar_TrustGametime =       CreateConVar("sm_trustfactor_mingametime", "24", "Global game playtime [hr] required to flag Trustworthy, 0 to disable", FCVAR_HIDDEN, true, 0.0);
	cvar_TrustServertime =     CreateConVar("sm_trustfactor_minservertime", "300", "Playtime on server(network) [min] required to flag Trustworthy, 0 to disable", FCVAR_HIDDEN, true, 0.0);
	cvar_TrustPoCBadge =       CreateConVar("sm_trustfactor_minpocprogress", "1", "Pillar of Community badge level required to flag Trustworthy, 0 to disable", FCVAR_HIDDEN, true, 0.0, true, 3.0);
	cvar_TrustDonorFlags =     CreateConVar("sm_trustfactor_donorflag", "z", "SourceMod AdminFlag to flag Trustworthy (Donors), empty to disable", FCVAR_HIDDEN);
	cvar_TrustDonorGroup =     CreateConVar("sm_trustfactor_donorgroup", "", "SourceMod Admin Group name to flag Trustworthy (Donors), empty to disable", FCVAR_HIDDEN);
	HookAndLoadConVar(cvar_CheckProfile, OnConVarChanged_checkProfile)
	HookAndLoadConVar(cvar_CheckSteamLevel, OnConVarChanged_checkSteamLvL)
	HookAndLoadConVar(cvar_CheckGametime, OnConVarChanged_checkGametime)
	HookAndLoadConVar(cvar_PlayerCacheURL, OnConVarChanged_playerCacheURL)
	HookAndLoadConVar(cvar_TrustCommunityLevel, OnConVarChanged_trustCommunityLevel)
	HookAndLoadConVar(cvar_TrustGametime, OnConVarChanged_trustGametime)
	HookAndLoadConVar(cvar_TrustServertime, OnConVarChanged_trustServertime)
	HookAndLoadConVar(cvar_TrustPoCBadge, OnConVarChanged_trustPoCBadge)
	HookAndLoadConVar(cvar_TrustDonorFlags, OnConVarChanged_trustDonorFlags)
	HookAndLoadConVar(cvar_TrustDonorGroup, OnConVarChanged_trustDonorGroup)
	AutoExecConfig();
	
	fwdOnTrustLoaded = new GlobalForward("OnClientTrustFactorLoaded", ET_Ignore, Param_Cell, Param_Cell);
	fwdOnTrustChanged = new GlobalForward("OnClientTrustFactorChanged", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	
	RegAdminCmd("sm_checktrust", Command_CheckTrust, ADMFLAG_GENERIC, "Read all trust values for a player");
	
	char steamid[MAX_STEAMID_LENGTH];
	for (int client=1; client<=MaxClients; client++) {
		if (!IsValidClient(client)) continue;
		if (IsClientAuthorized(client)) {
			GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid));
			OnClientAuthorized(client, steamid);
			OnClientPostAdminCheck(client);
		}
		if (AreClientCookiesCached(client)) {
			OnClientCookiesCached(client);
		}
	}
}

public void OnMapStart() {
	CreateTimer(60.0, Timer_Playtime, _, TIMER_REPEAT);
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
			CReplyToCommand(client, "  {gold}Trust Level: %d/9", cdata.trustLevel);
		}
	}
	return Plugin_Handled;
}


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

public void OnClientAuthorized(int client, const char[] auth) {
	EnsureClientData(client);
	
	TrustData cdata;
	GetClientTrustData(client, cdata);
	if (steamDlcId) cdata.premium = SteamWorks_HasLicenseForApp(client, steamDlcId) == k_EUserHasLicenseResultHasLicense;
	cdata.loaded |= LOADED_PREMIUM;
	
	//manually "finish" profile data if web disabled
	if (playerCacheUrl[0]==0 || swapi_checks==0) {
		cdata.loaded |= LOADED_PROFILEDATA;
		SetClientTrustData(client, cdata);
		if (cdata.loaded == LOADED_ALL) UpdateTrustfactor(client);
		return;
	}
	SetClientTrustData(client, cdata);
	
	char buffer[32];
	PrintToServer("[Trustfactor] Connecting with cache at %s for %N: %s, %d, %d", playerCacheUrl, client, client_steamIds[client], steamAppId, swapi_checks);
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, playerCacheUrl);
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(request, 1000);
	SteamWorks_SetHTTPRequestUserAgentInfo(request, playerCacheUserAgent);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "steamId", client_steamIds[client]);
	Format(buffer, sizeof(buffer), "%i", steamAppId);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "appId", buffer);
	Format(buffer, sizeof(buffer), "%i", swapi_checks);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "cdata", buffer);
	SteamWorks_SetHTTPRequestHeaderValue(request, "X-Trustfactor", PLUGIN_VERSION);
	SteamWorks_SetHTTPRequestContextValue(request, GetClientUserId(client));
	SteamWorks_SetHTTPCallbacks(request, OnProfileDataCached);
	SteamWorks_SendHTTPRequest(request);
}


public void OnClientPostAdminCheck(int client) {
	TrustData cdata;
	GetClientTrustData(client, cdata);
	cdata.isDonor = CheckClientAdminFlags(client);
	SetClientTrustData(client, cdata);
	if (cdata.loaded == LOADED_ALL) UpdateTrustfactor(client);
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

public void OnClientCookiesCached(int client) {
	EnsureClientData(client);
	
	TrustData cdata;
	char buffer[32];
	int value;
	bool loadingDone;
	GetClientTrustData(client, cdata);
	if (gCookiePlaytime != INVALID_HANDLE) {
		gCookiePlaytime.Get(client, buffer, sizeof(buffer));
		value = StringToInt(buffer);
		cdata.playtime = value;
	}
	loadingDone = ((cdata.loaded |= LOADED_LOCALDATA) == LOADED_ALL);
	SetClientTrustData(client, cdata);
	if (loadingDone) Notify_OnTrustFactorLoaded(client);
}

public void OnProfileDataCached(Handle handle, bool failed, bool successfull, EHTTPStatusCode statusCode, int userId) {
	int client = GetClientOfUserId(userId);
	if (client==0) {
		//client disconnected, we don't care anymore
		delete handle;
		return; 
	}
	bool loadingDone;
	TrustData cdata;
	GetClientTrustData(client, cdata);
	if (!successfull || statusCode != k_EHTTPStatusCode200OK) {
		PrintToServer("[TrustFactor] Proxy response failed for %N", client);
		if (successfull) delete handle;
	} else {
		int contentLength;
		if (SteamWorks_GetHTTPResponseBodySize(handle, contentLength)) {
			char[] buffer = new char[contentLength+1];
			SteamWorks_GetHTTPResponseBodyData(handle, buffer, contentLength);
			
			int version = SubStrToInt(buffer,0,2);
			if (version == 1 && contentLength >= 16) {
				int flags = SubStrToInt(buffer,2,2);
				cdata.profileSetup =  (flags & 0x01) != 0;
				cdata.profilePublic = (flags & 0x02) != 0;
				cdata.profileAge =    (flags & 0x04) != 0;
				cdata.badgeLevel =    (flags & 0xf0) >> 4;
				cdata.communityLevel = SubStrToInt(buffer,4,4);
				cdata.gametime = SubStrToInt(buffer,8,8);
			} else {
				PrintToServer("[TrustFactor] Proxy response version not supported");
			}
		}
		delete handle;
	}
	loadingDone = ((cdata.loaded |= LOADED_PROFILEDATA) == LOADED_ALL);
	SetClientTrustData(client, cdata);
	if (loadingDone) Notify_OnTrustFactorLoaded(client);
}

public void OnClientDisconnect(int client) {
	if (client_steamIds[client][0]!=0) {
		client_trustData.Remove(client_steamIds[client]);
		client_steamIds[client][0]=0;
	}
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

static void Notify_OnTrustFactorLoaded(int client) {
	UpdateTrustfactor(client,false);
	TrustData data;
	GetClientTrustData(client,data);
	Call_StartForward(fwdOnTrustLoaded);
	Call_PushCell(client);
	Call_PushCell(data.trustFlags);
	Call_Finish();
}

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

static bool IsValidClient(int client) {
	return 1<=client<=MaxClients && IsClientConnected(client) &&
		!IsFakeClient(client) && !IsClientReplay(client) && !IsClientSourceTV(client);
}

static bool GetTrustClient(int client, TrustData data) {
	if (!IsValidClient(client)) return false;
	GetClientTrustData(client, data);
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

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	CreateNative("IsClientTrustFactorLoaded", Native_IsLoaded);
	CreateNative("GetClientTrustFactors", Native_GetFactor);
	CreateNative("GetClientTrustLevel", Native_GetLevel);
	CreateNative("GetClientTrustFactorValue", Native_GetTrustValue);
	CreateNative("ReadTrustFactorString", Native_ReadFlagString);
	CreateNative("WriteTrustFactorString", Native_WriteFlagString);
	
	RegPluginLibrary("trustfactor");
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
	//try to read level
	int level;
	int readlv = StringToIntEx(buf[readtf], level);
	if (!readlv) level=-1;
	//write back
	SetNativeCellRef(2, readtf+readlv);
	SetNativeCellRef(3, level);
	return factors;
}
public any Native_WriteFlagString(Handle plugin, int numParams) {
	char outbuf[16]; //more than we need
	//get args
	TrustFactors factors = GetNativeCell(1);
	int maxLength = GetNativeCell(3);
	int level = GetNativeCell(4);
	//validate args
	int written;
	if (maxLength<=0) return 0;
	if (factors == UNTRUSTED) {
		SetNativeString(2, "", maxLength, _, written);
		return written;
	}
	//write chars
	TrustFactorString(factors, outbuf, sizeof(outbuf));
	//validate level
	int maxlevel;
	for (int temp=view_as<int>(factors); temp; temp>>=1) if (temp&1) maxlevel++;
	if (level>=maxlevel) level = -1;
	//write level
	if (level>=0) {
		Format(outbuf, sizeof(outbuf), "%s%i", outbuf, level);
	}
	//write out
	SetNativeString(2, outbuf, maxLength, _, written);
	return written;
}
