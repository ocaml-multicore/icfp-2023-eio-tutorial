(* This module is used by the solver to get the candiate versions of each packages. *)

type rejection =
  | UserConstraint of OpamFormula.atom
  | Unavailable

type t = {
  env : string -> OpamVariable.variable_contents option;
  packages : Packages.t;
  constraints : OpamFormula.version_constraint OpamTypes.name_map;    (* User-provided constraints *)
}

let user_restrictions t name =
  OpamPackage.Name.Map.find_opt name t.constraints

let dev = OpamPackage.Version.of_string "dev"

let env t pkg v =
  if List.mem v OpamPackageVar.predefined_depends_variables then None
  else match OpamVariable.Full.to_string v with
    | "version" -> Some (OpamTypes.S (OpamPackage.Version.to_string (OpamPackage.version pkg)))
    | x -> t.env x

let filter_deps t pkg f =
  Opam_lock.use @@ fun () ->
  let dev = OpamPackage.Version.compare (OpamPackage.version pkg) dev = 0 in
  f
  |> OpamFilter.partial_filter_formula (env t pkg)
  |> OpamFilter.filter_deps ~build:true ~post:true ~test:false ~doc:false ~dev ~default:false

let candidates t name =
  let user_constraints = user_restrictions t name in
  Packages.get_versions t.packages name
  |> OpamPackage.Version.Map.bindings
  |> List.rev
  |> List.map (fun (v, opam) ->
      match user_constraints with
      | Some test when not (OpamFormula.check_version_formula (OpamFormula.Atom test) v) ->
        v, Error (UserConstraint (name, Some test))
      | _ ->
        let pkg = OpamPackage.create name v in
        let available = OpamFile.OPAM.available opam in
        match OpamFilter.eval_to_bool ~default:false (env t pkg) available with
        | true -> v, Ok opam
        | false -> v, Error Unavailable
    )

let pp_rejection f = function
  | UserConstraint x -> Fmt.pf f "Rejected by user-specified constraint %s" (OpamFormula.string_of_atom x)
  | Unavailable -> Fmt.string f "Availability condition not satisfied"

let create ~constraints ~env packages =
  { env; packages; constraints }
