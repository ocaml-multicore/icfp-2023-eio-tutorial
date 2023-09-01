(* This example runs two tasks concurrently:

   - "task1" waits for a network connection.
   - "task2" raises an exception.

   Eio cancels task1 and reports the exception immediately.
   Lwt waits for a connection before reporting the error.

   Also, the backtrace from Eio is more useful; we can see that [simulated_error] was
   called from [task2]:

   Exception: Not_found
   Raised at Dune__exe__Errors.Example_eio.simulated_error in file "compare/errors.ml", line 25, characters 6-21
   Called from Dune__exe__Errors.Example_eio.run_task2 in file "compare/errors.ml", line 31, characters 4-22

   Lwt instead shows [simulated_error] being called from the Lwt engine:

   Exception: Not_found
   Raised at Dune__exe__Errors.Example_lwt.simulated_error.(fun) in file "compare/errors.ml", line 58, characters 6-21
   Called from Lwt.Sequential_composition.bind.create_result_promise_and_callback_if_deferred.callback in file "src/core/lwt.ml", line 1829, characters 23-26
   Re-raised at Lwt.Miscellaneous.poll in file "src/core/lwt.ml", line 3059, characters 20-29

   Also, Eio closes both FDs, even in the cancelled path.
*)

let () = Printexc.record_backtrace true

let simulate_error = true

module Example_eio = struct
  open Eio.Std

  let run_task1 net =
    traceln "Running task1 (wait for connection on port 8081)...";
    Switch.run @@ fun sw ->
    let socket = Eio.Net.listen ~sw ~backlog:5 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 8081)) in
    let conn, _addr = Eio.Net.accept ~sw socket in
    Eio.Net.close conn;
    traceln "Task1 done"

  let simulated_error () =
    Fiber.yield ();
    if simulate_error then (
      traceln "Raising exception...";
      raise Not_found
    )

  let run_task2 () =
    traceln "Running task2...";
    simulated_error ();
    traceln "Task2 done"

  let run () =
    Eio_main.run @@ fun env ->
    Fiber.both
      (fun () -> run_task1 env#net)
      (fun () -> run_task2 ())
end

module Example_lwt = struct
  open Lwt.Syntax

  let run_task1 () =
    print_endline "Running task1 (wait for connection on port 8082)...";
    let socket = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
    Lwt_unix.setsockopt socket SO_REUSEADDR true;
    let* () = Lwt_unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_any, 8082)) in
    Lwt_unix.listen socket 5;
    let* conn, _addr = Lwt_unix.accept socket in
    let* () = Lwt_unix.close conn in
    print_endline "Task1 done";
    Lwt.return_unit

  let simulated_error () =
    let* () = Lwt.pause () in
    if simulate_error then (
      print_endline "Raising exception... (won't appear until you connect to port 8082)";
      raise Not_found
    ) else Lwt.return_unit

  let run_task2 () =
    print_endline "Running task2...";
    let* () = simulated_error () in
    print_endline "Task2 done";
    Lwt.return_unit

  let run () =
    Lwt_main.run begin
      Lwt.join [
        run_task1 ();
        run_task2 ();
      ]
    end
end

let test fn =
  try fn ()
  with ex ->
    let bt = Printexc.get_raw_backtrace () in
    Fmt.epr "Example finished with exception:@.%a@." Fmt.exn_backtrace (ex, bt)

let () =
  Fmt.pr "Running Eio example...@.";
  test Example_eio.run;
  Fmt.pr "@.Running Lwt example...@.";
  test Example_lwt.run
