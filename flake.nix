{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    import-cargo.url = "github:edolstra/import-cargo";
    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , rust-overlay
    , import-cargo
    , crane
    }:
    let
      SYSTEMS = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      RUST_CHANNELS = [
        "stable"
        "beta"
      ];

      forEachRustChannel = fn: builtins.listToAttrs (builtins.map fn RUST_CHANNELS);

      cargoTOML = builtins.fromTOML (builtins.readFile ./Cargo.toml);

      version = "${cargoTOML.package.version}_${builtins.substring 0 8 self.lastModifiedDate}_${self.shortRev or "dirty"}";

    in
    flake-utils.lib.eachSystem SYSTEMS (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          (import rust-overlay)
        ];
      };

      cargoHome = (import-cargo.builders.importCargo {
        lockFile = ./Cargo.lock;
        inherit pkgs;
      }).cargoHome;

      # Additional packages required for some systems to build alacritty
      missingSysPkgs =
        if pkgs.stdenv.isDarwin then
          [
            pkgs.darwin.libiconv
          ] ++ ( with pkgs.darwin.apple_sdk.frameworks; [
            CoreServices
            CoreText
            Foundation
            OpenGL
            ApplicationServices
            CoreGraphics
            CoreVideo
            AppKit
            QuartzCore
            Security
          ])
        else
          [ ];

      mkRust =
        { rustProfile ? "minimal"
        , rustExtensions ? [
            "rust-src"
            "rust-analysis"
            "rustfmt"
            "clippy"
          ]
        , channel ? "stable"
        , target ? pkgs.rust.toRustTarget pkgs.stdenv.hostPlatform
        }:
        if channel == "nightly" then
          pkgs.rust-bin.selectLatestNightlyWith
            (toolchain: toolchain.${rustProfile}.override {
              extensions = rustExtensions;
              targets = [ target ];
            })
        else
          pkgs.rust-bin.${channel}.latest.${rustProfile}.override {
            extensions = rustExtensions;
            targets = [ target ];
          };

      # Build the various Crane artifacts (dependencies, packages, rustfmt, clippy) for a given Rust toolchain
      mkCraneArtifacts = { rust ? mkRust { } }:
        let
          craneLib = crane.lib.${system}.overrideToolchain rust;

          src = pkgs.lib.cleanSourceWith {
            src = pkgs.lib.cleanSource ./.;

            filter = path: type:
              builtins.any (filter: filter path type) [
                craneLib.filterCargoSources
              ];
          };

          # Args passed to all `cargo` invocations by Crane.
          cargoExtraArgs = "--frozen --offline --workspace";

        in
        rec {
          # Build *just* the cargo dependencies, so we can reuse all of that work (e.g. via cachix) when running in CI
          cargoArtifacts = craneLib.buildDepsOnly {
            inherit
              src
              cargoExtraArgs;
          };

          alacritty = craneLib.buildPackage {
            inherit
              src
              cargoExtraArgs
              cargoArtifacts;
          };

          rustfmt = craneLib.cargoFmt {
            # Notice that unlike other Crane derivations, we do not pass `cargoArtifacts` to `cargoFmt`, because it does not need access to dependencies to format the code.
            inherit src;

            # We don't reuse the `cargoExtraArgs` in scope because `cargo fmt` does not accept nor need any of `--frozen`, `--offline` or `--workspace`
            cargoExtraArgs = "--all";

            # `-- --check` is automatically prepended by Crane
            rustFmtExtraArgs = "--color always";
          };

          clippy = craneLib.cargoClippy {
            inherit
              src
              cargoExtraArgs
              cargoArtifacts;

            cargoClippyExtraArgs = "--all-targets -- --deny warnings --allow clippy::new-without-default --allow clippy::match_like_matches_macro";
          };

        };

      makeDevShell = { rust }: pkgs.mkShell {
        # Trick found in Crane's examples to get a nice dev shell
        # See https://github.com/ipetkov/crane/blob/master/examples/quick-start/flake.nix
        inputsFrom = builtins.attrValues (mkCraneArtifacts { inherit rust; });

        buildInputs = [
          pkgs.rust-analyzer
        ] ++ missingSysPkgs;

        RUST_SRC_PATH = "${rust}/lib/rustlib/src/rust/library";
      };
    in rec {
      packages = {
        alacritty = (mkCraneArtifacts { }).alacritty;
        default = packages.alacritty;
      };

      devShells = (forEachRustChannel (channel: {
        name = channel;
        value = makeDevShell { rust = mkRust { inherit channel; rustProfile = "default"; }; };
      })) // {
        default = devShells.stable;
      };

      checks = {
        inherit (mkCraneArtifacts { }) alacritty clippy rustfmt;
      };
    }
    ); # each systems
}

# make app
