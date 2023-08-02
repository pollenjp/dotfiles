# dev-tools

## dev packages

```sh
pip install -U \
    black \
    flake8 \
    autoflake8 \
    isort \
    mypy
```

## disable `ctrl+k` keybind in `terminalFocus`

```sh
python ./filter_keybinds.py < ./default_keybinds.jsonc | jq > filtered_keybinds.jsonc
```
