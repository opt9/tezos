#! /bin/sh

script_dir="$(cd "$(dirname "$0")" && echo "$(pwd -P)/")"
cd "$script_dir"/..

branch=$1
has_git() {
    which git && [ -d .git ]
}

if has_git && ! [ -z "$(git status -s)" ] ; then
    echo "This script cannot be applied within a dirty git directory,"
    echo "you need 'stash' or 'commit' your changes before."
    exit 1
fi

set -e

case "$branch" in
    zeronet)
        sed -i s/TEZOS/TEZOS_ZERONET/ ./lib_node_shell/distributed_db_message.ml
        patch -p1 < scripts/alphanet_constants.patch
        patch -p1 < scripts/zeronet.patch
        cp README.md docs/README.master
        cp docs/README.zeronet README.md
        if has_git; then git add docs/README.master; git commit -a -m "Zeronet: DO NOT MERGE" --author "Tezos CI <null@tezos.com>"; fi
        echo "Done"
        ;;
    alphanet)
        sed -i s/TEZOS/TEZOS_ALPHANET/ ./lib_node_shell/distributed_db_message.ml
        patch -p1 < scripts/alphanet_constants.patch
        cp README.md docs/README.master
        cp docs/README.alphanet README.md
        if has_git; then git add docs/README.master; git commit -a -m "Alphanet: DO NOT MERGE" --author "Tezos CI <null@tezos.com>"; fi
        echo "Done"
        ;;
    *)
        echo "Noop"
esac
