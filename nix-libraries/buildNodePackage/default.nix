{ pkgs, nodejs }:

let

pkg = {
  name,
  version,
  src,
  deps,
  devDependencies ? null,
  doCheck ? devDependencies != null,
  meta ? {},
  removePeerDependencies ? true,
  requireNodeVersion ? null, patchPhase ? "",
  preInstall ? "", postInstall ? "", shellHook ? ""
}@args:

let
  dependencies' = map (p: p.withoutTests) deps;
  devDependencies' = if devDependencies == null then []
                     else map (p: p.withoutTests) devDependencies;
  shouldTest = (devDependencies != null) && doCheck;
in

# Version must be present.
if version == "" then throw "No version specified for ${name}"
else

let
  inherit (pkgs.lib) splitString head tail;
  nodejs_version = nodejs.version or (head (tail splitString "-" nodejs.name));
in

if requireNodeVersion != null && nodejs_version != requireNodeVersion
then throw ("package ${name}-${version} requires nodejs ${requireNodeVersion},"
            + " but passed in version is ${nodejs_version}")
else

let
  inherit (pkgs.stdenv) mkDerivation;
  inherit (pkgs.stdenv.lib) concatStringsSep flip optional optionals;
  dependencies = dependencies';
  devDependencies = devDependencies';

  # Extract the nodejs sources to a folder. These will be used as an
  # argument to npm.
  sources = mkDerivation {
    name = "${nodejs.name}-sources";
    buildCommand = ''
      tar --no-same-owner --no-same-permissions -xf ${nodejs.src}
      mv $(find . -type d -mindepth 1 -maxdepth 1) $out
    '';
  };

  hasDependencies = dependencies != [] ||
                    (shouldTest && devDependencies != []);

  symlinkDep = dep: let _name = dep.pkgName; in ''
    ln -sv ${dep}/lib/node_modules/${_name} node_modules/${_name}
  '';

  # Define a few convenience functions used by the installer.
  defineVariables = ''
    SOURCE=$TMPDIR/source-${name}-${version}
    UNPACK=$TMPDIR/unpack-${name}-${version}
    SOURCE_TARBALL=$TMPDIR/fixed-source-${name}-${version}.tar.gz
    BUILD=$TMPDIR/build-${name}-${version}

    setupDependencies() {
      ${if hasDependencies then ''
        mkdir -p node_modules
        ${concatStringsSep "\n  " (map symlinkDep dependencies)}
        ${if !shouldTest then "" else
          concatStringsSep "\n  " (map symlinkDep devDependencies)}
        echo "Installed dependencies"
      '' else "true"}
    }

    runInstall() {
      # NPM looks in the HOME folder so we set it here.
      HOME=$PWD ${nodejs}/bin/npm install ${npmFlags} $SOURCE_TARBALL
    }

    fixPackageJson() {
      ${nodejs}/bin/node ${./removeImpureDependencies.js}
    }
  '';

  npmFlags = concatStringsSep " " ([
    # Disable any user-level npm configuration shenanigans.
    "--userconfig /dev/null"
    # This will make NPM fail if it tries to fetch a dependency.
    "--registry http://www.example.com"
    "--nodedir=${sources}"
    "--production"
    "--fetch-retries 0"
  ] ++
    # This flag will run the tests if enabled
    optional shouldTest "--npat");

  result = mkDerivation {
    inherit meta src npmFlags removePeerDependencies;
    name = "nodejs-${name}-${version}";
    # We need to make this available to packages which depend on this, so that we
    # know what folder to put them in.
    passthru.pkgName = name;
    passthru.version = version;
    passthru.withoutTests = pkg (args // {doCheck = false;});

    phases = ["setupPhase"
              "unpackPhase"
              "patchPhase"
              "buildPhase"
              "installPhase"];
    buildInputs = [pkgs.python nodejs] ++ optionals shouldTest devDependencies;
    propagatedBuildInputs = dependencies;

    shellHook = defineVariables + shellHook;

    setupPhase = defineVariables;

    unpackPhase = ''
      # Extract the package source if it is a tar file; else copy it.
      if [ -d $src ]; then
        if [ ! -e $src/package.json ]; then
          echo "No package.json file found in source."
          exit 1
        fi
        cp -r $src $SOURCE
        chmod -R +w $SOURCE
      elif tar -tf $src 2>/dev/null 1>&2; then
        # We will unpack the tarball here, and then set SOURCE to be the
        # first folder that contains a package.json within it.
        [ -d $UNPACK ] || {
          mkdir -p $UNPACK
          tar -xf $src -C $UNPACK
        }
        SOURCE=$(python ${./find_package_json_dir.py} $UNPACK $name)
      else
        echo "Invalid source $src: not a directory or a tarball."
        exit 1
      fi
      echo $SOURCE
    '';

    # In the patch phase we will remove impure dependencies from the
    # package.json file, patch impure shebangs, and recompress into a
    # tarball.
    patchPhase = ''
      (
        cd $SOURCE
        patchShebangs $SOURCE
        fixPackageJson
        ${patchPhase}
        tar -cf $SOURCE_TARBALL .
      )
    '';

    # In the build phase, we will prepare a node_modules folder with all
    # of the dependencies present, and then run npm install from the
    # fixed source tarball.
    buildPhase = ''
      # Prepare the build directory.
      (
        set -e
        mkdir -p $BUILD
        cd $BUILD
        setupDependencies
        runInstall
      )
    '';

    installPhase = ''
      ${preInstall}
      mkdir -p $out/lib/node_modules
      mv $BUILD/node_modules/${name} $out/lib/node_modules
      for submod in $(find $BUILD/node_modules -mindepth 1 -maxdepth 1); do
        mkdir -p $out/lib/node_modules/${name}/node_modules
        cp -r $submod $out/lib/node_modules/${name}/node_modules
      done

      # Copy generated binaries
      if [ -d $BUILD/node_modules/.bin ]; then
        mkdir $out/bin
        find $BUILD/node_modules/.bin -xtype f -exec ln -sv {} $out/bin/{} \;
      fi

      # Copy man pages if they exist
      manpath="$out/lib/node_modules/${name}/man"
      if [ -e $manpath ]; then
        mkdir -p $out/share
        for dir in $(find $manpath -maxdepth 1 -type d); do
          mkdir -p $out/share/man/$(basename "$dir")
          for page in $(find $dir -maxdepth 1); do
            ln -sv $page $out/share/man/$(basename "$dir")
          done
        done
      fi
      ${postInstall}
    '';
  };
in

result;
in
pkg
