#!/bin/bash -eux

cd /tmp

REPO_NAME="git-sdk-64"
if ! [[ -d "${REPO_NAME}" ]]; then
    git clone --depth=1 https://github.com/git-for-windows/${REPO_NAME}
fi

cp ${REPO_NAME}/usr/bin/pacman* /usr/bin/
cp -a ${REPO_NAME}/etc/pacman.* /etc/

mkdir -p /var/lib/
cp -a ${REPO_NAME}/var/lib/pacman /var/lib/

mkdir -p /usr/share/makepkg/
cp -a ${REPO_NAME}/usr/share/makepkg/util* /usr/share/makepkg/

pacman --database --check

curl -L https://raw.githubusercontent.com/git-for-windows/build-extra/master/git-for-windows-keyring/git-for-windows.gpg \
| pacman-key --add - \
&& pacman-key --lsign-key 1A9F3986
