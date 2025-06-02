{
  lib,
  stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs_20,
  electron_34,
  node-gyp,
  python310,
  jq,
  xcbuild,
  cctools,
  darwin,
  srcOnly,
  removeReferencesTo,
}: let
  nodejs = nodejs_20;
  electron = electron_34;

  nodeSrc = srcOnly nodejs;

  npmExec = exec: args: "npm exec -- ${lib.concatStringsSep " " args}";
in
  buildNpmPackage rec {
    pname = "bluebubbles-server";
    version = "1.9.9";

    src = fetchFromGitHub {
      owner = "BlueBubblesApp";
      repo = "bluebubbles-server";
      tag = "v${version}";
      hash = "sha256-0+GkBxw9E11UGY78BgJYZb8fAzBlFDi9DgfY1iv+Rs0=";
    };

    npmDepsHash = "sha256-8KoewlT3Qxdqg7mZTaPeGq7wPskB2kklPizPJqX+YMk="; #"sha256-PYRHiZDTN0E+f2TeDoW41noRQEgOgQue4G381LdONh8="; # "sha256-XUCp2em93l/SoO2Bm4QBFMhdxhxvtefauy46E0fXOas=";

    inherit nodejs;
    nativeBuildInputs = [
      jq
      # for node-gyp; <=3.10 per https://github.com/BlueBubblesApp/bluebubbles-server/issues/686
      python310
      electron
      # for node-gyp rebuild of better-sqlite3
      xcbuild
      cctools
      removeReferencesTo
    ];

    patches = [
      ./electron-builder-targets.patch

      ## fixes to allow building against newer (>20.11.X) node versions:
      ./upd-node-abi.patch
      # https://stackoverflow.com/a/79204979
      ./rm-deprecated-devEngines.patch
      # https://github.com/nodejs/node-addon-api/issues/1584#issuecomment-2389600641
      ./upd-node-mac-contacts-napi.patch
    ];

    makeCacheWritable = true;
    npmFlags = [
      "--no-audit"
      "--no-fund"
      "--verbose"
    ];

    # ignore scripts during config hook rebuild,
    # to avoid ngrok postinstall script w/ redundant binary download.
    # binary is provided in the bluebubbles-server src
    # npm rebuild run by electron-builder later
    npmRebuildFlags = ["--ignore-scripts"];
    preBuild = ''
      # the npmConfigHook sets this; improperly overrides later rebuilds against electron's ABI causing issues
      unset npm_config_nodedir
      unset npm_config_node_gyp

      export npm_config_nodedir="${electron.headers}"
      export npm_config_runtime=electron
      export npm_config_target="${electron.version}"
      export npm_config_build_from_source=true
      

      # remove ngrok scripts
      pushd node_modules/ngrok
        echo "Removing ngrok scripts"
        jq 'del(.scripts)' package.json > package.json.tmp && mv package.json.tmp package.json
      popd

      pushd node_modules/better-sqlite3
        echo "Rebuilding better-sqlite3 against electron"
        substituteInPlace binding.gyp \
          --replace-fail "'cflags_cc': ['-std=c++20']," \
                         "'cflags_cc': ['-std=c++20', '-w'],"

        npm run build-release --offline --nodedir="${electron.headers}" --runtime=electron --target="${electron.version}" --verbose
        find build -type f -exec remove-references-to -t "${electron.headers}" {} \;
      popd

      pushd packages/server
        # dist needs to be mutable for electron-builder
        echo "Creating mutable electron-dist"
        cp -r ${electron.dist} electron-dist
        chmod -R u+w electron-dist
        substituteInPlace package.json \
          --replace-fail \
            '"dist": "npm run build && electron-builder build --mac --publish never --config ./scripts/electron-builder-config.js"' \
            '"dist": "npm run build && electron-builder ${lib.concatStringsSep " " [
              "build" 
              "--dir"
              "--mac" 
              "--publish never" 
              "--config ./scripts/electron-builder-config.js" 
              #"-c.buildDependenciesFromSource=true"
              "-c.npmRebuild=true"
              #"-c.nodeGypRebuild=true"
              "-c.electronVersion=${electron.version}"
              "-c.electronDist=electron-dist"
              #"-c.npmArgs=--"
            ]}"'
      popd
      
      substituteInPlace package.json \
        --replace-fail '"build": "npm run build-ui && npm run build-server && rm -rf ./dist && mkdir -p ./dist && cp -R ./packages/server/releases/* ./dist/ && rm -rf ./packages/server/releases/ && rm -rf ./packages/ui/build/"' \
                       '"build": "npm run build-ui && npm run build-server"'
  
      find node_modules -type d -name prebuilds -exec rm -rv {} +
    '';

    /* package.json
    "start": "concurrently \"cd ./packages/ui && npm run start\" \"cd ./packages/server && npm run start\"",
    "build-ui": "cd ./packages/ui && npm run build && mkdir -p ../server/dist/static && rm -rf ../server/dist/static && cp -R ./build/** ../server/dist/ && cd ../../",
    "build-server": "cd ./packages/server && npm run dist && cd ../../",
    "release-server": "cd ./packages/server && npm run release && cd ../../",
    "build": "npm run build-ui && npm run build-server && rm -rf ./dist && mkdir -p ./dist && cp -R ./packages/server/releases/* ./dist/ && rm -rf ./packages/server/releases/ && rm -rf ./packages/ui/build/",
    "release": "npm run build-ui && npm run release-server"
    */

    /* packages/ui/package.json
    "start": "export BROWSER=none && react-app-rewired start",
    "build": "export NODE_ENV=production && react-app-rewired build"
    */

    /* packages/server/package.json
    "build": "export NODE_ENV=production && webpack --config ./scripts/webpack.main.prod.config.js",
    "start": "export NODE_ENV=development && webpack --config ./scripts/webpack.main.config.js && electron ./dist/main.js",
    "lint": "eslint --ext=jsx,js,tsx,ts src",
    "dist": "npm run build && electron-builder build --mac --publish never --config ./scripts/electron-builder-config.js",
    "release": "npm run build && electron-builder build --mac --publish always --config ./scripts/electron-builder-config.js",
    "rebuild": "electron-rebuild -f better-sqlite3 node-mac-contacts node-mac-permissions",
    "postinstall": "electron-rebuild install-app-deps && npm run rebuild"
    */


    /*buildPhase = ''
      # build UI
      pushd packages/ui
      ${npmExec "react-app-rewired" ["build"]}
      mkdir -p ../server/dist/
      cp -R ./build/** ../server/dist/
      popd

      # build server
      pushd packages/server
      ${npmExec "webpack" ["--config ./scripts/webpack.server.prod.config.js"]}
      ${npmExec "electron-builder" [
        "build" 
        "--mac" 
        "--publish never" 
        "--config ./scripts/electron-builder-config.js" 
        "--dir"
        "-c.electronVersion=${electron.version}" 
        "-c.electronDist=${electron}"
        "-c.npmRebuild=false"
        "-c.buildDependenciesFromSource=true"
        "-c.nodeGypRebuild=true"
      ]}
      # ${npmExec "electron-builder" ["node-gyp-rebuild"]}
      popd
    '';*/

    /*postBuild = ''
      ${npmExec "electron-builder" [
        "node-gyp-rebuild"
        "--help"
      ]}

      ${npmExec "electron-builder" ["node-gyp-rebuild"]}

      ${npmExec "electron-builder" [
        "--mac"
        "--dir"
        "--publish never"
        "--project packages/server"
        "--config scripts/electron-builder-config.js"
        "-c.buildDependenciesFromSource=true"
      ]}
    '';*/

    installPhase = ''
      runHook preInstall

      mkdir -p $out/Applications
      cp -r packages/server/releases/BlueBubbles.app $out/Applications

      runHook postInstall
    '';

    env = {
      ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
      CSC_IDENTITY_AUTO_DISCOVERY = "false";

      npm_config_build_from_source = "true";
      #npm_config_runtime = "electron";
      #npm_config_nodedir = electron.headers;
      #npm_config_target = electron.version;

      DEBUG = "electron-builder,electron-rebuild,webpack,prebuild-install";
    };

    meta = {
      description = "Server for the BlueBubbles messaging app";
      homepage = "https://github.com/BlueBubblesApp/bluebubbles-server";
      license = lib.licenses.asl20;
      maintainers = with lib.maintainers; [zacharyweiss];
      platforms = lib.platforms.darwin;
    };
  }
