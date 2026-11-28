UPDATE setting
SET default_value = '"https://api.github.com/repos/WobblyBit/picotorrent/releases/latest"'
WHERE key = 'update_checks.url';

UPDATE setting
SET value = NULL
WHERE key = 'update_checks.url' AND value = '"https://api.picotorrent.org/releases/latest"';
