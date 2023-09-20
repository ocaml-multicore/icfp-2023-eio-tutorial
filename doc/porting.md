# Porting an Lwt application to Eio

Before starting, ensure you have this repository cloned and the dependencies installed:

```sh
git clone --recursive https://github.com/ocaml-multicore/icfp-2023-eio-tutorial.git
cd icfp-2023-eio-tutorial
opam install --deps-only -t .
dune build
```

## The example application

We'll be converting a solver service, which can be found in the `server` directory.
It is a web-service that takes an opam-repository commit hash and a package name
and returns a set of packages that need to be installed to use it
(it is a simplified version of the [ocaml-ci solver service](https://github.com/ocurrent/solver-service/)).

To test it, start by running the service:

```
$ dune exec -- ./server/main.exe ../opam-repository -v
main.exe: [INFO] Starting server...
Server listening on TCP port 8080
```

Then, in another window use the test client to perform some queries:

```
$ make test
dune exec -- ./client/main.exe
+Requesting http://127.0.0.1:8080/solve/9faf3dbf816f376733b73f3ed8832c4213db4a02/lwt?ocaml_version=4.02.0
+Requesting http://127.0.0.1:8080/solve/9faf3dbf816f376733b73f3ed8832c4213db4a02/lwt?ocaml_version=4.14.0
+Requesting http://127.0.0.1:8080/solve/9faf3dbf816f376733b73f3ed8832c4213db4a02/lwt?ocaml_version=5.0.0
+5.0.0 : base-bigarray.base base-bytes.base base-domains.base base-nnp.base base-threads.base base-unix.base cppo.1.6.9 csexp.1.5.2 dune.3.9.1 dune-configurator.3.9.1 lwt.5.6.1 ocaml.5.0.0 ocaml-base-compiler.5.0.0 ocaml-config.3 ocaml-options-vanilla.1 ocamlfind.1.9.6 ocplib-endian.1.2
+4.14.0 : base-bigarray.base base-bytes.base base-threads.base base-unix.base cppo.1.6.9 csexp.1.5.2 dune.3.9.1 dune-configurator.3.9.1 lwt.5.6.1 ocaml.4.14.0 ocaml-base-compiler.4.14.0 ocaml-config.2 ocaml-options-vanilla.1 ocamlfind.1.9.6 ocplib-endian.1.2
+4.02.0 : base-bigarray.base base-bytes.base base-ocamlbuild.base base-threads.base base-unix.base cppo.1.6.5 dune.1.11.4 dune-configurator.1.0.0 jbuilder.transition lwt.5.2.0 mmap.1.1.0 ocaml.4.02.0 ocaml-base-compiler.4.02.0 ocaml-config.1 ocamlbuild.0 ocamlfind.1.9.6 ocplib-endian.1.0 result.1.5 seq.0.2.2
+Finished in 20.22 s
```

It's a bit slow the first time (as it loads all the opam files),
but if you run the client again without restarting the server then it will be much faster.
We'll fix the slow start-up soon!

## Switching to Eio_main

Eio and Lwt code can run at the same time, using the [Lwt_eio][] library.

Begin by adding the `eio_main` and `lwt_eio` libraries to the `dune` file.

Then, find the `Lwt_main.run` call and replace it with these three lines:

```ocaml
  Eio_main.run @@ fun env ->
  Lwt_eio.with_event_loop ~debug:true ~clock:env#clock @@ fun _ ->
  Lwt_eio.run_lwt @@ fun () ->
```

We're now using the Eio event loop instead of the normal Lwt one, but everything else stays the same:

- `Eio_main.run` starts the Eio event loop, replacing `Lwt_main.run`.
- `Lwt_eio.with_event_loop` starts the Lwt event loop, using Eio as its backend.
- `Lwt_eio.run_lwt` switches from Eio context to Lwt context.

Any piece of code is either Lwt code or Eio code.
You use `run_lwt` and `run_eio` to switch back and forth as necessary
(`run_lwt` lets Eio code call Lwt code, while `run_eio` lets Lwt code call Eio).

The `~debug:true` tells Lwt_eio to check that you don't perform Eio operations from
a Lwt context (doing so would cause the other Lwt threads to hang).

Run the new version to check that it still works.

### Overview of the code

- `Main` parses the commmand-line arguments and runs the web-server.
  It uses `Git_unix` to open the `opam-repository` clone and `Solver` to find solutions to client requests.

- `Solver` uses `Packages` to load the opam files from the Git store and then uses the 0install solver to find a solution.
  It caches the packages of the last used Git commit to make future runs faster.

- `Context` is used by the 0install solver to get the opam package data.
  It mostly just wraps a call to `Packages.get_versions`.

- `Packages` loads the opam files from the Git store.
  It starts with a Git commit (provided by the user)
  and uses that to get the Git "tree" corresponding to that commit's root directory.
  Then it gets the `packages` sub-directory, and loads each sub-directory of that as a package.
  For each package, it loads each sub-directory as a version.
  For each version, it loads the `opam` file.
  For example, `packages/lwt/lwt.5.7.0/opam ` is the opam metadata for Lwt 5.7.0.
  See [Git internals][] if you want to know more about how Git stores data.

### Converting the code

We can take any piece of Lwt code and switch it to Eio.

For example, we can change `Packages.of_commit` (which currently contains only Lwt code)
and put `Lwt_eio.run_lwt @@ fun () ->` at the start (leaving the rest of the code the same).
Now the function is an Eio function, returning `Packages.t` rather than `Packages.t Lwt.t`.

We can still use the function from Lwt context by using `run_eio`. So:

```ocaml
    Packages.of_commit t.store commit >|= fun pkgs ->
```

becomes

```ocaml
    Lwt_eio.run_eio (fun () -> Packages.of_commit t.store commit) >|= fun pkgs ->
```

But instead, let's convert the `packages` function to Eio.
We could just replace the Lwt promise with an Eio promise
(so that `Lwt.wait ()` becomes `Eio.Promise.create ()`),
but a more elegant solution is to use `Eio.Lazy`:

```ocaml
let packages t commit =
  match t.packages_cache with
  | Some (c, p) when Git_unix.Store.Hash.equal c commit -> Eio.Lazy.force p
  | _ ->
    let p = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
        Log.info (fun f -> f "Loading packages...");
        let pkgs = Packages.of_commit t.store commit in
        Log.info (fun f -> f "Loaded packages");
        pkgs
      ) in
    t.packages_cache <- Some (commit, p);
    Eio.Lazy.force p
```

Hint: you'll need to change the type of `t.packages_cache` too.

Unlike `Stdlib.Lazy`, `Eio.Lazy` allows multiple fibers to force the value at once.
The first fiber to do so will load it, and the others will wait.

Since Eio fibers can be cancelled, Eio requires us to say what should happen in this case.
``~cancel:`Restart`` says that if the first fiber is cancelled, the next one will take over.
(note: Lwt also allows cancellation, and ideally should also handle that here somehow,
but this particular application doesn't need it)

Now `solve` no longer needs to use the Lwt `>|=` operator when creating packages, so

 ```ocaml
  packages t commit >|= fun packages ->
```
becomes:
 ```ocaml
  let packages = packages t commit in
```

`solve` didn't contain any other Lwt code, so it is now an Eio function too.
Or rather, it's a plain OCaml function.
We removed the Lwt operator, but we didn't replace it with anything from Eio.
In fact, much of "converting from Lwt to Eio" is really just "removing Lwt"!

Finally, the call to `Solver.solve` in `main.ml` no longer needs to use `>>= function`, but
can instead be a plain OCaml `match` expression.

But be careful! `Solver.solve` is now an Eio function (it indirectly calls `Lwt_eio.run_lwt`),
so it needs to be called from Eio context.
Since we're using `Lwt_eio.with_event_loop ~debug:true`, this will be detected when you test it:

```
main.exe: [INFO] Loading packages...
+WARNING: Exception: Failure("Already in Lwt context!")
+         Raised by primitive operation at Lwt_eio.with_mode in file "vendor/lwt_eio/lib/lwt_eio.ml", line 70, characters 13-84
+         Called from Lwt_eio.run_lwt in file "vendor/lwt_eio/lib/lwt_eio.ml", line 268, characters 10-26
+         Called from Eio__Lazy.from_fun.force in file "vendor/eio/lib_eio/lazy.ml", line 17, characters 55-60
+         Called from Eio__Lazy.force in file "vendor/eio/lib_eio/lazy.ml", line 46, characters 54-58
+         Called from Dune__exe__Solver.packages in file "server/solver.ml", line 43, characters 12-28
```

Here, cohttp was running in Lwt context, so when `Packages.of_commit` did `run_lwt`, it reported a problem.
We could fix it by changing contexts some more:

```ocaml
Lwt_eio.run_eio @@ fun () ->
match Solver.solve solver request with
| Ok selection ->
  let body = selection |> List.map OpamPackage.to_string |> String.concat " " in
  Lwt_eio.run_lwt @@ fun () ->
  Server.respond_string ~status:`OK ~body ()
| Error msg ->
  Lwt_eio.run_lwt @@ fun () ->
  Server.respond_string ~status:`OK ~body:msg ()
```

However, this would probably be a good time to switch to cohttp-eio!
To start, replace the `Cohttp_lwt_unix.Server` with `Cohttp_eio.Server` and
update the `dune` file to use `cohttp-eio` instead of `cohttp-lwt-unix`.

You'll find that `Server.create` has gone.
Eio separates creation of the listening socket from running the server,
so we can start listening right at the beginning.
We'll have `main` take a listening socket rather than a port,
and replace the `Server.create` with `Server.run`:

```ocaml
let main ~socket opam_repo =
  ...
  Server.run socket (Server.make ~callback ())
    ~on_error:(traceln "Error handling connection: %a" Fmt.exn)
```

We can also remove the `open Lwt.Infix` and delete the last `>>=` from `main.ml`,
using `match Lwt_eio.run_lwt ... with` for the remaining Lwt Git_unix call.
This converts `main` into a Eio function.

Finally, create the listening socket in the start-up code:

```ocaml
let () =
  let info = Cmd.info "solver service" in
  let main () port opam_repo =
    Eio_main.run @@ fun env ->
    Lwt_eio.with_event_loop ~clock:env#clock @@ fun _ ->
    Switch.run @@ fun sw ->
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let socket = Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true env#net addr in
    traceln "Server listening on TCP port %d" port;
    main ~socket opam_repo
  in
  exit @@ Cmd.eval @@ Cmd.v info
    Term.(const main $ setup_log $ port $ opam_dir)
```

As always after making changes, it's a good idea to run the tests again and check that it's still working.

### Taking advantage of Eio

Removing `>>=`, `>|=` and `Lwt.return` from our code makes it a bit cleaner,
and can avoid depending on a concurrency library at all.
But there are more important benefits!

`Packages.candidates` is defined as:

```ocaml
type candidates = OpamFile.OPAM.t Lazy.t OpamPackage.Version.Map.t
```

Since we don't need to parse most of the opam files in the repository, the actual parsing is done lazily
(hence `OpamFile.OPAM.t Lazy.t`).
It would be even better if we could avoid loading the files until we need them too,
but we couldn't do that with Lwt.

The reason is that the solver library doesn't know about Lwt.
It requires us to provide a function (`Context.candidates`) with this non-Lwt signature:

```ocaml
val candidates : t -> OpamPackage.Name.t -> (OpamPackage.Version.t * (OpamFile.OPAM.t, rejection) result) list
```

We can't do any Lwt operations (such as `Git_unix.Store.read`) because they only give us a promise of the result,
not the result itself.
Without effects, we'd have to add a Lwt dependency to the solver (or functorise it over a user-specified monad).
But with effects, there's no problem. `Lwt_eio.run_lwt` has exactly the type we need:

```ocaml
val run_lwt : (unit -> 'a Lwt.t) -> 'a
```

Change `Packages.candidates` so that we lazily load all the versions for a given package, like this:

```ocaml
type candidates = OpamFile.OPAM.t OpamPackage.Version.Map.t Eio.Lazy.t
```

Hints:

- You'll need to think about which functions are now Eio functions, and which are still Lwt.
- Use `Eio.Lazy` (not plain `Lazy`) to make sure it won't crash with concurrent requests.

You should find the server runs much faster the first time now, since it only has to load the packages it needs.

## Completing the port

To finish the port, you can also switch to using `git-eio` instead of `git-unix`.

Hints:

- `Lwt_list.filter_map_p` can be replaced with `Eio.Fiber.List.filter_map`.
- `Lwt_list.filter_map_s` becomes just `List.filter_map`.
- Some Git modules have moved; e.g. `Git.Value` becomes `Git_eio.Value`.
- `main` should take an `Eio.Path.t` argument, not a string.
   Use `Eio.Path.pp` to display it.
- To get the path, call main like this:
  ```ocaml
      let ( / ) = Eio.Path.( / ) in
      Eio.Path.with_open_dir (env#fs / opam_repo) @@ fun opam_repo ->
      main ~socket opam_repo
  ```

Then we can remove the `Lwt_eio.with_event_loop` and the dependencies on `lwt_eio` and `lwt`.

Check that your final version still works by restarting the server and running `make test` again.
You might like to compare your final version with our solution in `solutions/3-eio`.

## Next

[Using multiple cores](./multicore.md)

[Git internals]: https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
[Lwt_eio]: https://github.com/ocaml-multicore/lwt_eio
