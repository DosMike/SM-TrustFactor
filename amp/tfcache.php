<?php
// you can delete the following two lines about errors once everything works
error_reporting(E_ALL);
ini_set("display_errors", 1);

// $rustart = getrusage();

$config = [
	'apikey' => 'steam web api key',
	'database' => 'database name',
	'username' => 'username',
	'password' => 'password',
	'host'     => 'localhost'
];

// connecting first, so you can check whether it works (should return 'Format' if database is reachable)
$sql = new mysqli($config['host'], $config['username'], $config['password'], $config['database']);
if ($sql->connect_errno) {
	fail($sql->connect_error);
}

function cget($var) {
	return array_key_exists($var, $_GET) && !empty(trim($_GET[$var])) && is_numeric($_GET[$var]);
}
//validate request
$headers = apache_request_headers();
if (empty($headers['X-Trustfactor']) || !cget('steamId') || !cget('appId') || !cget('cdata')) {
	cancel("Format");
}
if (str_contains($headers['Accept'], 'application/json')) {
	$resultType = "json";
} else {
	$resultType = "plain";
}
// set charset
$sql->set_charset('utf8mb4');
if ($sql->errno) {
	fail($sql->error);
}

//ensure tables
$sql->query(
"CREATE TABLE IF NOT EXISTS smtfc_player (
	steamId bigint unsigned PRIMARY KEY AUTO_INCREMENT,
	setup tinyint,
	visibility tinyint,
	accountage tinyint,
	level int,
	pocbadge tinyint,
	vacbanned tinyint,
	tradebanned tinyint,
	created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
)"
);
$sql->query(
"CREATE TABLE IF NOT EXISTS smtfc_gametime (
	playerId bigint unsigned NOT NULL,
	appId int NOT NULL,
	gametime int NOT NULL,
	PRIMARY KEY (playerId, appId),
	FOREIGN KEY (playerId)
		REFERENCES smtfc_player (steamId)
		ON DELETE CASCADE
)"
);
//invalidate caches
$sql->query(
"DELETE FROM smtfc_player WHERE `created` < NOW()-INTERVAL 12 HOUR"
);

function cancel($msg) {
	http_response_code(400 + intval(hash('crc32',$_SERVER['REQUEST_URI']))%17 );
	die ($msg);
}
function fail($msg) {
	http_response_code(500 + intval(hash('crc32',$_SERVER['REQUEST_URI']))%11 );
	die ($msg);
}

$cache = [
	'visibility'=>0,
	'setup'=>0,
	'oldaccount'=>0,
	'level'=>0,
	'pocbadge'=>0,
	'gametime'=>0,
	'vacbanned'=>0,
	'tradebanned'=>0,
];
$missing = [ false, false, false, false ]; //request types (SWAPI_CHECK_*)
//try to load data from cache
$result = $sql->query(
"SELECT smtfc_player.`setup`, smtfc_player.`visibility`, smtfc_player.`accountage`, smtfc_player.`level`, smtfc_player.`pocbadge`, smtfc_player.`vacbanned`, smtfc_player.`tradebanned`, smtfc_gametime.`gametime`
FROM smtfc_player
LEFT JOIN smtfc_gametime ON smtfc_player.`steamId` = smtfc_gametime.`playerId` AND smtfc_gametime.`appId` = '".mysqli_real_escape_string($sql, $_GET['appId'])."'
WHERE smtfc_player.`steamId` = '".mysqli_real_escape_string($sql, $_GET['steamId'])."'"
);
if (($row=$result->fetch_assoc())!==NULL) {
	if ($row['setup']===NULL || $row['visibility']===NULL || $row['accountage']===NULL) {
		$missing[0] = true;
	} else {
		$cache['setup'] = $row['setup'];
		$cache['visibility'] = $row['visibility'];
		$cache['oldaccount'] = $row['accountage'];
	}
	if ($row['level']===NULL || $row['pocbadge']===NULL) {
		$missing[1] = true;
	} else {
		$cache['level'] = $row['level'];
		$cache['pocbadge'] = $row['pocbadge'];
	}
	if ($row['gametime']===NULL) {
		$missing[2] = true;
	} else {
		$cache['gametime'] = $row['gametime'];
	}
	if ($row['vacbanned']===NULL || $row['tradebanned']===NULL) {
		$missing[3] = true;
	} else {
		$cache['vacbanned'] = $row['vacbanned'];
		$cache['tradebanned'] = $row['tradebanned'];
	}
} else {
	$missing = [ true, true, true, true ];
}

//load data we are allowed to postload
$vprofile = 0; //bits parsed in order by the plugin
$cdata = intval($_GET['cdata']);
if ($cdata & 1) { //check profile
	if ($missing[0]) {
		$data = jcurl("https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key={$config['apikey']}&steamids={$_GET['steamId']}");
		$player = $data['response']['players'];
		if (count($player)) $player = $player[0];
		else fail("Player");
		$cache['setup'] = $player['profilestate']==1;
		$cache['visibility'] = $player['communityvisibilitystate']==3;
		if (array_key_exists('timecreated', $player))
			$cache['oldaccount'] = (time()-intval($player['timecreated'])) > 2592000; //older than roughly a month
	}
	$vprofile = ($cache['setup']?1:0) + ($cache['visibility']?2:0) + ($cache['oldaccount']?4:0);
}
if ($cdata & 2) { //check steamlevel
	if ($missing[1]) {
		$data = jcurl("https://api.steampowered.com/IPlayerService/GetBadges/v1/?key={$config['apikey']}&steamid={$_GET['steamId']}");
		if (isset($data['response']['player_level'])) {
			$cache['level'] = $data['response']['player_level'];
		}
		if (isset($data['response']['badges'])) {
			$badge = array_values(array_filter($data['response']['badges'], function($badge){ return !array_key_exists('appid',$badge)&&$badge['badgeid']==2; }));
			if (count($badge)) $cache['pocbadge'] = $badge[0]['level'];
			
			if ($cache['oldaccount']==0 && ($vprofile & 4)==0) {
				$badge = array_values(array_filter($data['response']['badges'], function($badge){ return !array_key_exists('appid',$badge)&&$badge['badgeid']==1; }));
				if (count($badge) && $badge[0]['level']>0) {
					//years of service medal has levels (aka years)
					$cache['oldaccount']=1; //if player has this medal, they have an "old" account
					$vprofile |= 4;
				}
			}
		}
	}
}
if ($cdata & 4) { //check gametime
	if ($missing[2]) {
		$data = jcurl("https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key={$config['apikey']}&steamid={$_GET['steamId']}&include_played_free_games=1");
		if (isset($data['response']['games'])) {
			$game = array_values(array_filter($data['response']['games'], function($ginfo){ return $ginfo['appid']==$_GET['appId']; }));
			if (count($game)) {
				$cache['gametime'] = intval($game[0]['playtime_forever']/60);
			}
		}
	}
}
if ($cdata & 8) { //check banns
	if ($missing[3]) {
		$data = jcurl("https://api.steampowered.com/ISteamUser/GetPlayerBans/v1/?key={$config['apikey']}&steamids={$_GET['steamId']}");
		if (isset($data['players']) && count($data['players'])==1) {
			$bans = $data['players'][0];
			$cache['vacbanned'] = $bans['VACBanned'] || $bans['NumberOfVACBans']>0;
			$cache['tradebanned'] = $bans['EconomyBan']!=='none'; //doesn't seem to be documented? observed values: 'none', 'banned'
		}
	}
	if ($cache['vacbanned']) $vprofile |= 8;
	if ($cache['tradebanned']) $vprofile |= 16;
}

if (($cdata) && ($missing[0]||$missing[1]||$missing[2])) { //we need to ensure this row exists, even in only gametime was choosen
	$sql->query(
		"INSERT INTO smtfc_player (`steamId`,`setup`,`visibility`,`accountage`,`level`,`pocbadge`,`vacbanned`,`tradebanned`) VALUES ('".
			mysqli_real_escape_string($sql, $_GET['steamId'])."', '".
			intval($cache['setup'])."', '".
			intval($cache['visibility'])."', '".
			intval($cache['oldaccount'])."', '".
			intval($cache['level'])."', '".
			intval($cache['pocbadge'])."', '".
			intval($cache['vacbanned'])."', '".
			intval($cache['tradebanned'])
		."') ON DUPLICATE KEY UPDATE ".
			"`setup`='".intval($cache['setup']).
			"',`visibility`='".intval($cache['visibility']).
			"',`accountage`='".intval($cache['oldaccount']).
			"',`level`='".intval($cache['level']).
			"',`pocbadge`='".intval($cache['pocbadge']).
			"',`vacbanned`='".intval($cache['vacbanned']).
			"',`tradebanned`='".intval($cache['tradebanned'])."'"
	);
}
if (($cdata & 8) && $missing[2]) { //we have updated game data
	$sql->query(
		"INSERT INTO smtfc_gametime (`playerId`,`appId`,`gametime`) VALUES ('".
			mysqli_real_escape_string($sql, $_GET['steamId'])."', '".
			mysqli_real_escape_string($sql, $_GET['appId'])."', '".
			intval($cache['gametime'])
		."') ON DUPLICATE KEY UPDATE ".
			"`gametime`='".intval($cache['gametime'])."'"
	);
}


$responseData = sprintf("02%02X%02X%04X%08X", $vprofile&0xFF, $cache['pocbadge']&0xFF, $cache['level'], $cache['gametime']);
if ($resultType == "json") {
	echo json_encode(["value" => $responseData]);
} else {
	echo $responseData;
}


// $ru = getrusage();
// echo "<br>This process used " . rutime($ru, $rustart, "utime") . " ms for its computations\n";

// function rutime($ru, $rus, $index) {
    // return ($ru["ru_$index.tv_sec"]*1000 + intval($ru["ru_$index.tv_usec"]/1000))
     // -  ($rus["ru_$index.tv_sec"]*1000 + intval($rus["ru_$index.tv_usec"]/1000));
// }

function jcurl($at) {
	$ch = curl_init();
	curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
	curl_setopt($ch, CURLOPT_USERAGENT, 'TrustFactor/2 (github.com/DosMike/SM-TrustFactor; SourceMod plugin adapter) PHP/'.PHP_VERSION);
	curl_setopt($ch, CURLOPT_URL, $at);
	$result = curl_exec($ch);
	curl_close($ch);
	return json_decode($result, true);
}