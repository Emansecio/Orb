#!/bin/bash
# Refreshes Sources/Orb/Resources/Rich from the versions pinned here, checking npm's integrity hash. Run by hand when a
# version changes; the app never fetches these files. Nothing from the packages is executed.
set -euo pipefail
cd "$(dirname "$0")/.."

MERMAID_VERSION=12.2.0
MERMAID_SHA512=w7nr/SFrLO7BaVTs3dQTvYSV6nYSBj0Yy9DjBhsIJtAcHqRzXSq4Pg32ujHZ/AdWsAMNEvvhbm5dt9E2tOiHzw==
KATEX_VERSION=0.19.1
KATEX_SHA512=jG8uKntjSEcm2EpQOh0XturpPuuC9r3Sq5HLHdsFdWZT27E672SF19QEi+of0/YeOy15lDgRhKvr5614uRrEfA==

RICH=Sources/Orb/Resources/Rich
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() { # name version sha512
    curl -fsSL "https://registry.npmjs.org/$1/-/$1-$2.tgz" -o "$WORK/$1.tgz"
    actual=$(openssl dgst -sha512 -binary "$WORK/$1.tgz" | base64)
    [ "$actual" = "$3" ] || { echo "Integridade errada em $1" >&2; exit 1; }
    mkdir "$WORK/$1"
    tar xzf "$WORK/$1.tgz" -C "$WORK/$1"
}

fetch mermaid "$MERMAID_VERSION" "$MERMAID_SHA512"
fetch katex "$KATEX_VERSION" "$KATEX_SHA512"

cp "$WORK/mermaid/package/dist/mermaid.min.js" "$RICH/"
cp "$WORK/mermaid/package/LICENSE" "$RICH/LICENSE-mermaid"
cp "$WORK/katex/package/dist/katex.min.js" "$RICH/"
cp "$WORK/katex/package/LICENSE" "$RICH/LICENSE-katex"
cp "$WORK/katex/package/dist/fonts/"*.woff2 "$RICH/fonts/"
# Only the woff2 files ship: the fallbacks would be requests for files that are not there.
sed -E 's/,url\([^)]*\.(woff|ttf)\) format\("[a-z]+"\)//g' "$WORK/katex/package/dist/katex.min.css" > "$RICH/katex.min.css"
echo "Recursos atualizados: mermaid $MERMAID_VERSION, katex $KATEX_VERSION"
