# Third-Party Notices and License Boundaries

## Repository Code (`MIT`)

All original source code in this repository — including the ChatGPT Sites / Cloudflare Workers backend (`app/`, `src/`, `migrations/`, `drizzle/`), the standalone SwiftPM package (`ios/PokiSitesBridge/`), the Poki integration glue (`ios/PokiAppIntegration/`), and the build/test scripts (`scripts/`, `tests/`) — is licensed under the **MIT License** (see [LICENSE](LICENSE)).

## Upstream `Poki` & Prebuilt iOS IPA (`AGPL-3.0-only`)

The iOS build script ([`scripts/build-ios-ipa.sh`](scripts/build-ios-ipa.sh)) fetches and compiles against upstream [**JosssphZhou/poki**](https://github.com/JosssphZhou/poki) pinned at commit `9184aca5b9368a81f37f4e611827072a94105fcb`, which is licensed under **GNU Affero General Public License v3.0 (`AGPL-3.0-only`)**.

Accordingly:

- Any compiled iOS binary / `.ipa` built from `scripts/build-ios-ipa.sh` (including prebuilt unsigned `.ipa` assets attached to GitHub Releases) links against `PokiCore` and modifies upstream `Poki` sources, and is therefore distributed under **`AGPL-3.0-only`**.
- The complete Corresponding Source for every distributed `.ipa` consists of:
  1. Upstream `https://github.com/JosssphZhou/poki` at commit `9184aca5b9368a81f37f4e611827072a94105fcb`
  2. This repository (`ios/PokiSitesBridge/`, `ios/PokiAppIntegration/`, `scripts/patch-poki-upstream.py`, the `scripts/patch_poki_*.py` integration modules, and `scripts/build-ios-ipa.sh`)
- You can reproduce the unsigned External-mode IPA from source on macOS with Xcode, XcodeGen, and Rust (`aarch64-apple-ios`) by running:

  ```bash
  bash scripts/build-ios-ipa.sh
  ```
