# Go environment PATH

if command -q go
    set -l bin_path (go env GOPATH)/bin
    fish_add_path --prepend $bin_path
end
