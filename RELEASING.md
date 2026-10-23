# Releasing Unplug

Every release goes through the same steps: build, sign, notarize, publish on GitHub, and update the Homebrew cask. Skipping the cask step means `brew install` keeps serving the old version.

## One-time setup

You only need these once per Mac.

| What | Check it with | How to set it up |
|---|---|---|
| Xcode Command Line Tools | `xcode-select -p` | `xcode-select --install` |
| Developer ID Application certificate for **Sezer Iltekin (Z5693NZJLD)** in the login keychain | `security find-identity -v -p codesigning \| grep "Developer ID Application"` | Create it in the Apple Developer account (Certificates → Developer ID Application) and install it |
| notarytool keychain profile `notary` (Apple ID + app-specific password for team Z5693NZJLD) | `xcrun notarytool history --keychain-profile notary` | `xcrun notarytool store-credentials notary --apple-id <apple-id> --team-id Z5693NZJLD` (create the app-specific password at account.apple.com → Sign-In and Security) |
| GitHub CLI logged in as `iltekin` | `gh auth status` | `gh auth login` |
| Local clone of the tap | `ls ~/Developer/homebrew-tap` | `git clone https://github.com/iltekin/homebrew-tap.git ~/Developer/homebrew-tap` |

If your profile or signing identity has a different name, put it in a `.release.env` file at the repository root. It's ignored by git and loaded by `release.sh`:

```bash
NOTARY_PROFILE=my-profile-name
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

## Release checklist

Replace `1.0.1` with the new version. Use [semantic versioning](https://semver.org): patch for fixes, minor for new features.

### 1. Prepare `main`

```bash
cd ~/Developer/Unplug
git checkout main
git pull
git status   # must be clean
```

Make sure everything that should ship is committed and pushed. If the release changes what Unplug does, update `README.md` and `docs/index.html` (features, FAQ) in the same commit.

### 2. Build, sign and notarize

```bash
./release.sh 1.0.1
```

This builds the universal app with the version baked into `Info.plist`, signs it with the Developer ID (hardened runtime), notarizes it with Apple, staples the ticket, checks it with Gatekeeper, zips it to `build/Unplug-1.0.1.zip`, and writes `packaging/unplug.rb` with the new version and SHA-256.

It should end with `status: Accepted`, `The staple and validate action worked!` and `source=Notarized Developer ID`. If notarization fails, see the log:

```bash
xcrun notarytool log <submission-id> --keychain-profile notary
```

### 3. Publish the GitHub release

```bash
gh release create v1.0.1 build/Unplug-1.0.1.zip --title "Unplug 1.0.1" --notes "..."
```

The tag must be `v` + version and the asset must be named `Unplug-<version>.zip`: the cask builds its download URL from exactly these. Write short release notes listing what changed.

### 4. Update the Homebrew cask

```bash
cp packaging/unplug.rb ~/Developer/homebrew-tap/Casks/unplug.rb
cd ~/Developer/homebrew-tap
git pull
git add Casks/unplug.rb
git commit -m "Update unplug to 1.0.1"
git push
```

Only copy the cask **after** the GitHub release exists, otherwise brew users get a download error.

### 5. Verify like a user

```bash
brew update
brew audit --cask --online iltekin/tap/unplug
brew upgrade --cask unplug        # or: brew install --cask iltekin/tap/unplug
spctl --assess --type execute --verbose /Applications/Unplug.app
```

`brew audit` must pass and `spctl` must print `accepted` and `source=Notarized Developer ID`. Open Unplug from the menu bar and check **About** shows the new version.

The website (`docs/`) is served by GitHub Pages from `main` and its download links point to `releases/latest`, so it picks up the new release automatically.

## If something goes wrong

- **Wrong file in a release:** delete the release and tag (`gh release delete v1.0.1 --cleanup-tag`), fix, and run the checklist again from step 2. Don't change a published zip in place: its SHA-256 is pinned in the cask.
- **Cask points to a broken release:** revert the last commit in `homebrew-tap` and push, then fix the release.
- **Certificate expired:** Developer ID certificates last five years. Create a new one, install it, and update the identity in `release.sh` if the name changed.
