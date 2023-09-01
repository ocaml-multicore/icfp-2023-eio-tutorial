## Introduction to Eio

The [Eio README](https://github.com/ocaml-multicore/eio) covers most of the main features of Eio,
so you might want to read a bit of that first if you haven't used Eio at all.

Here, we'll look at a few differences between Lwt and Eio.

### Direct-style vs monadic code

Eio allows use of direct-style code, which is shorter, easier for beginners,
runs faster, and interoperates with non-Lwt code:

```diff
- foo () >>= fun x ->
+ let x = foo () in
```

```diff
- Lwt.catch
-   (fun () -> ...)
-   (function
-     | E -> ...
-     | ex -> Lwt.fail ex)
+ try
+   ...
+ with E -> ...
```

```diff
- Lwt.try_bind
-   (fun () -> ...)
-   (fun v -> ...)
-   (function
-     | E -> ...
-     | ex -> Lwt.fail ex)
+ match ... with
+ | v -> ...
+ | exception E -> ...
```

```diff
- let rec aux i =
-   if i <= 1000 then (...; aux (i + 1))
- in aux 1
+ for i = 1 to 1000 do ... done
```

```diff
- Lwt_list.iter_s f xs
+ List.iter f xs
```

### Performance

The `compare/parsing.ml` example opens `/dev/zero` and reads a load of data from it, one character at a time.
Eio is much faster, even though it's still only using one core:

```
$ dune exec -- ./parsing.exe
Eio took 0.35 s                    
Lwt took 1.46 s
Eio took 0.35 s
Lwt took 1.47 s
```

The reason is that Lwt always has to allocate a callback on the heap
in case `Lwt_io.read_char` needs to suspend and wait for the OS,
even though the data is usually buffered.

With Eio, we can also use multiple domains for more performance.
`parsing_par` does the test 4 times in parallel:

```
$ dune exec -- ./parsing_par.exe
Eio took 0.40 s                    
Lwt took 5.16 s
Eio took 0.40 s
Lwt took 5.20 s
```

### Performance monitoring

The `compare/perf.ml` example runs Eio and Lwt examples,
each running two threads doing the same amount of CPU work.
Using a `+fp` version of the compiler (to get frame pointers),
we can use `perf record -g` to profile it:

```
dune build -- ./compare/perf.exe && perf record -g ./_build/default/compare/perf.exe
```

The results show that we spent 50% of the time doing work in Lwt, but we've lost the task1/task2 distinction.
As before, the stack-trace only records that a leaf function was resumed by Lwt.
The Eio part of the results show the two tasks taking 25% of the time each:

```
perf report -g
- caml_start_program
   - 99.89% caml_startup.code_begin
      - 99.89% Dune.exe.Perf.entry
         - Dune.exe.Perf.time_560
            - 49.94% Lwt_main.run_495
               - Lwt_main.run_loop_435
                  - 49.83% Lwt_sequence.loop_346
                     - Lwt.wakeup_general_1071
                       Lwt.resolve_1034
                       Lwt.run_in_resolution_loop_1014
                       Lwt.iter_callback_list_944
                     - Lwt.callback_1373
                        - 49.77% Dune.exe.Perf.fun_967
                           + 49.77% Dune.exe.Perf.use_cpu_273
            - 49.90% Eio_linux.Sched.with_sched_inner_3088
               - 49.89% Eio_linux.Sched.with_eventfd_1738
                    Eio_linux.Sched.run_1519
                  - Stdlib.Fun.protect_320
                     - 49.86% caml_runstack
                          Stdlib.Fun.protect_320
                        - Eio.core.Fiber.fun_1369
                           - 25.07% Dune.exe.Perf.run_task2_425
                              + Dune.exe.Perf.use_cpu_273
                           - 24.78% Dune.exe.Perf.run_task1_421
                              + 24.77% Dune.exe.Perf.use_cpu_273
```

### Error handling

The `compare/errors.ml` file demonstrates an important difference in Eio's error handling.
The example runs two tasks concurrently:

- `task1` waits for a network connection.
- `task2` raises an exception.

When `task2` fails, Eio automatically cancels `task1` and reports the exception immediately.
Lwt instead waits for `task1` to finish (which might never happen) before reporting the error.
This often causes Lwt applications to fail with no visible error.

Backtraces from Eio are also often more useful.
We can see here that `simulated_error` was called from `task2`:

```
Exception: Not_found
Raised at Dune__exe__Errors.Example_eio.simulated_error in file "compare/errors.ml", line 25, characters 6-21
Called from Dune__exe__Errors.Example_eio.run_task2 in file "compare/errors.ml", line 31, characters 4-22
```

Lwt instead only shows that `simulated_error` was resumed by the Lwt engine:

```
Exception: Not_found
Raised at Dune__exe__Errors.Example_lwt.simulated_error.(fun) in file "compare/errors.ml", line 58, characters 6-21
Called from Lwt.Sequential_composition.bind.create_result_promise_and_callback_if_deferred.callback in file "src/core/lwt.ml", line 1829, characters 23-26
Re-raised at Lwt.Miscellaneous.poll in file "src/core/lwt.ml", line 3059, characters 20-29
```

Note that the Lwt example requires a `Lwt.pause` (simulating some IO) to show these problems.
If you remove that, then the stack trace is helpful and it doesn't wait for the server thread
(which is still listening even after `Lwt_main.run` returns).
Lwt code often behaves differently depending on whether it did IO or not.
By contrast, the Eio code behaves the same way if you remove the `Fiber.yield`.

### Resource leaks

Eio requires all resources to be attached to a *switch*, which ensures they are released when the switch finishes.

Lwt code often accidentally leaks resources, especially on error paths.
In the `errors.ml` example above, if you did cancel `run_task1` (e.g. with `Lwt.cancel`) then it would fail to close `conn`.
And it forgets to close `socket` whether you cancel it or not!

The Eio version ensures that both the listening socket and the connected socket are closed,
whether it completes successfully or fails.

### Bounds on behaviour

Usually the first thing we want to know about a program is what effect it will have on the outside world.
With Lwt, this is difficult. A Lwt program typically starts like this:

```ocaml
Lwt_main.run (main ())
```

Looking at this, we have no idea what this program might do.
We could read the `main` function, but that will call other functions, which call yet more functions.
Without reading all the code of every library being used (typically 100s of thousands of lines),
we can't answer even basic questions such as "will this program write to my `~/.ssh` directory?".

This is because Lwt treats OS resources such as the file-system and the network like global variables,
accessible from anywhere.
It's hard to reason about global variables, because any code can access them.

Eio instead provides access to the outside world as a function argument, usually named `env`.
By looking at what happens to the `env` argument, we can quickly get a bound on the program's behaviour.
For example:

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  let addr = `Tcp (Eio.Net.Ipaddr.V4.any, 8080) in
  let socket = Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true env#net addr in
  Eio.Path.with_open_dir (env#cwd / "opam-repository") @@ fun opam_repo ->
  main ~socket opam_repo
```

Placing the cursor on `env`, our text editor highlights the two uses:
this program uses the network and the current directory.
More specifically:

- It uses the network directly only once, to create a listening socket on port 8080.
- It uses the cwd only once, to get access to `~/opam-repository`.

If we wanted to know exactly how it uses the socket or the directory
we would check what `main` does with them, but we already have a useful bound on the behaviour.
For example, we now have enough information to know what firewall rules this program
requires.

For more details, see [Lambda Capabilities][].

[Lambda Capabilities]: https://roscidus.com/blog/blog/2023/04/26/lambda-capabilities/

### Monitoring

OCaml 5.1 allows programs to output custom events and this provides lots of
useful information about what an Eio program is doing.

At the time of writing, OCaml 5.1 hasn't been released, but see [Meio][] for a preview.
To try it, you'll need to apply [Eio PR#554](https://github.com/ocaml-multicore/eio/pull/554).

[Meio]: https://github.com/ocaml-multicore/meio

## Next

[Porting from Lwt to Eio](./porting.md)
