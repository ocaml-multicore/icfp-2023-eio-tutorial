(* A simple HTTP client to test the server. It sends 3 solver requests concurrently. *)

open Eio.Std

let solve_url ~commit ~ocaml_version pkg =
  Uri.of_string (Printf.sprintf "http://127.0.0.1:8080/solve/%s/%s?ocaml_version=%s" commit pkg ocaml_version)

let solve http ~ocaml_version ~commit pkg =
  Switch.run @@ fun sw ->
  let uri = solve_url ~commit ~ocaml_version pkg in
  traceln "Requesting %a" Uri.pp uri;
  let resp, body = Cohttp_eio.Client.get ~sw http uri in
  if resp.status = `OK then (
    Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int
  ) else (
    Fmt.failwith "Error from server: %s" (Cohttp.Code.string_of_status resp.status)
  )

let commit = "9faf3dbf816f376733b73f3ed8832c4213db4a02"
let requests =
  ["4.02.0", "lwt";
   "4.14.0", "lwt";
   "5.0.0", "lwt"]

let () =
  Eio_main.run @@ fun env ->
  let http = Cohttp_eio.Client.make env#net in
  let t0 = Unix.gettimeofday () in
  requests |> Fiber.List.iter (fun (ocaml_version, package) ->
      let solution = solve http ~commit ~ocaml_version package in
      traceln "%s : %s" ocaml_version solution
    );
  let t1 = Unix.gettimeofday () in
  traceln "Finished in %.2f s" (t1 -. t0)
