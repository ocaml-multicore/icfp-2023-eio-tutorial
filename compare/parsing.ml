(* Parse a load of data from /dev/zero, one character at a time.

   This is much faster with Eio, as Lwt pays the cost of possibly
   having to suspend for every byte, even though the data is usually
   buffered.

   Note: This isn't a very realistic workload and typically the
   difference between Lwt and Eio will be smaller.
*)

let n_bytes = 100_000_000

let buffer_size = 4096          (* Ensure Lwt and Eio are using the same size buffer *)

let time label fn =
  let t0 = Unix.gettimeofday () in
  fn ();
  let t1 = Unix.gettimeofday () in
  Fmt.pr "%s took %.2f s@." label (t1 -. t0)

module Example_eio = struct
  let parse r =
    for _ = 1 to n_bytes do
      let r = Eio.Buf_read.any_char r in
      ignore (r : char)
      (* assert (r = '\x00') *)
    done

  let run () =
    let ( / ) = Eio.Path.( / ) in
    Eio_main.run @@ fun env ->
    Eio.Path.with_open_in (env#fs / "/dev/zero") @@ fun zero ->
    parse (Eio.Buf_read.of_flow zero ~initial_size:buffer_size ~max_size:buffer_size)
end

module Example_lwt = struct
  open Lwt.Syntax

  let parse stream =
    let rec aux = function
      | 0 -> Lwt.return_unit
      | i ->
        let* r = Lwt_io.read_char stream in
        ignore (r : char);
        (* assert (r = '\x00'); *)
        aux (i - 1)
    in
    aux n_bytes

  let run () =
    Lwt_main.run begin
      let buffer = Lwt_bytes.create buffer_size in
      Lwt_io.(with_file ~buffer ~mode:input) "/dev/zero" @@ fun zero ->
      parse zero
    end
end

let () =
  time "Eio" Example_eio.run;
  time "Lwt" Example_lwt.run;
  time "Eio" Example_eio.run;
  time "Lwt" Example_lwt.run
