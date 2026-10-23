#!/bin/zsh
# İmzalı ve notarize edilmiş sürüm zip'ini hazırlar, Homebrew cask'ini günceller.
# Kullanım: ./release.sh 1.0.0
#
# Bir kerelik kurulum: notarytool için Apple ID bilgilerini anahtar zincirine kaydet.
#   xcrun notarytool store-credentials fortifill --apple-id <apple-id> --team-id Z5693NZJLD
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Kullanım: ./release.sh <sürüm>}"
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Sezer Iltekin (Z5693NZJLD)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-fortifill}"

./build.sh "$VERSION"
codesign --verify --deep --strict build/Unplug.app

ZIP="build/Unplug-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Unplug.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# Onay bileti uygulamaya iliştirilir; zip bu yüzden yeniden oluşturulur.
xcrun stapler staple build/Unplug.app
spctl --assess --type execute --verbose build/Unplug.app
rm -f "$ZIP"
ditto -c -k --keepParent build/Unplug.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA/" packaging/unplug.rb.template > packaging/unplug.rb

echo
echo "Zip:    $ZIP"
echo "SHA256: $SHA"
echo "Cask:   packaging/unplug.rb"
echo
echo "Sonraki adımlar:"
echo "  gh release create v$VERSION $ZIP --title \"Unplug $VERSION\""
echo "  packaging/unplug.rb dosyasını iltekin/homebrew-tap reposunda Casks/ altına koy"
