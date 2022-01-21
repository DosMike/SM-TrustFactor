#if defined _trustfactor_included
#endinput
#endif
#define _trustfactor_included

enum TrustFactors (<<=1) {
	UNTRUSTED = 0,
	TrustPlaytime = 1,     //playtime on server network
	TrustPremium,          //is using free2play account
	TrustDonorFlag,        //player is donor / has spent money on the server
	TrustCProfilePublic,   //is community profile public
	TrustCProfileSetup,    //is community profile set up
	TrustCProfileLevel,    //community profile level
	TrustCProfileGametime, //total playtime for the game
	TrustCProfileAge,      //profile age in months
	TrustCProfilePoCBadge, //progress for pillar of community badge
}

/**
 * Called when a clients trust factor was initially determined after connecting to the server
 * Will call after PostAdminCheck
 * This will not be called for bots (fake clients, sourcetv, replay)
 *
 * @param client - the validated client
 * @param factors - the validated factors
 */
forward void OnClientTrustFactorLoaded(int client, TrustFactors factors);
/**
 * Some configurations or values (e.g. playtime) can change while the player is on the server.
 * Whenever this causes a player trustfactor to change, this forward will be called.
 *
 * @param client - the validated client
 * @param oldFactors the trust factors active for this client previously
 * @param newFactors the trust factors active for the client now
 */
forward void OnClientTrustFactorChanged(int client, TrustFactors oldFactors, TrustFactors newFactors);

/**
 * Check if the trust factor for this client is available.
 *
 * @param client -the client to check
 * @return true if player is valid, not a bot and all enabled trustfactors were loaded
 */
native bool IsClientTrustFactorLoaded(int client);
/**
 * Get the factor the specified client fullfills, counting towards their trustlevel.
 *
 * @param client - the client to check
 * @return trust flags
 * @error invalid or bot client
 */
native TrustFactors GetClientTrustFactors(int client);
/**
 * Get the trust level of the specified client. This is effectively the sum of bits set in the trust factor value.
 * 
 * @param client - the client to check
 * @return the level of trust for this client
 * @error invalid or bot client
 */
native int GetClientTrustLevel(int client);

/**
 * Reads the trust level for a single trust factor. 
 *
 * @param client - client to query
 * @param factor - a signle trust factor to query
 * @return the stored value (for flags this is 1 the trust threashold is fullfilled)
 * @error invalid or bot client, or more then one factor bit set
 */
native int GetClientTrustFactorValue(int client, TrustFactors factor);

/**
 * When the server should be able to configure required trust flags for certain things, this can be used
 * similar to admin flag strings. In addition to what flags should be checked, this parser also reads a level
 * suffix. If the level suffix is missing it's value will be set to -1 requiring all flags.
 * This ensures you can always call CheckClientTrust(client, flags, level) with these parse results.
 * The chars are:
 * - t TrustPlaytime
 * - f TrustPremium
 * - d TrustDonorFlag
 * - p TrustCProfilePublic
 * - s TrustCProfileSetup
 * - l TrustCProfileLevel
 * - g TrustCProfileGametime
 * - o TrustCProfileAge
 * - b TrustCProfilePoCBadge
 * 
 * @param flagstring - the string to parse
 * @param bytesRead - the number of chars parsed
 * @param levelSuffix - the min amount of flags from those specified a player should have. (-1 if missing)
 * @return the parsed flag string.
 */
native TrustFactors ReadTrustFactorString(const char[] flagstring, int& bytesRead=0, int& levelSuffix=0);

/**
 * The inverse to ReadTrustFactorString
 *
 * @param flagstring - buffer for output
 * @param maxLength - the buffer size
 * @param levelSuffix - if >0 will append the level suffix
 * @return the amount of bytes written
 * @see ReadTrustFactorString
 */
native int WriteTrustFactorString(TrustFactors factors, char[] flagstring, int maxLength, int levelSuffix=-1);

/**
 * Checks a player trust flags:
 * The number of flags in factors that the client passes are counted.
 * If the client passes less than the specified amount of flags, the check fails.
 * 
 * @param client - the client to test
 * @param factors - the trust flags to count for this player
 * @param numPass - the min amount of flags from factors that have to pass (-1 to require all flags specified)
 * @return true if the player has all required flags and at least numPass flags match factors
 * @error if invalid or bot client
 */
stock bool CheckClientTrust(int client, TrustFactors factors, int numPass=-1) {
	TrustFactors cfactors = GetClientTrustFactors(client);
	
	//we are not counting
	if (factors == UNTRUSTED || numPass == 0) return true;
	
	//get the flags from test this player passed
	TrustFactors passed = (cfactors & factors);
	
	//require all test-flags to pass?
	if (numPass < 0 && passed == factors) return true;
	
	//count those flags
	int matched, max;
	for (int temp=view_as<int>(passed); temp; temp>>=1) if (temp&1) matched++;
	
	//check num flags
	return (matched >= numPass);
}

public SharedPlugin __pl_trustfactor = {
    name = "trustfactor",
    file = "trustfactor.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_trustfactor_SetNTVOptional() {
	MarkNativeAsOptional("IsClientTrustFactorLoaded");
	MarkNativeAsOptional("GetClientTrustFactors");
	MarkNativeAsOptional("GetClientTrustLevel");
	MarkNativeAsOptional("GetClientTrustFactorValue");
	MarkNativeAsOptional("ReadTrustFactorString");
	MarkNativeAsOptional("WriteTrustFactorString");
}
#endif
