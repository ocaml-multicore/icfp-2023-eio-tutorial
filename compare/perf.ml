[@@@warning "-A"]
(* Two threads use a lot of CPU time in a loop.

   Profiling using e.g. "perf record --call-graph=dwarf" gives more useful results for Eio,
   since the stack includes which task was running.
*)

let outer_iters = 2_000
let inner_iters = 2_000

let use_cpu () =
  for _ = 1 to inner_iters do
    ignore @@ Sys.opaque_identity @@ Digest.string "Hello!"
  done

module Example_eio = struct
  open Eio.Std

  let do_work () =
    Fiber.yield ();
    use_cpu ()
  [@@inline never]

  let run_task1 () =
    for _ = 1 to outer_iters do do_work () done

  let run_task2 () =
    for _ = 1 to outer_iters do do_work () done

  let run () =
    Eio_main.run @@ fun _ ->
    Fiber.both run_task1 run_task2
end

module Example_lwt = struct
  open Lwt.Syntax

  let do_work () =
    let* () = Lwt.pause () in
    use_cpu ();
    Lwt.return_unit
  [@@inline never]

  let run_task1 () =
    let rec outer = function
      | 0 -> Lwt.return_unit
      | i ->
        let* () = do_work () in
        outer (i - 1)
    in
    outer outer_iters

  let run_task2 () =
    let rec outer = function
      | 0 -> Lwt.return_unit
      | i ->
        let* () = do_work () in
        outer (i - 1)
    in
    outer outer_iters

  let run () =
    Lwt_main.run begin
      Lwt.join [
        run_task1 ();
        run_task2 ();
      ]
    end
end

let time label fn =
  let t0 = Unix.gettimeofday () in
  fn ();
  let t1 = Unix.gettimeofday () in
  Fmt.pr "%s took %.2f s@." label (t1 -. t0)

let () =
  time "Eio" Example_eio.run;
  time "Lwt" Example_lwt.run;
  time "Eio" Example_eio.run;
  time "Lwt" Example_lwt.run
