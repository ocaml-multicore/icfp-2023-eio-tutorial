## Prerequisites

You will need OCaml 5.1 or later, which can be installed using [opam](https://opam.ocaml.org/):

```sh
opam switch create 5.1.0~rc2
```

For profiling with `perf` (Linux-only), it may be helpful to use a compiler with frame-pointers enabled instead, like this:

```sh
opam switch create 5.1.0~rc2+fp ocaml-variants.5.1.0~rc2+options ocaml-option-fp
```

This repository uses Git submodules. Make sure they're enabled with:

```sh
git submodule update --init --recursive
```

The dependencies needed for the example program are given in the `tutorial.opam` file, and can be installed with:

```sh
opam install --deps-only -t .
```

The application also requires a copy of opam-repository:

```sh
git clone https://github.com/ocaml/opam-repository.git
```

You should then be able to build the examples with:

```sh
dune build
```

## Docker

There is also a `Dockerfile`, which can be used to create a Docker container with the examples built.

```ocaml
docker build -t icfp .
```

This is an easy way to use Linux profiling tools on macos or Windows machines.
It takes a while to build, so it's a good idea to do that ahead of time.

## ThreadSanitizer

For finding races, you might also want a compiler with `tsan` enabled (currently this uses OCaml 5.2-trunk):
```sh
sudo apt install libunwind-dev
opam switch create tsan ocaml-option-tsan
```
Warning: you will need plently of memory to compile packages in this switch, and it may fail silently if there isn't enough.

## Next

[Eio introduction and Lwt comparison](./intro.md)
