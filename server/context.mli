include Opam_0install.S.CONTEXT

val create :
  constraints:OpamFormula.version_constraint OpamTypes.name_map ->
  env:(string -> OpamVariable.variable_contents option) ->
  Packages.t ->
  t
(** [create ~constraints ~env packages] loads information about candidate packages from [packages],
    sorts and filters them, and provides them to the solver.
    
    @param constraints Allows filtering out candidates before they get to the solver.
    @param env Details about the target platform. *)
