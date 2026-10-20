# nix/tests/private-hosts.nix の作り物。名前が . で始まるファイル (エディタのロック・一時ファイルなど) はホストにしない
_: throw "privateHosts は . で始まるファイルを拾わない"
