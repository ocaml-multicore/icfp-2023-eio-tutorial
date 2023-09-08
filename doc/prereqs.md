## Prerequisites

You will need OCaml 5.1 or later, which can be installed using [opam](https://opam.ocaml.org/):

```sh
opam switch create 5.1.0~rc3
```

For profiling with `perf` (Linux-only), it may be helpful to use a compiler with frame-pointers enabled instead, like this:

```sh
opam switch create 5.1.0~rc3+fp ocaml-variants.5.1.0~rc3+options ocaml-option-fp
```

This repository uses Git submodules. Make sure they're enabled with:

```sh
git submodule update --init --recursive
```

The dependencies needed for the example program are given in the `tutorial.opam` file, and can be installed with:

```sh
opam install --deps-only -t .
```

The application also requires a copy of opam-repository (note: if using the Docker build below, this isn't needed as the Docker image already has a copy):

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
opam switch create 5.1.0~rc3+tsan
```
Warning: you will need plenty of memory to compile some packages on this switch, and the build will fail if it runs out of memory.

The Docker image includes a switch with ThreadSanitizer installed automatically.

## Next

[Eio introduction and Lwt comparison](./intro.md)
