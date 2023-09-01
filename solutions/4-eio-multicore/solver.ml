module Solver = Opam_0install.Solver.Make(Context)

type t = {
  store : Git_eio.Store.t;
  pool : Worker_pool.t;
  mutable packages_cache : (Git_eio.Store.Hash.t * Packages.t Eio.Lazy.t) option;
}

type request = {
  pkg : OpamPackage.Name.t;
  commit : Git_eio.Store.Hash.t;
  ocaml_version : OpamFormula.version_constraint;
}

let std_env
    ?(ocaml_native=true)
    ?sys_ocaml_version
    ?opam_version
    ~arch ~os ~os_distribution ~os_family ~os_version
    () =
  function
  | "arch" -> Some (OpamTypes.S arch)
  | "os" -> Some (OpamTypes.S os)
  | "os-distribution" -> Some (OpamTypes.S os_distribution)
  | "os-version" -> Some (OpamTypes.S os_version)
  | "os-family" -> Some (OpamTypes.S os_family)
  | "opam-version"  -> Some (OpamVariable.S (Option.value ~default:OpamVersion.(to_string current) opam_version))
  | "sys-ocaml-version" -> sys_ocaml_version |> Option.map (fun v -> OpamTypes.S v)
  | "ocaml:native" -> Some (OpamTypes.B ocaml_native)
  | "enable-ocaml-beta-repository" -> None      (* Fake variable? *)
  | v ->
    OpamConsole.warning "Unknown variable %S" v;
    None

let ocaml = OpamPackage.Name.of_string "ocaml"

let packages t commit =
  match t.packages_cache with
  | Some (c, p) when Git_eio.Store.Hash.equal c commit -> Eio.Lazy.force p
  | _ ->
    let p = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
        Log.info (fun f -> f "Loading packages...");
        let pkgs = Packages.of_commit t.store commit in
        Log.info (fun f -> f "Loaded packages");
        pkgs
      ) in
    t.packages_cache <- Some (commit, p);
    Eio.Lazy.force p

let solve t { pkg; commit; ocaml_version } =
  let env = std_env ()
              ~os:"linux"
              ~os_family:"debian"
              ~os_distribution:"debian"
              ~os_version:"12"
              ~arch:"x86_64"
  in
  let packages = packages t commit in
  let constraints = OpamPackage.Name.Map.singleton ocaml ocaml_version in
  let ctx = Context.create ~env ~constraints packages in
  Worker_pool.submit t.pool @@ fun () -> 
  match Solver.solve ctx [pkg] with
  | Ok x -> Ok (Solver.packages_of_result x)
  | Error e -> Error (Solver.diagnostics e)
  | exception ex -> Fmt.epr "Solver: %a@." Fmt.exn ex; raise ex

let create ~pool store = { pool; store; packages_cache = None }
