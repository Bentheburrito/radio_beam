{
  pkgs ? import <nixpkgs> { },
  target,
}:
with pkgs;
mkShellNoCC {
  packages = with pkgs; [
    tailwindcss_4
    esbuild
    gcc # for argon2
    inotify-tools # for phoenix live-reload
    graphviz # for visualizing module boundary dependencies with :boundary
    beam29Packages.elixir_1_20
  ];
  # Set env vars
  # GREETING = "Hello, Nix!";

  # TODO
  # buildInputs = [
  # ];
  #
  shellHook = ''
    ln -sf ${esbuild}/bin/esbuild ./_build/esbuild-${target}
    ln -sf ${tailwindcss_4}/bin/tailwindcss ./_build/tailwind-${target}
  '';
}
