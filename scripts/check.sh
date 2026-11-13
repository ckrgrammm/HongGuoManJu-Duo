#!/bin/zsh
set -eu
project_root="${0:A:h:h}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/manjuduo-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -module-cache-path "$check_dir/modules" "$project_root/ManjuDuo/Core/ProtocolCrypto.swift" "$project_root/Tests/CryptoCheck.swift" -o "$check_dir/crypto"
"$check_dir/crypto"
swiftc -module-cache-path "$check_dir/modules" "$project_root/ManjuDuo/Core/ProtocolCrypto.swift" "$project_root/ManjuDuo/Core/Models.swift" "$project_root/ManjuDuo/Core/LibraryStore.swift" "$project_root/ManjuDuo/Playback/CENCMedia.swift" "$project_root/Tests/CoreChecks.swift" -o "$check_dir/core"
"$check_dir/core"
