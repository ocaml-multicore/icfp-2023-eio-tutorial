(** Loads opam package metadata from an opam-respository commit. *)

type t
(** A particular commit of opam-repository. *)

val of_commit : Git_unix.Store.t -> Git_unix.Store.Hash.t -> t
(** [of_commit store hash] provides the packages at commit [hash] in [store]. *)

val get_versions : t -> OpamPackage.Name.t -> OpamFile.OPAM.t OpamPackage.Version.Map.t
(** [get_versions t pkg] returns all available versions of [pkg] in [t]. *)
