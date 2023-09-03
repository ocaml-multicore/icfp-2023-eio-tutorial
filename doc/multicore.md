# Using multiple cores

So far, the solver server only uses one core.
We'll now use multiple CPU cores to improve performance.

## Thread-safe logging

Before we start, note that the `Logs` library is not thread-safe by default.
Add a call to `Logs_threaded.enable ()` (using the `logs.threaded` library),
or you'll get errors like this:

```
main.exe: [INFO] tcp:127.0.0.1:41676: accept connection
main.exemain.exeINFO
main.exe: [main.exe: [INFOain.exe: [WARNING] Exception: Stdlib.Queue.Empty
                    Raised at Stdlib__Queue.take in file "queue.ml", line 73, characters 11-22
                    Called from Stdlib__Format.advance_left in file "format.ml", line 436, characters 6-31
```

## Using multiple domains with cohttp

There are a couple of ways we can use multiple cores in this example.
One option is to ask cohttp to run multiple accept loops.
For example, this uses 4 domains (in total):

```ocaml
let main ~domain_mgr ~socket opam_repo =
  ...
  Server.run ~additional_domains:(domain_mgr, 3) ...
```

(get `domain_mgr` using `env#domain_mgr`)

However, we don't have a performance problem handling HTTP requests,
and doing this means having to make the entire connection handler thread-safe.
For example, the solver caches the packages for the last commit:

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

This code relies on the fact that once we've seen that the commit we want isn't cached,
we can set `packages_cache` to a lazy value that will compute it atomically.

We could fix that by adding a mutex around this code.
In this case we could use a plain `Stdlib.Mutex`,
since we won't be switching fibers between checking the cache and putting the lazy value in it,
but it's safest to use `Eio.Mutex` anyway,
which handles that (by having the fiber wait for the lock, rather than raising an exception).

## Using a worker pool for solves

Alternatively, we can have just one domain handling HTTP requests and use a pool of workers for solving.
This minimises the amount of code we need to make thread-safe.

Here is a simple `worker_pool.ml` module:

```ocaml
open Eio.Std

type job = Job : (unit -> 'a) * ('a, exn) result Promise.u -> job

type t = job Eio.Stream.t

let submit (t:t) fn =
  let p, r = Promise.create () in
  Eio.Stream.add t (Job (fn, r));
  Promise.await_exn p

let rec run_worker (t:t) =
  let Job (fn, reply) = Eio.Stream.take t in
  let id = (Domain.self () :> int) in
  traceln "Domain %d: running job..." id;
  begin
    match fn () with
    | v -> Promise.resolve_ok reply v
    | exception ex -> Promise.resolve_error reply ex
  end;
  traceln "Domain %d: finished" id;
  run_worker t

let create ~sw ~domain_mgr n : t =
  let t = Eio.Stream.create 0 in
  for _ = 1 to n do
    Fiber.fork_daemon ~sw (fun () -> Eio.Domain_manager.run domain_mgr (fun () -> run_worker t))
  done;
  t
```

Each new domain runs a worker that accepts jobs from the stream.
Each job is a function run in the worker's domain and a resolver for the reply.

We start a pool of workers running at the start:
```ocaml
    let pool = Worker_pool.create ~sw ~domain_mgr:env#domain_mgr 3 in
```
and use it in `solver.ml`'s `solve` function to call the 0install solver:
```ocaml
  Worker_pool.submit t.pool @@ fun () -> 
  match Solver.solve ctx [pkg] with
```

## Testing

Whichever way you added support for multiple domains, you may find that it now crashes sometimes:

```
solver service: internal error, uncaught exception:
                Multiple exceptions:
                - Failure("Error parsing async.108.00.01: At ./<none>:2:0-2:10::\nParse error")
                  Raised at Stdlib.failwith in file "stdlib.ml", line 29, characters 17-33
                  Called from Dune__exe__Packages.read_versions.(fun) in file "solutions/4-eio-multicore/packages.ml", line 44, charact
                  ...
                - Failure("Error parsing mirage.0.10.0: At ./<none>:1:12-1:13::\nParse error")
                  Raised at Stdlib.failwith in file "stdlib.ml", line 29, characters 17-33
                  Called from Dune__exe__Packages.read_versions.(fun) in file "solutions/4-eio-multicore/packages.ml", line 44, charact
                  ...
```

If you don't get an error, try modifying `client/main.ml` to request three different packages
(e.g. `lwt`, `irmin` and `bap`).

To find races (and their causes) more reliably,
you can use [ocaml-tsan](https://github.com/ocaml-multicore/ocaml-tsan).

Note:
- ocaml-tsan uses OCaml 5.2 trunk.
  `cohttp-lwt-unix` uses `ppx_sexp_conv` which isn't compatible with this, but if you've completed the port to Eio
  then you don't need that anyway.
- To remove sexp support from the core cohttp library: `patch -p1 < remove-sexp.patch`

```
WARNING: ThreadSanitizer: data race (pid=145041)
  Read of size 8 at 0x7effe74adf78 by thread T4 (mutexes: write M85):
    #0 camlStdlib__Hashtbl.ongoing_traversal_280 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/hashtbl.ml:42 (main.exe+0x71f69b)htbl.iter_760 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/hashtbl.ml:162 (main.exe+0x720636)lCarton_git.get_1281 vendor/ocaml-git/src/carton-git/carton_git.ml:165 (main.exe+0x358bf6)
    #3 camlGit_eio__Store.read_inflated_4923 vendor/ocaml-git/src/git-eio/store.ml:190 (main.exe+0x31d5d8)
    #4 camlGit_eio__Store.read_opt_4953 vendor/ocaml-git/src/git-eio/store.ml:218 (main.exe+0x31dbd6)
    #5 camlGit_eio__Store.read_4997 vendor/ocaml-git/src/git-eio/store.ml:223 (main.exe+0x31dc9b)
    #6 camlDune__exe__Packages.read_dir_4776 solutions/4-eio-multicore/packages.ml:12 (main.exe+0x2df6d1)
    ...
  Previous write of size 8 at 0x7effe74adf78 by thread T1 (mutexes: write M81):
    #0 camlStdlib__Hashtbl.iter_760 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/hashtbl.ml:45 (main.exe+0x720665)
    #1 camlCarton_git.get_1281 vendor/ocaml-git/src/carton-git/carton_git.ml:165 (main.exe+0x358bf6)
    #2 camlGit_eio__Store.read_inflated_4923 vendor/ocaml-git/src/git-eio/store.ml:190 (main.exe+0x31d5d8)
    #3 camlGit_eio__Store.read_opt_4953 vendor/ocaml-git/src/git-eio/store.ml:218 (main.exe+0x31dbd6)
    #4 camlGit_eio__Store.read_4997 vendor/ocaml-git/src/git-eio/store.ml:223 (main.exe+0x31dc9b)
    #5 camlDune__exe__Packages.read_dir_4776 solutions/4-eio-multicore/packages.ml:12 (main.exe+0x2df6d1)
```

Even though ocaml-git is only being used in read-only mode, it still isn't thread safe.
To fix that, we can put a mutex around it:

```ocaml
module Store = struct
  module Store_unsafe = Git_eio.Store
  module Search_unsafe = Git_eio.Search.Make (Digestif.SHA1) (Store_unsafe)
  module Value = Store_unsafe.Value

  let lock = Mutex.create ()
  let with_lock fn =
    Mutex.lock lock;
    match fn () with
    | x -> Mutex.unlock lock; x
    | exception ex ->
      let bt = Printexc.get_raw_backtrace () in
      Mutex.unlock lock;
      Printexc.raise_with_backtrace ex bt

  let find store hash path =
    with_lock @@ fun () ->
    Search_unsafe.find store hash path

  let read store hash =
    with_lock @@ fun () ->
    Store_unsafe.read store hash

  let pp_error = Store_unsafe.pp_error
end
```

(note that e.g. `Search.find` is now `Store.find`)

Now we get:
```
WARNING: ThreadSanitizer: data race (pid=146066)
  Read of size 8 at 0x7b7400000b20 by thread T1 (mutexes: write M81):
    #0 camlStdlib__Weak.find_aux_780 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/weak.ml:280 (main.exe+0x72986e)
    #1 camlOpamLexer.__ocaml_lex_token_rec_911 src/opamLexer.mll:134 (main.exe+0x4abf95)
    #2 camlOpamBaseParser.get_three_tokens_792 src/opamBaseParser.mly:185 (main.exe+0x4aa540)
    #3 camlOpamBaseParser.main_804 src/opamBaseParser.mly:228 (main.exe+0x4aa8e4)
    #4 camlOpamFile.parser_main_3913 src/format/opamFile.ml:739 (main.exe+0x45f7f3)
    #5 camlOpamFile.of_string_4595 src/format/opamFile.ml:761 (main.exe+0x4635e1)
    #6 camlOpamFile.read_from_f_1529 src/format/opamFile.ml:172 (main.exe+0x45b78e)
    #7 camlDune__exe__Packages.read_package_4943 solutions/4-eio-multicore/packages.ml:50 (main.exe+0x2dfbf9)
    ...
  Previous write of size 8 at 0x7b7400000b20 by thread T6 (mutexes: write M89):
    #0 caml_modify runtime/memory.c:219 (main.exe+0x7c0dbd)
    #1 camlStdlib__Weak.loop_769 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/weak.ml:253 (main.exe+0x729325)
    #2 camlStdlib__Weak.fun_1139 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/weak.ml:298 (main.exe+0x729db3)
    #3 camlOpamLexer.__ocaml_lex_token_rec_911 src/opamLexer.mll:134 (main.exe+0x4abf95)
    #4 camlOpamBaseParser.get_three_tokens_792 src/opamBaseParser.mly:185 (main.exe+0x4aa540)
    #5 camlOpamBaseParser.main_804 src/opamBaseParser.mly:228 (main.exe+0x4aa8e4)
    #6 camlOpamFile.parser_main_3913 src/format/opamFile.ml:739 (main.exe+0x45f7f3)
    #7 camlOpamFile.of_string_4595 src/format/opamFile.ml:761 (main.exe+0x4635e1)
    #8 camlOpamFile.read_from_f_1529 src/format/opamFile.ml:172 (main.exe+0x45b78e)
    #9 camlDune__exe__Packages.read_package_4943 solutions/4-eio-multicore/packages.ml:50 (main.exe+0x2dfbf9)
```

Looks like `OpamFile.read_from_string` isn't thread-safe either! Let's put another lock around that.

Now we get:

```
  Atomic read of size 8 at 0x7f5a244d7ac8 by thread T4 (mutexes: write M85, write M644):
    #0 do_check_key_clean runtime/weak.c:113 (main.exe+0x7d2a88)
    #1 clean_field runtime/weak.c:180 (main.exe+0x7d2a88)
    #2 ephe_check_field runtime/weak.c:401 (main.exe+0x7d3444)
    #3 caml_ephe_check_key runtime/weak.c:412 (main.exe+0x7d41bb)
    #4 caml_weak_check runtime/weak.c:417 (main.exe+0x7d41bb)
    #5 caml_c_call <null> (main.exe+0x7d762f)
    #6 camlStdlib__Weak.check_398 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/weak.ml:60 (main.exe+0x726edb)#7 camlStdlib__Weak.loop_769 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/weak.ml:260 (main.exe+0x7294db)#8 camlStdlib__Weak.fun_1139 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/weak.ml:298 (main.exe+0x729d73)#9 camlOpamLexer.__ocaml_lex_token_rec_911 src/opamLexer.mll:126 (main.exe+0x4abcd9)
    #10 camlStdlib__Parsing.loop_521 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/parsing.ml:134 (main.exe+0x6ddf7e)lStdlib__Parsing.yyparse_515 /home/user/.opam/tsan/.opam-switch/build/ocaml-variants.5.2.0+trunk/stdlib/parsing.ml:165 (main.exe+0x6ddc99)amBaseParser.main_804 src/opamBaseParser.ml:460 (main.exe+0x4aac5c)
    #13 camlOpamFile.parser_main_3913 src/format/opamFile.ml:739 (main.exe+0x45f7b3)
    #14 camlOpamFile.of_string_4595 src/format/opamFile.ml:761 (main.exe+0x4635a1)
    #15 camlOpamFile.read_from_f_1529 src/format/opamFile.ml:172 (main.exe+0x45b74e)
    #16 camlDune__exe__Opam_lock.use_289 solutions/4-eio-multicore/opam_lock.ml:5 (main.exe+0x2e0f39)
    #17 camlDune__exe__Packages.read_package_4943 solutions/4-eio-multicore/packages.ml:51 (main.exe+0x2dfc39)
    ...
  Previous write of size 8 at 0x7f5a244d7ac8 by thread T2 (mutexes: write M81):
    #0 caml_ephe_clean runtime/weak.c:154 (main.exe+0x7d29b7)
    #1 caml_ephe_clean runtime/weak.c:173 (main.exe+0x7d3967)
    #2 ephe_sweep runtime/major_gc.c:1225 (main.exe+0x7beb42)
    #3 major_collection_slice runtime/major_gc.c:1684 (main.exe+0x7beb42)
```

This might be a bug in ocaml-tsan. We shouldn't be conflicting with the GC!
See https://github.com/google/sanitizers/wiki/ThreadSanitizerSuppressions for how to suppress warnings.
For example:

```
# The GC isn't our problem:
race:caml_major_collection_slice

# Suppressions aren't reliable if there's no stack
race:failed to restore the stack
```

## Performance

OK, let's see how much faster it is with 3 workers rather than 1!
(don't forget to switch back to the regular switch; tsan is really slow)

Testing on my Framework laptop, I get:

```
+Finished in 4.56 s         # Single-core, cold cache
+Finished in 5.46 s         # Three cores, cold cache
```

Hmm. It's about a second slower.

BUT that's in the cold-cache case where we're spending most of the time loading and parsing opam files,
which can't be done in parallel as we saw above. But running the tests again without restarting the solver,
we see the benefit:

```
+Finished in 1.29 s     # Single-core, warm cache
+Finished in 0.64 s     # Three cores, warm cache
```

About twice as fast!

However, Jon's macbook gets more reasonable results:
```
                  warm  cold
2-lwt-eio       : 6.24, 1.53
3-eio           : 6.06, 1.51
4-eio-multicore : 5.21, 0.55
```

If you get unexpected performance problems, there are several tools that might prove useful:

## Magic-trace

If you have a supported system, [magic-trace][] is a useful tracing tool. Run with:
```sh
magic-trace run -multi-thread  _build/default/service/main.exe -- ../opam-repository -v 
```
Then view the results at https://magic-trace.org/.

However, magic-trace can only report the last few ms of execution.
We see most threads are just waiting to be woken up (presumably they are waiting for a mutex).

## Olly

OCaml 5.1 adds support for custom events, which can be useful to see what an Eio program is doing.
However, 5.1 hasn't been released yet and so the required support hasn't been merged yet.

To try it, you'd need to apply [Eio PR#554](https://github.com/ocaml-multicore/eio/pull/554) to generate
events, turn on tracing in Eio, and use a patched version of the [olly][] tool:

```
opam pin runtime_events_tools 'https://github.com/TheLortex/runtime_events_tools.git#custom-events-without-eio'
```

However, there are some bugs that make this less useful at the moment;
e.g. you'll need to find a fix for https://github.com/tarides/runtime_events_tools/issues/20.

## Flame graphs

The `offcputime` tool records when an OS thread is suspended and resumed.
This can be used to see how much time is being spent waiting.
For example:

```
apt install bpfcc-tools
sudo /usr/sbin/offcputime-bpfcc -df -p (pgrep -f server/main.exe) 2 > out.stacks
```

Again, this shows a large amount of time waiting for mutexes.

See: https://www.brendangregg.com/flamegraphs.html


[olly]: https://github.com/tarides/runtime_events_tools
[magic-trace]: https://github.com/janestreet/magic-trace
