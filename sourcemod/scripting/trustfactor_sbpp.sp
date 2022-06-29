/**
 * This is basically sbpp_checker.sp, edited to report game/com ban count 
 * back to trustfactors instead of chat; thus credits go to the SB++ team. 
 * New Syntax is a bonus.
 * 
 * NOTE: just because it's issuing queries identical to sbpp_checker.sp does NOT
 *    make the queries "free". They will processed by the database again, the query
 *    cache ONLY helps with parsing the query! I would prefer sb++ having an api
 *    to query this information, maintanance seems to have slowed down a bit.
 */
// *************************************************************************
//  This file is part of SourceBans++.
//
//  Copyright (C) 2014-2016 SourceBans++ Dev Team <https://github.com/sbpp>
//
//  SourceBans++ is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, per version 3 of the License.
//
//  SourceBans++ is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with SourceBans++. If not, see <http://www.gnu.org/licenses/>.
//
//  This file is based off work(s) covered by the following copyright(s):
//
//   SourceBans Checker 1.0.2
//   Copyright (C) 2010-2013 Nicholas Hastings
//   Licensed under GNU GPL version 3, or later.
//   Page: <https://forums.alliedmods.net/showthread.php?p=1288490>
//
// *************************************************************************

#include <sourcemod>

char g_DatabasePrefix[10] = "sb";
Handle g_ConfigParser;
Handle g_DB;

void SBPP_OnMapStart() {
	SQL_TConnect(SBPP_OnDatabaseConnected, "sourcebans");
	SBPP_ReadConfig();
}

public void SBPP_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data) {
	if (hndl == INVALID_HANDLE)
		SetFailState("Failed to connect to SourceBans DB, %s", error);

	g_DB = hndl;
}

void SBPP_OnClientAuthorized(int client, const char[] auth) {
	if (g_DB == INVALID_HANDLE) return;
	/* Do not check bots nor check player with lan steamid. */
	if (!IsValidClient(client) || auth[0] == 'B' || auth[9] == 'L') return;
	
	char query[512];
	char ip[30];
	GetClientIP(client, ip, sizeof(ip));
	FormatEx(query, sizeof(query), "SELECT COUNT(bid) FROM %s_bans WHERE ((type = 0 AND authid REGEXP '^STEAM_[0-9]:%s$') OR (type = 1 AND ip = '%s')) UNION SELECT COUNT(bid) FROM %s_comms WHERE authid REGEXP '^STEAM_[0-9]:%s$'", g_DatabasePrefix, auth[8], ip, g_DatabasePrefix, auth[8]);
	SQL_TQuery(g_DB, SBPP_OnConnectBanCheck, query, GetClientUserId(client), DBPrio_Low);
}
public void SBPP_OnConnectBanCheck(Handle owner, Handle hndl, const char[] error, any userid) {
	int client = GetClientOfUserId(userid);
	if (!client || hndl == INVALID_HANDLE || !SQL_FetchRow(hndl)) return;
	
	int bancount = SQL_FetchInt(hndl, 0);
	int commcount = 0;
	if (SQL_FetchRow(hndl)) {
		commcount = SQL_FetchInt(hndl, 0);
	}
	
	//Report ban count back
	TrustData cdata;
	GetClientTrustData(client, cdata);
	cdata.sbppGameBans = bancount;
	cdata.sbppCommBans = commcount;
	cdata.loaded |= LOADED_SOURCEBANS;
	SetClientTrustData(client, cdata);
	Notify_OnTrustFactorLoaded(client);
}



static void SBPP_ReadConfig() {
	SBPP_InitializeConfigParser();

	if (g_ConfigParser == INVALID_HANDLE) return;

	char ConfigFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, ConfigFile, sizeof(ConfigFile), "configs/sourcebans/sourcebans.cfg");

	if (FileExists(ConfigFile)) {
		SBPP_InternalReadConfig(ConfigFile);
	} else {
		char Error[PLATFORM_MAX_PATH + 64];
		FormatEx(Error, sizeof(Error), "FATAL *** ERROR *** can not find %s", ConfigFile);
		SetFailState(Error);
	}
}

static void SBPP_InitializeConfigParser() {
	if (g_ConfigParser == INVALID_HANDLE) {
		g_ConfigParser = SMC_CreateParser();
		SMC_SetReaders(g_ConfigParser, SBPP_ReadConfig_NewSection, SBPP_ReadConfig_KeyValue, SBPP_ReadConfig_EndSection);
	}
}

static void SBPP_InternalReadConfig(const char[] path) {
	SMCError err = SMC_ParseFile(g_ConfigParser, path);
	if (err != SMCError_Okay) {
		char buffer[64];
		PrintToServer("%s", SMC_GetErrorString(err, buffer, sizeof(buffer)) ? buffer : "Fatal parse error");
	}
}

public SMCResult SBPP_ReadConfig_NewSection(Handle smc, const char[] name, bool opt_quotes) {
	return SMCParse_Continue;
}

public SMCResult SBPP_ReadConfig_KeyValue(Handle smc, const char[] key, const char[] value, bool key_quotes, bool value_quotes) {
	if (strcmp("DatabasePrefix", key, false) == 0) {
		strcopy(g_DatabasePrefix, sizeof(g_DatabasePrefix), value);
		if (g_DatabasePrefix[0] == '\0') {
			g_DatabasePrefix = "sb";
		}
	}
	return SMCParse_Continue;
}

public SMCResult SBPP_ReadConfig_EndSection(Handle smc) {
	return SMCParse_Continue;
}
