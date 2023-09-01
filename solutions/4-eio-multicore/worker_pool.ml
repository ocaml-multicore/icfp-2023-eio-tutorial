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
