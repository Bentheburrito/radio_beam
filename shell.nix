{
  pkgs ? import <nixpkgs> { },
  target,
}:
with pkgs;
mkShellNoCC {
  packages = with pkgs; [
    tailwindcss_4
    esbuild
    gnumake # for argon2
    inotify-tools # for phoenix live-reload
    beam28Packages.elixir_1_19
  ];
  # Set env vars
  # GREETING = "Hello, Nix!";

  # TODO
  # buildInputs = [
  # ];
  #
  shellHook = ''
    ln -s ${esbuild}/bin/esbuild ./_build/esbuild-${target}
    ln -s ${tailwindcss_4}/bin/tailwindcss ./_build/tailwind-${target}
  '';
}
