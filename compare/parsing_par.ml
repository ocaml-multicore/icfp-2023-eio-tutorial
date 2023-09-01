(* Like "parsing.ml", but doing parallel reads. *)

let n_bytes = 100_000_000
let n_parallel = 4

let time label fn =
  let t0 = Unix.gettimeofday () in
  fn ();
  let t1 = Unix.gettimeofday () in
  Fmt.pr "%s took %.2f s@." label (t1 -. t0)

module Example_eio = struct
  open Eio.Std

  let parse r =
    for _ = 1 to n_bytes do
      let r = Eio.Buf_read.any_char r in
      ignore (r : char)
    done

  let par_do domain_mgr n fn =
    Switch.run @@ fun sw ->
    for _ = 1 to n - 1 do
      Fiber.fork ~sw (fun () -> Eio.Domain_manager.run domain_mgr fn)
    done;
    fn ()       (* Use the original domain for the last one *)

  let run () =
    let ( / ) = Eio.Path.( / ) in
    Eio_main.run @@ fun env ->
    par_do env#domain_mgr n_parallel @@ fun () ->
    Eio.Path.with_open_in (env#fs / "/dev/zero") @@ fun zero ->
    parse (Eio.Buf_read.of_flow ~max_size:max_int zero)
end

module Example_lwt = struct
  open Lwt.Syntax

  let parse stream =
    let rec aux = function
      | 0 -> Lwt.return_unit
      | i ->
        let* r = Lwt_io.read_char stream in
        ignore (r : char);
        aux (i - 1)
    in
    aux n_bytes

  let run () =
    Lwt_main.run begin
      Lwt.join @@ List.init n_parallel (fun _ -> Lwt_io.(with_file ~mode:input) "/dev/zero" parse)
    end
end

let () =
  time "Eio" Example_eio.run;
  time "Lwt" Example_lwt.run;
  time "Eio" Example_eio.run;
  time "Lwt" Example_lwt.run
