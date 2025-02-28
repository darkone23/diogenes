{ pkgs, lib, config, inputs, ... }:

{
  # https://devenv.sh/basics/
  env.GREET = "devenv";

  # https://devenv.sh/packages/
  packages = [ pkgs.git pkgs.flex pkgs.bison pkgs.unzip pkgs.perlnavigator ];

  # https://devenv.sh/languages/
  languages.perl.enable = true;
  languages.javascript.enable = true;
  languages.c.enable = true;

  # https://devenv.sh/processes/
  # processes.cargo-watch.exec = "cargo-watch";

  # https://devenv.sh/services/
  # services.postgres.enable = true;

  # https://devenv.sh/scripts/
  scripts.hello.exec = ''
    echo hello from $GREET
  '';

  scripts.setup-deps.exec = ''
    bash -c "make && make -f mk.prebuilt-data"
  '';

  enterShell = ''
    hello
    git --version

    FLEX_PATH=$(dirname $(dirname $(which flex)))/lib
    export LIBRARY_PATH=$FLEX_PATH:$LIBRARY_PATH

    BISON_PATH=$(dirname $(dirname $(which bison)))/lib
    export LIBRARY_PATH=$BISON_PATH:$LIBRARY_PATH

    # export CC=$(which clang)
    # export CXX=$(which clang++)
  '';

  # https://devenv.sh/tasks/
  # tasks = {
  #   "myproj:setup".exec = "mytool build";
  #   "devenv:enterShell".after = [ "myproj:setup" ];
  # };
  tasks."diogenes:serve" = {
    exec = ''./server/diogenes-server.pl'';
  };
  tasks."diogenes:setup" = {
    # required before you can run serve
    exec = ''devenv shell setup-deps'';
  };

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    git --version | grep --color=auto "${pkgs.git.version}"
  '';

  # https://devenv.sh/pre-commit-hooks/
  # pre-commit.hooks.shellcheck.enable = true;

  # See full reference at https://devenv.sh/reference/options/
}
