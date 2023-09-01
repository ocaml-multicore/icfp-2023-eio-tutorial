open Lwt.Infix

module Request = Cohttp.Request
module Server = Cohttp_lwt_unix.Server

let parse_request req =
  let uri = Request.uri req in
  let path =
    uri
    |> Uri.path
    |> String.split_on_char '/'
    |> List.filter ((<>) "")
  in
  match Request.meth req, path with
  | `GET, [] -> `Main
  | `GET, ["solve"; commit; pkg] ->
    let pkg = OpamPackage.Name.of_string pkg in
    let commit = Git_unix.Store.Hash.of_hex commit in
    begin match Uri.get_query_param uri "ocaml_version" with
      | Some v ->
        let ocaml_version = (`Eq, OpamPackage.Version.of_string v) in
        `Solve { Solver.pkg; commit; ocaml_version }
      | None -> `Bad_request "Missing ocaml_version"
    end;
  | _, _ -> `Not_found

let main ~port opam_repo =
  Log.info (fun f -> f "Starting server...");
  Git_unix.Store.v (Fpath.v opam_repo) >>= function
  | Error e -> Fmt.failwith "Can't open Git store %S: %a" opam_repo Git_unix.Store.pp_error e
  | Ok store ->
    let solver = Solver.create store in
    let callback _conn req _body =
      match parse_request req with
      | `Main -> Server.respond_string ~status:`OK ~body:"Usage: GET /solve/COMMIT/PKG?ocaml_version=VERSION" ()
      | `Not_found -> Server.respond_string ~status:`Not_found ~body:"Not found" ()
      | `Bad_request msg -> Server.respond_string ~status:`Bad_request ~body:msg ()
      | `Solve request ->
        Solver.solve solver request >>= function
        | Ok selection ->
          let body = selection |> List.map OpamPackage.to_string |> String.concat " " in
          Server.respond_string ~status:`OK ~body ()
        | Error msg ->
          Server.respond_string ~status:`OK ~body:msg ()
    in
    let server = Server.create ~mode:(`TCP (`Port port)) (Server.make ~callback ()) in
    Fmt.pr "Server listening on TCP port %d@." port;
    server

(* Command-line interface *)

let setup_log style_renderer level =
  Fmt_tty.setup_std_outputs ?style_renderer ();
  Logs.set_level level;
  Logs.set_reporter (Logs_fmt.reporter ());
  ()

open Cmdliner

let setup_log =
  Term.(const setup_log $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let port =
  Arg.value @@
  Arg.opt Arg.int 8080 @@
  Arg.info
    ~doc:"The port to listen on"
    ~docv:"PORT"
    ["port"]

let opam_dir =
  Arg.required @@
  Arg.pos 0 Arg.(some dir) None @@
  Arg.info
    ~doc:"The path of an opam-repository clone"
    ~docv:"DIR"
    []

let () =
  let info = Cmd.info "solver service" in
  let main () port opam_repo =
    Lwt_main.run (main ~port opam_repo)
  in
  exit @@ Cmd.eval @@ Cmd.v info
    Term.(const main $ setup_log $ port $ opam_dir)
