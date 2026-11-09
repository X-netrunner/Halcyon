# The always-on helpers (hx, hal, hgl, power-manager, touchpad-gestures, ...): the whole Cargo workspace in one build.
{ lib, rustPlatform, pkg-config, src }:

rustPlatform.buildRustPackage {
  pname = "halcyon-helpers";
  version = "0-unstable";
  src = lib.cleanSourceWith {
    inherit src;
    # only what cargo needs: the workspace manifest, the lock file and the crates
    filter = path: type:
      let rel = lib.removePrefix (toString src + "/") (toString path); in
      rel == "Cargo.toml" || rel == "Cargo.lock" || rel == "src" || lib.hasPrefix "src/" rel;
  };
  cargoLock.lockFile = ../Cargo.lock;
  nativeBuildInputs = [ pkg-config ];
  # the tests stub system programs that are not in the build sandbox; CI runs them
  doCheck = false;
  meta = {
    description = "Halcyon's Rust helpers";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
