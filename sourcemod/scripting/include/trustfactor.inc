#if defined _trustfactor_included
#endinput
#endif
#define _trustfactor_included

enum TrustFactors (<<=1) {
	UNTRUSTED = 0,         //can be read as "allows untrusted to do x"
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
 * Called when a clients trust factor was initially determined after connecting
 * to the server. Will be called after PostAdminCheck. This will not be called
 * for bots (fake clients, sourcetv, replay)
 *
 * @param client - the validated client
 * @param factors - the validated factors
 */
forward void OnClientTrustFactorLoaded(int client, TrustFactors factors);
/**
 * Some configurations or values (e.g. playtime) can change while the player is
 * on the server. Whenever this causes a player trustfactor to change, this
 * forward will be called.
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
 * @return true if player is valid, no bot and enabled trustfactors were loaded
 */
native bool IsClientTrustFactorLoaded(int client);
/**
 * Get the factor the specified client fullfills, counting towards their trust
 * level. If the web cache was not set up/configured and no premium dlc was
 * found for the game, this can be at max TrustPlaytime+TrustDonorFlag.
 *
 * @param client - the client to check
 * @return trust flags
 * @error invalid or bot client
 */
native TrustFactors GetClientTrustFactors(int client);
/**
 * Get the trust level of the specified client. This is effectively the sum of
 * bits set in the TrustFactors bit string value.
 * 
 * @param client - the client to check
 * @return the level of trust for this client
 * @error invalid or bot client
 */
native int GetClientTrustLevel(int client);

/**
 * Returns the value for one specified TrustFactor. For most values this will
 * only return 1 for "passed". A value of 0 is safe to be assumed "failed".
 *
 * @param client - client to query
 * @param factor - a signle trust factor to query
 * @return the stored value
 * @error invalid or bot client, or more then one TrustFactors bit set
 */
native int GetClientTrustFactorValue(int client, TrustFactors factor);


/**
 * Simpler version of ReadTrustCondition.
 * 
 * This version only converts flag chars to a TrustFactor value. It is similar
 * to ReadFlagString() as it converts the chars in a string to a bit string of
 * TrustFactors.
 * 
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
 * @param flagstring - the flag string to parse
 * @param TrustFactors - the parsed value
 * @return number of bytes read
 */
native int ReadTrustFactorChars(const char[] flagstring, TrustFactors& condition);

/**
 * Convert all trust factor bits to their char representation. Reverse of
 * ReadTrustFactorChars()
 *
 * @param factors - the falg bits to convert
 * @param flagstring - buffer for output
 * @param maxLength - the buffer size
 * @return the amount of bytes written
 * @see ReadTrustFactorChars
 */
native int WriteTrustFactorChars(TrustFactors factors, char[] flagstring, int maxLength);

/**
 * Since natives cannot take enum Structs, this takes an array using the struct
 * value order. Please consider using TrustCondition.Parse()!
 * 
 * Parse a trust condition string. This can be used similar to ReadFlagString().
 * 
 * The condition string has two parts. No parst has to be specified (= always
 * trust client). This first part are the required flags. If a client is missing
 * any of these trust flags, the check fails. The second part are the optional
 * flags. The client only needs a certain amount of those.
 * > RRR requires 3 flags R, where a flac is one of the chars below.
 * > TTTn requires n optional flags T where n < the amount of optional flags.
 * > RRR+TTTn would be a combination, requiring all R flags, and n of the
 *   optional T flags.
 * If n <0 or n >= amount of T flags, the optional flags are treated equal to
 *   required flags.
 * If n == 0, the optional flags are ignored.
 * > tg+*2 would mean the player has to have the configured server playtime and
 *   global playtime in addition to any other 2 trust factors.
 * > *+*0 would be equal to *-1 would be equal to * would be equal to tfdpslgob.
 * > *0 would be qual to no condition / empty string
 * 
 * This returns a TrustCondition that can .test() clients.
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
 * @param conditionString - the string to parse
 * @param condition - array with [required:TrustFactors, optional:TrustFactors, optionalCount:int]
 * @return number of bytes parsed
 */
native int ParseTrustConditionStringRaw(const char[] conditionString, any condition[3]);

/**
 * Since natives cannot take enum Structs, this takes an array using the struct
 * value order. Please consider using TrustCondition.ToString()!
 * 
 * Generates the trust factor string from a TrustCondition
 *
 * @param condition - array with [required:TrustFactors, optional:TrustFactors, optionalCount:int]
 * @param conditionString - buffer for output
 * @param maxLength - the buffer size
 * @return the amount of bytes written
 * @see ReadTrustCondition
 */
native int ComposeTrustConditionStringRaw(any condition[3], char[] conditionString, int maxLength);


/**
 * Struct for testing client trust.
 * This struct is intended to be filled by ParseTrustConditionString() from
 * within a convar change handler. After the TrustCondition is loaded, it can
 * .Test() clients for the required trust factors.
 * 
 * This way there is some kind of common ground for specifying the required
 * trust for clients to perform actions.
 */
enum struct TrustCondition {
	TrustFactors required; //these bit have to be set for a client to pass
	TrustFactors optional; //this is a group of optional trustfactors
	int optionalCount; //holds the amount of optional trustfactors a client needs to pass
	
	/**
	 * Checks if the specified client has the required trust factors and the
	 *   optionalCount amount of optional flags.
	 * - If this is an empty condition (no required, optionalCount 0)
	 *   => returns true
	 * - If the client lacks the required flags
	 *   => returns false
	 * - If no additional factors required (optionalCount 0)
	 *   => returns true
	 * - If all optional factors are required (-1) shortcuts to
	 *   => return factors == optionals
	 * - Counts optional bits and bits set for client
	 *   => returns client bits >= optionalCount
	 * 
	 * @param client the player to test
	 * @return true if trust check passes
	 * @error if the client trust factor was not yet loaded, the client is invalid or fake
	 */
	bool Test(int client) {
		TrustFactors factors = GetClientTrustFactors(client);
		if (this.required == UNTRUSTED && this.optionalCount == 0) 
			return true; //we are not counting
		if ((factors & this.required) != this.required) 
			return false; //one or more required flags are missing if there are required flags
		if (this.optionalCount == 0) return true; //we have the required bits and don't care for optionals => passed
		TrustFactors phase2 = (this.optional &~ this.required); //don't double check required
		if (this.optionalCount < 0) return (factors & phase2) == factors; //all optionals required? ok whatever, nice shortcut
		//count those flags
		int matched, max;
		for (int temp=view_as<int>(phase2); temp; temp>>=1) if (temp&1) max++;
		for (int temp=view_as<int>(phase2 & factors); temp; temp>>=1) if (temp&1) matched++;
		//prevent requiring more than possible
		int required = (this.optionalCount > max) ? max : this.optionalCount;
		return matched >= required;
	}
	/**
	 * Empties this struct for reuse.
	 * Since an empty TrustCondition will have neither required nor optionals
	 * flags .Test() will always pass until those values are loaded again.
	 */
	void Always() {
		this.required = UNTRUSTED;
		this.optional = UNTRUSTED;
		this.optionalCount = 0;
	}
	/**
	 * Parse a trust condition string. This can be used similar to ReadFlagString().
	 * 
	 * The condition string has two parts. No parst has to be specified (= always
	 * trust client). This first part are the required flags. If a client is missing
	 * any of these trust flags, the check fails. The second part are the optional
	 * flags. The client only needs a certain amount of those.
	 * > RRR requires 3 flags R, where a flac is one of the chars below.
	 * > TTTn requires n optional flags T where n < the amount of optional flags.
	 * > RRR+TTTn would be a combination, requiring all R flags, and n of the
	 *   optional T flags.
	 * If n <0 or n >= amount of T flags, the optional flags are treated equal to
	 *   required flags.
	 * If n == 0, the optional flags are ignored.
	 * > tg+*2 would mean the player has to have the configured server playtime and
	 *   global playtime in addition to any other 2 trust factors.
	 * > *+*0 would be equal to *-1 would be equal to * would be equal to tfdpslgob.
	 * > *0 would be qual to no condition / empty string
	 * 
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
	 * - * Is a meta char, meaning all flags
	 * 
	 * @param conditionString - the string to parse
	 * @param condition - the output structure for testing clients
	 * @return number of bytes parsed
	 */
	int Parse(const char[] string) {
		any data[3];
		int read = ParseTrustConditionStringRaw(string, data);
		if (read >= 0) {
			this.required = data[0];
			this.optional = data[1];
			this.optionalCount = data[2];
		}
		return read;
	}
	/**
	 * The inverse to .Parse(). This is intended to debugging / default configs.
	 * 
	 * @param buffer - the output buffer to write the string to
	 * @param maxlength - the size of your buffer
	 * @return number bytes written
	 * @see .Parse()
	 */
	int ToString(char[] buffer, int maxlength) {
		any data[3];
		data[0] = this.required;
		data[1] = this.optional;
		data[2] = this.optionalCount;
		return ComposeTrustConditionStringRaw(data, buffer, maxlength);
	}
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
	MarkNativeAsOptional("ReadTrustFactorChars");
	MarkNativeAsOptional("WriteTrustFactorChars");
	MarkNativeAsOptional("ParseTrustConditionStringRaw");
	MarkNativeAsOptional("ComposeTrustConditionStringRaw");
}
#endif
