{ pkgs ? import <nixpkgs> { }, target }:
with pkgs;
mkShell {
  packages = with pkgs; [
    tailwindcss_4
    esbuild
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
