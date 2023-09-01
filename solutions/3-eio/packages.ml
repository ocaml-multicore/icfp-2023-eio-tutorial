open Eio.Std

module Store = Git_eio.Store
module Search = Git_eio.Search.Make (Digestif.SHA1) (Store)

type candidates = OpamFile.OPAM.t OpamPackage.Version.Map.t Eio.Lazy.t

type t = candidates OpamPackage.Name.Map.t

(* Load a Git directory tree from the store by hash. *)
let read_dir store hash =
  match Store.read store hash with
  | Error e -> Fmt.failwith "Failed to read tree: %a" Store.pp_error e
  | Ok (Git_eio.Value.Tree tree) -> Some tree
  | Ok _ -> None

(* Load [pkg]'s opam file from its directory. *)
let read_package store pkg hash =
  match Search.find store hash (`Path [ "opam" ]) with
  | None ->
    Fmt.failwith "opam file not found for %s" (OpamPackage.to_string pkg)
  | Some hash -> (
      match Store.read store hash with
      | Ok (Git_eio.Value.Blob blob) ->
        let blob = Store.Value.Blob.to_string blob in
        begin
          try OpamFile.OPAM.read_from_string blob
          with ex ->
            Fmt.failwith "Error parsing %s: %s" (OpamPackage.to_string pkg) (Printexc.to_string ex)
        end
      | _ ->
        Fmt.failwith "Bad Git object type for %s!" (OpamPackage.to_string pkg)
    )

(* Get a map of the versions inside [entry] (an entry under "packages") *)
let read_versions store (entry : Store.Value.Tree.entry) =
  match read_dir store entry.node with
  | None -> OpamPackage.Version.Map.empty
  | Some tree ->
    Store.Value.Tree.to_list tree
    |> Fiber.List.filter_map (fun (entry : Store.Value.Tree.entry) ->
        match OpamPackage.of_string_opt entry.name with
        | Some pkg ->
          let opam = read_package store pkg entry.node in
          Some (pkg.version, opam)
        | None ->
          Log.info (fun f -> f "Invalid package name %S" entry.name);
          None
      )
    |> OpamPackage.Version.Map.of_list

let read_packages ~store tree =
  Store.Value.Tree.to_list tree
  |> List.filter_map (fun (entry : Store.Value.Tree.entry) ->
      match OpamPackage.Name.of_string entry.name with
      | exception ex ->
        Log.warn (fun f -> f "Invalid package name %S: %a" entry.name Fmt.exn ex);
        None
      | name ->
        Some (name, Eio.Lazy.from_fun ~cancel:`Restart (fun () -> read_versions store entry))
    )
  |> OpamPackage.Name.Map.of_list

let of_commit store commit : t =
  match Search.find store commit (`Commit (`Path [ "packages" ])) with
  | None -> Fmt.failwith "Failed to find packages directory!"
  | Some tree_hash ->
    match read_dir store tree_hash with
    | None -> Fmt.failwith "'packages' is not a directory!"
    | Some tree -> read_packages ~store tree

let get_versions (t:t) name =
  match OpamPackage.Name.Map.find_opt name t with
  | None -> OpamPackage.Version.Map.empty
  | Some versions -> Eio.Lazy.force versions
