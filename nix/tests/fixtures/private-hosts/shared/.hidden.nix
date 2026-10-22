# nix/tests/private-hosts.nix の作り物。名前が . で始まるファイル (エディタのロック・一時ファイルなど) は shared/ でも拾わない
throw "privateHosts は shared/ の . で始まるファイルを拾わない"
