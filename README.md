A mostly complete implementation of most of the components of a complete [Uxntal](https://wiki.xxiivv.com/site/uxntal.html) and [Varvara](https://wiki.xxiivv.com/site/varvara.html) system in a library-first fashion.

`zig build` will compile three binary analogues to the reference implementations of uxnasm, uxncli and uxnemu:

  - uxn-asm: The Uxntal assembler
  - uxn-cli: Runs Uxn ROMs in a headless fashion
  - uxn-sdl: Runs Uxn ROMs with audio and video support in SDL

The tools support different arguments but are pretty basic. (see `--help` for each)

All three major components (Uxn core VM, Varvara devices and assembler) are exposed as Zig modules for embedding in other environments. The modules are named as such:

 - `uxn-core`
 - `uxn-varvara`
 - `uxn-asm`

The Varvara audio, video and input devices are independant of external systems for audio and video and can be implemented in a way that makes sense for the embedded application. Generic device intercepts for input and output can be defined in addition to or as replacement for any given device.

Until a proper API documentation is available, the three produced binaries shall serve as usage examples.