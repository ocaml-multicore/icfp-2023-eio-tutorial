open Eio.Std

module Request = Cohttp.Request
module Server = Cohttp_eio.Server

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
    let commit = Git_eio.Store.Hash.of_hex commit in
    begin match Uri.get_query_param uri "ocaml_version" with
      | Some v ->
        let ocaml_version = (`Eq, OpamPackage.Version.of_string v) in
        `Solve { Solver.pkg; commit; ocaml_version }
      | None -> `Bad_request "Missing ocaml_version"
    end;
  | _, _ -> `Not_found

let main ~socket opam_repo =
  Log.info (fun f -> f "Starting server...");
  match Git_eio.Store.v opam_repo with
  | Error e -> Fmt.failwith "Can't open Git store %a: %a" Eio.Path.pp opam_repo Git_eio.Store.pp_error e
  | Ok store ->
    let solver = Solver.create store in
    let callback _conn req _body =
      match parse_request req with
      | `Main -> Server.respond_string ~status:`OK ~body:"Usage: GET /solve/COMMIT/PKG?ocaml_version=VERSION" ()
      | `Not_found -> Server.respond_string ~status:`Not_found ~body:"Not found" ()
      | `Bad_request msg -> Server.respond_string ~status:`Bad_request ~body:msg ()
      | `Solve request ->
        match Solver.solve solver request with
        | Ok selection ->
          let body = selection |> List.map OpamPackage.to_string |> String.concat " " in
          Server.respond_string ~status:`OK ~body ()
        | Error msg ->
          Server.respond_string ~status:`OK ~body:msg ()
    in
    let on_error ex =
      let bt = Printexc.get_raw_backtrace () in
      Log.warn (fun f -> f "%a" Fmt.exn_backtrace (ex, bt))
    in
    Server.run ~on_error socket (Server.make ~callback ())

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

let ( / ) = Eio.Path.( / )

let () =
  let info = Cmd.info "solver service" in
  let main () port opam_repo =
    Eio_main.run @@ fun env ->
    Switch.run @@ fun sw ->
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    let socket = Eio.Net.listen ~sw ~backlog:5 ~reuse_addr:true env#net addr in
    traceln "Server listening on TCP port %d" port;
    Eio.Path.with_open_dir (env#fs / opam_repo) @@ fun opam_repo ->
    main ~socket opam_repo
  in
  exit @@ Cmd.eval @@ Cmd.v info
    Term.(const main $ setup_log $ port $ opam_dir)
