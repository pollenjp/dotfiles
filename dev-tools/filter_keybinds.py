import json
import sys

if __name__ == "__main__":
    fixed_json = "".join(line for line in sys.stdin.readlines() if not line.startswith("//"))
    d = json.loads(fixed_json)

    out = []
    for key_item in d:
        key = key_item["key"]
        if key.lower().startswith("ctrl+k"):
            # key_item["command"] = f'-{key_item["command"]}'
            # out.append(key_item)
            # continue

            if "when" not in key_item.keys():
                key_item["when"] = "!terminalFocus"
                # if not key_item["command"].startswith("-"):
                #     key_item["command"] = f'-{key_item["command"]}'
                out.append(key_item)

            else:
                # elif key_item["when"].startswith("terminalFocus"):
                if key_item["command"].startswith("-"):
                    key_item["command"] = f'-{key_item["command"]}'
                # key_item["when"] = f'!terminalFocus && {key_item["when"]}'
                key_item["when"] = "terminalFocus"
                out.append(key_item)

    print(json.dumps(out))
